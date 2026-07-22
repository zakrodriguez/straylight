# cbom-toolkit Design

Original design for the four core CycloneDX CBOM glue tools between the scanners and
the observatory. The Python side has since grown (PQC classification, protocol probes,
alerting, dashboard provisioning); see `cbom-toolkit/python/` and `docs/cbom-pipeline.md`.

## Goals

- Master the CycloneDX 1.6 CBOM spec through implementation
- Build glue tools in PowerShell and Python (validation, diffing, ingestion, scoring)
- Deploy a multi-scanner crypto discovery platform across the lab
- Stress-test the spec with realistic and adversarial crypto scenarios
- Culminate in an operational crypto observatory with OpenSearch dashboards and PQC scoring

## Structure

As built (full tool-by-tool listing in `cbom-toolkit/README.md`):

```
cbom-toolkit/
  schema/
    cbom_envelope.json    # single source of truth for field types + producers
  powershell/             # 4 tools: CbomValidate / CbomDiff / CbomIngest / CbomScore
  python/                 # validation, diffing, ingest, scoring, mapping generation,
                          # PQC classification, protocol probes, alerting, dashboards
  baselines/              # per-profile, per-scanner reference CBOMs for diffing
```

Two directories from the original design are **planned, not yet in the repo**:

```
  scenarios/              # PLANNED — see "Break Scenarios" below (not implemented)
    realistic/            #   expired certs, SHA-1, CRL gaps
    adversarial/          #   rogue CAs, downgrade attacks
  tests/sample-cboms/     # PLANNED — known-good / known-bad CBOM fixtures
```

## Scanning Layer

Five scanners were envisioned, each producing CycloneDX CBOM from a different angle.
**Design target vs. reality:** the operational pipeline runs six — theia, nmap-network,
ejbca-api, pqc-handshake, pqc-ssh, pqc-openpgp (see `docs/cbom-pipeline.md`); the `cipheriq`
role is included unconditionally by `ansible/playbooks/scanner1.yml`, so it deploys on
scanner1 in every profile that includes that VM (`pqc-full`, `full`, and the
scanner-centric profiles). Generation
and basic viewing are covered by these tools — no need to build our own.

| Tool | Type | Source | What It Sees |
|---|---|---|---|
| cbomkit-theia | Static files/containers | PQCA/IBM | Certs, keys, java.security, source code |
| CBOM-Lens | Active network + files | CZERTAINLY | nmap TLS/SSH probing across lab network |
| CipherIQ cbom-generator | Static discovery | CipherIQ (GPL3) | Alternative static scanner |
| CipherIQ crypto-tracer | eBPF runtime | CipherIQ (GPL3) | Live crypto API calls at kernel level |
| CipherIQ pqc-flow | Passive network | CipherIQ (GPL3) | TLS/SSH/IKEv2/QUIC handshake sniffing |

Existing viewer: CipherIQ cbom-explorer (web UI) — no need to build cbom-parse. All are
containerized; deploy to SCANNER1 (dedicated scanner VM) or other Linux VMs. crypto-tracer
needs kernel access (privileged container); pqc-flow a promiscuous NIC.

## Target Applications

Apps deployed as rich crypto surfaces for the scanners.

### Tier 1: Deploy + Configure (TLS, keystores, client certs)

- **Keycloak** — Java IAM: SAML signing, OIDC tokens (JWT/JWS/JWE), TLS
  keystores, client cert auth, token encryption.
- **HashiCorp Vault** — PKI secrets engine (cert issuance), transit engine
  (encryption/signing/HMAC), auto-unseal (key wrapping); can integrate with AD CS.
- **Apache NiFi** — Java data flow: node-to-node TLS, content encryption,
  provenance signing, deeply customized java.security config.

### Tier 2: Deploy Light

- **Gitea** — Go Git server: TLS, SSH host keys, GPG commit signing.
- **MinIO** — S3-compatible storage: TLS, KMS encryption keys, server-side encryption.

