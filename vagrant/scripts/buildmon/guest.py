"""Read-only, timeout-bounded guest probe. Never raises; failures are soft."""
from __future__ import annotations
import base64
import http.client
import re
import socket
import subprocess
from xml.etree import ElementTree

ALLOWED_SSH = ("cat /proc/loadavg", "uptime -s", "systemctl is-active winrm")

_BOOT_RES = (
    re.compile(r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})"),  # uptime -s / ISO
    re.compile(r"^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\."),        # CIM datetime
)


def parse_boot_time(text):
    """Normalize a boot timestamp to YYYY-MM-DDTHH:MM:SS, or None."""
    text = (text or "").strip()
    for rx in _BOOT_RES:
        m = rx.match(text)
        if m:
            y, mo, d, h, mi, s = m.groups()
            return f"{y}-{mo}-{d}T{h}:{mi}:{s}"
    return None


def tcp_reachable(ip, port, timeout_s=3, connector=None):
    """True iff a TCP connection to ip:port opens within timeout. Never raises."""
    connector = connector or socket.create_connection
    try:
        sock = connector((ip, int(port)), timeout=timeout_s)
        sock.close()
        return True
    except OSError:
        return False


# One-shot WSMan Enumerate (read-only: never Create/Command/Signal). Basic
# auth over the lab's plain-HTTP WinRM (the same transport ansible uses,
# per the rendered inventory). Guests that disable Basic post-hardening
# make this soft-fail; TCP reachability still stands.
_WSMAN_ENUM_BODY = """<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing"
 xmlns:w="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd"
 xmlns:n="http://schemas.xmlsoap.org/ws/2004/09/enumeration">
 <s:Header>
  <a:To>http://{ip}:{port}/wsman</a:To>
  <a:ReplyTo><a:Address s:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address></a:ReplyTo>
  <a:Action s:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2004/09/enumeration/Enumerate</a:Action>
  <w:ResourceURI s:mustUnderstand="true">http://schemas.microsoft.com/wbem/wsman/1/wmi/root/cimv2/*</w:ResourceURI>
  <w:MaxEnvelopeSize s:mustUnderstand="true">153600</w:MaxEnvelopeSize>
  <a:MessageID>uuid:11111111-2222-3333-4444-{ip_hex}</a:MessageID>
  <w:OperationTimeout>PT10S</w:OperationTimeout>
 </s:Header>
 <s:Body>
  <n:Enumerate>
   <w:OptimizeEnumeration/>
   <w:MaxElements>1</w:MaxElements>
   <w:Filter Dialect="http://schemas.microsoft.com/wbem/wsman/1/WQL">SELECT LastBootUpTime FROM Win32_OperatingSystem</w:Filter>
  </n:Enumerate>
 </s:Body>
</s:Envelope>"""


def winrm_last_boot(ip, port, user, password, timeout_s=10, http_factory=None):
    """(last_boot, note) via one read-only WSMan WQL enumerate. Never raises."""
    factory = http_factory or (lambda i, p, timeout: http.client.HTTPConnection(i, p, timeout=timeout))
    ip_hex = "".join(f"{int(o):02x}" for o in ip.split(".")).ljust(12, "0")[:12]
    body = _WSMAN_ENUM_BODY.format(ip=ip, port=port, ip_hex=ip_hex)
    auth = base64.b64encode(f"{user}:{password}".encode()).decode()
    try:
        conn = factory(ip, port, timeout=timeout_s)
        conn.request("POST", "/wsman", body, {
            "Content-Type": "application/soap+xml;charset=UTF-8",
            "Authorization": "Basic " + auth,
        })
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
    except Exception as exc:
        return None, f"winrm probe error: {type(exc).__name__}"
    if resp.status != 200:
        return None, f"winrm http {resp.status}"
    try:
        for el in ElementTree.fromstring(data).iter():
            if el.tag.split("}")[-1] == "LastBootUpTime":
                txt = (el.text or "").strip() or "".join((c.text or "") for c in el)
                return parse_boot_time(txt), None
    except ElementTree.ParseError:
        return None, "winrm response not xml"
    return None, "winrm response lacked LastBootUpTime"


def _default_runner(argv, timeout):
    p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    out = p.stdout if p.stdout.strip() else p.stderr
    return (p.returncode, out)

class GuestProber:
    def __init__(self, vm, transport, target, runner=None, timeout_s=10, connector=None, http_factory=None):
        self.vm = vm
        self.transport = transport
        self.target = target
        self.runner = runner or _default_runner
        self.timeout_s = timeout_s
        self.connector = connector
        self.http_factory = http_factory

    def _argv(self):
        # Only reachable for ssh: probe() early-returns for every winrm target
        # (with or without ip/port) before this is ever called.
        host = self.target.get("host", self.vm)
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, ALLOWED_SSH[0]]

    def probe(self):
        base = {"reachable": False, "last_boot": None, "pending_reboot": None,
                "cpu_pct": None, "mem_pct": None, "note": None}
        ip, port = self.target.get("ip"), self.target.get("port")
        if ip and port:
            base["reachable"] = tcp_reachable(ip, port, timeout_s=self.timeout_s, connector=self.connector)
            if base["reachable"] and self.transport == "ssh" and self.target.get("key"):
                argv = ["ssh", "-i", self.target["key"],
                        "-o", "BatchMode=yes",
                        "-o", "StrictHostKeyChecking=no",
                        "-o", "UserKnownHostsFile=/dev/null",
                        "-o", "ConnectTimeout=5",
                        f"{self.target.get('user', 'vagrant')}@{ip}",
                        "uptime -s"]
                try:
                    rc, out = self.runner(argv, self.timeout_s)
                except Exception as exc:
                    base["note"] = f"ssh probe error: {type(exc).__name__}"
                    return base
                if rc == 0:
                    base["last_boot"] = parse_boot_time(out)
                else:
                    base["note"] = (out or "ssh nonzero exit").strip()[:80]
            elif base["reachable"] and self.transport == "winrm" and self.target.get("password"):
                base["last_boot"], note = winrm_last_boot(
                    ip, port, self.target.get('user', 'vagrant'),
                    self.target["password"], timeout_s=self.timeout_s,
                    http_factory=self.http_factory)
                if note:
                    base["note"] = note
            return base
        if self.transport == "winrm":
            base["note"] = "winrm probe not wired (cred follow-up)"
            return base
        try:
            rc, out = self.runner(self._argv(), self.timeout_s)
        except subprocess.TimeoutExpired:
            base["note"] = "probe timed out"
            return base
        except Exception as exc:  # never raise out of a probe
            base["note"] = f"probe error: {type(exc).__name__}"
            return base
        if rc != 0:
            base["note"] = (out or "nonzero exit").strip()[:80]
            return base
        base["reachable"] = True
        return base
