import os, sys, subprocess, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import guest  # noqa: E402
from guest import GuestProber  # noqa: E402

class TestGuestProber(unittest.TestCase):
    def test_ssh_success(self):
        def runner(argv, timeout):
            return (0, "0.15 0.20 0.10 1/200 12345")   # /proc/loadavg-ish
        g = GuestProber("acme1", "ssh", {"host": "acme1"}, runner=runner)
        r = g.probe()
        self.assertTrue(r["reachable"])
        self.assertIsNone(r["note"])

    def test_timeout_is_soft(self):
        def runner(argv, timeout):
            raise subprocess.TimeoutExpired(cmd=argv, timeout=timeout)
        g = GuestProber("dc1", "ssh", {"host": "dc1"}, runner=runner)
        r = g.probe()
        self.assertFalse(r["reachable"])
        self.assertEqual(r["note"], "probe timed out")

    def test_nonzero_is_soft(self):
        def runner(argv, timeout):
            return (255, "connection refused")
        g = GuestProber("dc1", "ssh", {"host": "dc1"}, runner=runner)
        r = g.probe()
        self.assertFalse(r["reachable"])
        self.assertIsNotNone(r["note"])

    def test_only_allowlisted_commands(self):
        seen = []
        def runner(argv, timeout):
            seen.append(argv)
            return (0, "ok")
        GuestProber("acme1", "ssh", {"host": "acme1"}, runner=runner).probe()
        joined = " ".join(seen[0])
        self.assertTrue(any(a in joined for a in ("uptime", "loadavg", "is-active")))

    def test_nonzero_note_carries_diagnostic_text(self):
        def runner(argv, timeout):
            return (255, "ssh: connect to host acme1 port 22: Connection refused")
        r = GuestProber("acme1", "ssh", {"host": "acme1"}, runner=runner).probe()
        self.assertFalse(r["reachable"])
        self.assertIn("Connection refused", r["note"])

    def test_winrm_soft_fails_until_wired(self):
        r = GuestProber("dc1", "winrm", {"host": "dc1"}).probe()
        self.assertFalse(r["reachable"])
        self.assertIn("not wired", r["note"])


class TestTcpLayer(unittest.TestCase):
    def test_tcp_reachable_true_on_connect(self):
        opened = []
        class _Sock:
            def close(self):
                opened.append("closed")
        self.assertTrue(guest.tcp_reachable(
            "192.168.59.10", 5985, connector=lambda addr, timeout: _Sock()))
        self.assertEqual(opened, ["closed"])

    def test_tcp_reachable_false_on_oserror(self):
        def _fail(addr, timeout):
            raise OSError("refused")
        self.assertFalse(guest.tcp_reachable("192.168.59.10", 5985, connector=_fail))

    def test_prober_with_ip_uses_tcp_for_reachable(self):
        p = guest.GuestProber("dc1", "winrm",
                              {"ip": "192.168.59.10", "port": 5985,
                               "user": "vagrant", "password": "vagrant"},
                              connector=lambda addr, timeout: type("S", (), {"close": lambda s: None})())
        r = p.probe()
        self.assertTrue(r["reachable"])

    def test_prober_without_ip_keeps_legacy_behavior(self):
        p = guest.GuestProber("web1", "winrm", {"host": "web1"})
        r = p.probe()
        self.assertFalse(r["reachable"])  # legacy placeholder path

    def test_prober_forwards_configured_timeout_to_tcp_reachable(self):
        seen_timeouts = []
        def _connector(addr, timeout):
            seen_timeouts.append(timeout)
            return type("S", (), {"close": lambda s: None})()
        p = guest.GuestProber("dc1", "winrm",
                              {"ip": "192.168.59.10", "port": 5985},
                              timeout_s=7, connector=_connector)
        p.probe()
        self.assertEqual(seen_timeouts, [7])


class TestBootTimeParse(unittest.TestCase):
    def test_uptime_s_format(self):
        self.assertEqual(guest.parse_boot_time("2026-07-05 18:00:01"),
                         "2026-07-05T18:00:01")

    def test_cim_datetime_format(self):
        self.assertEqual(guest.parse_boot_time("20260705180001.500000-300"),
                         "2026-07-05T18:00:01")

    def test_iso_format_passthrough(self):
        self.assertEqual(guest.parse_boot_time("2026-07-05T18:00:01Z"),
                         "2026-07-05T18:00:01")

    def test_garbage_returns_none(self):
        self.assertIsNone(guest.parse_boot_time("not a time"))
        self.assertIsNone(guest.parse_boot_time(""))

