# Pull Request

> **Note:** Straylight is not currently accepting external pull requests — see
> [CONTRIBUTING.md](../CONTRIBUTING.md#pull-request-policy). External PRs will be
> closed with thanks. This template is used by the maintainer's own PRs.

## What this changes

<!-- One paragraph. The "why" matters more than the "what" — the diff already shows the what. -->

## Profile(s) tested

<!-- Which LAB_PROFILE values did you live-test this against? Required for any change touching ansible/, profiles/, scripts/, or Vagrantfile. -->

- [ ] `core`
- [ ] `ad-cs-one-tier`
- [ ] `ad-cs-two-tier`
- [ ] `pqc-linux`
- [ ] `pqc-full`
- [ ] Other: `___`
- [ ] Not applicable (docs / lint / CI only)

## validate.sh

<!-- Required for ansible / Vagrantfile / config changes. Run before + after. -->

| | PASS | FAIL | SKIP |
|---|---|---|---|
| Before | | | |
| After | | | |

## Checklist

- [ ] Branch named `feat/`, `fix/`, `docs/`, `chore/`, or `refactor/`
- [ ] Linted locally (`ansible-lint`, `yamllint`, `shellcheck`)
- [ ] Live-tested against the profile(s) checked above (not just by reading the diff)
- [ ] Docs updated if behavior changed (README, `vagrant/docs/`, role README, etc.)
- [ ] CHANGELOG.md `[Unreleased]` section updated for user-visible changes
- [ ] No new TODO / FIXME / XXX added without an issue link
- [ ] No secrets or credentials committed

## Screenshots / output

<!-- For UI changes (OSD dashboards, install-wizard prompts, etc.) or notable runtime output. Skip if not applicable. -->

## Related issues

<!-- Closes #N, references #M, depends on #L. -->
