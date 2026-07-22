# Security Policy

## Scope

Straylight is a **lab environment** intended for learning and demonstration. It is explicitly **not** intended for production use:

- Default credentials are baked into `vagrant/config.rb` and visible in this public repo.
- The lab is designed to be reachable from your VirtualBox host-only network only. Do not expose any VM to the public internet.
- Some lab walkthroughs **intentionally** drive the PKI into broken/insecure states (expired certs, offline CRLs, untrusted chains) as teaching scenarios.

Because of the above, "the lab has weak credentials" or "this lab scenario is vulnerable" is **by design** and not a security issue.

## What we do treat as a security issue

- Vulnerabilities in Straylight's own scripts (`up.sh`, `nuke.sh`, install-wizard, ansible roles authored here) that allow privilege escalation, credential exposure outside the lab boundary, or arbitrary code execution on the host.
- Supply-chain risks: insecure use of `curl | bash`, unpinned packages, missing checksum verification, etc.
- Default configurations that create risk beyond what's already documented (e.g., a role that disables Windows Defender without warning).

## Reporting

Please report privately via GitHub's **private vulnerability reporting**: the [Report a vulnerability](https://github.com/zakrodriguez/straylight/security/advisories/new) form under this repository's Security tab. Public Issues are disabled on this repository, so the private form is the only channel.

Include:
- Affected files / scripts / roles
- Reproduction steps
- Impact assessment
- Suggested fix if you have one

We aim to acknowledge reports within 3 business days and ship a fix or mitigation within 30 days for high-severity issues.

## Disclosure

Coordinated disclosure preferred. We'll credit reporters in the fix's commit message and CHANGELOG entry unless you'd rather stay anonymous.

## Out of scope

- Findings against upstream products (EJBCA, step-ca, Hydra, OpenSearch, Ansible, Vagrant, VirtualBox). Report those to their respective vendors.
- Microsoft AD CS quirks documented in `vagrant/docs/adsi-constraint-violation.md` and similar known-issue docs — those are workarounds for upstream behavior, not vulnerabilities in straylight.
