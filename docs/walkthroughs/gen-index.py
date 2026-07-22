#!/usr/bin/env python3
"""Generate INDEX.md — a deep-linked, learning-path-ordered navigator for the
Straylight lab walkthroughs.

Run it after adding or editing labs:

    python3 docs/walkthroughs/gen-index.py        # writes docs/walkthroughs/INDEX.md

Grouping is driven by the MODULES table below (mirrors README.md's module
catalog, foundations-to-advanced). Each lab is matched to exactly one module by
filename prefix; the script asserts full coverage so a new lab can never silently
fall out of the index.
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# (group, name, source, profile_hint, patterns)
#   patterns match labs/*-walkthrough.md stems (deep-linked here)
# Order matters: a lab is assigned to the FIRST module it matches.
MODULES = [
    # ── Trust lifecycle ──
    ("Trust lifecycle", "Revocation", "fixmycert", "stepca-only / ad-cs-two-tier", ["revocation-"]),
    ("Trust lifecycle", "AD CS Revocation (end-to-end)", "straylight", "ad-cs-two-tier", ["adcs-revocation"]),
    ("Trust lifecycle", "CAA records", "fixmycert", "stepca-only", ["caa-"]),
    # ── Automation ──
    ("Automation", "ACME extended", "fixmycert", "stepca-only / acme1", ["acme1-"]),
    ("Automation", "HTTP-01 automation", "fixmycert", "stepca-only / web1", ["http-01-"]),
    ("Automation", "DNS-PERSIST-01", "fixmycert", "stepca-only", ["dns-persist-01-", "dns-01-vs-", "acme-account-key-"]),
    # ── Operations ──
    ("Operations", "Failure scenarios", "fixmycert", "core / pqc-full", ["failure-"]),
    ("Operations", "AD CS category", "fixmycert", "ad-cs-two-tier", ["adcs-architecture", "adcs-templates", "adcs-autoenrollment"]),
    ("Operations", "AD CS functional test", "gradenegger.eu", "ad-cs-two-tier", ["adcs-functest-"]),
    ("Operations", "CRYPT_E_REVOCATION_OFFLINE", "gradenegger.eu", "ad-cs-two-tier", ["crl-offline-"]),
    ("Operations", "CERT_E_UNTRUSTEDCA", "gradenegger.eu", "ad-cs-two-tier", ["untrustedca-"]),
    ("Operations", "AD CS Template Flag Processing", "internal", "ad-cs-two-tier", ["template-flags-"]),
    ("Operations", "OpenSSL FIPS Compliance", "fixmycert", "apps1", ["openssl-fips-"]),
    ("Operations", "Code Signing", "fixmycert", "apps1 / manage1", ["code-signing-"]),
    ("Operations", "PKI Automation Gap", "fixmycert", "observe1 / scanner1", ["pki-automation-"]),
    ("Operations", "Java KeyStore", "fixmycert", "tomcat1", ["java-keystore-"]),
    ("Operations", "Web Server SSL Configuration", "fixmycert", "web1 / apps1", ["webserver-ssl-"]),
    ("Operations", "mTLS", "straylight", "pqc-full", ["mtls-"]),
    # ── Forward-looking & PQC ──
    ("Forward-looking & PQC", "PQC", "fixmycert", "pqc-full / pqc-linux", ["pqc-algorithms", "pqc-chimera-tls", "pqc-cbom-audit", "pqc-adcs-gap"]),
    ("Forward-looking & PQC", "PQC — Composite signatures (canary)", "straylight", "pqc-full", ["pqc-composite-"]),
    ("Forward-looking & PQC", "PQC — Cryptographic Message Syntax", "straylight", "pqc-full", ["cms"]),
    ("Forward-looking & PQC", "PQC — Cloudflare edge posture", "straylight", "scanner1", ["cloudflare-pqc"]),
]


def matches(stem, pat):
    """A lab stem matches a pattern if it equals the pattern or starts with it
    (prefix patterns end in '-'; exact stems do not)."""
    return stem == pat or stem.startswith(pat if pat.endswith("-") else pat + "-")


def title_of(path, stem):
    """First H1, trimmed to the concept (before the em-dash subtitle, sans
    'Walkthrough'). Falls back to a prettified stem."""
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("# "):
                    t = line[2:].strip()
                    t = re.split(r"\s+[—–-]\s+", t)[0].strip()
                    t = re.sub(r"\s+Walkthrough$", "", t).strip()
                    return t or stem
    except OSError:
        pass
    return stem.replace("-", " ").title()


def main():
    lab_paths = sorted(glob.glob(os.path.join(HERE, "labs", "*-walkthrough.md")))
    quizzes = {os.path.basename(p)[: -len("-quiz.md")] for p in glob.glob(os.path.join(HERE, "quizzes", "*-quiz.md"))}
    stems = [os.path.basename(p)[: -len("-walkthrough.md")] for p in lab_paths]

    assigned = {}  # stem -> module name
    by_module = {}  # module name -> [stems]
    for stem in stems:
        for group, name, src, prof, pats in MODULES:
            if any(matches(stem, p) for p in pats):
                assigned[stem] = name
                by_module.setdefault(name, []).append(stem)
                break

    orphans = [s for s in stems if s not in assigned]
    if orphans:
        sys.stderr.write("ERROR: labs not matched to any module (add a MODULES entry):\n")
        for o in orphans:
            sys.stderr.write(f"  - {o}\n")
        sys.exit(1)

    nist = sorted(glob.glob(os.path.join(HERE, "nist-labs", "*-walkthrough.md")))
    total = len(stems)

    # Only emit modules that actually have labs on disk — the catalog may be a
    # deliberate subset (e.g. example-only while the rest awaits verification).
    present = [m for m in MODULES if by_module.get(m[1])]

    # ── by-profile inversion ──
    by_profile = {}
    for group, name, src, prof, pats in present:
        if prof:
            by_profile.setdefault(prof, []).append(name)

    out = []
    w = out.append
    w("<!-- GENERATED by gen-index.py — do not edit by hand. Run: python3 docs/walkthroughs/gen-index.py -->")
    w("# Lab Index")
    w("")
    nist_note = f" (+ {len(nist)} NIST labs)" if nist else ""
    w(f"Deep-linked navigator for the **{total} lab walkthrough{'s' if total != 1 else ''}**{nist_note}, "
      "grouped by module in a foundations-to-advanced order. Each lab links its walkthrough "
      "and paired quiz.")
    w("")
    w("Generated from the files on disk — see [README.md](README.md) for the narrative catalog.")
    w("")
    w("## Start here")
    w("")
    groups_present = {m[0] for m in present}
    w("- **New to PKI?** Work top-down through the modules. Each lab pairs "
      "1:1 with an external guide (the guide teaches the concept; the lab makes you type the keystrokes).")
    w("- **Have a specific goal?** Jump via the table below — it maps each module to the "
      "`LAB_PROFILE` (or specific component) you need running.")
    if any("PQC" in g for g in groups_present):
        w("- **Just want PQC?** See the *Forward-looking & PQC* section.")
    w("")
    w("## By profile or component")
    w("")
    w("Which `LAB_PROFILE` — or specific host/component — a module's labs need running. "
      "Entries that name a host (e.g. `apps1`, `web1`, `scanner1`, `tomcat1`) are "
      "`LAB_COMPONENTS`, not `LAB_PROFILE` names; bring up a profile that includes that host "
      "(e.g. `full`).")
    w("")
    w("| Profile or component | Modules |")
    w("|---|---|")
    for prof in sorted(by_profile):
        w(f"| `{prof}` | {', '.join(by_profile[prof])} |")
    w("")
    w("## Modules")
    w("")

    last_group = None
    for group, name, src, prof, pats in present:
        if group != last_group:
            w(f"### {group}")
            w("")
            last_group = group
        head = f"#### {name}  ·  {src}"
        if prof:
            head += f"  ·  needs `{prof}`"
        w(head)
        w("")
        w("| Lab | Quiz |")
        w("|---|---|")
        for stem in sorted(by_module[name]):
            path = os.path.join(HERE, "labs", f"{stem}-walkthrough.md")
            title = title_of(path, stem)
            quiz = (f"[quiz](quizzes/{stem}-quiz.md)" if stem in quizzes else "—")
            w(f"| [{title}](labs/{stem}-walkthrough.md) | {quiz} |")
        w("")

    # ── NIST track (only when the nist-labs dir has content) ──
    if nist:
        w("### NIST track — SP 800-52 Rev 2 (TLS)")
        w("")
        w("Server/client TLS configuration against the NIST profile. Needs `ad-cs-two-tier` (or any "
          "TLS endpoint).")
        w("")
        w("| Lab | Quiz |")
        w("|---|---|")
        nq = {os.path.basename(p)[: -len("-quiz.md")] for p in glob.glob(os.path.join(HERE, "nist-quizzes", "*-quiz.md"))}
        for p in nist:
            stem = os.path.basename(p)[: -len("-walkthrough.md")]
            title = stem.replace("nist-800-52-", "").replace("-", " ").title()
            quiz = (f"[quiz](nist-quizzes/{stem}-quiz.md)" if stem in nq else "—")
            w(f"| [{title}](nist-labs/{stem}-walkthrough.md) | {quiz} |")
        w("")
    w("---")
    w("")
    nist_tail = f" + {len(nist)} NIST labs" if nist else ""
    w(f"_{total} lab{'s' if total != 1 else ''} across {len({m[1] for m in present})} "
      f"module{'s' if len(present) != 1 else ''}{nist_tail}. "
      "Regenerate with `python3 docs/walkthroughs/gen-index.py`._")

    text = "\n".join(out) + "\n"
    with open(os.path.join(HERE, "INDEX.md"), "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"Wrote INDEX.md — {total} labs assigned to {len(by_module)} modules, "
          f"{len(nist)} NIST labs, 0 orphans.")


if __name__ == "__main__":
    main()
