# CBOM Pipeline

CBOM stands for Cryptographic Bill of Materials: a CycloneDX 1.6 JSON inventory of every cryptographic asset deployed across the lab — certificates, algorithms, key exchange methods, and key material. CycloneDX extends the standard Software BOM (SBOM) format with a `cryptoProperties` object that describes crypto material as first-class components. The pipeline identifies which parts of the PKI infrastructure are vulnerable to quantum computing and which are not.

## How it works

Two phases, followed by a post-processing chain.

```
  VMs                    Phase 1              Phase 2                Post-processing
  ────                   ───────              ───────                ───────────────
  DC1 ──┐                                    ┌─ theia ──────┐
  ROOTCA─┤  export certs   cbom-export/       │              ├─ dedup
  ISSUECA┤  ──────────► cer/crt/crl/pem ─────┤              ├─ validate
  WEB1 ──┤               keys                │              ├─ diff (vs baseline)
  EJBCA1─┤                                   ├─ nmap ───────┤─ ingest (OpenSearch)
  STEPCA1┘                                   │  + kex_probe ├─ score (PQC readiness)
                                             │              │
                                             └─ ejbca-api ──┘
```

### Phase 1: Export

`cbom-scan.sh` extracts raw cryptographic artifacts from every running VM.

**Windows VMs** (DC1, ROOTCA, ISSUECA, WEB1, etc.): a PowerShell script uploaded via `vagrant upload` and run over WinRM enumerates `Cert:\LocalMachine\*` stores (My, Root, CA, Trust), exports each cert as a `.cer` file, and grabs CRLs from `C:\PKI\CRL` and `CertEnroll`. Vagrant has no native download command for WinRM, so the script base64-encodes each file and streams it back through stdout as `FILE:<name>:<base64>` lines, decoded host-side.

**Linux VMs** (EJBCA1, STEPCA1, HYDRA1, OBSERVE1): a bash script piped through `vagrant ssh` collects certs/keys from the host filesystem (`/etc/ssl/certs`, etc.) and from each running Docker container (`/opt/step/certs`, `/var/lib/ejbca`, etc.), using the same base64 transfer.

Everything lands in `cbom-export/<vm>/` as flat `.cer`, `.crt`, `.crl`, `.pem`, and `.key` files per source VM.

### Phase 2: Scanners

**Six scanners** ship in two tiers: the three base scanners documented below (`theia`, `nmap-network`, `ejbca-api`) and three PQC-aware probes (`pqc-handshake`, `pqc-ssh`, `pqc-openpgp`, shipped as `pqc_handshake_probe.py` / `pqc_ssh_probe.py` / `pqc_openpgp_probe.py`) that detect ML-KEM/ML-DSA TLS handshakes, hybrid SSH KEX, and Kyber OpenPGP subkeys respectively — see the [PQC demo runbook](pqc-demo-runbook.md).

#### theia

IBM's [cbomkit-theia](https://github.com/IBM/cbomkit-theia) static scanner. It parses the exported files from `cbom-export/`, identifying signature algorithms, key types, key sizes, validity periods, and issuer chains, and emits CycloneDX CBOM JSON. Runs locally (binary or Docker container).

#### nmap-network

Runs from the scanner1 VM inside the lab network. Two parts:

1. An nmap sweep with `ssl-cert` and `ssl-enum-ciphers` NSE scripts across all lab IPs on TLS-relevant ports — what is actually served over the wire, not just what sits in a cert store. `nmap_to_cbom.py` converts the raw XML to CBOM and resolves PQC OIDs: nmap's NSE scripts lack PQC mappings and report raw OIDs like `2.16.840.1.101.3.4.3.18`, which the converter translates to names like `ML-DSA-65`.

2. An OpenSSL 3.5 key-exchange probe (`kex_probe.py`). nmap reports TLS 1.3 cipher suites but not the negotiated key-exchange group, so this script uses `openssl s_client` to attempt handshakes with specific groups — including PQC hybrids like `X25519MLKEM768` — and merges the successes into the CBOM as additional components.

#### ejbca-api

nmap can't complete TLS handshakes with pure ML-DSA server certs (its OpenSSL 3.0 doesn't support them), so this scanner bypasses TLS: it SSHes into the EJBCA VM and runs `ejbca.sh` CLI commands to enumerate CAs and their certificates. PQC CAs stay discoverable regardless of client TLS support.

### Post-processing chain

Each scanner's output goes through the same sequence:

**Dedup** (`cbom-dedup.py`): cbomkit-theia emits one algorithm component per certificate — 30 RSA-2048 certs yield 30 identical components. Dedup merges them by fingerprint (name + crypto properties), keeps one canonical component, and rewrites all `bom-ref` pointers in the dependency graph.

**Validate** (`cbom_validate.py`): structural checks against CycloneDX 1.6 — required top-level fields (`bomFormat`, `specVersion`, `serialNumber`), `subjectName`/`notValidBefore`/`notValidAfter` on every certificate, weak-algorithm flags (MD5, SHA1, DES), and dependency references that resolve to existing components.

**Diff** (`cbom_diff.py`): compares the current scan against the baseline — a previous scan's deduplicated output stored in `cbom-toolkit/baselines/` — reporting added, removed, and changed components (new certificates, expirations, algorithm changes). Skipped on first run when no baseline exists.

**Ingest** (`cbom_ingest.py`): bulk-sends each component as a structured JSON event to OpenSearch on OBSERVE1, host-side via the `observe_tls` nginx front on :9244 (TLS + Basic Auth); the raw :9200 listener is loopback-only behind it. Each event carries crypto properties, PQC classification (`quantum-safe`, `quantum-vulnerable`, `weak-classical`), source VM, scanner name, and timestamp, feeding OpenSearch Dashboards (served at `https://192.168.56.53/` on :443 via the same nginx; the raw :5601 listener is loopback-only).

