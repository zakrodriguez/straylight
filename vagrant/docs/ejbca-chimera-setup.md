# EJBCA Chimera Setup — Known Workaround

The lab issues chimera (RSA + ML-DSA-65 alt-sig) certificates from `EJBCA-Chimera-Root-CA`. For the CA to emit the alt-sig OIDs (`2.5.29.72`/`73`/`74`) on issued leaves, the `ejbca_pqc` role applies a **direct database patch** against EJBCA's `CAData` table; no supported EJBCA path covers this case. This document records the cause and the path to a supported fix.

## Symptom

Without the patch, `EJBCA-Chimera-Root-CA` issues certificates with the **primary** RSA signature but no alt-sig extensions, so PQC-aware verifiers see a classical-only cert. In some configurations the CAToken goes "offline" at the first sign attempt: `X509CAImpl` looks up `alternativeCertSignKey` in propertydata, doesn't find it, and throws.

## Root cause (EJBCA 9.3.7)

Two pieces missing from the CAToken serialization:

1. **`alternativeSignatureAlgorithm`** is not populated by `ejbca.sh ca init`, so the CAToken LinkedHashMap lacks the key and `X509CAImpl.generateCertificate()` has no algorithm to call `getAlternativePrivateKey()` against.
2. **`alternativeCertSignKey`** is accepted by `ca init --tokenprop` (as a key=value in the props file) but **silently dropped** during CAToken serialization; the resulting `propertydata` string carries only `certSignKey`/`crlSignKey`/`testKey`/`defaultKey`.

Neither the CLI (`ejbca.sh ca init`), the REST API, nor (as of EJBCA CE 9.3.7) the admin web UI's "Edit CA" form exposes these CAToken-internal fields.

## What we ship

The `ejbca_pqc` role's `Patch Chimera Root CA catoken` task runs a Python script via `docker exec ejbca-db` that:

1. **SELECTs** the `data` blob for `EJBCA-Chimera-Root-CA` from the `CAData` table.
2. **Inserts** `alternativeSignatureAlgorithm=ML-DSA-65` into the catoken LinkedHashMap (between the existing `encryptionalgorithm` entry and the closing `</object>`).
3. **Inserts** `alternativeCertSignKey=signKeyMLDSA` into the `propertydata` key=value string.
4. **UPDATEs** the row.

The task checks for both strings via SQL `LIKE` first; re-runs are no-ops. The patch is positionally fragile: it anchors on the exact preceding pattern (`SHA512WithRSAAndMGF1` followed by `</void>`) and, if a future EJBCA release changes that ordering, errors with `"alt-sig algo anchor not found — schema may have changed"` rather than silently failing.

## Path to a supported fix

Three alternatives considered; none currently viable.

### Option A — EJBCA REST API

A CA-edit endpoint accepting `alternativeSignatureAlgorithm` + `alternativeCertSignKey` would let the role call it with `ansible.builtin.uri` and skip the DB patch. **Not exposed in 9.3.7**: the CA Management REST endpoints cover create / activate / revoke / get-cert but not catoken-property edit. Would need an upstream EJBCA RFE.

### Option B — Playwright drives the admin UI

The pattern is already in use in this lab — `ejbca_chimera_profile/files/configure-chimera.py` uses Playwright in a Docker sidecar to configure cert + EE profiles via the admin web UI. But audit findings against EJBCA CE 9.3.7's admin UI confirm the "Edit CA" page does **not render** fields for `alternativeSignatureAlgorithm` or `alternativeCertSignKey` — they're CAToken-internal, never wired into the UI.

**Upstream status as of 2026-05-20:** EJBCA **9.4** addresses this on the Enterprise side via two Keyfactor changelog tickets — **ECA-13071** "Ability to create Hybrid CAs with ca init CLI" and **ECA-13368** "Improve Admin UI message for alternative signature algorithm". The 9.4.2 "Creating a Hybrid CA" doc (docs.keyfactor.com) lists "Alternative Signing Algorithm" and `alternativeCertSignKey` as Create-CA form fields. **However:**

