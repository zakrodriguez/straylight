# Architecture Evolution

Why a consolidation pass collapsed the lab's hand-synced duplications into
single sources of truth. Current state: [ARCHITECTURE.md](../ARCHITECTURE.md).

## The diagnosis

Knowledge that should exist once (the table below) existed N times,
hand-synchronized, with patches accumulating where copies drifted; at least one live bug
traced to a recent dotfile-fallback fix treating its symptom. Remediation, per
subsystem: collapse each duplication into one source of truth, derive
everything else from it, and guard the derivation against silent drift.

## What changed, by theme

### 1. Single sources of truth (the core structural shift)

| Knowledge | Was | Now |
|---|---|---|
| VM topology | 3 disagreeing VM lists across Vagrantfile / scripts / inventory | one `vagrant/topology.yml` → derives components, IPs, inventory, script registries |
| Authoritative inventory doc | inventory restated in ~5 docs, no freshness check | `ARCHITECTURE.md` table, CI-verified against `topology.yml` (`doc_inventory_test.rb`) |
| Dependency ordering | "issueca depends on rootca+web1" in a code comment + blind `sleep`s | declarative `dependencies` DAG + readiness probes |
| CA implementation | parallel classical + PQC role pairs | one pair selected by `ca_crypto_provider`; publication in one `publish_ca_artifacts` role |
| CBOM field vocabulary | 4 hand-synced copies (ingest / mapping / dashboards / classifier) | one versioned `cbom_envelope.json` → generates the OpenSearch mapping |
| PQC verification probes | duplicated in `validate.sh` *and* `pqc-migrate` with an "update both" comment | both consume `scripts/lib/pqc-verify/` |
| Config + secrets | `.env` mis-binding; admin-password literals in 3+ scripts | one resolver-parsed `.env`; one secrets injection point |
| Scheduled-task lifecycle | the schtasks create/run/poll/delete block copy-pasted 7× | one `win_scheduled_task` helper role |

### 2. `validate.sh` decomposition

The 2,459-line monolith kept every role's assertion logic apart from its role
and drifted silently. Now: a 180-line harness + per-VM `scripts/checks/<vm>.sh`
modules; a "vanishing checks" guard (a check erroring under `set -e` + `|| true`
emitted no PASS/FAIL line and left the tally silently — now a FAIL); per-check
remote-script cleanup; a per-run log artifact.

### 3. PKI lifecycle correctness

- **Revocation exercised end-to-end**: throwaway leaf → `certutil -revoke` →
  republish → confirm `CRYPT_E_REVOKED` (CRLs were freshness-checked, never
  revocation-checked); see the
  [revocation walkthrough](walkthroughs/labs/adcs-functest-4-revocation-walkthrough.md).
- **CRL republish automated** (`ca_crl_republish` role on the online issuing
  CAs); the 26-week CRL validity had silently substituted for it.
- **Separate revocation namespaces**: the PQC hierarchy bakes `/crl/pqc` +
  `/aia/pqc` into issued certs; classical and ML-DSA hierarchies never touch
  each other's namespace on revocation or CRL refresh.
- **Trust-anchor distribution documented once**: per-anchor map in
  `ARCHITECTURE.md` (which anchor reaches which store by which mechanism).

### 4. Reproducibility & observability hardening

- **Packer**: four byte-identical version templates → one parameterized template
  + a box-versioning contract (`config.vm.box_version`); golden-master asymmetry
  resolved by a documented patch path (runtime WSUS, not a stale baked baseline).
- **Observability**: an ISM policy for index lifecycle/retention closes the
  silent disk-fill → read-only → ingest-stop mode on single-node indices;
  index templates against type-drift; a generalized systemd timer +
  `ExecStartPost` ingest pattern (`observe_timer` role) replaces hand-rolled
  per-producer units; the AD CS audit ingested, not dead-ended as a text file.

### 5. Convention consolidation

The WinRM identity model (SYSTEM-context scheduled task vs
explicit-domain-admin), formerly folk knowledge re-derived per role, is now
documented once; PQC-demo cert contracts reconciled; cms-lab var names made
symmetric with single-sourced CA config; role defaults moved from `set_fact`
to `defaults/main.yml`.

## Execution & validation

Scoped, separately-reviewed PRs landed in dependency order, then were
live-validated together on a `pqc-full` cold build (13 VMs); loud verification
surfaced several latent bugs the old silence had hidden — among them a CSR
submit racing the issuing-CA RPC startup, and stale index/path references from
the namespace split.

## Net effect

One source, derived everywhere, CI-guarded; drift now fails loudly instead of
silently. The lab carries 69 Ansible roles and 14 profiles; `validate.sh` is
roughly 92% smaller.