## Schema contract + retention

The OpenSearch document shape is a versioned contract with one source of truth: `cbom-toolkit/schema/cbom_envelope.json` (envelope version `cbom-envelope/v1`). It declares every `cbom_*`/`cf_*`/`adcs_*` field with its OpenSearch type — including `cbom_source`, a `keyword` — plus a **producer registry** mapping a report's `schema` key to its ingest handler. `cbom_ingest.py` dispatches on that explicit `schema` field (CycloneDX is the default when none is recognized); it does not sniff field names with `startswith`. Every emitted document is stamped with `cbom_envelope_version` and `cbom_schema`. The OpenSearch index mapping is generated from the same file by `gen_opensearch_mapping.py` and applied by the `opensearch_stack` role, so index and producer cannot drift on types.

Three producers ship today: CycloneDX (theia/nmap/ejbca-api/pqc-* probes), `cloudflare_pqc/v1` (edge PQC probe), and `adcs_pqc_audit/v1` (the AD CS layered gap audit — `Invoke-PqcAudit.ps1` writes a JSON sidecar that the `adcs_pqc_audit` role ingests into OpenSearch rather than leaving it only on disk). Adding producer N+1 is one edit to the envelope file plus a handler function.

Recurring probe scheduling is factored into the reusable `observe_timer` role: a systemd timer + service with an optional `ExecStartPost` ingest hook (probe runs, then pipes its report through `cbom_ingest.py`). `cloudflare_pqc` consumes it rather than defining its own timer.

Retention is server-side: the `opensearch_stack` role installs an ISM policy (`straylight-retention`, 14-day delete phase) and index templates (`straylight-logs`, `straylight-cbom`) that lock field types. Beats ship to date-suffixed indices (`logs-windows-YYYY.MM.dd`, `logs-linux-YYYY.MM.dd`) so the delete phase ages out whole daily indices on the single-node cluster.

**Score** (`cbom_score.py`): classifies every algorithm component into one of four buckets:

| Category | Examples | Meaning |
|----------|----------|---------|
| quantum-safe | AES, SHA-2/SHA-3, ML-KEM, ML-DSA, SLH-DSA, XMSS, LMS | Resistant to known quantum attacks |
| quantum-vulnerable | RSA, ECDSA, ECDH, DH, Ed25519 | Broken by Shor's algorithm |
| weak-classical | MD5, SHA-1, DES, RC4 | Broken now, not just by quantum |
| unknown | anything unrecognized | Needs manual classification |

Results are grouped by VM; the quantum-safe percentage yields a grade: GREEN (>=80% safe), AMBER (>=50%), RED (<50%).

**Baseline rotation**: the current deduplicated output replaces the stored baseline for the next run's diff.

## Orchestration

`cbom-orchestrate.sh` wraps the pipeline with scheduling:

- One-shot execution (default)
- Watch mode with configurable interval (`--watch 30m`)
- systemd timer installation for unattended recurring scans (`--install-cron 1h`)
- Run history tracking in a JSONL file with status, duration, and log paths

## Usage

```bash
# Full pipeline (export + all scanners + ingest + score)
LAB_PROFILE=ad-cs-two-tier bash scripts/cbom-pipeline.sh

# Single scanner
LAB_PROFILE=ad-cs-two-tier bash scripts/cbom-pipeline.sh --scanner nmap-network

# Skip cert export, re-scan existing data
bash scripts/cbom-pipeline.sh --scan-only

# Skip OpenSearch ingest
bash scripts/cbom-pipeline.sh --no-ingest

# Orchestrated recurring scan
bash scripts/cbom-orchestrate.sh --watch 1h

# Check last run status
bash scripts/cbom-orchestrate.sh --status
```

## The PQC angle

The lab's three CA platforms (AD CS, EJBCA, step-ca) have post-quantum algorithms added, and the pipeline measures migration progress: as ML-DSA certificates are enrolled, hybrid key exchange is enabled, or RSA CAs are replaced, the readiness score moves from RED toward GREEN. The diff step catches regressions — a re-provisioned VM that loses its PQC cert and falls back to RSA shows up in the diff.

## File layout

```
scripts/
  cbom-pipeline.sh        # main pipeline entry point
  cbom-scan.sh            # phase 1: export certs from VMs
  cbom-orchestrate.sh     # scheduling wrapper
  cbom-dedup.py           # algorithm deduplication

cbom-toolkit/schema/
  cbom_envelope.json      # single source of truth: field types + producer registry

cbom-toolkit/python/
  gen_opensearch_mapping.py  # cbom_envelope.json → OpenSearch index mapping
  nmap_to_cbom.py         # nmap XML → CycloneDX CBOM (with PQC OID resolution)
  ejbca_api_to_cbom.py    # EJBCA CLI → CycloneDX CBOM
  kex_probe.py            # openssl s_client KEX group probe
  cbom_validate.py        # CycloneDX 1.6 structure validation
  cbom_diff.py            # baseline diffing
  cbom_ingest.py          # OpenSearch bulk ingest
  cbom_score.py           # PQC readiness scoring
  cbom_alerts.py          # alerting rules
  osd_dashboards.py       # OpenSearch dashboard provisioning
  pqc_classify.py         # PQC algorithm classification logic
  pqc_handshake_probe.py  # TLS PQC handshake probe
  pqc_ssh_probe.py        # SSH PQC KEX probe
  pqc_openpgp_probe.py    # OpenPGP PQC key probe

cbom-export/              # staging dir (git-ignored, populated at runtime)
cbom-output/              # scan results and logs
cbom-toolkit/baselines/   # stored baselines for diffing
```