### Tier 3: Source-Only (clone and scan, don't run)

- **EJBCA CE source** — already running; clone source for Java crypto scanning.
- **Bouncy Castle source** — the crypto library itself; broad surface of crypto primitives.
- **Keycloak source** — compare source-declared crypto vs runtime-deployed crypto.

## Tools

The four core tools the scanners don't provide, each originally built in PowerShell and Python.

### Tool 1: cbom-validate

Validate CBOMs beyond JSON schema — crypto-specific correctness.

Checks:
- JSON schema validation (CycloneDX 1.6)
- bom-ref integrity (deps reference existing components)
- Required cert fields (subject, issuer, validity dates)
- Valid algorithmProperties (primitive, parameterSetIdentifier)
- No orphaned components (no dependency links)
- Sane key sizes (not 0, not negative)
- Weak algorithm warnings (MD5, SHA-1, RSA < 2048)

Output: PASS/WARN/FAIL per check, summary, optional JSON output.

### Tool 2: cbom-diff

Diff two CBOMs to detect changes over time.

Identity: match by cryptoProperties content, not bom-ref (changes between scans).

Output:
- Added/removed certificates (with subject/issuer)
- Added/removed algorithms
- Expiry changes (cert renewed, cert closer to expiry)
- Algorithm changes with warnings (e.g. SHA-1 appeared)
- Summary line: `+3 certs, -1 cert, +1 algorithm (SHA-1 — WARNING)`

### Tool 3: cbom-ingest

Transform CBOM JSON into OpenSearch documents: each component becomes a structured log
message (`cbom_scanner`, `cbom_asset_type`, `cbom_vm`, `cbom_algorithm`, `cbom_pqc_status`,
cert validity, key size, …) sent to the OpenSearch bulk API (host-side via the
`observe_tls` TLS front on :9244; the raw :9200 listener is loopback-only).

As built, `cbom-toolkit/schema/cbom_envelope.json` (envelope `cbom-envelope/v1`) defines
every `cbom_*`/`cf_*`/`adcs_*` field with its OpenSearch type plus a producer registry.
`cbom_ingest.py` dispatches on each report's explicit `schema` key (default CycloneDX;
other producers `cloudflare_pqc/v1`, `adcs_pqc_audit/v1`) — not `startswith` field-name
sniffing — and stamps each document with `cbom_envelope_version`/`cbom_schema`.
`gen_opensearch_mapping.py` generates the OpenSearch index mapping from the same file.
See [cbom-pipeline.md](cbom-pipeline.md) for the contract and retention
(`straylight-retention` ISM policy, `straylight-logs`/`straylight-cbom` templates).

### Tool 4: cbom-score

PQC readiness scoring per VM.

Classification:
- **Quantum-vulnerable**: RSA (all sizes), ECDSA, ECDH, DSA, DH
- **Quantum-safe**: AES (128+), SHA-256+, SHA-3, ML-KEM, ML-DSA, SLH-DSA
- **Weak (classical)**: MD5, SHA-1, RSA < 2048, DES, 3DES, RC4

Scoring:
- Extract VM name from evidence.occurrences.location (path prefix before /)
- Group components by VM
- Calculate: quantum-vulnerable % / quantum-safe % / weak %
- Score: GREEN (>80% safe), AMBER (50-80%), RED (<50%)

Output:
- Per-VM scorecard (table: VM, total, vulnerable, safe, weak, score, grade)
- Lab-wide summary
- Specific migration targets per VM (list of algorithms to replace)
- CNSA 2.0 compliance flags
- JSON output option for ingestion into OpenSearch via cbom-ingest

## Break Scenarios

> **Status: design proposal — not yet implemented** (no scripts or `scenarios/` directory in the repo).

### Realistic

