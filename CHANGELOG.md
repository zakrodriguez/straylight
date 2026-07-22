# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) starting at v0.1.0.

## [Unreleased]

## [2.8.2] — 2026-07-21

### Changed
- **Inbound closed to everything except security reports.** CONTRIBUTING.md drops the bug-report and feature-request paths (Issues are disabled on the public repository) — open channels are forks and security disclosures; SECURITY.md's reporting channel switches from the non-routable `security@straylight.lab` address to GitHub private vulnerability reporting; both issue templates removed; quickstart contributing line updated. (#249)
- **Seed-prep wording for the public snapshot.** The five doc references to the `content/walkthroughs-unverified` branch now use "development archive" framing that reads correctly in both this repo and the future public snapshot repo (one operational pointer with the branch name kept in `docs/walkthroughs/README.md`); README gains a **Provenance** section — developed privately since April 2025, public repo = curated snapshot line, dated CHANGELOG as the authoritative timeline. (#248)

### Fixed
- **Claims-correctness audit fix pass — 151 verified findings corrected across 35 publishable docs.** Six parallel auditors checked ~955 statically-checkable claims against the code; six fixers corrected every confirmed finding, each re-verified against the cited source. Systemic corrections: every two-tier walkthrough drove `client1`, a VM the profile doesn't ship (→ `manage1`); EJBCA admin URLs gained the required `:8443`; loopback-only `:5601`/`:9200` URLs now route via observe_tls (`:443` Dashboards, `:9244` ingest); `docs/configuration.md` no longer documents nonexistent knobs (`template_name`, `key_archival_enabled`, `forest_mode`, `ou_path`, `snapshot_save`, `WSUS_CONTENT_PATH`, nmap/Npcap, taskbar pins, RemoteSigned) and cites config.rb symbols instead of line numbers; retry budgets updated to current code (machine_cert 90×20s, subordinate_ca 75×20s, domain_join 45×20s + 6×60s); Phase-2 overlap default and CA-only 60s stagger documented; RAM/time figures recomputed (`full` ~77 GB, `pqc-full` ~51 GB / ~95–110 min cold, two-tier ~45–50 min cold, `ad-cs-minimal` 3 VMs ~3 GB); svc-account password corrected to `SvcPKI00!`; walkverify docs stop claiming lint is CI-wired and now match capture=/normalizer/golden-provenance implementation; buildmon README documents the up.sh auto-attach default (`LAB_BUILDMON=off`), pidfile PID tracking, `reset-attempts`, and real `hung`/adoption/tie-break semantics; packer README rescopes baked-box benefits to `BOX_WIN_SERVER` consumers and drops a nonexistent box fallback; openssl-lab lessons re-verified live on OpenSSL 3.0.13 (lesson 08's OCSP revocation flow and lesson 11's TLS 1.3 listing rebuilt end-to-end; 3.x output drift fixed throughout); cold-build readiness-edge map recounted (30 edges: 28 clean-signal, 2 bounded-retry); STRAYLIGHT-REFERENCE realigned to v2.8.1 with a catalog-status note for labs parked on `content/walkthroughs-unverified`. Same-day seed-tree secrets scans (gitleaks + trufflehog via docker) ran clean: 0 findings. (#247)

## [2.8.1] — 2026-07-18

### Changed
- **adcs-functest labs numbered in run order** — the four files shared the indistinguishable INDEX title "ADCS Functional Test"; they are now `adcs-functest-1-service-health` → `2-connectivity` → `3-issuance` → `4-revocation` (the spec's run order: Lab 3 issues the cert Lab 4 revokes), with matching quiz renames, "Lab N" in every H1 (so INDEX titles are distinct), renamed walkverify goldens + updated `lab:` fields (lint re-verified on both annotated labs), exam/README reference updates, and INDEX regenerated. The top-level README's module description now states the correct order. (#244)
- **CONTRIBUTING.md: external pull requests politely declined** due to maintainer time constraints (reviewing and live-testing changes against multi-VM lab builds is the bottleneck). Bug reports, feature requests, security disclosures, and forks remain welcome; the PR workflow/style sections were replaced by the policy, and the PR template carries a matching notice. (#243)
- **Repo-wide documentation condensing pass** (README treatment applied to the rest of the doc tree): 45 files across `docs/`, `vagrant/docs/`, `vagrant/scripts/*/README`, `packer/`, `ARCHITECTURE.md`, and `CONTRIBUTING.md` trimmed 8178 → 7459 lines. Prose compressed to plain declarative style; all commands, URLs, IPs, paths, credentials, versions, table data, error strings, heading anchors, and evidentiary hedges preserved (verified per-file against the diff; repo-wide link/anchor check clean — the only remaining broken links are pre-existing CHANGELOG references to files parked on `content/walkthroughs-unverified`). Lab/quiz/exam content, walkverify goldens, specs, and generated INDEX.md untouched; openssl-lab lessons received a lighter redundancy-only trim. (#242)
- **README.md condensed** (~453 → ~240 lines): host support stated once, Lab Topologies / Customization / Select Topology folded into the profile table, Configuration, and Quick Start; Optional VMs collapsed to one entry per VM. All commands, URLs, credentials, and paths retained. (#240)
- **New `docs/walkthroughs/walkverify-design.md`** — design write-up for the walkthrough verification harness (sentinel annotations, golden companions, lint/verify/check, `capture=` chained-state threading, NAT-topology conventions); the harness README's stale "chained state remains human-verified" limitation updated to reflect `capture=` (#232) and the frozen v2.8.0 goldens. (#240)

## [2.8.0] — 2026-07-12

### Added
- **The `adcs-functest` revocation and service-health walkthroughs are now verifiable end-to-end on the standard two-tier NAT topology**, each with a frozen walkverify golden companion (`walkverify check`: revocation **15/15**, service-health **6/6**). Both were unrunnable as written because they drove the CA *remotely* from `manage1` — `certutil -config`/`-getreg`, `Invoke-Command`, `-ComputerName` — over DCOM/WinRM paths that can't traverse the shared VirtualBox NAT interface (`RPC_S_SERVER_UNAVAILABLE`; every VM shares `10.0.2.15`). They now run their CA-administration steps **locally on `issueca`**, per a new host-placement convention documented in `docs/walkthroughs/README.md`: CA-admin steps (`certutil -config` `-view`/`-revoke`/`-CRL`/`-getreg`, `certreq -submit`) run `host=<ca>`; relying-party steps (`-verify -urlfetch`, url-cache) run `host=<client>`; cross-host artifacts move over SMB or the Ansible controller, never DCOM. Revocation additionally distributes the fresh CRL to the CDP (web1's `PKI$` share) on republish so relying parties see the revocation, and both labs' assertions were aligned to this build's actual Server 2025 `certutil`/registry output (`CERT_TRUST_IS_REVOKED`/`CRYPT_E_REVOKED`, ` -- `-separated dispositions, `HashAlgorithm = -1` provider-default, `CACertHash` as `REG_MULTI_SZ`). (#235, #237, #238)
- **`vagrant/ansible/playbooks/functest-cert.yml` — the revocation-lab fixture.** Provisions a fresh Issued `functest1.yourlab.local` WebServer cert on `issueca` via the proven `pqc_machine_cert` recipe (`Add-CATemplate` + `certreq -f -q -new/-submit` in a domain-admin **batch** scheduled task — the `-q` suppresses the hidden CSP prompt that otherwise hangs non-interactive `certreq`, and the batch logon supplies the DCOM credentials WinRM network-logon lacks), extracts the RequestID/SerialNumber, and stages the cert to `manage1` through the Ansible controller (past the WinRM double-hop). Re-run before each `walkverify verify`/`check`. (#236)

### Changed
- **Pre-public cleanup:** scrubbed residual `/home/zak` paths and dropped internal planning docs (`docs/superpowers/` is now gitignored, kept in git history). (#234)

### Notes
- Server 2025's `CertSvc` is hardened: it recovers from a corrupt `CACertHash` (or a bogus KSP provider) by locating its signing cert by name, so service-health's deliberate-break demo (Steps 6–7) can't be reproduced via registry corruption on this build — those steps are now documented, build-dependent human prose and are not part of the automated verification.

## [2.7.0] — 2026-07-10

### Added
- **`walkverify` chained-state capture — stateful walkthrough steps are now verifiable.** A step declares `capture=NAME:/regex/` in its `@verify` sentinel; at run time the harness extracts group 1 from that step's output and binds `$NAME` into a run-scoped namespace that every later step consumes — injected like companion `parameters`, but populated at runtime. Steps stay isolated one-shot invocations (the live lab carries side-effect state, the harness carries the data), so there is no transport change, no companion schema change, and no new dependency. A single `_run_steps` loop threads bindings for both `check` (continue-past-failure) and `verify` (fail-fast via `stop_on_error`); `lint` gains order-aware resolution (a `$var` resolves against companion parameters, preamble assignments, or a strictly-earlier capture) with distinct forward-reference and parameter-shadow diagnostics, and no longer false-flags PowerShell automatics (`$_`) or within-step-assigned locals. The `adcs-functest` **revocation** (`RequestId`/`SerialNumber`) and **service-health** (`OrigThumbprint`) labs are retrofitted so their previously-un-annotated stateful steps capture/consume and lint clean — removing walkverify's "chained-state = future enhancement" limitation. 77 stdlib unit tests (injected fake runner, no live VMs). Golden companions for the two labs are captured post-merge by the maintainer against a standing lab (service-health parameters: `CA`, `Work`, `reg`). (#232)

## [2.6.0] — 2026-07-10

### Added
- **`walkverify` — walkthrough verification harness (first increment: the `adcs-functest` module).** Turns the one-time hand-verification of a walkthrough into a replayable regression test — verify once, keep it as a guard. Each verifiable fenced block carries one invisible HTML-comment sentinel (`<!-- @verify host= step= expect=/regex/ rc= -->`) on the line above it — invisible in rendered GitHub markdown, never contaminating a copy-pasted command. Three modes: `verify` runs a lab against a live build, captures real output, and freezes a `*.golden.yml` companion on human approval; `check` re-runs and asserts `rc` + every `expect` regex (continuing past failures for a full pass/fail map); `lint` is static-only (no VMs) for the per-PR gate — annotations parse, companions are well-formed, and step↔companion is a bijection. Transport reuses buildmon's `creds.py` (WinRM-basic for Windows guests, the vagrant SSH key for Linux); PowerShell state is re-materialized per step from companion `parameters` + an idempotent host-scoped `preamble`; volatile output is masked by named normalizers applied only to asserted fields. Pure Python stdlib, buildmon-style injected-fake-runner tests — 52 tests, zero live VMs in the suite. First increment annotates the four `adcs-functest` labs (39 sentinels). (#227)

### Fixed
- **`cbom_diff`: baseline drift-detection no longer fires on certificate re-issuance.** `get_fingerprint` keyed on the entire `cryptoProperties` blob, so every cold build's freshly-issued CA hierarchy + leaf certs — new validity timestamps, new keypairs (hence new `subjectPublicKeyRef`/`signatureAlgorithmRef` UUIDs), the churny EJBCA container UID, and non-deterministic RDN ordering — read as spurious drift, burying any genuine crypto change. The fingerprint now canonicalizes `cryptoProperties`: drops `notValidBefore`/`notValidAfter`, resolves each `*Ref` to the referenced component's stable name, masks the per-deployment EJBCA ManagementCA userId (`c-<…>`), and sorts RDN components (splitting only before an attribute, so a comma inside a value survives). A genuinely different algorithm, key, or subject still resolves to a different fingerprint, so real drift is preserved. Proven on real data: the 2026-05-20 pqc-full baselines diff to 0 changes against a fresh recapture (`ejbca-api`, `nmap-network`, `pqc-handshake`). 9 fingerprint tests + 42-test cbom suite green. (#228, #230)

### Changed
- **pqc-full CBOM baselines recaptured on a clean v2.5.0 cold build.** All six pqc-full scanner baselines regenerated against a first-try-clean 99-minute cold build + `pqc-migrate` + `pqc-mtls`, via `cbom-pipeline.sh`'s auto-rotation. Every delta was per-issuance volatile churn (timestamps, UUIDs, container UID, RDN order) — zero components added or removed, no algorithm/key/curve/security-level change — confirming the crypto surface is identical to the 2026-05-20 capture. (#229)

## [2.5.0] — 2026-07-09

### Added
- **`up.sh` auto-attaches the buildmon collector to every build.** The observer sidecar now launches automatically against the new build's logdir, pinned to the resolved profile (immune to the core/ad-cs-one-tier equal-set ambiguity when a twin lab is standing). `LAB_BUILDMON=off` opts out; the hook is strictly best-effort — an attach failure prints the manual command and the build proceeds untouched. Closes the long-standing "up.sh hook" follow-up from the original buildmon ship. (#225)
- **`buildmon`: guest probes for VMs that appear after collector startup.** `GuestProbePool` gains dynamic registration (`add_prober` enables an empty pool and spawns the probe thread mid-run), and the collector wires probers through a shared factory on VM adoption and on late profile inference — previously such VMs stayed dark for the whole run, and a collector attached before its profile was known ran with probing disabled forever. Closes the "guest-probe cred wiring" follow-up. (#225)

### Fixed
- **`buildmon`: a VM whose play ends cleanly on a "Wait for ..." dependency task now reads `done`, not `waiting-dep` forever** — the clean `PLAY RECAP` outranks the last-seen task name (the manage1 self-heal shape from the 2026-07-06 cascade). Schema note corrected: `waiting_on` carries a dependency label (e.g. `"ca1 root cert"`), not a VM name. New `ok:`-tally fixture covers the previously zero-asserted result-counting path. 177 tests. (#225)

## [2.4.1] — 2026-07-09

### Fixed
- **`buildmon`: the VBox coverage tie-break no longer resolves against a standing lab while a larger lab could still be mid-creation.** During an unsettled Phase 1, a standing lab that supersets the observed create-log stems was the only candidate with every stem registered, so the tie-break confidently bound fresh builds to the wrong (standing) profile — both cold builds of the 2026-07-07 concurrent soak misbound to `ad-cs-two-tier`, inheriting its cross-run attempt counters and VBox name map. The tie-break now requires either zero superset candidates (the stems cannot be a partial build of anything known — immediate, as before) or a settled create phase (the same 180s heuristic as the exact-match gate; the collector's periodic re-inference observes the settle). 170 tests. (#217, #223)
- **`nuke.sh`: usage line advertised `--yes`, but the parser only accepts `--yes-delete-without-prompt`** — `--yes` errored "Unknown option" and the natural fallback `--confirm` still blocks on the interactive NUKE prompt in non-tty automation. Help text corrected; no behavior change. (#221)

### Added
- **Cold-start hardening campaign 2 — simultaneous triple-profile criterion, met on round 1.** `vagrant/docs/cold-build-readiness-edges.md` now defines and records the concurrency-grade acceptance bar: `pqc-full` + `ad-cs-one-tier` + `core` cold-built simultaneously (Phase-1 creates fully overlapped, standing `ad-cs-two-tier` untouched), all first-try clean — achieved 2026-07-09 (108m47s / 63m46s / 63m26s, 21/21 VMs first-attempt OK, zero transient machine-lock collisions; the v2.4.0 lock-guard machinery was armed but never provoked). (#222)

## [2.4.0] — 2026-07-07

### Added
- **`buildmon` multi-lab support — several builds running simultaneously.** The collector now **infers the lab profile** from the logdir's VM logs when `--profile` is omitted (`<vm>-create.log` files reveal the full VM set within seconds of Phase 1; exact component-set match wins, VBox-registration breaks ties like `core` vs `ad-cs-one-tier`, and a collector attached too early re-infers on every adoption rather than guessing) — without a profile, the VBox machine names (`straylight-<profile>-<vm>`) can't be resolved and every lab's `dc1` is ambiguous, leaving all power states `unknown`. VM resolution and auto-adoption now also use `<vm>-create.log` stems, so Phase 1 shows every VM as `pending` instead of falling back to the registered-VBox-machines tier, which mixed VMs from *every* concurrently registered lab into one feed (observed live: a pqc-full build tracking a phantom `ca1` from the neighboring one-tier lab). New `buildmon list` subcommand shows recent builds (newest first, validate-only dirs skipped) with profile/phase/feed freshness; a feed's own profile beats re-inference. `buildmon.sh` gains `list` and `start` (collector-only, no TUI) subcommands; `-p PROFILE` now *selects* the newest build matching that profile instead of being just a hint; the default pick skips non-build dirs and notes other live builds. 12 new tests (72 total).
- **`vagrant/scripts/buildmon.sh` — one-command buildmon launcher.** `buildmon.sh` starts the collector (idempotently — never double-attaches to the same logdir) on the newest build log directory and opens the live TUI; `status` gives a one-shot plain snapshot, `tail` follows the event stream, `stop` shuts the collector down cleanly. `-l LOGDIR`/`-p PROFILE` override the defaults (newest `vagrant/logs/<timestamp>/` directory — never the `ansible.log` file — and `$LAB_PROFILE`; the profile is optional since the collector derives and auto-adopts VMs from the logdir). Collector runs detached and survives terminal close; console output lands in `<logdir>/buildmon/collector-console.log`.
- **Cold-build readiness edge map** (`vagrant/docs/cold-build-readiness-edges.md`) — the spec behind the cold-build hardening campaign: every cross-VM dependency edge in the build (30 found), the readiness signal that gates each one, and the principle (wait on a real, observable upstream signal — never a timing assumption). Inventory result: 29/30 edges were already clean-signal gated; the one real gap is fixed below.
- **`buildmon` cross-run attempt tracking — reprovisions are no longer indistinguishable from cold builds.** `history.py` scans same-profile sibling logdirs newest→oldest to compute each VM's `attempt` (1 + prior failed/interrupted runs, stopping at the VM's last success or a manual reset marker); the feed gains optional per-VM `attempt` + `prior{failed,interrupted}` (emitted only when attempt > 1, still `buildmon/v1`), surfaced in the TUI row and `buildmon list` (`reprovision(N)`). `buildmon.sh -p <profile> reset-attempts` writes the cutoff marker. 36 new tests; real-data validated against the 2026-07-02 pqc-full reprovision history. (#208)
- **`buildmon` guest probes, warm-reboot detection, and alert hooks.** Read-only guest reachability probing feeds a per-VM `GUEST up/down` column; VBox power edges, TCP reachability flaps, and `last_boot` advances fuse into at most one `reboots` increment per reboot window — making guest-OS warm reboots (invisible to VBox: `VMState` stays `running`) finally visible, live-verified on a dc1 AD DS promo reboot. `buildmon.sh -e CMD` / `BUILDMON_ON_EVENT` exec an alert hook with the JSON event on stdin for failed/hung/done transitions. (#209)

### Fixed
- **`buildmon` hardening from first field use** (alongside real one-/two-tier builds): the collector now **auto-adopts** any VM whose `<vm>.log` appears in the logdir but isn't in the resolved topology — a wrong `--profile` self-heals instead of silently showing phantom VMs and missing real ones (plus a startup warning when the logdir's logs disagree with the profile); `collect` hard-fails with a clear message when `--logdir` isn't a directory (the `ls -t` trap: `ansible.log` is always the newest entry in `vagrant/logs/` during a build); `status.json` is published world-readable (`0644` — `mkstemp` left it `0600`, unreadable by other users/agents); the TUI blanks the meaningless ever-growing duration/stall columns once a VM reaches a terminal state; README documents the cwd-independent `__main__.py` invocation. 4 new tests (60 total).
- **`machine_cert`: idempotent cleanup of empty-subject autoenrollment-race certs.** Autoenrollment can fire mid-provision (notably during manage1's RSAT install) before the template's attribute set has materialized, leaving a Subject-less, EKU-less cert in `LocalMachine\My`. Harmless in itself, but `validate.sh`'s cert-hygiene check flagged it on every fresh cold build until hand-cleaned. The role now removes such certs (precise guard: empty Subject AND zero EKUs — the real machine cert always has both) right after confirming the real Server-Auth cert is present. Live-exercised on a clean `core` cold build (task `ok` on ca1/web1/manage1; 4/4 VMs `failed=0`).
- **`cert_templates`: template-publish failures now preserve their evidence.** On the rare cold-build publish failure, the role's unconditional temp-file cleanup deleted the scheduled task's log/status before anyone could read them. Cleanup now runs on the success path only; the failure path copies both to `C:\tmp\publish-templates-FAILED.*` before raising.
- **`up.sh`: a lock error striking mid-boot no longer leaves a half-configured VM that a plain retry silently "fixes".** The v2.2.3 lock retry re-ran `vagrant up` against a machine the interrupted attempt had already powered on, so Vagrant skipped boot-wait + guest network configuration entirely — the create "succeeded", the guest never got its static host-only IP, and the provision phase later died `UNREACHABLE: No route to host` (pqc-full web1, 2026-07-06). `create_vm` now tracks whether a failed attempt booted the VM and power-cycles it (lock-free `VBoxManage controlvm poweroff`) before retrying, so the full boot + network-config sequence re-runs. A new `_vagrant_retry_lock` helper also extends the transient-lock retry to every other lock-prone vagrant call that previously failed a build outright: Phase-3 background provisions, the dc1 overlap provision, snapshot save/restore, and the whole `--rebuild` path (whose create had no retry at all). (#211, #212)
- **`buildmon.sh`: `stop` → immediate `start` no longer races the dying collector; bare invocations no longer land on `dead-*` corpse dirs.** `stop` drops a `buildmon/stopping` marker before TERM and `start` waits out a flushing collector (the graceful final snapshot — guest probes across every VM — measured 25–35s+ on a 13-VM lab, so a fixed post-kill wait kept losing the race and `start` no-op'd with "already running"). Default logdir selection and `-p` matching skip `dead-*`-prefixed dirs, whose feeds mixed stale log state with live guest probes of a current build's same-named VMs. (#210, #212)
- **`subordinate_ca`: the online `-ParentCA` install could hang forever on the multihomed DCOM submit — replaced with offline request + `certreq -submit -config`.** The DCOM `ICertRequest` tower enumeration can bind the shared VirtualBox NAT IP (`10.0.2.15`) and block with no internal timeout (two-tier issueca 2026-07-06: 30 min to the schtask ceiling, `certocm.log` frozen at `Create Request`, zero requests reaching the parent; the `certutil -ping` readiness gate passes anyway). Same failure class #178 fixed for machine enrollment — this was the remaining call site. The wrapper now installs the CA with `-OutputCertRequestFile` (offline request), submits via certreq's direct named-host RPC bind (fails fast, 15×20s retry budget, explicit "Taken Under Submission" detection with operator remediation), then finishes locally; the Ansible-side timeout now also kills the wrapper's process tree, which `schtasks /delete` left running. Warm-tested (13s vs the 30-min hang) and cold-validated on both crypto lanes. (#213, #215)
- **`subordinate_ca` Phase 3: four cold-build defects in the offline finishing step, found and fixed on the first cold run.** (1) bare `certutil -installcert` raises a *hidden UI prompt* in the non-console schtask session and blocks at ~0 CPU — both call sites now pass `-f -silent`; (2) cold guests died `CERT_E_CHAINING` because the offline flow received only the leaf cert (the old DCOM response had carried the full chain) — `certreq -submit` now captures the PKCS#7 chain via its third output argument and Phase 3 splits it into the `Root`/`CA` stores with pure .NET before installing; (3) re-running over a prior attempt's pending-cert CA failed "already installed" — Phase 1 now uninstalls the incomplete role config and retries once; (4) a leftover `subca.rsp` failed every submit retry with `ERROR_FILE_EXISTS` — per-attempt output cleanup. Cold-validated live on both the classical and ML-DSA lanes: installs in 33–34s, clean recaps. (#218, #219)
- **`buildmon` collector: profile inference is now provisional while a larger lab could still be mid-creation, and a VM's *last* provision attempt decides its state.** Three fixes from the 2026-07-06 three-concurrent-labs incident: an exact component-set match no longer wins while another profile is a strict superset of the observed stems (7 of pqc-full's 13 create-logs exactly impersonated ad-cs-two-tier → confidently-wrong profile, blind to 6 VMs) — ambiguity resolves via the VBox tie-break or a 180s create-settle heuristic, with periodic re-inference while unknown; fatal-finish markers are attempt-scoped, so an in-place `vagrant provision` rerun's clean recap overrides the earlier failure instead of leaving a false `hung` VM dragging the build phase to `failed` across collector restarts; and helper logs (e.g. `web1-reload.log`) are no longer adopted as phantom VMs when a known profile disowns them. 10 new tests (168 total); replay-validated against the live incident logdir. Known residual: the VBox coverage tie-break can still resolve prematurely against a standing superset lab during Phase 1 (#217). (#210, #214, #216)

### Removed
- **Walkthroughs catalog reduced to one example module pending hands-on verification.** `docs/walkthroughs/` now ships only the **AD CS functional test** module (`adcs-functest-*`: 4 labs + quizzes + exam + design spec) as the representative example; the other ~200 files (76 labs, 73 quizzes, 18 exams, 18 specs, the 8-lab NIST track, and the template-processing reference notes) are preserved on the `content/walkthroughs-unverified` branch and return module-by-module as each passes manual, hands-on verification. `INDEX.md` regenerated (`gen-index.py` now tolerates absent modules / an empty NIST track instead of crashing); walkthroughs `README.md` rewritten for the example-only state; all repo references into removed labs (top-level `README.md`/`ARCHITECTURE.md`, `architecture-evolution.md`, `pqc-demo-runbook.md`, `acme_client`/`cloudflare_pqc` role comments) repointed to the holding branch — zero dangling links.

## [2.3.0] — 2026-07-01

### Added
- **`buildmon` — build-observability sidecar** (`vagrant/scripts/buildmon/`, Python stdlib-only). Aggregates every build-progress source into one live, machine-readable feed: per-VM ansible task + result tallies + current-task duration + stall detection (from the per-VM logs), VirtualBox power state + full-restart reboot transitions (read-only `VBoxManage`), build-phase derivation (creating → dc1-provision → parallel-provision → done/failed), cross-VM dependency-wait detection ("Wait for Root CA cert" → `waiting-dep: ca1 root cert`), and completion from a clean `PLAY RECAP` — so it works attached to *any* build, no PIDs needed. Fills the `up.sh` Phase-2 blind spot where dc1's ~14-minute promo showed only `waiting on background PID`. Run `python3 -m buildmon collect --logdir ../logs/<ts> --profile core` (sidecar) and `... watch` (curses/plain TUI); tools/agents poll `<logdir>/buildmon/status.json` and tail the append-only `events.ndjson` (versioned contract in `scripts/buildmon/schema.md`). Strictly an observer: no `vagrant`/`ansible` invocation, VBox verb allowlist, read-only guest-probe allowlist with soft-fail + isolation threading (probing ships disabled pending cred wiring). 56 unit/integration tests incl. an offline full-build replay; live-smoked against a real completed `core` build. Follow-ups tracked in the PR: guest-probe cred wiring, optional `up.sh` auto-launch hook, guest-OS warm-reboot visibility.

## [2.2.3] — 2026-07-01

### Changed
- **Per-lab forwarded-port windows — the ~12-concurrent-VM host ceiling is gone.** The box-defined WinRM/RDP/SSH forwards auto-correct into Vagrant's default `usable_port_range` of 2200–2250: 51 ports at 4 forwards per Windows VM caps the whole host at ~12 concurrent VMs, and the 13th VM's create dies with "the ports in the auto-correction range are all also used" (hit 2026-07-01 launching `full` alongside three running labs). Each lab now gets its own disjoint 800-port auto-correct window derived from its subnet, `2200+PORT_OFFSET .. 2999+PORT_OFFSET` (`.56` → 2200–2999, `.57` → 3200–3999, …): ~200 VMs of headroom per lab, and simultaneously-launching labs can no longer race each other for the same host ports. (#197)

### Fixed
- **Subnet allocator: two labs launched in the same window can no longer be handed the same /24.** `lib/lab_network.rb` counted only *running* VMs as occupying a subnet, but a freshly-launched lab has no VMs registered for the first minutes of Phase 1 — so `full` and `pqc-full`, brought up two minutes apart on 2026-07-01, were both allocated `192.168.59` (both dc1s at `.59.10`, the exact pre-v2.2.0 collision). Allocation now happens under an exclusive flock on a host-global claim registry (`~/.straylight/lab-subnets.json`): a claim marks the /24 taken from the instant it's chosen, stays live while any of the lab's VMs remain *registered* (running **or halted** — which also fixes the documented halted-lab-resume subnet-hop limitation), or for a 30-minute grace window when none are, and stale claims self-prune so a nuked lab frees its /24. Running VMs stay authoritative; CI/lint boxes without VBoxManage never touch the registry. 7 new allocator tests incl. the same-window race regression. (#198)
- **`up.sh` no longer hard-fails a build on Vagrant's transient machine-action lock.** Vagrant acquires its per-machine flock (`~/.vagrant.d/data/lock.machine-action-<md5>.lock`) with retry disabled, so a momentary overlap with another vagrant process touching the same machine killed an otherwise healthy Phase-1 create with "Vagrant can't use the requested machine because it is locked!" — seen 2026-07-01 when three labs built concurrently and the two-tier build's dc1/manage1 creates died mid-import/boot. `create_vm` now detects that signature and retries the create up to 3× with a 10s backoff (detection scoped to the current attempt's log output, so an earlier lock error can't mask a different later failure; non-lock failures still fail immediately). Also gated the Phase-2-overlap `vagrant provision dc1` on the create actually succeeding: it previously fired even after a failed create, running Ansible against a VM whose host-only NIC was never configured (stuck on 169.254.x APIPA) and burying the real error under a misleading `UNREACHABLE ... No route to host`; Phase 2 now fails fast (`DC1 create failed — skipping provision`) and the FATAL message points at `dc1-create.log` instead of the absent provision log. (#196)

## [2.2.2] — 2026-07-01

### Fixed
- **NIST 800-52 step-ca client-cert issuance now actually runs.** The `nist-800-52-mtls-profile` and `key-establishment` labs issue certs from step-ca's JWK `admin` provisioner, but the commands could not succeed as written — three compounding bugs, all confirmed against a booted `stepca-only` lab: (1) the admin provisioner is password-protected, so `step ca certificate --provisioner admin` prompted interactively and hung under `sudo bash -c` — now writes the `stepca_password` lab default to a file and passes `--provisioner-password-file`; (2) `--not-after 720h` exceeded the admin provisioner's 24 h maximum certificate duration and was rejected outright — changed to `--not-after 24h`; (3) `step ca revoke --serial "$SERIAL"` used a non-existent `--serial` flag (and serial-based revoke prompts to pick a provisioner interactively) — switched to possession-based `step ca revoke --cert … --key …`. Issuances are now self-contained (explicit `--ca-url …:9000` + `--root`) and were live-verified end-to-end (issue + revoke, exit 0). (#194)
- **Exam Deep Dive answer keys are no longer mislabeled or answer-leaking.** The acme-extended, http-01-automation, mtls, and pqc exams already carried answer-key entries for the "Deep Dive" Q41–Q80, but under an inconsistent `**A41.**`–`**A80.**` prefix, and every Deep Dive multiple-choice stem still bolded its correct option — spoiling the answer before the collapsible key. Removed the stem-bold from all Deep Dive MC options and renamed the `A##` key headers to `Q##`, so each exam is a clean, contiguous Q1–Q80 key with no in-stem leaks. No answer content changed. (#194)
- **CI `Lint` job unbroken after ansible-lint 26.6.** ansible-lint is installed unpinned (`ansible-lint>=24`); 26.6.0 promoted five pre-existing rule families (`yaml[colons]`, `yaml[commas]`, `name[template]`, `command-instead-of-module`, `ignore-errors`) to `production`-profile errors, turning the previously-green Lint red on unchanged content. Extended the existing `.ansible-lint` `skip_list`/`warn_list` — the same "pre-existing stylistic/idiom patterns, not worth churning" policy already applied to `yaml[line-length]`, `name[casing]`, `command-instead-of-shell`, etc. Version-independent, unlike pinning the tool. (#193)

## [2.2.1] — 2026-07-01

### Removed
- **cert-manager lab family cut** (4 walkthroughs + quizzes + exam + spec, 10 files). The lab ships no k3s/Kubernetes infrastructure to run them against, and the content referenced a fabricated cert-manager API surface (a nonexistent `caBundle.installCRDs` Helm value, a `renew-before-percent` annotation, wrong alert-selector labels and metric names). `INDEX.md` regenerated (80 labs / 22 modules / 0 orphans); remaining cert-manager mentions are conceptual tool references in prose, not links.

### Fixed
- **`docs/walkthroughs` public-readiness correctness pass.** These 228 lab/quiz/exam/spec files were AI-generated and de-vendored but never human-read; a multi-agent review (cross-checking every claim against the live repo) surfaced 366 findings, which were corrected across the tree before the public visibility flip. Highlights:
  - **The step-ca revocation-lab family was built on a false premise.** Stock step-ca (`DOCKER_STEPCA_INIT_ACME`) ships **no** OCSP responder and issues leaves with no AIA/CDP, so `openssl ocsp`/CRL steps no-op and the documented "good/revoked" output was unreachable. All six revocation walkthroughs + quizzes (and the CAA/NIST labs that leaned on the same premise) were repointed to **EJBCA CE's real built-in OCSP responder** (`http://ejbca1:8080/ejbca/publicweb/status/ocsp`) and CRL (`ejbca.sh ca getcrl`/`createcrl`), with step-ca reframed as the passive-revocation contrast. Live-verified end-to-end on a booted `ejbca-only` lab.
  - **`pqc-adcs-gap` thesis corrected.** It claimed Windows Server 2025 CNG lacks ML-DSA/ML-KEM; CNG PQC primitives are GA (Nov 2025, KB5068861) and the real gap is the CertEnroll/AD CS **issuance** layer. Probe is `BCryptOpenAlgorithmProvider`, not the false-negative `certutil -csptest`.
  - **`mtls-ejbca-admin` rewritten against the shipped EJBCA** — no dedicated "ManagementCA" exists (admin certs come from `EJBCA-Issuing-CA`); real P12 path (`/opt/ejbca/data/secrets/superadmin.p12`), password sourced from `superadmin.pwd`, and flag-based EJBCA 9.3.7 CLI syntax.
  - **Command/reference corrections across the board:** AD CS CA common names hyphenated (`YOURLAB-Issuing-CA`) so `certutil -config` resolves; CDP/AIA host `pki.yourlab.local/crl,/aia`; `LAB_PROFILE` bring-up lines fixed to profiles that actually define the target VMs; NIST 800-52 step-ca URLs given `:9000` and the fingerprint computed on the host (not inside a nested heredoc); OpenSSL FIPS AES modes (ECB/OFB/CFB are approved), KAT/enforcement behavior, and an inverted CI gate; Windows PKI HRESULTs/event-IDs/OIDs; JKS key-protection mechanism (SHA-1-based, not DES); CAA records via the `-Type 257` Unknown-record cmdlet; HAProxy `ocsp-update` (2.8+) and Apache `SSLCertificateChainFile` (deprecated-but-functional) facts; quiz/exam answer-key errors; dead links; and AI-tell placeholders (bare "the URL", leaked exam answers, duplicate "Deep Dive" exam padding).

## [2.2.0] — 2026-06-30

### Added
- **Per-lab host-only /24 subnets — concurrent labs no longer collide.** Every lab previously drew its static IPs from one global `topology.yml` `network` (`192.168.56`), so running two profiles at once put both labs' `web1` on `192.168.56.30`, both `dc1`s on the same IP, etc., on one shared host-only subnet — first-mover won the address and later labs failed with WinRM `Connection refused` / a broken CA hierarchy. Each lab is now allocated its **own** host-only `/24`, chosen dynamically at bring-up by `lib/lab_network.rb`: the lowest free third octet from `192.168.56` upward, skipping `/24`s already occupied by running VMs (queried via `VBoxManage`). A profile is **not** pinned to a subnet — it reuses whatever `/24` its own running VMs are on, else grabs the next free one. `Topology.network` is overridden per-run from the allocated value, so `IP_ADDRESSES`, the Vagrantfile private networks + cross-VM vars, the rendered Ansible inventory, and `/etc/hosts` all follow automatically; bash consumers (`up.sh`, `validate.sh`, the `cbom-*`/`pqc-*` scripts) get it via an exported `LAB_NETWORK` and a new `lab_vm_ip`/`lab_network` resolver in `scripts/lib/lab-secrets.sh`. An explicit `LAB_NETWORK` (shell or `vagrant/.env`) still wins. VirtualBox's default host-only range (`192.168.56.0/21`) covers 8 concurrent labs (`.56`–`.63`) with zero host config; beyond that, widen `/etc/vbox/networks.conf`.
  - **Migration:** if you ran the old install-wizard, `vagrant/.env` contains a baked `LAB_NETWORK=192.168.56` line that pins **every** profile back to the shared `.56` subnet and silently re-introduces the collision. **Delete that line** (or re-run `scripts/install-wizard.sh`, which no longer writes it) to enable per-lab subnets. `profile-helper.sh` prints a one-time note when it detects this.
- **KVM/AMD-V VirtualBox blocker troubleshooting doc** (`docs/kvm-amd-v-vbox-blocker.md`) — diagnosing and fixing the `VERR_SVM_HOST_SVME_NOT_ENABLED` VM-start failure (dies at the first VM, dc1) when the host's `kvm_amd`/`kvm` kernel modules hold AMD-V exclusively: how to confirm it's the modules and not BIOS (`svm` flag vs `lsmod` refcount), plus the runtime (`modprobe -r`) and durable (blacklist) fixes. (#189)

### Changed
- **`nuke.sh` destroys VMs in parallel, with a hard-poweroff first.** The serial `vagrant destroy` loop idled on Vagrant's per-VM Ruby startup and a 10–30s ACPI graceful-shutdown wait per *running* VM (~5–6 min on a 13-VM profile). VMs are now hard-powered-off up front via `VBoxManage controlvm … poweroff` (so `vagrant destroy` skips the ACPI wait) and destroyed concurrently, capped at `NUKE_PARALLELISM` (default 8). `--keep`/`--only`/`not_created` handling and the failure tally are unchanged. ~5–6 min → under a minute. (#186)

### Removed
- **`vagrant/docs/cbom-diagram.vsdx`** — stale binary Visio export, superseded by the editable `cbom-diagram.drawio` (+ `.txt`) beside it; unreferenced anywhere in the repo. (#189)

### Fixed
- **observe_timer: ingest service rendered `--insecureStandardOutput=journal`.** The systemd `.service` template ended the `ExecStartPost` ingest line on a `{% for %}` loop; with Ansible's `trim_blocks` the trailing newline was stripped and the next directive (`StandardOutput=journal`) concatenated onto the last ingest arg. For `cloudflare_pqc` (last arg `--insecure`) this made `cbom_ingest.py` reject the command, so the Cloudflare-edge CBOM docs never reached OpenSearch and `validate.sh`'s `cloudflare_pqc-opensearch-ingest` check failed on every build. Switched the arg loop to `| join(' ')` so the line ends on an expression and the newline survives. (#184)
- **docs(how-it-works): corrected the PQC-migration run block.** It used the stale top-level `inventory/pqc.ini` (rendered only for whatever profile ran last — e.g. `ad-cs-two-tier`, missing every PQC host); corrected to the per-profile `inventory/<profile>/pqc.ini`. The lab-wide `psf_init`/`schtask_admin_init` need no `-e` override — `pqc-chimera.yml`'s `vars_files` fallback (#152) supplies them. (#183, #185)

## [2.1.5] — 2026-06-29

### Fixed
- **Cold-build readiness gates for the cms-lab CA enrollments + cert_templates.** Two cold-build races, surfaced by a clean `pqc-full` cold build:
  - `cms_lab_linux` (scanner1) submits its CSRs `delegate_to` the issuing CAs. On a cold build scanner1 outran issueca/issueca-pqc and a delegated WinRM call landed during the CA's **domain-join reboot** → the host went *unreachable*, which **no** Ansible retry primitive survives (verified: `until`+`ignore_unreachable` skips through it; `block`/`rescue` does not catch unreachable). Replaced the delegated probe with a **reboot-immune forward-signal gate**: scanner1 polls the issuing CA's CRL on web1's CDP (`/crl/<CA>.crl`, `/crl/pqc/<CA>.crl`) until 200 — a published CRL means that CA is up and past its reboot, and `uri`→web1 is `until`-retryable (a non-200 is a normal failed result, not host-unreachable).
  - `cert_templates` had no Ansible-level retry — a transient WMI/scheduled-task stall under parallel-provision load timed out the 600s `schtasks` wait and hard-failed the CA. Added idempotent `until/retries` (3×) so a recoverable in-guest stall is retried. (A fully hung/network-dead VM remains VBox-level and out of scope.)
- **cms_lab_linux: replace hang-prone `certutil -ca.chain` with an AIA cert fetch.** The chain-export step ran `certutil -ca.chain` on the issuing CAs to extract their certs; that command builds **and revocation-checks** the chain (AIA/CRL/OCSP retrieval + a local CA-RPC call) and, with no task timeout, **hung a cold build 15+ min at ~0% CPU**. It now fetches the issuing-CA cert from web1's AIA over HTTP (the same reboot/hang-immune path the root cert already used) and converts it with `openssl x509` — no certutil, no CA-RPC, no revocation, `until`-retryable. Drops the unused intermediate `.p7b`. Live-validated on scanner1.

## [2.1.4] — 2026-06-28

### Fixed
- **cms_lab_windows: enroll lab certs via `certreq -submit` instead of `Get-Certificate`.** On the multi-homed Vagrant CA VMs every guest shares the VirtualBox NAT IP `10.0.2.15`, so the CA's RPC endpoint mapper hands a remote client an endpoint that resolves to the client *itself* — `Get-Certificate`/CertEnroll's DCOM bind then fails with `RPC_S_SERVER_UNAVAILABLE` (0x800706ba), breaking the manage1 RSA + ML-DSA-65 lab-CA enrollments on a cold build. The role now renders an AD-bound template INF and submits with `certreq -new/-submit -config "<host>\<ca>"/-accept` under a SYSTEM scheduled task (the same direct-bind path `machine_cert` autoenroll and `pqc_machine_cert` already use), which is unaffected by the shared-NAT RPC misroute. New `templates/{rsa-labca,mldsa-labca}.inf.j2` + `templates/labca-enroll.ps1.j2`; CA config strings sourced from the existing `vars/cms_lab_ca.yml` single source of truth.

## [2.1.3] — 2026-06-26

### Added

- **Generated lab `INDEX.md` navigator** — a deep-linked, module-grouped index of
  the lab walkthroughs (each lab → its walkthrough, paired quiz, and the
  `LAB_PROFILE` it needs), produced by
  [`gen-index.py`](docs/walkthroughs/gen-index.py). (#163)

### Changed

- **Install wizard is Linux-only** — dropped macOS support and the `--topology`
  flag (topology is selected via `LAB_PROFILE`); added a historical Windows 11
  note. (#160)
- **Documentation tone + accuracy pass** across the root docs, `ARCHITECTURE.md`,
  and the `vagrant/docs/` guides — neutral-tone revisions, consistent "Straylight"
  capitalization in prose, a simplified Host-platform section, the Linux-only host
  policy stated explicitly, a dropped README version banner, and a corrected CBOM
  Mermaid diagram. (#159, #161, #162, #164, #167)
- **De-branded residual "Shark Lab" → "Straylight Lab"** inside the lab
  walkthroughs — code-signing cert CN, GPG signing-key name, the apt/dnf
  signed-repo slug + keyring filename, and two stray prose references. (#169)

### Removed

- **The `zakrodriguez/shark` upstream companion-repo dependency.** The lab
  walkthroughs under `docs/walkthroughs/` are now self-contained Straylight
  content rather than a vendored snapshot — removed the cross-link machinery and
  deleted `SYNC.md` (the upstream-sync procedure). (#168)

### Fixed

- **Lab catalog count** — corrected the walkthrough lab count (added the missing
  `pqc-composite-tls` lab). (#165)

## [2.1.2] — 2026-06-25

### Added

- **EJBCA Enterprise composite-cert spike runbook** —
  [`vagrant/docs/ejbca-ee-composite-spike-runbook.md`](vagrant/docs/ejbca-ee-composite-spike-runbook.md).
  A throwaway, off-lab procedure to prove EJBCA **EE 9.5** issues a LAMPS
  composite certificate end-to-end and capture the intel the eventual CE 9.5
  upgrade needs (composite SPKI/sig OIDs, draft level, issuance surface, bundled
  WildFly/BC versions), buying down the composite-sig CANARY upgrade-plan
  unknowns before CE 9.5 publishes. Explicitly **not** part of the lab build —
  no profile, role, or cold build touches it; keeps the open-source-only
  (CE + step-ca) promise intact. (#148)

### Changed

- **Tech-debt hardening sweep (2026-06)** — idempotency + error-handling guards
  across Ansible roles and Ansible collection pinning (#153); shell-script
  hardening (trap-based cleanup, `flock` watch guards, `mktemp` + `VBoxManage`
  error handling) in `up.sh` / `nuke.sh` / `start-vms.sh` / `stop-vms.sh` /
  `validate.sh` (#154); CI job timeouts + GitHub Action SHA pinning in `ci.yml`
  (#151). Validated end-to-end on a full `pqc-full` cold build (231/0/2).
- **Docs accuracy** — AD CS ML-DSA **leaf** issuance marked shipped (was a stale
  "in progress") across README, `ARCHITECTURE.md`, and `pqc-demo-runbook.md` (#150).

### Fixed

- **Standalone `pqc-migrate.yml` group_vars gap** — the chimera dc1 trust play now
  loads `psf_init` / `schtask_admin_init` via a `vars_files` fallback, so the
  orchestrator runs against `inventory/<profile>/pqc.ini` with no `-e` overrides
  (#152). Confirmed on the cold build: all 5 phases ran clean with no extra vars.
- **`cms_lab_linux` CSR submit cold-build race** — widened the RSA (`issueca`) and
  ML-DSA (`issueca-pqc`) submit retry guards from `retries: 10` (~5 min) to
  `retries: 40` (~20 min) so they outlast a cold issuing-CA provision (~28 min);
  fixes a `scanner1` provision abort (WS-Man `InvalidSelectors`) on cold
  `pqc-full` builds (#155).
- **`validate.sh` machine-cert chain check** — exclude self-signed certs
  (`Issuer -ne Subject`) so the check no longer grabs a `cms_lab_windows`
  self-signed demo cert and reports a false "Cert chain invalid" on manage1 (#156).

## [2.1.1] — 2026-06-24

### Added

- **Composite-signature lane (expected-fail canary).** Documents the third
  PQC-signature philosophy — IETF LAMPS composite signatures
  (`draft-ietf-lamps-pq-composite-sigs`, OID `1.3.6.1.5.5.7.6.41` for
  `MLDSA65-RSA3072-PSS`) — alongside the existing pure-ML-DSA and chimera/alt-sig
  lanes. A go/no-go spike against the pinned stack confirmed **live** that
  EJBCA CE 9.3.7 cannot issue composite (`gencsr` rejects the key algorithm:
  *"Key Algorithm MLDSA65-RSA3072-PSS was unknown"*; bundled BouncyCastle 1.80.2
  predates composite, which lands in BC 1.82) and OpenSSL 3.5 cannot serve it, so
  the lane ships as a documented, reproducible canary (Gate A ❌) with EJBCA 9.5
  as the named unblock path. New
  [composite-sig walkthrough](docs/walkthroughs/labs/pqc-composite-tls-walkthrough.md)
  + [quiz](docs/walkthroughs/quizzes/pqc-composite-tls-quiz.md) put all three
  hybrid-signature philosophies on one design matrix (key/sig model,
  backward-compat, separability, standards home); cross-linked from the chimera
  walkthrough and the walkthroughs catalog. Spike verdict recorded in the
  design spec.

- **Editable draw.io diagram companions** for all 16 of the repo's Mermaid
  diagrams (`ARCHITECTURE.md` ×6, `docs/how-it-works.md` ×9,
  `docs/configuration.md` ×1). Each inline ` ```mermaid ` block is kept (still
  renders natively on GitHub) and gains a linked `.drawio.svg` under
  `docs/diagrams/` that renders as an image **and** opens editable in draw.io
  (embedded `<mxfile>`). Mermaid stays canonical; draw.io is the editable
  companion (manual double-maintenance — no automated Mermaid↔draw.io sync). (#145, #146)

### Changed

- `ARCHITECTURE.md` — recorded the **host platform as Linux-only** (new "Host
  platform" section). Windows (via WSL2) and macOS hosts were evaluated and
  declined: WSL2 → VirtualBox host-only networking is unguaranteed by any vendor,
  WSL2 forces a Hyper-V/NEM performance tax that compounds the cold-build races,
  and macOS needs an ARM-guest track blocked by Windows Server ARM64
  availability. (#144)

- `vagrant/docs/server-build-workflow.md` — added a prerequisites note for the
  `VERR_SVM_HOST_SVME_NOT_ENABLED` VirtualBox boot failure: on AMD hosts a
  loaded `kvm_amd`/`kvm` module set holds AMD-V away from VirtualBox; free it
  with `sudo modprobe -r kvm_amd kvm` before building.

- `docs/configuration.md` — renamed the configuration "layer" ladder off OSI-colliding numbers (`Layer 1`…`Layer 10`) to named tiers in precedence order; the per-role Windows + Linux config tier (formerly `Layer 9`) is now the **Config Plane**. Updated all headings, the precedence ladder, the "Where to set what" table link text, the Mermaid subgraph (`L9` → `CP`), prose, and the two in-doc cross-references. Anchor `#layer-9--…` → `#config-plane--per-role-config-windows--linux-os-settings--app-installs`. No content moved.

- Integrated the **Recall** plugin for local session history — `.gitignore` for
  `.recall/` artifacts + auto-save config. Developer tooling only; no lab impact. (#142)

## [2.1.0] — 2026-06-18

Architecture-review remediation complete. This release lands the final six
campaigns of the 2026-06 review (C7–C12 + C9 part 2) — the theme throughout is
collapsing the lab's hand-synced duplications into single sources of truth and
adding guards so they can't silently drift again (see the new
[docs/architecture-evolution.md](docs/architecture-evolution.md)). Headline work:
the `validate.sh` monolith decomposed into a harness + per-VM check modules;
observability contracts (versioned CBOM envelope, ISM retention, index
templates); PKI lifecycle correctness (PQC CDP/AIA namespace split, automated
CRL republish, end-to-end revocation); Packer consolidation; a shared PQC
verifier; and `ARCHITECTURE.md` made the CI-checked authoritative VM inventory.
The whole set was **live-validated together on a full `pqc-full` cold build
(13 VMs): 231/0/2** — which caught and fixed three real bugs (a `cms_lab_linux`
enroll RPC race, a `cms_lab_linux` PQC-AIA path missed by C10's namespace split,
and a cloudflare ingest query stale after C7's keyword mapping). An exhaustive
parallel docs pass then propagated the new architecture across every
lab-architecture doc. Role count 66 → 69.

### Added — observability contracts + retention (campaign C7)
- **Versioned CBOM ingest envelope** (OBS-01). The `cbom_*`/`cf_*`/`adcs_*`
  field vocabulary and the producer registry now live in ONE source of truth,
  `cbom-toolkit/schema/cbom_envelope.json`. The OpenSearch index mapping is
  generated from it by `cbom-toolkit/python/gen_opensearch_mapping.py`
  (consumed by the `opensearch_stack` role), so the index and the ingest
  producer can no longer drift on field types. `cbom_ingest.py` dispatches via
  the registry keyed on the report's `schema` field (falling back to CycloneDX)
  instead of ad-hoc `startswith()` sniffing, and stamps every document with
  `cbom_envelope_version` + `cbom_schema`.
- **Index lifecycle / retention** (OBS-02). The `opensearch_stack` role applies
  an ISM policy (`straylight-retention`, default 14-day delete phase) auto-
  attached to `logs-*`/`cbom*` indices. Beats now ship to date-suffixed
  indices (`logs-windows-%{+yyyy.MM.dd}` / `logs-linux-%{+yyyy.MM.dd}`) so the
  delete phase ages out whole daily indices instead of letting one fixed-name
  index grow unbounded on the single-node cluster.
- **Beats index templates** (OBS-03). A server-side `straylight-logs` index
  template locks `@timestamp`/`lab_source`/`lab_domain`/`log_type`/`message`
  types (and a `straylight-cbom` template applies the generated CBOM mapping),
  closing the silent type-drift-drops-documents gap from dynamic mapping.
- **Generalized the timer+ingest pattern + ingested the AD CS audit** (OBS-06).
  New reusable `observe_timer` role templates a systemd oneshot service + timer
  + optional `ExecStartPost` ingest hook; `cloudflare_pqc` now consumes it
  instead of hand-rolling its own units (the emitted `cloudflare-pqc.timer`
  unit name is unchanged, so validate.sh is unaffected). `Invoke-PqcAudit.ps1`
  now also writes an `adcs_pqc_audit/v1` JSON sidecar; the `adcs_pqc_audit`
  role fetches it and ingests it through `cbom_ingest.py`, so the audit feeds
  OpenSearch instead of being a text-file dead-end.
- **Robust deterministic `_id`** (OBS-08). `cbom_ingest.py` mixes a content
  hash into the `_id` when the scan timestamp is coarse or missing, so distinct
  scans taken in the same window no longer silently overwrite each other while
  an identical re-ingest of the same record still upserts.
- Validation: offline only — `py_compile` + 33 classifier tests pass,
  `ansible-lint` clean on the new `observe_timer` role, mapping generator and
  ingest dispatch smoke-tested. **Not** live-tested: the active lab profile is
  `pqc-adcs-two-tier`, which has no observe1/scanner1; needs a `pqc-full`
  cold-build to exercise ISM/template creation and the end-to-end ingest paths.
### Changed — consolidated the Packer image pipeline (campaign C8)
- **Collapsed the four near-identical version templates into ONE parameterized
  template** (PACK-01/07). `packer/windows/{2016,2019,2022,2025}/windows-server-*.pkr.hcl`
  (100% identical except a version string + `guest_os_type`) and their
  byte-identical `Autounattend.xml` copies are replaced by a single
  `packer/windows/windows-server.pkr.hcl` selected via `-var win_version=<ver>`
  (validated against 2016/2019/2022/2025) with a `locals` lookup map for the
  one per-release difference (`guest_os_type`), plus one shared, version-neutral
  `packer/windows/answer_files/Autounattend.xml`. The 2016-Datacenter-vs-Standard
  image-index caveat is now documented in that one file instead of a stale
  "verified against the 2022 ISO" comment carried in all four.
- **Added a box freshness contract** (PACK-04). `build-images.sh` now stamps
  each build with a `box_version` (default UTC datestamp `YYYY.MM.DD`, override
  `BOX_VERSION=...`), names the artifact `straylight-windows-server-<ver>-<box_version>.box`,
  and registers it with `vagrant box add --box-version`, so rebuilds no longer
  silently overwrite each other under one name. `config.rb` reads
  `STRAYLIGHT_BOX_VERSION` and the Vagrantfile threads it into
  `config.vm.box_version` (via a new `set_box` helper) for `straylight/*` boxes
  only; upstream gusztavvargadr boxes keep their own versioning.
- **Resolved the patch-baseline / WSUS asymmetry** (PACK-02/06). DECISION:
  straylight boxes ship **unpatched by design** — the patch path is the runtime
  WSUS golden-master loop (`wsus_server` role + `cache-wsus.sh`), not a baked
  snapshot. `install-updates.ps1` is kept but reduced to staging the
  `PSWindowsUpdate` module (its dead `Get-WindowsUpdate` line stays commented,
  now with an explicit rationale), and a new "Patch baseline" section in
  `packer/README.md` documents why baking updates would duplicate the cache, go
  stale every Patch Tuesday, and undo PACK-04's reproducibility.
### Changed — conventions pass: role/var/identity consistency (campaign C11)
- **`openssh_pqc` + `gnupg_pqc` declare defaults via `defaults/main.yml`** (LROL-06),
  matching the `openssl_35` model instead of self-referencing `set_fact`
  fallbacks. Behavior-identical: `defaults/main.yml` has the lowest var
  precedence, so play/inventory overrides still win exactly as before.
- **CMS-lab var names made symmetric + CA config single-sourced** (LROL-05). The
  asymmetric `cms_lab_win_classical_*` infix is gone (now
  `cms_lab_win_{ca_config,ca_template}`, mirroring `cms_lab_linux`'s scheme:
  bare `*_ca_*` = classical, `*_pqc_*` = PQC). The four AD CS enrollment strings
  (classical/PQC CA config + template names), previously duplicated in both
  roles' defaults, now live once in `vagrant/ansible/vars/cms_lab_ca.yml`, which
  both roles `include_vars` (the existing `playbook_dir/../` idiom). Resolved
  values are byte-identical.
- **Windows identity model documented in one place** (WROL-07). A new "Windows
  identity model" section in `roles/README.md` is the single source of truth for
  the three security contexts (default WinRM user vs SYSTEM scheduled task vs
  explicit-domain-admin scheduled task), the double-hop rationale, and a decision
  shortcut; cross-referenced from `enterprise_ca` (domain-admin) and
  `machine_cert` (SYSTEM), the canonical implementations.
- **PQC-demo cert contract reconciled** (LROL-04). `openssl_pqc_demo` no longer
  silently assumes sibling CA PEMs: the issuing/root/chain paths are now
  overridable vars in its `defaults/main.yml` (defaulting to the prior hard-coded
  sibling paths), asserted up front with a clear `fail_msg` like
  `nginx_pqc_demo`. The shared cert contract is documented once in
  `roles/README.md` ("PQC demo cert contract"). Behavior-preserving; the only new
  effect is an earlier, clearer failure when the contract is unmet.
- **Shared scheduled-task helper** (WROL-06). The copy-pasted domain-admin
  `schtasks` create/run/poll/delete/read-back lifecycle is centralized in the new
  `win_scheduled_task` role (dot-sourceable `Invoke-StraylightAdminScheduledTask`,
  exposed via `{{ schtask_admin_init }}`). `ejbca_ad_trust` + `stepca_ad_trust` —
  the two byte-identical, lowest-risk sites — now route through it, dropping ~25
  lines of boilerplate each; wired into the 3 playbooks that run them. The
  higher-risk bespoke sites (`enterprise_ca`, `subordinate_ca`, `ca_services`,
  `cert_templates`, `cert_templates_pqc`) are deferred to the cold build. (Role
  count 67 → 68.)
### Changed — docs architecture: authoritative inventory + freshness check (campaign C12)
- **ARCHITECTURE.md is now the authoritative, CI-checked VM inventory** (DOC-10).
  The fleet was restated across ~5 docs with no source of truth and no guard —
  CI only proved profiles *resolve*. ARCHITECTURE.md's "VM inventory" section
  now carries a full 20-VM table (name/IP/OS/role) derived from
  `vagrant/topology.yml`, and new `vagrant/test/doc_inventory_test.rb` fails the
  build if the table drifts from topology.yml. CI now also runs the C5
  `topology_test.rb` consistency suite (previously only `lab_profile_test.rb`
  ran).
- **README VM tables replaced with links, not restatement** (DOC-09). The
  one-tier/two-tier tables silently omitted the entire Linux/observability/
  PQC-AD-CS fleet; they're replaced with pointers to the authoritative
  ARCHITECTURE.md inventory + topology docs, so there's no fourth hand-synced
  copy to drift.

### Changed — PKI lifecycle: CRL republish, namespace split, revocation (campaign C10)
- **Separate CDP/AIA namespace for the PQC hierarchy** (PKI-01). The classical
  and ML-DSA hierarchies no longer share one CRL/AIA directory on web1: PQC CAs
  now bake `http://pki.<domain>/crl/pqc` + `/aia/pqc` into issued certs, and
  `publish_ca_artifacts` gained a `publish_subdir` param so PQC artifacts land in
  `\crl\pqc` + `\aia\pqc` on the PKI$ share (web1 pre-creates + serves them; MIME
  + dir-browse inherited from the parent virtual dirs). A revocation or CRL
  refresh in one hierarchy never touches the other's namespace.
- **Automated CRL republish on the online issuing CAs** (PKI-04) via the new
  `ca_crl_republish` role — a daily SYSTEM scheduled task runs `certutil -CRL`
  and re-copies to web1's CDP, run once at provision time too. The 26-week CRL
  validity is now a cold-start cushion, not the refresh mechanism. Offline
  standalone roots are excluded by design. (Role count 66 → 67.)
- **Revocation exercised end-to-end** (PKI-02) — new
  `docs/walkthroughs/labs/adcs-revocation-walkthrough.md`: enroll a throwaway
  leaf → `certutil -revoke` → republish → confirm `CRYPT_E_REVOKED`. Closes the
  gap where CRLs were checked for freshness but never for carrying a revocation.
- **Trust-anchor distribution map** added to ARCHITECTURE.md (PKI-03) — a
  per-anchor source of truth for which anchor reaches which store by which
  mechanism, plus the CDP-namespace + revocation-lifecycle summary.
- **observe1 ACME cold-start note corrected** (PKI-05) — the :443 cert
  self-heals via the `acme-renew` boot unit (`OnBootSec=5min`); manual
  `vagrant provision observe1` is only for an immediate re-issue. Held up as the
  reference lifecycle pattern in the runbook.

### Changed — decomposed the validate.sh monolith (campaign C9, part 1)
- **Split the 2,459-line `validate.sh` into a harness + per-VM check modules**
  (SCRP-01). `validate.sh` is now 180 lines (bootstrap → profile/VM discovery
  → dispatch → aggregation). The harness core moved to
  `scripts/lib/validate-harness.sh` (`record_result`, `launch_check`, the
  `run_windows_check`/`run_linux_check` transports, `is_running`, `skip_*`);
  the shared `ps_check_*` PowerShell snippets to `scripts/checks/common.sh`;
  and each VM's assertions to `scripts/checks/<vm>.sh` as a
  `register_checks_<vm>()` function. Check bodies were carried over verbatim —
  dispatch order is preserved so output stays byte-stable.
- **Vanishing checks now fail loudly** (SCRP-04). A check that errored under
  `set -e` + `|| true` used to emit no PASS/FAIL line and silently disappear
  from the tally; the aggregator now surfaces a FAIL for any launched check
  that produced no recognized result (SKIP-only output still counts as ran).
- **Per-check remote scripts self-delete** (SCRP-02). `run_windows_check` now
  removes its uploaded `C:\validate-*.ps1` in the same WinRM call, so no
  per-check debris accumulates on Windows VMs across runs.
- **validate runs leave a triage artifact** (SCRP-10). Output is teed to
  `logs/<timestamp>/validate.log` (ANSI-stripped), mirroring up.sh's
  per-run log convention.

### Changed — shared PQC verifier, one source of truth (campaign C9, part 2)
- **Killed the `pqc-migrate` ↔ `validate.sh` hand-sync** (PLAY-04). The
  `playbooks/README.md` directive "when a probe semantic changes, update both"
  is gone. The three probe bodies that both tools genuinely share now live once
  in `scripts/lib/pqc-verify/`: `ssh-kex.sh` (OpenSSH 10 ML-KEM hybrid KEX),
  `gpg-kyber.sh` (GnuPG Kyber/ML-KEM round-trip), and `tls-pure-leaf.sh` (pure
  ML-DSA-65 TLS leaf, `PORT`-injected). `validate.sh` `cat`s these files into
  its remote check strings — byte-identical to the previous inline heredocs, so
  C9-part-1's byte-stable output is preserved — and `pqc-migrate-{ssh,gpg,tls}.yml`
  run the same files via `ansible.builtin.script` with
  `failed_when: "'FAIL:' in <reg>.stdout"`. Editing one file now updates both.
- Probes that diverge by design stay consumer-specific and are documented as
  such in `playbooks/README.md`: Foundation (EJBCA CA ML-DSA assertion), the
  chimera DER-hex / `asn1parse` OID probes, the Windows `win_shell` IIS + AD
  trust probes, and the global posture sweep.

## [2.0.0] — 2026-06-15

Second stable release. Major bump: the topology→profile model, the
`ADCS_TOPOLOGY` env-var removal, the `web`→`web1` VM rename, and the removal
of the offensive AD CS / incident-attack content are breaking changes — see
the per-entry migration notes below. Headline additions since v1.0.0: a
parallel ML-DSA AD CS hierarchy (`pqc-adcs-two-tier`), the CMS (RFC 5652)
hands-on lab, the Cloudflare edge-PQC observation lab, 97 vendored shark
walkthroughs, WSUS golden-master caching, and the C1–C6 architecture-review
remediations (declarative topology + dependency DAG, secrets purge, .env
resolver fix, CA-role unification).

### Changed — unified classical/PQC AD CS CA roles + folded PQC playbook (campaign C4)
- **Merged the parallel PQC CA roles into the classical ones** —
  `pqc_standalone_ca` → `standalone_ca`, `pqc_subordinate_ca` →
  `subordinate_ca`, selected at runtime by `ca_crypto_provider` (RSA default
  vs `ML-DSA:87`/`ML-DSA:65`). Provider-gated ML-DSA preflight, provider-
  selected CAPolicy templates, and subordinate trust of `RootCAPQC.crt` vs
  `RootCA.crt` accordingly (WROL-01/02, PKI-06). Role count 68 → 66.
- **Extracted `publish_ca_artifacts`** (renamed from `publish_root_ca`,
  tag-parameterized via `publish_tag`) — replaces the byte-identical inline
  WEB1 SMB-publish blocks in `enterprise_ca`/`subordinate_ca` with
  `include_role` (WROL-04).
- **Folded `pqc-ca.yml` into the unified `ca.yml`** with a single `ca_is_pqc`
  switch (KB install self-gated on `kb_prereq`; classical keeps the C6
  `host_ready` probe, PQC keeps its settle + `cert_templates_pqc`); deleted
  `pqc-ca.yml`, repointed the Vagrantfile. Net −200 lines (WROL-05).
- Validated via full `pqc-adcs-two-tier` cold build: 7/7 VMs (both classical
  and ML-DSA hierarchies, ML-DSA-65 leaf issuance E2E), `validate.sh` 111/0/2.

### Fixed — mechanical accuracy + doc-drift wins (campaign C3)
- **`profile-build.yml`** PASS/FAIL/SKIP summary parse rewritten to strip ANSI
  and match the real `validate.sh` tally line (SCRP-05); `.gitignore` now
  ignores `__pycache__/` + `*.pyc` (SCRP-09).
- **`minio_tag` pinned** to a release tag instead of `latest` (LROL-07);
  `adcs_pqc_audit` output path corrected (WROL-08); `opensearch_stack`
  dashboard gate 6 → 7 (OBS-04).
- **Doc drift swept** across README / ARCHITECTURE / SECURITY / CONTRIBUTING /
  configuration / how-it-works / quickstart / build-deployment + packer +
  walkthrough refs: removed the deleted `incident-*` / scenarios framework,
  corrected the role count (→ 66), walkthrough counts (82 labs + 8 NIST),
  `pqc-full` VM count (→ 13), and the `svc-ndes`/`svc-cep` README password
  (`SvcPKI00!`, per `config.rb`) — surfaced by an exhaustive doc stale-ref
  sweep (DOC-01..08, PACK-03).

### Changed — declarative VM topology + dependency DAG (campaigns C5+C6)
- **New `vagrant/topology.yml`** — single source of truth for the VM table
  (name, IP, OS, box, inventory groups, `depends_on`/`requires_ready`).
  Ruby (`lib/topology.rb` → `IP_ADDRESSES`/`VALID_COMPONENTS`/`INVENTORY_HOSTS`
  + define blocks), bash (`scripts/lib/vm-registry.sh`), and Ansible inventory
  all derive from it. Dissolves the ~7 hand-synced VM representations (T1).
  Canonical names fixed: `web` → `web1`, underscore PQC keys → hyphenated
  (PROF-04/08).
- **Inventory generation is now an explicit step** (`lib/render_inventory.rb`,
  gated on `LAB_RENDER_INVENTORY=1`) — a bare `vagrant status` no longer
  mutates inventory files (PROF-03). Adds a canonical grouped `inventory.ini`
  (PLAY-02); makes the two `group_vars/all.yml` disjoint (PLAY-05); derives
  `lab_static_hosts` + beats creds from the SoT (LROL-08/02).
- **Shared bash libs** `scripts/lib/{colors,log,vm-registry}.sh` replace the
  five divergent ANSI palettes + three disagreeing VM lists (SCRP-03).
- **`host_ready` role (C6)** replaces the blind 180s pre-subordinate-CA pause
  with a bounded readiness probe (≤5 min then clear failure) keyed on topology
  `requires_ready`/`provides` (PLAY-03/06, partial).
- **`test/topology_test.rb`** — anti-drift consistency guard (fields, octets,
  acyclic DAG, profile/VALID_COMPONENTS parity).
- Validated both in-place (5/5 + validate 93/0/4) and via full cold build
  (5/5 in 41m53s + validate 93/0/4).

### Fixed — wizard-selected profile silently built `core` (PROF-01, campaign C1)
- **New `vagrant/lib/lab_env.rb`** — loads `vagrant/.env` into ENV (real
  environment always wins; auto-loaded by `lab_profile.rb` and the
  Vagrantfile, so `vagrant` invoked directly and every profile-helper
  consumer — validate.sh, clean.sh, snap.sh — now see wizard-selected
  values). Previously a bash `source` of the wizard's bare `KEY=VALUE`
  file created shell variables only; the Ruby resolver and vagrant
  children read ENV and silently fell back to the `core` profile.
- **`up.sh` `.env` loading rewritten** — non-clobbering export loop. Also
  fixes a precedence inversion: a bare `source` after an inline
  `LAB_PROFILE=x bash up.sh` *overwrote* the inline value (assignment to
  an already-exported var updates the environment).
- **Resolver reports `source=dotenv`** when the profile came from the file;
  4 new regression tests (14 runs, 45 assertions).

### Fixed — hardcoded credentials/endpoints purged from scripts + role defaults (C2)
- **New `vagrant/scripts/lib/lab-secrets.sh`** — `lab_groupvar KEY` resolves
  credentials/endpoints from the active profile's generated
  `inventory/<profile>/group_vars/all.yml`; fails loudly when the file or
  key is missing instead of silently using a stale literal.
- **`cbom-pipeline.sh` / `pqc-remediate.sh` / `validate.sh`** — the
  `TenTowns00!` password fallbacks (×3), `foo123` EJBCA token literals (×3),
  and `192.168.56.53` endpoint literals now resolve via `lab_groupvar`
  (env vars still override). validate.sh's cloudflare ingest check resolves
  in the parent and passes via env to the `bash -c` child.
- **`cloudflare_pqc` role defaults** — `https://192.168.56.53:9244` /
  `beats` / `TenTowns00!` literals replaced with
  `{{ observe_ip }}` / `{{ beats_tls_port }}` / `{{ beats_basic_auth_* }}`
  (same safety-net convention as filebeat/winlogbeat). A credential
  rotation or observe1 re-IP no longer silently breaks only this producer.
- **`ejbca_chimera_profile` defaults** — `chimera_admin_url` built from
  `{{ ejbca_ip }}` + new `chimera_admin_port` var instead of a literal
  IP:port (the EJBCA admin :8443, distinct from the 8444/8443 PQC split).
- Rendered-output equivalence verified against pqc-full group_vars:
  all four substituted values byte-identical to the old literals.

### Added — exhaustive architecture review (findings report)
- **New `docs/reviews/2026-06-11-architecture-review.md`** — 9-dimension parallel
  architectural review of the full repo (profiles, Windows + Linux roles,
  playbooks/inventory, scripts, PKI/trust design, observability, Packer, docs
  drift). 74 findings (3 critical, 18 high), five systemic themes, and a
  12-campaign remediation breakdown. Both criticals were reproduced live before
  inclusion: `.env`-sourced `LAB_PROFILE` never reaches the resolver (wizard
  path silently builds `core`), and `cloudflare_pqc` hardcodes the admin
  password + observe1 endpoint in role defaults. Findings only — fixes land as
  separate scoped PRs.

### Removed — offensive AD CS exploitation + incident-attack content
- **Deleted the ESC walkthrough labs** (`adcs-esc1`, `adcs-esc15-*`: detection /
  exploitation / remediation / vulnerability, plus quizzes / spec / exam) from
  `docs/walkthroughs/`. These were vendored from `shark` and remain canonical
  there; they are no longer re-vendored here (see `SYNC.md`).
- **Deleted the `incident-drill-*` walkthrough module** (compromise / drift /
  runbook / weak-crypto labs + quizzes + spec + exam) and the
  `vagrant/docs/incident-scenarios.md` runbook.
- **Removed the CBOM break-scenario engine** — `vagrant/cbom-toolkit/scenarios/`
  (all 10 realistic + adversarial deploy/cleanup scripts and `run-scenario.sh`)
  and `vagrant/scripts/scenario-reset.sh`.
- **Removed the four `incident-*` profiles** (`incident-compromise`,
  `incident-drift`, `incident-weak-crypto`, `incident-everything`) and the
  `up.sh` Phase 4 scenario-application logic + `--skip-scenarios` flag.
- **Simplified `validate.sh`** — dropped the scenario `expected_failures.txt`
  / XFAIL / UPASS machinery; the summary is now PASS / FAIL / SKIP only.
- **Slimmed `lab_profile.rb`** — removed the `scenarios:` profile key and its
  validation; rewrote `lab_profile_test.rb` to cover the resolver's
  component/resource validation paths (10 tests, 37 assertions) instead.
- **Docs reconciled** across README, GETTING-STARTED, ARCHITECTURE,
  how-it-works, configuration, quickstart, the walkthroughs index/SYNC/
  reference, and the CI profile-resolve matrix (now 14 real profiles, adds
  the previously-missing `pqc-adcs-two-tier`).

### Added — CMS (RFC 5652) hands-on lab (`cms_lab_linux` + `cms_lab_windows`) (PR #112)
- **New walkthrough `docs/walkthroughs/labs/cms-walkthrough.md`** — 10 exercises
  covering SignedData / EnvelopedData / AuthEnvelopedData with classical (RSA,
  ECDSA) and PQC (ML-DSA-65, ML-KEM-768) algorithms, on parallel Linux
  (scanner1) + Windows (manage1) tracks. ~60–90 min end-to-end. Live result:
  **10/10 PASS on Linux, 10/10 PASS on Windows.**
- **Two new roles:** `cms_lab_linux` provisions `/opt/cms-lab/` on scanner1;
  `cms_lab_windows` provisions `C:\cms-lab\` on manage1. Both gate on
  `issueca` + `issueca-pqc` being in the active profile's inventory.
- **CSR-delegation cert sourcing on Linux** — same pattern for classical RSA
  (delegated to `issueca`) and PQC ML-DSA-65 (delegated to `issueca-pqc`).
  No step-ca / no ACME on the Linux side (lessons-learned from attempt 1).
- **Windows uses `Get-Certificate` as SYSTEM** (scheduled-task pattern so the
  request comes from `MANAGE1$` machine identity, which has Domain Computers
  enroll right). `certreq -submit -attrib "CertificateTemplate:..."`
  silently drops the template name over the wire — Get-Certificate's LDAP
  enrollment policy embeds the template OID properly. Enrolled certs honor
  the template's non-exportable key flag, so the role writes thumbprint
  sidecar files and scripts load via `Cert:\LocalMachine\My` instead of PFX.
- **Honest PQC gap documentation, validated against live Server 2025:**
  - `Pkcs.SignedCms.ComputeSignature()` **now accepts ML-DSA** on Server 2025
    (.NET update closed the previously-documented gap). Canary flipped to
    positive — ALERTs on regression.
  - `Pkcs.EnvelopedCms.Encrypt` with ECDH-ES `KeyAgree` recipients returns
    `STATUS_NOT_SUPPORTED` (0xC00000BB). Ex 6 is a Windows-side canary; Linux
    openssl handles ECDH-ES fine.
  - `EnvelopedCms` doesn't accept ML-KEM recipients (RFC 9629) or AES-GCM
    `AuthEnvelopedData` (RFC 5083). Ex 7, 8 canaries.
  - ML-KEM in EnvelopedData hand-built via `asn1crypto` on Linux as a
    teaching-grade RFC 9629-ish demo.
  - `System.Formats.Asn1.AsnReader` is .NET 5+ only — Server 2025's default
    shell is PowerShell 5.1 / .NET Framework 4.x. Ex 9 uses
    `System.Security.Cryptography.AsnEncodedData.Format()` instead.
- **5 new validate.sh checks** — `cms_lab-linux-certs`, `cms_lab-linux-scripts-runnable`,
  `cms_lab-windows-certs`, `cms_lab-windows-scripts-runnable`, `cms_lab-interop`.
- **`pqc-full` profile expanded** to include `rootca-pqc` + `issueca-pqc`
  (the profile's name implies full PQC; previously it only had the classical
  AD CS hierarchy). 11 → 13 VMs.

### Added — Cloudflare edge PQC observation lab (`cloudflare_pqc` role) (PR #110)
- **New `cloudflare_pqc` role on scanner1** probes 3 Cloudflare edge endpoints
  (1.1.1.1, cloudflare.com, dash.cloudflare.com) across 3 TLS stacks
  (OpenSSL OQS, BoringSSL, Go stdlib MLKEM) every 6h via
  `cloudflare-pqc.timer`, writing 9 probe records per run to
  `/var/lib/cloudflare-pqc/report.json`.
- **OpenSearch ingest** — `cloudflare-pqc.service` ExecStartPost= hook + a
  provision-time run pipe `report.json` through `cbom_ingest.py`'s
  `cloudflare_pqc/v1` schema branch (introduced in PR #99), upserting 9
  per-endpoint/stack documents into the `cbom` index with deterministic
  `_id` from `(cbom_bom_ref, cbom_location, cbom_scan_time)`. Powers the
  new `Cloudflare Edge PQC Posture` OSD dashboard panel.
- **`validate.sh` check** — `cloudflare_pqc-opensearch-ingest` queries
  observe1:9244 for `cbom_source.keyword:cloudflare-pqc` docs in the
  last 12h, joining the existing report + PQC negotiation + timer checks.
- **Partial-stack support fix** — observe1.yml's `Add A record for
  observe1.yourlab.local` task now uses `ignore_unreachable: true` so
  builds with dc1 powered-off but in inventory degrade gracefully instead
  of aborting the play. `observe_tls/defaults/main.yml` declares
  `beats_basic_auth_user` / `_password` / `beats_tls_port` as safety-net
  defaults (mirrors the PR #98 pattern that missed this role).
- Live-tested on pqc-full (scanner1 + observe1 + stepca1 + dc1): 9/9 docs
  upserted to OpenSearch, validate.sh check returns 9 hits.

### Added — `pqc_machine_cert` role + manage1 ML-DSA-65 machine cert
- `pqc_machine_cert` Ansible role — enrolls an ML-DSA-65 Server-Auth machine
  cert via certreq under a SYSTEM scheduled task. Reused by both
  `cert_templates_pqc` (CA-self proof of issuance) and `manage1.yml`
  (domain-client PQC enrollment). manage1 now holds two parallel machine
  certs — RSA from YOURLAB-Issuing-CA and ML-DSA-65 from
  YOURLAB-PQC-Issuing-CA — when the active profile includes a PQC issuing
  CA. Gated by `'issueca-pqc' in groups['all']` so non-PQC profiles skip the
  KB5087539 install cost.

### Added — WSUS golden-master patch-DB caching (software cache)
- **Unified WSUS caching under the software cache.** `resources/software/wsus-cache/`
  is now the R/O golden master for both SUSDB (catalog DB) and WsusContent (~118 GB
  binaries). The running WSUS works on its own `D:\WSUS` + WID copy; the cache is
  restored to that working copy at provision start and is R/O at runtime.
- **SUSDB auto-captures** at provision end (floor-guarded; `WSUS_CACHE_CAPTURE=false`
  to disable), generalizing the prior one-shot save. **WsusContent capture is explicit**
  (`scripts/cache-wsus.sh` → `wsus-capture` provisioner) because content downloads
  asynchronously after the provision finishes. `WSUS_CACHE_RESTORE=false` forces a
  fresh sync. Retired the separate `WSUS_CONTENT_PATH` / `C:\WSUS-Backup` mechanism.

### Added — PQC AD CS hierarchy: `pqc_subordinate_ca` role; wire `issueca-pqc` (PR #93)
- **Enterprise ML-DSA-65 subordinate CA.** New `pqc_subordinate_ca` role provisions `issueca-pqc` as an enterprise issuing CA signed by the `rootca-pqc` standalone ML-DSA-87 root, completing the parallel PQC two-tier hierarchy alongside the classical `rootca`/`issueca`.

### Added — PQC AD CS hierarchy: `pqc_standalone_ca` role + `pqc-ca.yml` playbook; wire `rootca-pqc` (PR #92)
- **Standalone ML-DSA-87 root CA.** New `pqc_standalone_ca` role + `pqc-ca.yml` playbook provision `rootca-pqc` as an offline-style standalone root signing with ML-DSA-87. Gated on Windows update KB5087539 for AD CS post-quantum CNG support.

### Added — Scaffold `rootca-pqc` + `issueca-pqc` VMs + `pqc-adcs-two-tier` profile (PR #90)
- **New profile `pqc-adcs-two-tier`** stands up the classical two-tier AD CS hierarchy alongside a parallel PQC hierarchy. Adds the `rootca-pqc` (.25) and `issueca-pqc` (.26) VMs to `config.rb` and the Vagrantfile component map. End-entity ML-DSA leaf templates (`cert_templates_pqc`) are forthcoming (PR #94).

### Added — Server build workflow operator runbook (PR #96)
- **`docs/server-build-workflow.md`** documents the end-to-end server build workflow for operators.

### Added — `windows_kb_install` Ansible role + `fetch-windows-kb.sh` helper + KB5087539 patch sweep (2026-05-26 / 2026-05-27)
- **PR #87** (`abc0a64`): new `vagrant/ansible/roles/windows_kb_install/` role + `vagrant/ansible/playbooks/install-windows-kb.yml` playbook for installing a single Windows hotfix / cumulative update by KB number. Generic — accepts any `KB[0-9]+`. Cache-first (`{{ software_source }}\<KB>.msu`) with download fallback (`-e msu_url=<url>` + optional SHA256 pin). wusa.exe runs in a SYSTEM-context scheduled task wrap because under WinRM Basic auth wusa hits a restricted-token / DPAPI error — same workaround the `sql_server` role uses for setup.exe. Idempotent via `Get-HotFix -Id` check; reboots only if wusa returns rc=3010 and `kb_install_reboot_if_needed=true`; verifies KB present post-install. All PowerShell complexity lives in `templates/install-kb.ps1.j2` (rendered via `win_template`, invoked via `win_command`) to keep the YAML free of the Jinja-vs-shell quoting hazard documented in memory `pqc-verification-gotchas`. Live-tested end-to-end on manage1 (25 min wall): syntax-check + idempotency + cache-miss fail + input validation + SYSTEM-schtask plumbing + full real install all pass. PR included a `fix(install-windows-kb)` commit that dropped a self-referencing playbook-level `vars: { msu_url: "{{ msu_url | default('') }}" }` block — Ansible expanded the self-reference recursively and Jinja2's recursion guard fired (same trap as commit `48af5dd` from May).
- **PR #88** (in progress): `vagrant/scripts/fetch-windows-kb.sh` helper that closes the cache-seeding gap. Microsoft Update Catalog mints per-request GUIDs for direct `.msu` URLs, so a static manifest entry (the `cache-software.sh` pattern used for upstream packages) is fragile — wrong shape for KBs. Helper scrapes the catalog `Search.aspx` for the update GUID, POSTs to `DownloadDialog.aspx` for the current direct `.msu` URL, downloads to `vagrant/resources/software/<KB>.msu` (auto-mounts to `C:\Software\<KB>.msu` on every Windows VM via VirtualBox share), and verifies SHA256 against the committed `vagrant/resources/software/kb-pins.txt`. The `.msu` files themselves stay gitignored (1-3 GB each); only the `kb-pins.txt` integrity pins commit. Updated the `windows_kb_install` role's cache-miss error message to point at the helper.
- **KB5087539 patch sweep** — Windows Server 2025 May 2026 cumulative installed across all 5 ad-cs-two-tier VMs:
  - 2026-05-26: manage1 (25 min wall, live-test target for PR #87), then rootca + issueca in parallel (19 min, forks=2).
  - 2026-05-27: dc1 + web1 in parallel (22 min, forks=2).
  - All 5 VMs now report build 26100.32860 (was 26100.32230) and `Get-HotFix -Id KB5087539` returns `InstalledBy: NT AUTHORITY\SYSTEM`. Pre-install LKG snapshots: `pre-kb5087539-2026-05-26` on rootca/issueca/manage1, `pre-kb5087539-2026-05-27` on dc1/web1.
  - **What this unlocks**: KB5087539 lands the Microsoft AD CS PQC GA — ML-DSA-44/65/87 can now be selected as the CA cryptographic provider via `Install-AdcsCertificationAuthority -CryptoProviderName "ML-DSA:65#Microsoft Software Key Storage Provider"`. The existing classical RSA CAs are unchanged (the provider is bound at install time; switching requires uninstall + reinstall). A parallel PQC AD CS hierarchy (`rootca-pqc` + `issueca-pqc`) is the planned coexistence model — see follow-up PR for the Vagrantfile + profile scaffolding.
  - Memory `pqc-windows-reference.md` refreshed: Layer 2 (CertEnroll) + Layer 3 (AD CS Enterprise CA issuance) flipped from "NOT YET GA" to "GA MAY 2026 (KB5087539)".

### Added — Vendor 97 lab walkthroughs from `zakrodriguez/shark` under `docs/walkthroughs/` (2026-05-26)
- **Closes the discoverability gap** between straylight (the lab) and shark (the walkthroughs). A fresh straylight clone now surfaces 97 hands-on labs across 22 modules + 1 NIST SP track without requiring a second-repo discovery.
- **Subset strategy (Option E from the integration handoff)**: vendored the 22 modules / 89 labs that exercise specific straylight VMs or profiles (acme-extended, adcs-category/functest/esc15, caa-records, cert-manager, code-signing, crl-offline, dns-persist-01, failure-scenarios, http-01-automation, incident-drill, java-keystore, mtls, openssl-fips, pki-automation, pqc, revocation, revocation-deep-dive, template-flags, untrustedca, webserver-ssl) plus the 8-lab NIST SP 800-52 Rev 2 track. The 13 platform-independent modules / 52 labs (tls-fundamentals, tls-comparison, hash-functions, file-formats, openssl-category, san-explainer, forward-secrecy, s-client, ssh-cert, dev-ssl, cdn-ssl, clm, cert-validity) stay in shark only — cross-linked from the catalog.
- **Vendored content**: 89 lab walkthroughs (`docs/walkthroughs/labs/`) + 89 per-lab quizzes (`quizzes/`) + 22 module exams + 22 design specs + 8 NIST labs + 8 NIST quizzes + 1 NIST exam + 3 NIST specs + 2 reference docs (MS-CRTD template-flag behavior notes + straylight v1.0 defaults snapshot).
- **Sync direction**: shark is canonical. Edits flow shark → straylight via the refresh procedure in [`docs/walkthroughs/SYNC.md`](docs/walkthroughs/SYNC.md). Upstream pinned to shark commit `5d508fb` (tag `checkpoint-2026-05-25-35-modules`).
- **Top-level README** gains a "Lab Walkthroughs" section between Quick Start and Lab Profiles surfacing the catalog with per-area module pointers.

## [1.0.0] — 2026-05-25

First stable release. The lab is reliable, documented, OSS-ready. Cold-build of `ad-cs-two-tier` from a destroyed state validates green (`93 PASS / 0 FAIL / 2 SKIP`, 46m02s wall time on a host with the `straylight/windows-server-2025` Desktop box opted-in for `manage1`). Sprint 3 (Packer pre-bake + `cert_templates` publish-list fix) closes the long-running Failure #85 cascade. Validator hardened against SAN-identity machine cert false positives. EJBCA Chimera + PQC migration orchestrator paths land in their durable forms. Entries below cover the 2026-05-16 → 2026-05-25 window.

### Changed — `enterprise_ca` CRL period: drop dead-code 2-week else branch (2026-05-25)
- Simplify `vagrant/ansible/roles/enterprise_ca/templates/CAPolicy.inf.j2` to always use the 26-week (~6-month) CRL period. The previous `{% if ca_type == 'EnterpriseRootCA' %} ... {% else %} CRLPeriodUnits=2 ... {% endif %}` had an unreachable else branch — `enterprise_ca` is only ever invoked with `ca_type=EnterpriseRootCA` (per `vagrant/ansible/playbooks/ca.yml` lines 101-104; the other two ca_type values dispatch to `standalone_ca` and `subordinate_ca`). Matches the `subordinate_ca` template's 26-week setting (committed earlier with cold-start-FAIL motivation). No runtime behavior change — closes the documentation gap.

### Fixed — PQC migration orchestrator end-to-end unblock (commits `fa02c34`..`f2f3d49`, 2026-05-16..18)
Seven commits landed on main between 2026-05-16 and 2026-05-18 without their own PRs. They take the PQC migration orchestrator (`vagrant/scripts/pqc-remediate.sh` + `pqc-migrate*.yml` playbook tree, originally shipped in PR #36 on 2026-05-14) from "fails mid-phase" to live-verified end-to-end on `pqc-full` (0 failures across 7 hosts: dc1, ejbca1, hydra1, observe1, stepca1, web1, localhost). Documented retrospectively per the "always update docs as part of release" rule.

- **`fa02c34` (2026-05-16) — Phase 2 unblock: pure-leaf decoupling + chimera catoken restart.** Two changes to `pqc-migrate-tls.yml`. (1) Flip import order so `pqc-pure-leaf.yml` (depends only on EJBCA-PQC-Issuing-CA) runs before `pqc-chimera.yml`; add `meta: clear_host_errors` between imports + `ignore_unreachable: true` on each verification play so a chimera failure does not poison the `pqc_pure_leaf_endpoints` hosts. (2) Restart the ejbca-ce container after the chimera catoken DB patch in the `ejbca_pqc` role. Mutating `CAData` + `clearcache -ca` re-reads the CA row but does NOT rebuild the in-memory `CAToken` wrapper — cached propertydata still lacks `alternativeSignatureAlgorithm`. Symptom is paradoxical: CA + token both report active, yet `ca createcert` fails with "CA token is offline" while `ca activateca` refuses with "must be offline to be activated". Container restart drops every Java cache. Restart gated on the same `chimera_altsig_check.stdout == '0'` pre-patch missing-field check, idempotent.

- **`884db30` (2026-05-16) — `alternativeCertSignKey` propertydata patch (the real chimera fix).** Live-testing `fa02c34` showed the catoken-restart was treating the symptom. EJBCA's `ca init --tokenprop <file>` accepts `alternativeCertSignKey signKeyMLDSA` in the props file but silently drops it when serializing the CAToken. Live propertydata after `ca init` only carries `certSignKey` / `crlSignKey` / `testKey` / `defaultKey`. `alternativeCertSignKey` is what tells `X509CAImpl` which key alias inside the CryptoToken to use for the post-quantum signature; without it, sign-time lookup returns null and CAToken reports offline even though CryptoToken + keys are healthy. Fix: extend the chimera-catoken patch to apply both mutations as one atomic UPDATE — insert `alternativeSignatureAlgorithm=ML-DSA-65` into the catoken LinkedHashMap AND append `alternativeCertSignKey=signKeyMLDSA` to the propertydata key=value string. Idempotency gate AND-checks both substrings; each block self-gates so half-applied state auto-completes. Live-verified 2026-05-16: `ejbca.sh createcert` against EJBCA-Chimera-Root-CA returned rc=0; observe1:8443 serves chimera leaf with OIDs 2.5.29.72 / 73 / 74; observe1:8444, stepca1:9444, ejbca1:8444, hydra1:8444 all serve pure ML-DSA-65 leaves; web1:8443 IIS chimera install passes self-loopback TLS check.

- **`f6e5e70` (2026-05-18) — standalone-invocation Ansible vars for pqc-*.yml playbooks.** Two fixes so `pqc-*.yml` playbooks invoked standalone via `ansible-playbook` (not through Vagrant's `ansible` provisioner) get the same vars Vagrant passes via `extra_vars`. Surfaced 2026-05-18 during `pqc-chimera.yml` live-test on pqc-full: dc1 trust play failed sequentially on `psf_init`, `ejbca_ip`, `lab_netbios`. (1) Inline `ansible_connection=ssh` + `ansible_port=22` at host level for ssh hosts in `pqc.ini` (mirrors the winrm-host branch). Host-level vars beat inventory `group_vars/all.yml`, so the linux ssh hosts still get ssh when the rendered `all.yml` sets `ansible_connection: winrm` for "all". (2) Render `ansible/inventory/group_vars/all.yml` at Vagrantfile parse time with `COMMON_VARS + EJBCA_VARS + STEPCA_VARS + HYDRA_VARS` contents. Ansible auto-discovers it for any inventory under `inventory/`. Live-verified 2026-05-18: pqc-chimera.yml end-to-end zero-failure across ejbca1 (ok=8), observe1 (ok=17), web1 (ok=25), dc1 (ok=6 including AD `-dspublish` via scheduled task); EJBCA-Chimera-Root-CA visible in dc1's enterprise Root store (thumbprint `5A9F5EC3CC27037B2869A7D41E9C5FA0A75AC6CF`).

- **`b468cb6` (2026-05-18) — alt-sig OID probe by DER byte sequence, not `asn1parse` text.** Phase 2 verification on observe1:8443 was grepping for the dotted form of the ML-DSA-65 OID (`2.16.840.1.101.3.4.3.18`) in `openssl asn1parse` output. Fails on Ubuntu 22.04's system openssl 3.0 because `asn1parse` does NOT recurse into extension OCTET STRING contents (the `altSignatureAlgorithm` value appears as `OCTET STRING [HEX DUMP]:...` with no nested OBJECT line), and system openssl 3.0 doesn't know ML-DSA-65 in `obj_dat.h` so it would print the dotted form only for known OIDs. The cert IS correct — the OID is BER-encoded inside the OCTET STRING as `06 09 60 86 48 01 65 03 04 03 12`. Probe now greps for that hex byte sequence in the cert's `xxd` hex dump. Works regardless of which openssl build is parsing.

- **`48af5dd` (2026-05-18) — drop self-referencing `lab_domain` default in web1 verify.** After `f6e5e70` (rendered `inventory/group_vars/all.yml` provides `lab_domain`), the play-level `vars: { lab_domain: "{{ lab_domain | default('yourlab.local') }}" }` triggered Jinja2's recursive-loop guard: `Error while resolving value for '_raw_params': Recursive loop detected in template`. The play-level var refers to a var of the same name in a higher scope, and Ansible templates the play-level value before resolving the parent. Fix: remove the play-level default; rely on group_vars. Comment notes the fallback — pass `-e lab_domain=...` explicitly if running standalone against an inventory without `group_vars/all.yml`.

- **`18ff360` (2026-05-18) — ADSI LDAP DN concatenation in dc1 chimera-trust probe.** The probe built its query path as `LDAP://$trustedRootDN/CN=EJBCA-Chimera-Root-CA` — slash-joined. ADSI LDAP paths require comma-concatenated DNs with the leaf `CN=` at the FRONT: `LDAP://CN=EJBCA-Chimera-Root-CA,CN=Certification Authorities,...`. The slash form silently returned an unbound ADSI object; `$container.Path` empty, `$container.cACertificate` empty, property names empty. Probe treated this as "not published" and threw FAIL even though `certutil -dspublish RootCA` had populated the entry. Verified live: corrected DN returns thumbprint `5A9F5EC3CC27037B2869A7D41E9C5FA0A75AC6CF`.

- **`f2f3d49` (2026-05-18) — replace stale `$TOPOLOGY` refs with `$LAB_PROFILE_NAME`.** `$TOPOLOGY` was a holdover from the pre-composable-lab era when `ADCS_TOPOLOGY` selected one-tier / two-tier topologies. After the LAB_PROFILE refactor the variable is no longer set anywhere — running `pqc-remediate.sh` under `set -u` (via Ansible's `ansible.builtin.shell`, which propagates that flag) blew up with `TOPOLOGY: unbound variable` on lines 263 and 363, killing Phase 5 of `pqc-migrate.yml`'s orchestrator after every scanner had already completed successfully. Replaced all 7 `$TOPOLOGY` uses with `$LAB_PROFILE_NAME` (set by sourced `profile-helper.sh`). Filenames now match the `cbom-pipeline.sh` convention (`cbom-<scanner>-<profile>-<timestamp>-deduped.json`). The lone semantic case — the "two-tier only" chimera gate at line 191 — now detects by checking the rendered `pqc.ini` for the `[iis]` + `[domain_controllers]` groups, so it stays in sync with whatever profile selection logic is active without a hardcoded list. Live-verified: `LAB_PROFILE=pqc-full bash vagrant/scripts/pqc-remediate.sh --rescan-only` runs all 5 CBOM scanners end-to-end, ingests results into OpenSearch at observe1:9200.

### Added — `cert_templates` JSON-drift detection (2026-05-25)
- **Re-import template when JSON's `msPKI-Template-Minor-Revision` exceeds the value in AD.** Previously the role's step 1.5 took the `Already exists` branch for every existing template and never propagated JSON edits to AD. Edits to any `vagrant/resources/software/Straylight-*.json` only landed on fresh-AD cold-builds. New behavior: compare JSON's `msPKI-Template-Minor-Revision` to AD's. If JSON > AD, `Remove-ADCSTemplate` + `New-ADCSTemplate -Publish` (preserves the template OID because `msPKI-Cert-Template-OID` is pinned in the JSON, so already-issued certs still chain). If JSON ≤ AD, skip. Convention: bump the minor revision in the JSON file whenever the bytes change, so the next `vagrant provision` on a CA VM picks the change up.

### Fixed — `Straylight-Fiddler-1Y-RSA2048-SHA256-v1` template period mismatch (2026-05-25)
- **`pKIExpirationPeriod`: 2 years → 1 year (to match the `1Y` in the template name).** Decoded bytes `[0,128,114,14,93,194,253,255]` = `-630720000000000` 100-ns ticks = **730 days** = 2 years. Replaced with Machine template's 1-year bytes `[0,64,57,135,46,225,254,255]` = 365 days. Per the design doc (`vagrant/docs/plans/2026-03-07-chocolatey-migration-design.md`), the template was intended to issue 1-year subordinate CA certs for Fiddler Classic's BouncyCastle CertMaker; the bytes had drifted from the documented intent.
- **`pKIOverlapPeriod`: 3 days → 42 days.** Original `[0,192,194,128,164,253,255,255]` = 3 days renewal window — too short for safe autoenrollment renewal at the 8-hour group-policy refresh cadence; a missed tick window left the cert expiring before next enrollment attempt. Replaced with Machine template's 42-day overlap `[0,128,166,10,255,222,255,255]` (matches the AD CS default).
- **`msPKI-Template-Minor-Revision`: 0 → 1.** Bumps the template version so clients pick up the change on next autoenrollment tick instead of using the cached object.
- `pKIKeyUsage` (`[6,0]` = keyCertSign + cRLSign) was already correct for the subordinate-CA use case and not changed.

### Fixed — `validate.sh` duplicate-cert-subjects false positive on SAN-identity machine certs (2026-05-25)
- **Group by (Subject + Template OID) instead of Subject alone; skip empty-Subject groups.** `Straylight-Machine-*` and `Straylight-Fiddler-*` templates populate identity via `SubjectAlternativeName`, not the Subject DN — both ship with empty Subject by design. Round 1 USE_STRAYLIGHT_BOXES=true cold-build had manage1 enrolled for both templates (Machine-1Y + Fiddler-1Y), and the validator's `Group-Object Subject` grouped both empty-Subject certs into one group with Count=2, triggering FAIL with an empty `$names` payload (`Duplicate cert subjects in LocalMachine\My:` with nothing after the colon). Fix: change the group key to `"$Subject::$TemplateOID"` so different-template certs are not conflated, and skip groups whose Subject is empty (still surfaces genuine same-template / non-empty-Subject dupes). Verified: 93 PASS / 0 FAIL / 2 SKIP on ad-cs-two-tier post-fix.

### Added — Sprint 3 Packer pre-bake pipeline (PR #75, 2026-05-25)
- **`straylight/windows-server-2025` Desktop Vagrant box (locally baked).** `packer/` pipeline produces a Server 2025 Standard (Desktop Experience) box with PowerShell 7.4.7, VirtualBox Guest Additions, and ADCS features pre-installed. HCL2 templates at `packer/windows/2025/windows-server-2025.pkr.hcl` + 2016/2019/2022 siblings. Lab-bake provisioner layer at `packer/scripts/windows/lab-bake/` covers GA install, PS7 install from `STRAYLIGHT_CACHE` CD attached via `cd_files`, ADCS feature install, and `Measure-Task` task-level timings written to `~/straylight/packer-build-logs/<version>-timings.csv`. Build: `cd packer && ./build-images.sh 2025` (~30 min wall time). Opt in: `USE_STRAYLIGHT_BOXES=true LAB_PROFILE=<x> ./up.sh` flips `BOX_WIN_SERVER_2025` from `gusztavvargadr/windows-server-2025-standard` to `straylight/windows-server-2025` in `vagrant/config.rb`. Server Core variants stay on `gusztavvargadr`: Server 2025 Core sysprep stalls in Packer after PnP driver generalize, and ADCS+sysprep is unsupported per Microsoft. Build pipeline integrity check (gzip -t + tar VMDK extract + qemu-img info + VBoxManage clonemedium dry-run) runs after every box build.

### Fixed — `cert_templates` publish-list (PR #75 commit `783a08c`, 2026-05-25)
- **List all Straylight-* templates in step 2's `Add-CATemplate` array instead of relying on `New-ADCSTemplate -Publish` from step 1.5.** `-Publish` only fires when the template is new. On a re-provisioned CA the AD template object already exists; step 1.5 takes the "Already exists" branch and skips Publish; the new CA never adds the template to its local `certificateTemplates` issuance list. `Straylight-Machine-1Y-RSA2048-SHA256-v1` had the correct ACL on the AD object (Domain Computers Enroll + Autoenroll) but the CA refused to issue it because it was not in the local issuance list. Domain Computers' autoenrollment loop found no eligible templates, logged no enrollment attempt, never produced a Server Auth cert. Result: 30 × 30s = 15 min wait failure on every dependent `machine_cert` task (web1, manage1, tomcat1). Observed on ca1: AD container had 11 Server-Auth-EKU templates; CA issuance list had 7, missing every `Straylight-Machine-*` variant. Fix: list all 8 `Straylight-*` templates in step 2's `$templates` array passed to `Add-CATemplate` (idempotent). Inline comment in `cert_templates/tasks/main.yml` documents the `-Publish`-only-on-new behavior.

### Fixed — Round 19 CA-VM hardening (PR #74, 2026-05-25)
- **Replace post-Join WMI restart with a 240s `pause:` after `Include domain_join role` in `ca.yml`, gated on `ca_type != StandaloneRootCA`.** Round 18 (post PR #73): ca1 + issueca both failed with `WS-Management ... InvalidSelectors HTTP 500` after PR #73's `raw Restart-Service Winmgmt` fix landed. `raw` uses WinRM; InvalidSelectors comes from the WinRM dispatcher, not the win_powershell wrapper. Ansible `until/retries` only catches module-payload failures, not transport-level WinRM errors. Server 2025's WMI service comes up non-deterministically after a domain-join reboot preceded by ADCS-feature install: some boots have healthy WMI, others reject InvalidSelectors for several minutes. `pause:` is a control-side no-op (no WinRM call) and cannot fail; WMI stabilizes within 2-3 min on cold-build. PR #73's raw Restart-Service task removed.
- **Removed `no_log: true` from the enterprise_ca install task.** Round 18 ca1 enterprise_ca install failed and `no_log` censored the error. Schedule-task credentials are passed via `/rp`, not via Ansible vars in the script body — no secrets in task output. Matches the PR #48 subordinate_ca `no_log` removal.

### Fixed — Round 17 follow-ups (PR #73, 2026-05-24)
- **Post-Join WMI restart via `ansible.builtin.raw` (superseded by PR #74).** Round 17: ca1 post-Join WMI/CIM probe failed on the first attempt with `InvalidSelectors HTTP 500`, zero retries logged. `until/retries` only catches module-payload failures, not transport-level WinRM errors fired before the `win_powershell` wrapper finishes setup. Added `Restart-Service Winmgmt -Force` task immediately after `Join domain`, invoked via `ansible.builtin.raw`. `Restart-Service` uses Service Control Manager, not WMI. 15s settle before the probe re-ran. Rolled back in PR #74 because `raw` also goes through WinRM and hit the same InvalidSelectors error in round 18.
- **`cert_templates` "Directory object not found" → AD-replication retry helper.** Round 17 issueca's `cert_templates` task threw `Directory object not found` mid-loop. ADSI write (via `New-ADCSTemplate`) hits one DC; the immediate `Get-ADObject` read on the next line may target a different DC where replication has not completed. First surfaced on ca1 in round 10; recurred on issueca in round 17. Added a `Get-ADObjectWaitForReplication` helper inside the `cert_templates` wrapper that retries on `Directory object not found` / `Cannot find object` messages (15 × 4s = 60s window). Other exception types fail fast. Applied to both `Get-ADObject` call sites in the autoenroll permission-grant loops.

### Fixed — PS7 install (PRs #70, #71, #72, 2026-05-23..24)
- **Drop the pre-MSI reboot; mutex probe alone suffices (PR #72, round 15, 2026-05-24).** Round 15 (post PR #71): pre-staging PS7 MSI to `C:\ProgramData\Straylight\` failed silently on issueca — pre-stage task reported `ok` but nothing landed on disk (verified via `vagrant winrm`). Install then failed with "file cannot be reached" through 5 retries. Removed: pre-stage to `C:\ProgramData\Straylight`, `shutdown.exe` reboot + `wait_for_connection`, ensure-stage-dir task, cleanup-pre-staged-MSI task. New flow: check pwsh installed → check staged MSI on `C:\Software` synced folder → wait for `Global\_MSIExecute` mutex free (60 × 10s = 10 min ceiling) → install with 5× retry on 1618.
- **Stage PS7 MSI to `C:\ProgramData\Straylight\` (PR #71, round 14, superseded by PR #72).** Round 14 (post PR #70): ca1 cleared PS7 install; issueca failed with `the file at the path 'C:\Windows\Temp\PowerShell-7.4.7-win-x64.msi' cannot be reached` through 5 retries. Pre-stage task reported `ok` but the MSI was gone by install time — Server 2025's reboot triggers `C:\Windows\Temp` cleanup via Disk Cleanup / StorageSense. Round 14 fix: stage to `C:\ProgramData\Straylight\` + explicit `win_file: state=directory` + `force: true` on `win_copy`.
- **Probe `Global\_MSIExecute` mutex before PS7 install + retry on 1618 (PR #70, round 13, 2026-05-23).** Round 13: pre-staging the MSI worked; install hit rc 1618 ("Another installation is in progress"). The fixed 30s post-reboot settle was insufficient — Server 2025's post-boot installer chain (Defender platform updates, .NET runtime patching) holds the global MSI execute mutex >30s on cold-build. (1) Active probe of `Global\_MSIExecute` before install: open mutex, try to acquire, release. `WaitOne` returns false → mutex held → task fails and Ansible retries (60 × 10s = 10 min ceiling); mutex doesn't exist → no installer running. (2) Retry the install task itself 5 × 30s backoff for the race between mutex probe success and `msiexec` launch.

### Added
- **`up.sh` auto-detects `baseline` snapshots and restores instead of building (Sprint 3 Path A).** First run with `--save-snap all` saves a snapshot named `baseline` after each VM's provision completes. Subsequent `bash up.sh` (or `up.sh --all`) runs now check `vagrant snapshot list <vm>` for a `baseline` entry — when found, the VM is routed to the restore-from-snapshot path instead of create+provision. No flag required. Restored VMs show `(snap)` in the build plan output and `✓ restored` instead of an Ansible task stream. Set `LAB_AUTO_RESTORE_BASELINE=false` to disable auto-detect (falls back to explicit `--restore-snap` opt-in). On the `full` profile after a successful baseline bake, this turns subsequent cold-builds into a ~5-10 min restore sequence (vs. ~2 hr from scratch). Caveat: snapshots are tied to this VirtualBox host — destroyed by `nuke.sh`, not portable to other developers (that's Path B / Packer territory, separate sprint).

### Performance
- **Comprehensive software cache audit — every external install now has a local-cache-first path.** Round 3 cold-build verification (2026-05-22) showed 10 Windows VMs concurrently fetching PowerShell 7.4.7 from GitHub saturated egress for ~20 min — the role had a cache-first pattern but the artifact was never staged. Audited every `get_url` / `win_get_url` / inline-`curl` call across the role tree; closed 7 gaps:
  - **Roles that had the pattern but no staged artifact** — added entries to `vagrant/scripts/software-manifest.yml` so `bash vagrant/scripts/cache-software.sh` now downloads them into `vagrant/resources/software/`:
    - PowerShell 7.4.7 MSI (`common` role) — the egress saturator from round 3.
    - Filebeat 8.17.0 Linux tarball (`filebeat` role).
    - Filebeat 8.17.0 Windows zip (`filebeat_iis` role).
  - **Roles with no cache-first pattern at all** — added stat-check + copy-from-cache + fallback-to-upstream:
    - `acme_client/step_cli.yml` — Smallstep step CLI 0.28.3 deb.
    - `openssh_pqc` — OpenSSH 10.0p2 source tarball.
    - `gnupg_pqc` — 7-tarball dependency chain (libgpg-error, libgcrypt, libassuan, libksba, npth, pinentry, gnupg). Cached together under `resources/software/gnupg-cache/` so they don't clutter the top-level software dir. The inline shell loop now checks the cache before falling back to `curl https://www.gnupg.org/...`.
    - `cbom_lens` — Go 1.25.6 tarball. Separate from the already-existing cbom-lens binary cache (the binary cache short-circuits the entire build; the Go cache covers the build-from-source path when the binary cache misses).
  - **cache-software.sh enhancements** — script now `mkdir -p`s the parent dir for nested filenames (e.g. `gnupg-cache/foo.tar.bz2`), so subdirectory caches like `gnupg-cache/` work without manual setup.
  - **Net effect on next cold-build with cache populated**: ~20 min saved (no PS7 egress storm), ~5 min saved on scanner1/apps1 from Filebeat-tarball staging, ~3 min on stepca1 from step CLI cache, ~5 min on scanner1's openssh_pqc tarball, ~8 min on apps1's GnuPG dep chain. Plus removes external dependency on github.com/gnupg.org/cdn.openbsd.org/elastic.co/go.dev for those 7 sources.
  - **First-time setup**: users must run `bash vagrant/scripts/cache-software.sh` once to download the new entries (~320 MB total). Pre-existing entries with checksums already in the manifest are skipped if already present.

### Fixed
- **Post-Join CIM probe 3-min window insufficient for unlucky variance (round 10, 2026-05-23).** Round 10 parallel rebuild of ca1+issueca: ca1 cleared the post-Join probe in seconds, issueca exhausted all 30 × 6s = 180s retries (WS-Management rejected `InvalidSelectors` for >3 min after the domain-join reboot). Same probe, same playbook, different luck — WMI service restart timing varies across reboots. Bumped probe to 60 × 6s = 6 min ceiling. Still no waste on healthy builds — probe exits as soon as WMI responds.

- **PS7 MSI install racing with Windows post-boot installer activity (Failure #17, round 7, 2026-05-23).** Round 7 targeted rebuild of ca1 + issueca both failed at `common : Install PowerShell 7 from local cache` with exit code 1618 ("Another installation is in progress"). Root cause: freshly-booted Server 2025 has built-in post-boot installer work (Defender platform updates, .NET runtime, etc.) that holds the global MSI execution mutex. On full-profile cold-builds, Phase 1's sequential VM creation gave each VM ~50 min to settle BEFORE Phase 3's PS7 install hit them, masking the race; `up.sh --rebuild` (and any tight build pattern) doesn't. Fix: add a `win_reboot` task before the PS7 install, gated on `pwsh_installed.stat.exists == false` — fires only on cold-build first run, idempotent on subsequent runs. `post_reboot_delay: 30` gives WindowsInstaller service time to finish background work.

- **ca1 post-Join WMI/CIM probe window too tight (Failure #12 redux, round 6, 2026-05-23).** Round 6 verification showed PR #62's Winmgmt restart cleared the pre-Join WMI race on ca1 (ca1 cleared `Join domain`), but the post-Join probe added in PR #58 timed out at 10 × 6s = 60s — WMI restart after the domain-join reboot took longer than 60s to settle on this round. Bumped post-Join probe to 30 × 6s = 3 min ceiling. The probe only iterates until WMI returns, so a healthy build still exits in ~6s; the longer ceiling just bounds the variable cold-build case.
- **subordinate_ca ERROR_DS_RANGE_CONSTRAINT returned with 60s pause (Failure #10 redux, round 6, 2026-05-23).** Round 6 verification showed issueca's `Install-AdcsCertificationAuthority` failing with the SAME `ERROR_DS_RANGE_CONSTRAINT (0x80072082)` at `CCertSrvSetup::SetCASetupProperty(set_CAType=EnterpriseSubordinateCA)` that PR #55's 60s AD-settle pause was supposed to mitigate — the 60s window was insufficient on cold-build with cold AD disks. Bumped AD-settle pause to 180s. Same trade-off shape as the post-Join probe — adds 2 min to healthy builds, but bounds the failure window for the variable cold-build case.

- **ca1 Join domain WMI race recurrence (Failure #6 redux, 2026-05-23).** Round 5 verification showed PR #52's WMI/CIM probe + PR #54's 60s CA-VM launch stagger let rootca + issueca clear `Join domain` cleanly, but ca1 still hit `WS-Management ... InvalidSelectors HTTP 500` — the probe passed (WMI looked OK at that moment), but the `microsoft.ad.membership` module's later CIM calls hit a transient race fired by the multi-feature ADCS install burst that immediately precedes domain_join on CA VMs. The race rotates VM-to-VM per round, so a single VM is bitten each time. Fix: insert an **explicit `Restart-Service Winmgmt -Force`** task in `playbooks/ca.yml` between the "Pre-install additional ADCS features" tasks and `Include domain_join role`, followed by a 10s settle. Cascades stop+start through WMI's dependency tree (WMI Performance Adapter, Security Center, etc.), forcing a clean repository state before the domain join. The probe inside domain_join still runs as a safety net.
- **subordinate_ca install timeout too tight (Failure #16, 2026-05-22).** Round 5 verification showed `Install Enterprise Subordinate CA via scheduled task` hitting the 900-second wait ceiling — the script's parent CA wait (~10 min built-in) plus `Install-AdcsCertificationAuthority` (5-10 min on a slow disk) can cumulatively exceed 15 min on cold-build. When the wait expired, `schtasks /delete` killed the still-running install, leaving `ca-install.log` empty and the fatal threw `"Subordinate CA installation failed. Log: "` with no payload. Bumped `$maxWait` to 1800s (30 min) and added timeout-distinguishing diagnostic: on wait expiry, capture `schtasks /query /v` BEFORE the delete and append it to the throw message so timeout failures are now distinguishable from actual install errors.

- **`bash up.sh --all` silently fell back to `core` profile (Failure #15, latent since 2026-05-11)** — the `--all` branch did `LAB_PROFILE=full source profile-helper.sh`, but a leading `VAR=value` only sets the variable for the duration of the command — bash doesn't persist it in the parent shell after `source` returns. So every subsequent `vagrant up` / `vagrant provision` in up.sh inherited an empty `ENV['LAB_PROFILE']`, the Vagrantfile resolver fell back to `core`, and any VM not in the `core` 4 (dc1/manage1/web1/ca1) failed with `"machine ... not found configured for this Vagrant environment"`. Round 4 (2026-05-22) hit this and lost 14 VMs at 0-16s each. The bug was masked for months because callers usually invoked the script as `LAB_PROFILE=full bash up.sh` (env var set on the bash invocation propagates naturally to children). Fix: explicit `export LAB_PROFILE=full` before the source.

- **CA-VM post-Join WMI/CIM race (Failure #12)** — round 3 verification (2026-05-22) showed PR #54's CA-VM launch stagger let ca1 clear `Join domain` cleanly, but the very next CIM-using task (`Ensure DNS is set on host-only adapter after domain join reboot`) hit the same `WS-Management ... InvalidSelectors` HTTP 500. The race window is broader than the pre-Join probe handled: WMI restarts during the domain-join reboot and isn't fully settled when downstream `Get-NetIPConfiguration` / `Get-CimInstance` calls fire. Added a `Wait for WMI/CIM stability after domain-join reboot` task in the `domain_join` role — mirrors the pre-Join probe (10 retries × 6s, 60s upper bound) AND exercises the NetAdapter CIM provider directly (not just `Win32_ComputerSystem`) so transient NetTCPIP namespace races also get caught before the next task runs.
- **cert_templates publish credential rejection on issueca (Failure #11)** — after PR #54 + #55 unblocked issueca through the full `subordinate_ca` install, the next task (`cert_templates: Publish templates and configure autoenrollment via scheduled task`) failed with `Either the target name is incorrect or the server has rejected the client credentials`. Identical-shape failure to PR #48's `ERROR_LOGON_FAILURE` on `subordinate_ca`: the scheduled task runs as `lab_netbios\Administrator` via `/ru /rp`, but the Batch-logon token can drop privileges, so `Get-ADObject` / `Set-ADObject` fall through to a Kerberos handshake that the AD server then rejects (SPN-cache / token mismatch). Built an explicit `$adCred = New-Object PSCredential` inside the wrapper and added `-Credential $adCred` to all four AD cmdlet calls (2× `Get-ADObject`, 2× `Set-ADObject`) — forces NTLM with the full Administrator identity, same fix shape PR #48 used for `Install-AdcsCertificationAuthority`.
- **`up.sh` hang detection for crashed Ansible runs (Failure #13)** — round 3 verification (2026-05-22) had scanner1's playbook crash at 18:29 (`community.general.archive` not found), then `up.sh` waited on it for ~3 hours afterward, blocking the rest of the cold-build from finishing. Root cause: `check_finished_vms` only marked a VM done when `kill -0 $pid` failed — but the vagrant subprocess can hang internally after Ansible reports a fatal failure, leaving the PID alive indefinitely. Added a two-signal hang detector: VM is marked HUNG (status 137) if (a) the log contains `Ansible failed to complete successfully` or a non-zero `PLAY RECAP failed=` line AND (b) the log hasn't been touched in `$LAB_HANG_DETECT_SEC` seconds (default 600s = 10 min). On detection, `up.sh` SIGTERMs the subshell, SIGKILLs after a 2s grace, then `wait`s it so the rest of the parallel build can continue. Override the window with `LAB_HANG_DETECT_SEC=N ./up.sh`; set to 0 to disable.

- **issueca subordinate_ca `ERROR_DS_RANGE_CONSTRAINT` mitigation + diagnostic (Failure #10)** — round 2 verification showed `Install-AdcsCertificationAuthority` failing with `0x80072082 (WIN32: 8322 ERROR_DS_RANGE_CONSTRAINT)` immediately after the domain_join + reboot, despite PR #48's `-Credential` fix landing (auth was succeeding). Suspect: AD machine-account token / group propagation hadn't finished when the subordinate CA install tried to register itself in `CN=Enrollment Services`. Two changes: (1) `ca.yml` playbook now sleeps 60s between `domain_join` and `subordinate_ca` for EnterpriseSubordinateCA, letting AD settle; (2) `subordinate_ca` role's catch block now dumps full `$_` detail (InnerException, Category, FQEID, TargetObject) **plus** the last 40 lines of `C:\Windows\Logs\Setup\AdcsSetup.log` (and fallback ADCS logs) to `ca-install.log` — so if the install still fails, we see which exact attribute violated range constraints, not just the generic error message.

- **CA-VM domain-join race stagger (Failure #9)** — round 2 full-profile verification (2026-05-22) showed PR #52's WMI/CIM probe was insufficient: the probe ran successfully on ca1 but the immediate next `Join domain` task still hit `WS-Management ... InvalidSelectors` HTTP 500. All 6 retries hit the same error. The race is between CA VMs (ca1 / issueca) — both kick off `microsoft.ad.membership` at roughly the same point in their playbooks (~5 min after Phase 3 start), and dc1's WMI / AD layer can't handle the concurrent machine-account creates cleanly. Round 1 failed issueca, round 2 failed ca1 — race rotates per run. Fix: `up.sh` now adds `LAB_CA_LAUNCH_STAGGER_SEC` (default 60s) between consecutive CA-VM launches in Phase 3. Effective stagger between ca1 and issueca = 120s (ca1 → 60s → rootca → 60s → issueca), enough separation that the domain_join race doesn't fire. Set `LAB_CA_LAUNCH_STAGGER_SEC=0` to disable.

- **`full` profile cold-build follow-up fixes** — three more failure modes surfaced by the 2026-05-22 verification (which proved PR #48's `psframework` + `cipheriq` fixes work, then surfaced new issues downstream):
  - **`domain_join` WMI/CIM race after ADCS feature install (issueca)** — issueca alone failed at `Join domain` with `WS-Management ... InvalidSelectors` (HTTP 500). All 9 other Windows VMs joined cleanly. Root cause: the three back-to-back `win_feature` ADCS installs that immediately precede `domain_join` on CA VMs (`Cert-Authority`, `Web-Enrollment`, `Device-Enrollment`, `Enroll-Web-Pol`, `Enroll-Web-Svc`) transiently destabilize WMI's `Win32_ComputerSystem` provider — the exact class `microsoft.ad.membership` uses. Earlier tasks (`Set DNS`, `Wait for AD DS`) ran through `win_powershell` which uses a lighter CIM path and didn't expose the issue. Added a `Win32_ComputerSystem` probe (10 retries × 6s) before `Join domain`; bumped Join domain retries 3→6 and delay 30s→60s.
  - **`cert_templates` no_log censoring (ca1)** — `Publish templates and configure autoenrollment via scheduled task` had `no_log: true` which censored the actual error during ca1's 2026-05-22 failure (`ok=41 failed=1`). Same family as PR #48's `subordinate_ca` no_log removal — template payloads aren't sensitive, and censored output costs hours of guessing. Dropped `no_log`.
  - **`wsus_server` title fallback fuzzy match + degrade-instead-of-fail** — PR #48 fix #4 added a title fallback (`Title -eq 'Windows 11'`) for when the GUID-based product lookup misses. 2026-05-22 verification revealed actual catalog titles vary ("Windows 11 Client, version 23H2 and later, Servicing Drivers" etc.) — exact-match misses them. Switched to `-like '*Windows 11*'` (excluding sub-products with slashes in title). If even fuzzy match exhausts, log the first 10 candidate titles (so the operator can update the pattern) and return successfully without product selection — WSUS isn't on the PKI critical path; better to deploy degraded than fail the whole role.

### Performance
- **Sprint 2b alt — WSUS SUSDB catalog cache (~30 min savings on cold-builds after the first)**:
  - `wsus_server` role now caches `C:\Windows\WID\Data\SUSDB.mdf` + `SUSDB_log.ldf` (~52 MB total) to `C:\Software\wsus-cache\` (host: `vagrant/resources/software/wsus-cache/`) after a successful catalog sync.
  - Subsequent cold-builds: detect the cached database, stop WID + WSUS services, copy the cached files into `C:\Windows\WID\Data\`, restart services, and run `wsusutil postinstall` to refresh server identity. The existing `GetUpdateCategory($win11Guid)` early-exit in the sync task then takes the populated-catalog path and skips the 30-45 min Microsoft Update sync.
  - First cold-build: cache miss → full sync as before → save the resulting SUSDB to cache.
  - Both restore and save blocks use Ansible `block`/`rescue` to clean up if anything fails (delete stale cache + restart services + fall through to fresh sync).
  - Cache location documented at `vagrant/resources/software/wsus-cache/README.md`. To invalidate: `rm vagrant/resources/software/wsus-cache/SUSDB.*`.
- **Sprint 2a — scanner1 source-build cache (~15 min savings on cold-builds after the first)**:
  - `openssl_35` role caches the built `/opt/openssl-3.5/` tree as `openssl-{version}.tar.gz` under `{{ software_source_linux }}/scanner-cache/` after the first build. Subsequent cold-builds extract the cached tarball instead of re-downloading + re-configuring + re-compiling. ~9 min → ~10s. Cache invalidates automatically when `openssl_35_version` changes.
  - `cbom_lens` role caches the built Go binary as `cbom-lens.bin` in the same cache dir. Subsequent cold-builds copy the binary instead of fetching Go + cloning + building. ~3 min → ~5s.
  - `cbom_source_repos` role archives the cloned `/opt/cbom-sources/` (keycloak + bc-java + ejbca-ce, ~500 MB) as `cbom-sources.tar.gz`. Subsequent cold-builds extract instead of re-cloning. ~3 min → ~20s. Also avoids GitHub rate limits on repeated full clones.
  - Cache lives under `vagrant/resources/software/scanner-cache/` (host-local, gitignored, populated by first cold-build). Documented in `vagrant/resources/software/scanner-cache/README.md`. To invalidate: delete the matching file.
- **Sprint 1 quick wins (~20 min cumulative savings on `full` profile)**:
  - **Phase 2 overlap.** `up.sh` now forks dc1's Ansible provision into the background as soon as the dc1 VM is created in Phase 1 — running it concurrently with the remaining Phase 1 box-clones instead of waiting until Phase 1 ends. Phase 2 just `wait`s for the background PID. Saves ~15 min on profiles where Phase 1 dwarfs Phase 2 (`full`, `ad-cs-two-tier`, `ad-cs-one-tier`). Disable with `LAB_PHASE2_OVERLAP=false ./up.sh`. Auto-skipped when dc1 is snapshot-restored or already a working DC.
  - **`machine_cert` wait-loop gpupdate throttling.** The two retry loops (Root CA wait and Server Auth EKU wait) previously ran `gpupdate /force` on **every** iteration (~10-15s each + 20s Ansible delay = ~30-40s/retry). gpupdate doesn't make AD GPO replication faster — it just refreshes the local copy. Now gpupdate fires on retry 1 + every 6th retry afterwards (Root CA) or every 4th (EKU), polling cheaply in between. Saves ~5-7 min per affected VM on healthy mid-case waits (15 retries). 4 affected VMs on `full` × ~5 min = ~20 min worst case, ~5 min typical.

### Fixed
- **`full` profile cold-build failure modes — five distinct fixes** found by the 2026-05-21 first-ever cold-build (captured in `docs/v1.0-baselines-logs/2026-05-21-batch/full-profile-failure/`):
  - **`psframework` event log bootstrap** — `ansible-core/module_utils/csharp/Ansible.Basic.cs:365-384` swallows `SecurityException` from `EventLog.SourceExists()` but then calls `CreateEventSource("Ansible", "Application")` unguarded, which throws an unhandled `InvalidOperationException` if the source already exists in another log. ca1 hit this and failed at task 2 (`ok=1, failed=1`). Pre-creating the source via `ansible.builtin.raw` (which bypasses `Ansible.Basic.cs` entirely) ensures `SourceExists()` returns True reliably before the first `win_*` module runs.
  - **`machine_cert` cascade diagnostics** — when the 30-min Root CA wait exhausts, attach actionable cascade context (issueca SMB reachability, AD pKIEnrollmentService count, AD Certification Authorities count) to the error. Tells the operator whether to look at issueca (Issue #1) or the local machine. The 90-retry healthy-cascade tolerance is unchanged — only the throw message gets smarter.
  - **`subordinate_ca` ERROR_LOGON_FAILURE** (issueca, the cascade root) — `Install-AdcsCertificationAuthority` ran inside a `Batch`-logon scheduled task and relied on implicit Kerberos to contact the parent CA via RPC. The Batch token sometimes drops the Enterprise Admins SID, yielding `0x8007052e ERROR_LOGON_FAILURE`. Adding explicit `-Credential $adCred` (built inside the wrapper from `lab_netbios\Administrator` + `admin_password`) forces NTLM with the full identity.
  - **`cipheriq` Dockerfile presence check** — three upstream repos (`cbom-generator`, `crypto-tracer`, `pqc-flow`) cloned into `/opt/cipheriq/`, but the compose template hardcoded `build:` directives for all three. When any repo shipped without a top-level Dockerfile (observed: `pqc-flow`), `docker compose up` failed. Role now stat-checks each clone's Dockerfile and renders compose with `{% if x in cipheriq_valid_services %}` blocks per service — missing services are skipped cleanly instead of failing the bake.
  - **`wsus_server` partial catalog tolerance** — `Run catalog sync for product list` threw if the "Windows 11" GUID (`72e7624a-5b00-45d2-b92f-e561c0a6a160`) wasn't found, even when 300+ categories synced successfully (observed: 310 categories returned without Win 11 GUID, likely upstream catalog reorganization). Now: if sync ends and Win 11 GUID is missing but `>= 300` categories present, log warning and continue; downstream `wsus_products` task falls back to title match (`Title -eq 'Windows 11'`) when GUID lookup misses. Sync still fails hard if `< 300` categories — that signals a real connectivity issue.

### Changed
- **manage1 reboxed from Windows 11 → Server 2025 Desktop Experience.** The Win 11 24H2 Languages and Optional Features ISO (which would have unlocked fast RSAT via `Add-WindowsCapability -Source`) is only available through VLSC / MSDN / Visual Studio Subscriptions — not a viable dependency for an open lab. Server 2025 Desktop ships RSAT on-disk via WinSxS; `Install-WindowsFeature` lands in ~30s. `client1` stays Windows 11 for the client-perspective demo. Saves ~30 min on every Windows profile that includes manage1 (`core`, `ad-cs-one-tier`, `ad-cs-two-tier`, `full`).
  - `Vagrantfile` — `mgmt.vm.box = BOX_WIN_SERVER` (was `BOX_WIN_CLIENT`); removed manage1's `FOD_PATH` synced-folder block and `fod_source` extra var.
  - `roles/manage/tasks/main.yml` — replaced 96-line scheduled-task `Add-WindowsCapability` dance with a 6-line `win_feature` call (RSAT-AD-Tools, RSAT-ADCS-Mgmt, RSAT-DNS-Server, GPMC).
  - `playbooks/manage1.yml` — dropped the 1800s WinRM timeout override (no longer needed) and the Win-11 comment header.
  - `config.rb` — removed `FOD_PATH` / `FOD_AVAILABLE` constants (orphaned after rebox).
  - `docs/configuration.md` + `vagrant/GETTING-STARTED.md` — updated manage1 OS row and the FoD/RSAT plumbing sections.

### Added
- **`lab_desktop_enabled` opt-out for cold-build performance.** New COMMON_VARS toggle (defaults to `true`, set `LAB_DESKTOP_ENABLED=false ./up.sh` to disable) gates the three pure-UX roles. Skipping saves ~5-7 min per Desktop Experience VM (manage1, client1, tomcat1):
  - `bginfo` — wallpaper render is wasted if no one logs in.
  - `gui_tools` — NetTools / Firefox / Notepad++ are operator-only.
  - `desktop_customize` — taskbar tweaks, OneDrive uninstall, public-desktop shortcuts.
- **`bginfo` Server Core gate.** Detects `Get-ComputerInfo.WindowsInstallationType == 'Server Core'` and `meta: end_role`s — saves ~105s per Core VM (dc1, dc2, ca1, rootca, issueca, web1, wsus1). On `full` that's ~12 min. Re-uses the `is_server_core` host fact published by the `common` role; falls back to its own detection if invoked standalone.
- **`common` role Explorer-settings gate on Server Core.** The "Configure Explorer settings for all user profiles" task (HideFileExt, ShowSuperHidden, LaunchTo, etc.) loaded user-profile hives on every Windows VM — wasted on Server Core which has no Explorer shell. Now skipped via the new `is_server_core` host fact.
- **pqc-linux standalone support.** First successful cold-build of `LAB_PROFILE=pqc-linux` end-to-end (no Windows / AD CS). Required 7 fixes — none were single-bug, they were a fanout of design gaps where the Linux-only profile path had never been exercised. Validate.sh: `40 PASS / 0 FAIL / 6 SKIP` after pqc-migrate.
  - `roles/common_linux/defaults/main.yml` + `tasks/main.yml` — `lab_static_hosts` map and conditional `blockinfile` /etc/hosts task gated `when: "'dc1' not in groups['all']"`. Fallback for `*.lab_domain` resolution when no AD DNS.
  - `roles/common_linux/templates/resolv.conf.j2` — wrap `nameserver {{ dc_ip }}` in `{% if 'dc1' in groups['all'] %}` so Linux-only profiles don't time out on a non-existent DC.
  - `roles/stepca/templates/docker-compose.yml.j2` — `extra_hosts:` block rendered from `lab_static_hosts` when no dc1, so step-ca's container can resolve ACME challenge targets (Docker DNS is isolated from the host's /etc/hosts).
  - `roles/common_linux/tasks/main.yml` — `set_fact: lab_static_hosts` to publish the var as a host fact (Ansible 2.10+ scopes `include_role` defaults privately; downstream roles couldn't otherwise see it).
- `ejbca_pqc` role: forward-compatible Playwright skeleton at `files/set-chimera-altsig.py` and `ejbca_chimera_method` feature flag (`db_patch` | `playwright`) in `defaults/main.yml`. Default stays `db_patch` until EJBCA CE 9.4 ships and the JSF selectors are verified against a live 9.4 Edit-CA DOM. Setting `ejbca_chimera_method: playwright` on 9.3.7 fails fast with `FIELD-MISSING` (exit 2) by design. Tracks upstream tickets ECA-13071 + ECA-13368; CE 9.4 ETA per Keyfactor maintainer is "sometime in 2026."

### Changed
- `Vagrantfile` — `ejbca_two_tier: COMPONENTS.include?("ejbca1")` (was `TOPOLOGY == 'two-tier'`). EJBCA's hierarchy is independent of AD CS topology; tying it caused pqc-linux to skip creating EJBCA-Issuing-CA which broke `ejbca_admin_bootstrap` + `ejbca_chimera_profile`.
- `playbooks/acme1.yml` + `playbooks/observe1.yml` — gate `delegate_to: dc1` tasks (AD DNS A-record updates) on `when: "'dc1' in groups['all']"`.
- `vagrant/scripts/validate.sh` — gate the two AD DNS check blocks (acme1 walkthrough names; observe1 hostname) on `dig @192.168.56.10 .` reachability; emit `SKIP` line on Linux-only profiles instead of `FAIL`.
- `docs/configuration.md` — surface Layer 9 (per-role Windows + Linux config) in the Overview so it's findable from the top: expanded the 10-layer ladder, added 14 Windows/Linux-specific rows to the "Where to set what" table with anchor links, redrew the Mermaid diagram so Layer 9 is a labeled subgraph showing `defaults` / `tasks` / `files` / `templates`. No content moved — Layer 9 itself unchanged.
- `vagrant/docs/ejbca-chimera-setup.md` — Option B (Playwright) section rewritten with verified EJBCA 9.4 upstream status, Keyfactor CE issue #943 link, and the concrete flip-the-default checklist for when 9.4 lands.
- `docs/quickstart-walkthrough.md` — replaced "Screenshots TBD" disclaimer with positive framing that text-only is intentional + sufficient (every step is captured as a command transcript, log excerpt, or named artifact).

### Fixed
- `docs/configuration.md` Layer 9 accuracy: Sysmon version line ref (279 → 280), GnuPG build chain (corrected `ntbtls` → `pinentry`), acme.sh pin mechanism (`--upgrade-to-version` flag → `git version: "3.1.0"` checkout).

### Verification
- **Three new profiles cold-build verified green** (joining `pqc-full` from v0.2.0):
  - `core`: 78m 50s up.sh, **81 PASS / 0 FAIL / 3 SKIP** (after standard dup-cert cleanup on manage1).
  - `ad-cs-two-tier`: 86m 43s up.sh, **93 PASS / 0 FAIL / 2 SKIP** (after dup-cert cleanup).
  - `pqc-linux`: 23m 7s initial up.sh + ~50m of fix iterations + 22m pqc-migrate, **40 PASS / 0 FAIL / 6 SKIP**. The fixes shipped in this release.
- CBOM baselines refreshed for pqc-linux: `cbom-toolkit/baselines/baseline-{ejbca-api,nmap-network,pqc-handshake,pqc-openpgp,pqc-ssh}-pqc-linux.json`.

## [0.2.0] — 2026-05-20

OSS foundation + CI + cold-start hardening. Not a 1.0 cut — significant groundwork landed but no full stability promise yet. Cold-build of `pqc-full` from a destroyed state validates green (`202 PASS / 0 FAIL / 2 SKIP` after pqc-migrate + pqc-mtls).

### Added — OSS foundation
- `LICENSE` (MIT), `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CHANGELOG.md` at repo root.
- `.github/ISSUE_TEMPLATE/{bug_report,feature_request}.md` + `.github/PULL_REQUEST_TEMPLATE.md`.
- `ARCHITECTURE.md` with Mermaid diagrams (composition model, topology variants, chimera flow, CBOM pipeline, data flow) + PQC feature matrix.
- `docs/quickstart-walkthrough.md` — text-only first-run walkthrough (screenshots deferred).
- `vagrant/ansible/roles/README.md` — index of all 58 ansible roles grouped by capability area.
- `vagrant/docs/incident-scenarios.md` — reference for all 4 `incident-*` profiles + 10 break scenarios.
- `vagrant/docs/ejbca-chimera-setup.md` — known DB-patch workaround documented; Playwright fix path remains blocked upstream (EJBCA UI doesn't expose CAToken-internal fields).

### Added — CI + quality gates
- `.github/workflows/ci.yml` — lint job (ansible-lint + yamllint + shellcheck + `ruby -c`) + ruby test job + per-profile resolve matrix across all 17 profiles.
- `.github/workflows/profile-build.yml` — weekly self-hosted cold-build of pqc-full / ad-cs-two-tier / pqc-linux.
- `.ansible-lint`, `.yamllint`, `.editorconfig`, `.gitattributes` configs (errors-only policy; cosmetic findings surface as annotations without blocking merge).

### Added — Install / cold-start
- `scripts/install-wizard.sh --list-supported-hosts` flag + macOS (Homebrew) install branch; explicit fail-fast on Windows hosts with WSL2 pointer.
- `docs/v1.0-profile-baselines.md` — cold-build verification record + recommended baseline matrix.

### Changed — Story positioning
- README rewrite: PQC + three-audience framing (PKI learning, PQC migration, incident-response practice) in the headline. PROJECT_STRUCTURE block trimmed to point at the new roles index.
- `vagrant/docs/pqc-demo-runbook.md` gets a prominent **Known Limitations** section covering Microsoft AD CS CertEnroll gap, GnuPG ML-DSA signing pending 2.6.x, and OpenSSL 3.5 TLS 1.3 `-Verify` permissiveness.
- README + GETTING-STARTED + lab-topologies all link the Known Limitations + component status docs for discoverability.
- Issuing CA CRL validity bumped from 2 weeks → 26 weeks in `subordinate_ca/templates/CAPolicy-subordinate.inf.j2` to match root CA cadence.
- 16 YAML/Jinja2 files normalized from CRLF to LF line endings (`.gitattributes` enforces going forward).

### Fixed — Cold-start cascade (commit `46afbd9`)
First cold-build attempt from a destroyed state surfaced three cascading failures masked by warm rebuilds. All three fixed in this release:
- `acme_client/tasks/trust.yml` — added `wait_for` on stepca1:9000 before the curl fetches step-ca's root cert. Previously raced with stepca1's docker-compose-up.
- `subordinate_ca/tasks/main.yml` — parent CA wait extended from 10 min to 25 min. Cold rootca takes ~14 min on Server 2025; the 10-min ceiling let issueca give up ~4 min before rootca was ready, cascading into web1/manage1 missing the Root CA cert. Also dropped `no_log: true` on the install task — the censored output buried the root cause for 30 min on the failed build.
- `machine_cert/tasks/main.yml` — Root CA cert wait extended from 10 min to 30 min to cover the upstream chain (rootca finish + issueca parent-CA wait + install + dspublish).
- `vagrant/scripts/scenario-reset.sh` — renamed `DONE` → `RESET_DONE` to satisfy shellcheck (SC1081/SC1069 false-positive against the bash `done` keyword).

### Removed
- `vagrant/docs/cross-cert-bridge-design.md` — the AD CS ↔ EJBCA-Chimera cross-cert design deferred to a future release. v0.2.0 ships direct trust-store distribution via Group Policy + `certutil -dspublish` to the AD Configuration NC.
- `vagrant/ansible/roles/fiddler_cert/` — dead code, zero playbook references.

### Operational notes
- **Cold-build of `pqc-full` from a destroyed state takes ~91 min**, plus ~36 min for `pqc-migrate.yml` + ~3 min for `pqc-mtls.yml` + manual gpupdate cycle on manage1 to propagate chimera trust + cleanup of empty-subject duplicate certs. Snapshot the lab once green to skip the cycle on subsequent sessions.
- Snapshot `healthy-v0.2.0` saved across all 11 VMs as the post-build restore point.
- Validate the lab via `LAB_PROFILE=pqc-full bash vagrant/scripts/validate.sh` — target `202 PASS / 0 FAIL / 2 SKIP`.

## [0.1.1] — 2026-05-20

Maintenance, hygiene, and documentation polish on top of v0.1.0.

### Added
- Validator coverage for the pure-PQC mTLS surface — observe1:8445 unit health, scanner1 client cert, ML-DSA-65 handshake validation. Baseline: 202 PASS / 0 FAIL / 2 SKIP on `pqc-full` (#42).
- `vagrant/docs/lab-topologies.md` — consolidated one-tier vs two-tier reference replacing the per-directory READMEs in the deleted `topologies/` tree.

### Changed
- Runbook documents the mTLS variant on observe1:8445 and refreshes stale CBOM baselines (#43).
- README corrected: 4 broken script paths fixed (no more references to `scripts/bootstrap/`); 6 profile VM counts updated to match `vagrant/profiles/*.yml`.
- `vagrant/.gitignore` now covers `cbom-export/` and `logs/` (runtime spew that wasn't tracked but had no explicit ignore).

### Removed
- Pre-Vagrant PowerShell deploy scripts at repo root (4 files).
- Stale state-notes `.txt` files and the orphan `.vagrant/` directory at repo root.
- `vagrant/topologies/{one-tier-adcs,two-tier-adcs}/` — folded into `vagrant/docs/lab-topologies.md`; `snapshot.sh` helpers superseded by the profile-aware `vagrant/snap.sh`.
- `vagrant/tools/config-editor.html` and `vagrant/straylight-quiz-1.md` archived under `vagrant/docs/archive/`.
- `vagrant/ansible/roles/fiddler_cert/` — zero playbook references; dead code.

Net diff across the v0.1.0…v0.1.1 range: roughly +170 lines, −985 lines.

## [0.1.0] — 2026-05-19

First semver-versioned release. Headline feature: pure-PQC mTLS surface with ML-DSA-65 client cert authentication.

### Added
- **Pure-PQC mTLS endpoint** at `observe1:8445` with `openssl s_server -Verify 1` requiring a client certificate signed by EJBCA-PQC-Issuing-CA. Companion playbook enrolls an ML-DSA-65 client cert on scanner1 (#41).
- `pqc-mtls` Ansible playbook + `pqc_mtls_clients` inventory group.
- `pqc-migrate.yml` orchestrator + five phase playbooks (foundation, pure-leaf, chimera, audit, validation) verified end-to-end on `pqc-full` across 7 hosts (#36, #38).
- 13-lesson OpenSSL mastery lab workbook in `docs/openssl-lab/` (#37).
- Validator gating: PQC/chimera/step-ca checks now skip when not in the active profile (#34).
- A5-shadow-CA scenario rewritten for two-tier topology, publishing the rogue CA to AD NTAuth via dc1.

### Changed
- `validate.sh` excludes `*-1M-*` short-lived test templates from the 30-day expiry check (#39).
- Standalone CA polls CertSvc RPC readiness before `certutil -crl` (#33).
- SHA-1 in CA hash algorithm + issued certs is now a validator FAIL.

### Fixed
- `pqc-migrate` orchestrator unblocked end-to-end: SYSTEM-context certreq, CA HashAlgorithm registry flip, chimera catoken propertydata patch, ADSI LDAP DN format, alt-sig OID probe via DER hex (#35, #38).
- `r2-weak-crypto` scenario runs in SYSTEM context (#35).
- `scenarios` heredoc em-dash to hyphen fix (#32).
- SQL Server 2022 host (`sqlhost1`) added with ISO cache + `VALID_COMPONENTS` fix (#31).

## [0.0.1] — 2025-09 (approximate)

Initial tagged release. End-to-end one-tier AD CS lab provisioning from scratch via Vagrant + Ansible.

### Highlights at v0.0.1
- One-tier AD CS topology (DC1 + CA1 + WEB1 + CLIENT1) with Web Enrollment, NDES, CEP/CES, key archival, autoenrollment GPO, and custom cert templates.
- Two-tier topology (offline ROOTCA + Enterprise ISSUECA) migrated from shell provisioners to Ansible.
- Optional VMs: DC2, MANAGE1 (RSAT), WSUS1, EJBCA1 (CE on Docker), STEPCA1 (step-ca on Docker), TOMCAT1 (Tomcat + JDK 17), HYDRA1 (Ory Hydra OIDC), OBSERVE1 (OpenSearch + Dashboards, migrated from Graylog).
- CBOM toolkit: 3 scanners (theia, nmap-network, ejbca-api) plus pipeline + dashboards.
- PQC remediation surfaces: ML-DSA-65 CAs in EJBCA, pure-PQC TLS endpoints on observe1/ejbca1/stepca1/hydra1, chimera certs (Linux + Windows IIS), OpenSSH 10 with ML-KEM hybrid KEX on 4 hosts, GnuPG 2.5 with Kyber-768 subkeys.
- 10 incident scenarios (r1-r5 reliability + a1-a5 adversarial) wired into four `incident-*` profiles.
- Composable-lab refactor: `LAB_PROFILE` replaces `ADCS_TOPOLOGY`; 17 profile YAMLs in `vagrant/profiles/`; per-profile dotfile dirs (`.vagrant-<profile>/`).

### Deprecated at v0.0.1
- `ADCS_TOPOLOGY` env var — replaced by `LAB_PROFILE`. The resolver hard-errors with a migration hint if the old var is set without `LAB_PROFILE`.

[Unreleased]: https://github.com/zakrodriguez/straylight/compare/v2.8.0...HEAD
[2.8.0]: https://github.com/zakrodriguez/straylight/compare/v2.7.0...v2.8.0
[2.7.0]: https://github.com/zakrodriguez/straylight/compare/v2.6.0...v2.7.0
[2.6.0]: https://github.com/zakrodriguez/straylight/compare/v2.5.0...v2.6.0
[2.5.0]: https://github.com/zakrodriguez/straylight/compare/v2.4.1...v2.5.0
[2.4.1]: https://github.com/zakrodriguez/straylight/compare/v2.4.0...v2.4.1
[2.4.0]: https://github.com/zakrodriguez/straylight/compare/v2.3.0...v2.4.0
[2.3.0]: https://github.com/zakrodriguez/straylight/compare/v2.2.3...v2.3.0
[2.2.3]: https://github.com/zakrodriguez/straylight/compare/v2.2.2...v2.2.3
[2.2.2]: https://github.com/zakrodriguez/straylight/compare/v2.2.1...v2.2.2
[2.2.1]: https://github.com/zakrodriguez/straylight/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/zakrodriguez/straylight/compare/v2.1.5...v2.2.0
[2.1.5]: https://github.com/zakrodriguez/straylight/compare/v2.1.4...v2.1.5
[2.1.4]: https://github.com/zakrodriguez/straylight/compare/v2.1.3...v2.1.4
[2.1.3]: https://github.com/zakrodriguez/straylight/compare/v2.1.2...v2.1.3
[2.1.2]: https://github.com/zakrodriguez/straylight/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/zakrodriguez/straylight/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/zakrodriguez/straylight/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/zakrodriguez/straylight/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/zakrodriguez/straylight/compare/v0.2.0...v1.0.0
[0.2.0]: https://github.com/zakrodriguez/straylight/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/zakrodriguez/straylight/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/zakrodriguez/straylight/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/zakrodriguez/straylight/releases/tag/v0.0.1