- EJBCA CE 9.4 has not shipped — latest on `Keyfactor/ejbca-ce` is r9.3.7 (2025-12-16). Per maintainer @primetomas on issue [#943](https://github.com/Keyfactor/ejbca-ce/issues/943), CE 9.4 is projected for "sometime in 2026."
- 9.4.2 is GA only via the EJBCA Licensing Mechanism (EE channel); a Keyfactor license would violate the lab's "open-source comparison" framing.
- Only the **Create-CA** flow is documented in 9.4. **Edit-of-existing-CA** may still not expose the fields, so a retrofit (the path the lab uses) could still need the DB patch even on 9.4.

**Forward-compatible skeleton:** the lab carries a Playwright skeleton at `ejbca_pqc/files/set-chimera-altsig.py`, behind the `ejbca_chimera_method` feature flag (default `db_patch`). Setting `ejbca_chimera_method: playwright` on EJBCA 9.3.7 fails with exit code 2 + `FIELD-MISSING` by design. Flip steps are under "When the upstream fix lands" below.

### Option C — Patch via EJBCA CLI tooling

`ejbca.sh ca import` accepts an explicit `--props` file that *should* honor `alternativeCertSignKey`, but the value is read into `CAToken.setKeyAliasesProperty()` and **dropped before serialization** — same root cause as `ca init`. Fixing the CAToken serializer upstream is out of scope for the lab.

## When the upstream fix lands

The role already has both branches: `defaults/main.yml` declares `ejbca_chimera_method: db_patch` (current default); `tasks/main.yml` gates DB-patch tasks `when: ejbca_chimera_method == 'db_patch'` and Playwright tasks `when: ejbca_chimera_method == 'playwright'`; `files/set-chimera-altsig.py` is the Playwright sidecar script.

When EJBCA CE 9.4 ships and is verified:

1. Bump `ejbca_image_tag` in `ansible/inventory/<profile>/group_vars/all.yml` to 9.4.x (consumed by `roles/ejbca/templates/docker-compose.yml.j2`).
2. Re-record selector IDs from a live 9.4 Edit-CA page (open the page, "View Source", grep for `editcapage:`); update `SEL_ALT_ALGO` / `SEL_ALT_KEY` / `SEL_SAVE` in `set-chimera-altsig.py` — the current values are hypothesized; JSF IDs may differ.
3. Set `ejbca_chimera_method: playwright` in the lab's group_vars or playbook invocation; run `vagrant provision ejbca1` and verify alt-sig OIDs appear on issued leaves.
4. Flip the default in `defaults/main.yml` from `db_patch` → `playwright`; cold-build `pqc-full` to verify.
5. Remove the DB-patch path + Python script in a follow-up release and update this doc with the version that introduced the supported path.

If 9.4 only fixes the **Create** flow (likely, based on the 9.4 docs scope), the DB patch stays for the lab's retrofit use case. The Playwright path becomes useful only if `ejbca.sh ca init` is rewritten to take the alt-sig params, in which case the role can invoke the new CLI flags directly and the skeleton becomes vestigial.

## Risks

- **DB schema changes**: the patch is positionally fragile against EJBCA's CA catoken XML format. The anchor strings are explicit but the version target is unstated; re-test the patch after any upgrade past 9.3.7.
- **MariaDB connection**: the patch shells out to `docker exec ejbca-db mariadb` with hardcoded `ejbca/ejbca` credentials. Production deployments would need parameterization.
- **No transaction**: the SELECT + UPDATE are two separate calls; a concurrent EJBCA-side CA edit could race. Lab-only.

## See also

- `vagrant/ansible/roles/ejbca_pqc/defaults/main.yml` — `ejbca_chimera_method` feature flag
- `vagrant/ansible/roles/ejbca_pqc/tasks/main.yml` — DB-patch + Playwright branches (gated)
- `vagrant/ansible/roles/ejbca_pqc/files/set-chimera-altsig.py` — Playwright skeleton (requires EJBCA 9.4+)
- `vagrant/ansible/roles/ejbca_chimera_profile/files/configure-chimera.py` — the original Playwright pattern this skeleton mirrors
- `vagrant/docs/pqc-demo-runbook.md` → Known Limitations — audience-facing summary
- [Keyfactor EJBCA 9.4 release notes](https://docs.keyfactor.com/ejbca/latest/ejbca-9-4-release-notes) — ECA-13071 / ECA-13368
- [Keyfactor CE issue #943](https://github.com/Keyfactor/ejbca-ce/issues/943) — Hybrid CA CLI; CE 9.4 ETA "sometime in 2026"
