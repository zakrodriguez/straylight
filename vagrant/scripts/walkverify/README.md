# walkverify — walkthrough verification harness

Turns the one-time hand-verification of a walkthrough lab into a replayable
regression test. Human markdown stays the teaching content; a per-lab
`docs/walkthroughs/walkverify/<lab>.golden.yml` companion carries the assertions.
Design rationale: [docs/walkthroughs/walkverify-design.md](../../../docs/walkthroughs/walkverify-design.md).

## Annotating a lab
Above each runnable check with a knowable expected output, add one invisible
sentinel (an HTML comment — never rendered, never copy-pasted):

    <!-- @verify host=manage1 step=ping-admin expect=/interface is alive/ rc=0 -->
    ```powershell
    certutil -config $CA -ping
    ```

Keys: `host` (required), `step` (required, unique), `expect=/regex/` (repeatable),
`rc` (default 0), `strict=true` (full-output diff, default off), `preamble=true`
(the one idempotent setup block whose vars later steps need).

Interactive discovery (e.g. `certutil -config -` GUI dialog) is never run — its
value goes in the companion's `parameters:` instead.

## Workflow
- `walkverify.sh lint  <lab.md>` — static-only: annotations parse, companion
  valid, every `$var` resolved. No VMs. Intended as a per-PR gate; not
  currently wired into CI.
- `walkverify.sh verify <lab.md> --profile <p>` — run against a LIVE build,
  capture output, approve → writes the golden companion. The one-time
  hand-verification, now producing an artifact.
- `walkverify.sh check <lab.md>` — replay against a standing lab, assert
  rc+expect per step. Scheduled / on-demand (needs a live build).

## Known limitations
- The connectivity lab discovers `$CA` via an interactive setup block
  (`certutil -config -` dialog) that the harness does not run, and uses
  `$Work` throughout; its companion `parameters:` MUST supply both `CA` and
  `Work`. The service-health lab needs neither: an annotated `preamble=true`
  step assigns `$CA` on `issueca`, it uses no `$Work`, and its shipped golden
  carries `parameters: {}` and lints clean.
- Steps that depend on per-run or chained state — e.g. a freshly-issued
  certificate's RequestId/SerialNumber (revocation) — are handled via
  `capture=Name:/regex/`: the pattern's group 1, extracted from the step's
  output, becomes a binding named by the `Name:` prefix, injected into every
  later step and taking precedence over static `parameters`. Of the shipped
  labs only revocation declares `capture=` (its RequestId/SerialNumber);
  service-health's six sentinels carry none. Both are fully machine-verified.
- A capturing step's golden `captured` retains the run's volatile value, so
  do not set `strict=true` on a step that declares `capture=` — the strict
  full-output diff would never re-match. Assert on it with `expect=` instead.

## Returning a parked module
A parked module returns from the development archive to
`docs/walkthroughs/` when it is annotated, `verify` yields a green golden, and
`check` re-passes on a fresh build.

## Live capture (maintainer, post-merge)
The shipped adcs-functest goldens (service-health, revocation) were produced by
running `verify` with `--profile ad-cs-two-tier` and `parameters: {}` against
the build each lab's "Before you start" block prescribes:
`LAB_PROFILE=ad-cs-two-tier vagrant up dc1 issueca manage1`.
