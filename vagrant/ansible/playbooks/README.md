# Ansible Playbooks

Ansible playbooks for the straylight Vagrant + Windows PKI lab.

## PQC migration playbooks vs validate.sh

`pqc-migrate-*.yml` and `scripts/validate.sh` both run PQC verification
probes but serve different audiences and aren't merged into one tool:

| Use case                                         | Tool                                       |
| ------------------------------------------------ | ------------------------------------------ |
| One-shot migration: install + verify each phase  | `pqc-migrate-<phase>.yml` or `pqc-migrate.yml` |
| Standing lab health: run periodically, all checks| `bash scripts/validate.sh`                 |
| Per-phase debugging during migration             | Re-run the specific `pqc-migrate-<phase>.yml`  |

### Shared verifier — one source of truth

Probe bodies shared by both tools live in **`scripts/lib/pqc-verify/`**, one
self-contained bash script per probe. Each emits `PASS:`/`FAIL:` lines and
always exits 0 (the `validate.sh` contract — failure is a `FAIL:` line, not
the exit code). There is no hand-synced second copy:

| Probe                          | Shared script                          | validate.sh consumer (`checks/pqc-chimera.sh`)        | Migration consumer            |
| ------------------------------ | -------------------------------------- | ----------------------------------------------------- | ----------------------------- |
| OpenSSH 10 ML-KEM hybrid KEX   | `lib/pqc-verify/ssh-kex.sh`            | `<vm>-ssh-pqc` loop (`cat`'d into the check)          | `pqc-migrate-ssh.yml` (`script:`) |
| GnuPG Kyber/ML-KEM round-trip  | `lib/pqc-verify/gpg-kyber.sh`          | `<vm>-gpg-pqc` loop                                   | `pqc-migrate-gpg.yml` (`script:`) |
| Pure ML-DSA-65 TLS leaf        | `lib/pqc-verify/tls-pure-leaf.sh`      | `<host>-pqc-pure` loop (`PORT=` injected)             | `pqc-migrate-tls.yml` (`script:`, `PORT=8444`) |

`validate.sh` `cat`s these files into its remote check string (byte-identical
to the previous inline heredocs); the migration playbooks run them with
`ansible.builtin.script` and `failed_when: "'FAIL:' in <reg>.stdout"`.
**To change a probe semantic, edit the one file under `lib/pqc-verify/`.**

### Probes that remain consumer-specific (technique diverges by design)

Not in the shared library — the two consumers deliberately use different
techniques, so a single body can't serve both:

- **Foundation** (EJBCA PQC/chimera CA ML-DSA-65 assertion) — migration-only;
  `validate.sh` checks CA/cert *existence* (`ejbca1-pqc` in `checks/ejbca1.sh`),
  not the ML-DSA primary-key OID.
- **TLS chimera (observe1:8443)** — the migration playbook greps the raw DER
  hex of the ML-DSA-65 alt-sig OID (system openssl can't name it); `validate.sh`
  uses `asn1parse -strparse` on a host that has openssl 3.5. Same fact, two
  encodings.
- **TLS chimera (web1 IIS, dc1 AD Trusted Root)** — Windows-only probes via
  `win_shell` (.NET `SslStream` / ADSI); `validate.sh` probes web1 from scanner1
  with openssl. Different host + transport.
- **Posture** — migration-only global CBOM-sweep summary; `validate.sh` checks
  per-host state, not the aggregate posture JSON.

## Related playbooks

- **AD CS PQC CA provisioning** is handled by the unified `ca.yml` — for the PQC CA VMs (which set `ca_crypto_provider` + `kb_prereq`) it installs the prerequisite Windows update via `windows_kb_install`, then drives the same `standalone_ca` / `subordinate_ca` roles in ML-DSA mode to stand up an ML-DSA root + subordinate hierarchy on Server 2025 (plus `cert_templates_pqc` on the issuing CA).
- **`install-windows-kb.yml`** installs a single Windows hotfix / cumulative update by KB number (wraps the `windows_kb_install` role).
