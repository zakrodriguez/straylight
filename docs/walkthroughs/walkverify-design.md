# How walkthroughs are made verifiable

The walkthroughs in `docs/walkthroughs/` are teaching documents: prose, commands
to type, and expected output. Originally, "verified" meant a maintainer had run
the commands by hand once and confirmed they worked. That claim decays — a role
change, a Server 2025 behavior change, or a topology change can silently break a
lab, and nothing detects it. The walkverify harness
(`vagrant/scripts/walkverify/`) converts that one-time hand-verification into a
replayable regression test, without altering what the reader sees.

This document explains the design. For day-to-day usage, see
[`vagrant/scripts/walkverify/README.md`](../../vagrant/scripts/walkverify/README.md).

## Design: three artifacts per lab

### 1. The markdown stays pure teaching content

Machine-readable assertions are added as HTML comments directly above each
runnable code block. They never render and never get copy-pasted by a reader.
Example from the revocation lab:

```
<!-- @verify host=issueca step=confirm-revoked expect=/0x15 \(21\) -- Revoked/ expect=/Reason: Superseded/ rc=0 -->
```

The sentinel keys:

| Key | Meaning |
|---|---|
| `host` | Which VM runs the block (`issueca`, `manage1`, …; the special value `lab` means bash on the host machine itself, used for e.g. `vagrant status`) |
| `step` | Unique identifier within the lab |
| `expect=/regex/` | Repeatable; each pattern must match the output |
| `rc` | Expected exit code (default 0) |
| `strict=true` | Additionally diff the full output against the frozen golden copy |
| `preamble=true` | The one idempotent setup block per host whose variables later steps need |
| `capture=Name:/regex/` | Extract a value from this step's output into a variable available to later steps |

### 2. The golden companion

`docs/walkthroughs/walkverify/<lab>.golden.yml` is the frozen record of a real,
approved run. Per step it stores the expected rc, the expect patterns, and
`captured` — the literal output the maintainer saw and signed off on. It also
carries two lab-level maps:

- `parameters:` — values for variables the harness cannot discover because they
  come from an interactive step the harness will never run. The mechanism is
  supported by the companion validator but unused so far: both shipped goldens
  carry `parameters: {}`. The connectivity lab, whose config string a reader
  first discovers through a `certutil -config - -ping` GUI picker, sidesteps
  the need by assigning `$CA = "ISSUECA.yourlab.local\YOURLAB-Issuing-CA"` in
  an in-lab preamble step.
- `normalizers:` — named regex→placeholder rules for legitimately volatile
  output. The revocation lab's golden maps serial-number lines to `<SERIAL>` so
  a different certificate serial on the next run does not produce a false
  failure. At check time, normalizers apply only to the output fields being
  asserted on. At verify time the maintainer approves the raw output, and the
  harness writes the golden's `captured` text with the normalizers already
  applied. Built-in suggestors exist for latencies, serials,
  GUIDs, and ISO timestamps.

### 3. The harness

`vagrant/scripts/walkverify/` — small single-purpose modules (annotation
parsing, companion validation, execution, capture extraction, normalization,
gating, orchestration), each with its own test file. Three commands tie the
artifacts together.

## The three commands

**`walkverify.sh lint <lab.md>`** — fully static, no VMs; intended as a
per-PR gate, though not currently wired into `.github/workflows`.
It parses the sentinels, validates the companion, and runs an order-aware
variable analysis: every `$var` a step references must be defined by the
companion's `parameters`, an assignment in that host's preamble, an assignment
earlier in the same step, or a `capture=` from a strictly earlier step. It
distinguishes "undefined" from "forward reference" (captured only by this or a
later step), and rejects a capture that shadows a parameter. PowerShell
automatic variables (`$_`, `$true`, `$matches`, …) are excluded so they don't
false-positive.