class TestSshProbe(unittest.TestCase):
    def _prober(self, runner):
        return guest.GuestProber(
            "ejbca1", "ssh",
            {"ip": "192.168.59.50", "port": 22, "user": "vagrant", "key": "/tmp/k"},
            runner=runner,
            connector=lambda addr, timeout: type("S", (), {"close": lambda s: None})())

    def test_ssh_last_boot_populated(self):
        seen = {}
        def runner(argv, timeout):
            seen["argv"] = argv
            return (0, "2026-07-05 18:00:01\n")
        r = self._prober(runner).probe()
        self.assertTrue(r["reachable"])
        self.assertEqual(r["last_boot"], "2026-07-05T18:00:01")
        self.assertIn("-i", seen["argv"])
        self.assertIn("/tmp/k", seen["argv"])
        self.assertIn("vagrant@192.168.59.50", seen["argv"])
        self.assertIn("uptime -s", seen["argv"])

    def test_ssh_failure_soft_keeps_tcp_reachable(self):
        r = self._prober(lambda argv, timeout: (255, "auth denied")).probe()
        self.assertTrue(r["reachable"])       # TCP still said yes
        self.assertIsNone(r["last_boot"])
        self.assertIn("auth denied", r["note"])

    def test_ssh_runner_exception_is_soft_failed(self):
        def runner(argv, timeout):
            raise OSError("connection reset")
        r = self._prober(runner).probe()
        self.assertTrue(r["reachable"])        # TCP result untouched
        self.assertIsNone(r["last_boot"])
        self.assertIn("OSError", r["note"])


_SOAP_OK = """<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:n="http://schemas.xmlsoap.org/ws/2004/09/enumeration"
 xmlns:w="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd"
 xmlns:p="http://schemas.microsoft.com/wbem/wsman/1/wmi/root/cimv2/Win32_OperatingSystem">
 <s:Body><n:EnumerateResponse><w:Items>
  <p:Win32_OperatingSystem><p:LastBootUpTime>20260705180001.500000-300</p:LastBootUpTime></p:Win32_OperatingSystem>
 </w:Items><w:EndOfSequence/></n:EnumerateResponse></s:Body></s:Envelope>"""


class _FakeResp:
    def __init__(self, status, body):
        self.status = status
        self._body = body.encode()
    def read(self):
        return self._body


class _FakeConn:
    last = None
    def __init__(self, status=200, body=_SOAP_OK):
        self._status, self._body = status, body
        _FakeConn.last = self
        self.requests = []
    def request(self, method, path, body, headers):
        self.requests.append((method, path, body, headers))
    def getresponse(self):
        return _FakeResp(self._status, self._body)
    def close(self):
        pass


class TestWinrmProbe(unittest.TestCase):
    def test_last_boot_parsed_from_soap(self):
        lb, note = guest.winrm_last_boot(
            "192.168.59.10", 5985, "vagrant", "vagrant",
            http_factory=lambda ip, port, timeout: _FakeConn())
        self.assertEqual(lb, "2026-07-05T18:00:01")
        self.assertIsNone(note)
        method, path, body, headers = _FakeConn.last.requests[0]
        self.assertEqual((method, path), ("POST", "/wsman"))
        self.assertTrue(headers["Authorization"].startswith("Basic "))
        self.assertIn("SELECT LastBootUpTime FROM Win32_OperatingSystem", body)

    def test_http_401_soft_fails(self):
        lb, note = guest.winrm_last_boot(
            "192.168.59.10", 5985, "vagrant", "bad",
            http_factory=lambda ip, port, timeout: _FakeConn(status=401, body=""))
        self.assertIsNone(lb)
        self.assertIn("401", note)

    def test_garbage_body_soft_fails(self):
        lb, note = guest.winrm_last_boot(
            "192.168.59.10", 5985, "vagrant", "vagrant",
            http_factory=lambda ip, port, timeout: _FakeConn(body="<not-xml"))
        self.assertIsNone(lb)
        self.assertIsNotNone(note)

    def test_prober_winrm_enriches_last_boot(self):
        p = guest.GuestProber(
            "dc1", "winrm",
            {"ip": "192.168.59.10", "port": 5985, "user": "vagrant", "password": "vagrant"},
            connector=lambda addr, timeout: type("S", (), {"close": lambda s: None})(),
            http_factory=lambda ip, port, timeout: _FakeConn())
        r = p.probe()
        self.assertTrue(r["reachable"])
        self.assertEqual(r["last_boot"], "2026-07-05T18:00:01")


if __name__ == "__main__":
    unittest.main()