- R1: Expired certificate in VM store
- R2: SHA-1 cert issuance via CA template
- R3: CRL gap (delete CRL files from WEB1)
- R4: Near-expiry subordinate CA (7-day validity)
- R5: Duplicate CA names (same subject, different keys)

### Adversarial

- A1: Rogue root CA injected into trust store
- A2: Algorithm downgrade (RSA-2048/SHA-256 -> RSA-1024/SHA-1)
- A3: Wildcard cert injection from foreign CA
- A4: Private key in web-accessible directory
- A5: Shadow CA (second EJBCA, different root, same naming)

Each scenario: deploy script + cleanup script. cbom-diff + cbom-validate are the detection layer.

## Observatory Capstone

### Scanner Orchestration

**Design target:** all six scanners run on schedule, each producing CycloneDX CBOM JSON.
- cbom-scan.sh (existing) — exports certs from all VMs via WinRM/SSH
- cbomkit-theia — scans exported artifacts + container images + source repos
- CBOM-Lens — active network scan of 192.168.56.0/24
- CipherIQ crypto-tracer — continuous eBPF monitoring
- CipherIQ pqc-flow — continuous passive network capture

Pipeline: scanner → cbom-validate → cbom-diff (vs baseline) → cbom-ingest → OpenSearch
Periodic: cbom-score runs after each scan cycle, results ingested via cbom-ingest.

### OpenSearch Dashboards

**1. Crypto Posture Overview**
- Algorithm distribution (pie: RSA vs ECDSA vs AES vs SHA families)
- Quantum-vulnerable vs quantum-safe ratio (bar)
- Total certs / keys / algorithms per VM (table)
- Scanner coverage (which scanners found what)

**2. Certificate Lifecycle**
- Expiry timeline (histogram: certs expiring in 7/30/90/365 days)
- Recently issued certs (last 24h/7d)
- Cert authority breakdown (which CA issued what)
- Chain depth distribution

**3. Drift Detection**
- New components since last scan (table, filterable by type)
- Removed components (trust store shrinkage)
- Algorithm changes (SHA-1 appeared, new key types)
- Triggered alerts feed

**4. PQC Readiness Scorecard**
- Per-VM red/amber/green score based on quantum-vulnerable crypto percentage
- Breakdown: what specific algorithms need migration
- Trend over time (movement toward or away from PQC readiness)
- CNSA 2.0 compliance checklist mapping

### Alert Rules

- CRITICAL: Rogue root CA detected (new root not issued by lab CAs)
- CRITICAL: Private key found in unexpected location
- HIGH: SHA-1 or MD5 algorithm appeared
- HIGH: RSA key < 2048 bits detected
- MEDIUM: Certificate expiring within 30 days
- MEDIUM: Algorithm downgrade detected (stronger -> weaker between scans)
- LOW: New certificate issued (informational)
- LOW: Trust store changed (component added/removed)

### Scanner Correlation

Cross-reference what each scanner finds to answer:
- What does the network scan find that static scan missed? (TLS-only certs not in stores)
- What crypto is in use at runtime (crypto-tracer) that doesn't appear in any cert store?
- Do all scanners agree on the algorithm inventory?
- Coverage gaps: which VMs/services have no scanner visibility?

## Key Resources

- CBOM Capabilities: https://cyclonedx.org/capabilities/cbom/
- Authoritative Guide (PDF): https://cyclonedx.org/guides/OWASP_CycloneDX-Authoritative-Guide-to-CBOM-en.pdf
- CycloneDX 1.6 JSON Schema: https://github.com/CycloneDX/specification/blob/master/schema/bom-1.6.schema.json
- IBM CBOM repo: https://github.com/IBM/CBOM
- cbomkit-theia: https://github.com/PQCA/cbomkit-theia
- CBOM-Lens: https://github.com/CZERTAINLY/CBOM-Lens
- CipherIQ: https://github.com/CipherIQ
- PQCA: https://pqca.org/