**`walkverify.sh verify <lab.md> --profile <p>`** — the one-time
hand-verification, now producing an artifact. It runs every annotated step
against a live build, shows the maintainer the real output, and on approval
writes the golden companion. It stops on the first runtime error so a known
cascade doesn't keep firing live commands.

**`walkverify.sh check <lab.md>`** — the regression replay. It re-runs all
steps against a standing lab (continuing past failures so a complete pass/fail
map is produced), then gates each step: exit code must match, every expect
regex must match the normalized output, and strict steps must match the
normalized golden output byte-for-byte. Golden values override the markdown's
sentinel values where they differ, so tightening an assertion doesn't require
touching the teaching text.

## How steps execute

The runner resolves each host's transport (WinRM for Windows, SSH for Linux)
through the same credential resolver buildmon uses, then shells out to
`vagrant winrm` / `vagrant ssh` with a 300-second timeout, combining stdout and
stderr. For each non-preamble step it assembles a script in three layers:
variable assignments, then the host's preamble block, then the step's command.
Assignments are injected as PowerShell single-quoted literals with embedded
quotes doubled — no `$`-expansion, backslashes stay literal — which both
prevents injection and survives CA config strings like
`ISSUECA.yourlab.local\YOURLAB-Issuing-CA`.

### Chained state via `capture=`

Steps run in document order with a shared bindings map: a step declaring
`capture=` has its pattern's group 1 extracted from the output and bound to
the name given in the `capture=NAME:` prefix, and those
bindings are injected into every later step, taking precedence over static
parameters. This is what made the revocation lab automatable. From its
`resolve-cert-ids` step:

```
<!-- @verify host=issueca step=resolve-cert-ids
     capture=RequestId:/RequestID=([0-9A-Fa-f]+)/
     capture=SerialNumber:/SerialNumber=([0-9A-Fa-f]+)/ expect=/RequestID=/ rc=0 -->
```

Every subsequent step — `certutil -view -restrict "RequestID=$RequestId"`,
`certutil -revoke $SerialNumber 4`, grepping the CRL dump for `$SerialNumber` —
receives the run's actual values.

One rule follows: a capturing step must not set `strict=true`, because its
stored golden output contains that run's volatile value and a full diff would
never re-match. Assert on it with `expect=` instead.

## Conventions that made the AD CS functest labs green

Three conventions and fixes were needed for the assertions to pass reliably on
the two-tier NAT topology (v2.8.0, PRs #235–#238):

- **CA-admin steps run on the CA host.** Remote `certutil -config` / CertEnroll
  calls from `manage1` fail with `RPC_S_SERVER_UNAVAILABLE` on multi-homed
  Vagrant VMs, so all revoke/view/CRL steps carry `host=issueca` and run
  locally on the CA.
- **A fixture playbook issues the test certificate.** Rather than depending on
  whatever the reader enrolled, an Ansible fixture issues
  `functest1.yourlab.local` and writes its RequestId/SerialNumber to
  `C:\ProgramData\adcs-functest\functest-cert-ids.txt`; the lab's
  `resolve-cert-ids` step reads that file and captures the values, making the
  chain deterministic on any fresh build.
- **CRL distribution to the CDP is part of the lab.** `certutil -CRL` publishes
  locally on the CA, but relying parties fetch from
  `http://pki.yourlab.local/crl/` on web1 — so the publish step copies the
  fresh CRLs to web1's share, and the final steps assert the client-side truth
  (`CERT_TRUST_IS_REVOKED`, `CRYPT_E_REVOKED` from
  `certutil -verify -urlfetch` on `manage1`), with expects matching Server
  2025's output wording. Related: `certreq` without `-q` opens a GUI prompt
  over WinRM and hangs forever.

## Lifecycle

A module parked in the development archive returns when three
things are true:

1. its labs are annotated and pass `lint`;
2. a maintainer `verify` run against a live build yields an approved green
   golden;
3. `check` re-passes on a fresh build.

From then on, `lint` guards every PR statically, and `check` can be replayed
against any standing lab to catch regressions from role or platform changes.
