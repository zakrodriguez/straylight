# cbom-toolkit

CycloneDX **Cryptographic Bill of Materials (CBOM)** tools between the lab's
crypto scanners and the OpenSearch observatory on `observe1`: validate, diff,
classify, score, and ingest CBOM JSON, plus live-endpoint PQC probes.

End-to-end pipeline (export → scan → dedup → validate → diff → classify →
ingest → dashboards): [`../docs/cbom-pipeline.md`](../docs/cbom-pipeline.md).
Entry points (`cbom-pipeline.sh`, `cbom-scan.sh`, `cbom-orchestrate.sh`,
`cbom-dedup.py`) live under [`../scripts/`](../scripts/) and call these tools.

## Layout

```
cbom-toolkit/
  schema/        # the document contract (1 file)
  python/        # 14 tools — the primary implementation
  powershell/    # 4 tools — Windows-side equivalents of the core glue tools
  baselines/     # reference CBOMs for drift detection
```

## `schema/`

| File | Purpose |
|---|---|
| `cbom_envelope.json` | Single source of truth for the OpenSearch document contract: every `cbom_*` / `cf_*` / `adcs_*` field with its OpenSearch type, plus a **producer registry** (CycloneDX, `cloudflare_pqc/v1`, `adcs_pqc_audit/v1`). The index mapping is generated from it; ingest dispatches on it; new fields/producers are a one-file edit. |

## `python/` — 14 tools

**Glue / pipeline:**

| Tool | What it does |
|---|---|
| `cbom_validate.py` | CycloneDX 1.6 structural validation — required fields, `bom-ref` integrity, weak-algorithm flags. |
| `cbom_diff.py` | Diffs a scan against a stored baseline (added / removed / changed components, expiry shifts). |
| `cbom_score.py` | PQC readiness scoring per VM — quantum-safe / quantum-vulnerable / weak-classical, graded GREEN / AMBER / RED. |
| `cbom_ingest.py` | Pushes components to OpenSearch via the bulk API; dispatches by the envelope's producer registry (not field-name sniffing). |
| `cbom_alerts.py` | Alerting rules (rogue root CA, weak algorithms, near-expiry certs, downgrades). |
| `gen_opensearch_mapping.py` | Generates the OpenSearch index mapping from `schema/cbom_envelope.json`. |
| `pqc_classify.py` | Single source of truth for PQC algorithm classification, shared by the scoring + ingest paths. |

**Scanners / converters:**

| Tool | What it sees |
|---|---|
| `nmap_to_cbom.py` | Converts nmap `ssl-cert` / `ssl-enum-ciphers` XML into CycloneDX CBOM, resolving PQC signature OIDs to names (e.g. `ML-DSA-65`). |
| `ejbca_api_to_cbom.py` | Enumerates EJBCA CAs/certs via the `ejbca.sh` CLI and emits CycloneDX CBOM (sees PQC CAs that TLS scanners can't reach). |
| `kex_probe.py` | `openssl s_client` TLS key-exchange group probe, including PQC hybrid groups like `X25519MLKEM768`. |
| `pqc_handshake_probe.py` | TLS PQC handshake probe (OpenSSL 3.5) — detects ML-DSA leaves and ML-KEM hybrid KEX on pure-PQC / chimera endpoints. |
| `pqc_ssh_probe.py` | SSH PQC KEX probe — detects `mlkem768x25519-sha256` and related hybrid KEX. |
| `pqc_openpgp_probe.py` | OpenPGP PQC key probe — detects Kyber (ML-KEM) encryption subkeys in GnuPG keyrings. |

**Dashboards:**

| Tool | What it does |
|---|---|
| `osd_dashboards.py` | Provisions the OpenSearch Dashboards definitions (PQC posture, certificate lifecycle, drift, per-VM scorecards). |

`python/tests/` holds unit tests (e.g. `test_pqc_classify.py`).

## `powershell/` — 4 tools

Windows-side equivalents of the core glue tools.

| Tool | Equivalent of |
|---|---|
| `CbomValidate.ps1` | `cbom_validate.py` |
| `CbomDiff.ps1` | `cbom_diff.py` |
| `CbomIngest.ps1` | `cbom_ingest.py` |
| `CbomScore.ps1` | `cbom_score.py` |

## `baselines/`

Per-profile, per-scanner reference CBOMs (`baseline-<scanner>-<profile>.json`)
that `cbom_diff.py` compares fresh scans against to flag drift — a new cert, a
changed algorithm, a PQC endpoint regressing to classical.
