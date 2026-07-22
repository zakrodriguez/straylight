# Contributing to Straylight

Straylight is a Vagrant + VirtualBox PKI lab, maintained by one person in spare time.

## Pull request policy

**Straylight is not accepting pull requests at this time.** Reviewing and live-testing external changes against multi-VM lab builds takes more time than the maintainer currently has, so PRs will be closed with a pointer to this policy — please don't take it personally, and thank you for the interest. If this changes, this file and the PR template will say so.

The best ways to contribute instead:

- **Fork freely** — the MIT license means you can build on the lab without waiting on upstream.
- **Report security issues** — the one inbound channel that is always open; see [SECURITY.md](SECURITY.md).

## Issues

Issues are disabled on this repository. With PR review already out of scope, an issue tracker the maintainer cannot service would only collect stale reports. The one exception is security: vulnerabilities are always welcome through the private channel described in [SECURITY.md](SECURITY.md).

## For forks

[.github/copilot-instructions.md](.github/copilot-instructions.md) is the canonical reference for code conventions, architecture, and common task patterns. CI (ansible-lint, yamllint, shellcheck, profile-resolution tests) runs on PRs within a fork the same way it does here.

## Code of Conduct

This project follows the [Contributor Covenant v2.1](CODE_OF_CONDUCT.md). Be kind, be specific, assume good faith.

## Security issues

Security reports are the exception to the no-PR policy's spirit: they are always welcome. Don't file public issues for vulnerabilities — see [SECURITY.md](SECURITY.md) for the disclosure process.

## Questions?

There is no support channel — the lab ships as-is. The docs tree ([README](README.md), [ARCHITECTURE.md](ARCHITECTURE.md), [docs/](docs/)) is the intended path to answers; fork and experiment from there.
