# OpenSSL Mastery Lab

Hands-on lab for openssl-3.x CLI mastery: 13 lessons, ~3.5 hours total.
Self-contained — `bootstrap.sh` generates all sample certs/keys locally;
no network or external CA required. Each lesson links to the corresponding
fixmycert.com interactive demo as an optional visual companion; the lab
works standalone.

## Quick start

```bash
cd vagrant/docs/openssl-lab
bash bootstrap.sh             # generates certs/ (~5 min, one-time)
$EDITOR lessons/01-inspect-cert.md
```

Re-bootstrap if `certs/.bootstrap-time` is older than 30 days. Not all
sample artifacts are 365-day: lesson 07's CRL has a 30-day `nextUpdate`
(past it, lesson 07 prints extra "CRL has expired" lines) and six of
the leaf certs are 90-day — those set the window.

## Skill matrix

|  # | Lesson                     | Level | Time | fixmycert demo |
|----|----------------------------|-------|------|----------------|
|  1 | Inspect a cert             | intro | 10m  | Decode This Certificate |
|  2 | Verify a cert chain        | intro | 15m  | Chain of Trust Builder |
|  3 | Generate key + CSR         | intro | 15m  | CSR Walkthrough |
|  4 | Self-sign a cert           | intro | 10m  | Quick Self-Signed |
|  5 | Format conversion          | intro | 10m  | PEM/DER/PKCS12 |
|  6 | Debug TLS handshake        | intermediate | 20m | TLS Handshake Visualizer |
|  7 | CRL inspection             | intermediate | 15m | CRL Lifecycle |
|  8 | OCSP query                 | intermediate | 20m | OCSP vs CRL |
|  9 | Decode extensions          | intermediate | 15m | SAN/EKU Explorer |
| 10 | Hostname mismatch          | intermediate | 15m | Why Doesn't This Validate? |
| 11 | Cipher suites + protocols  | advanced | 20m | Cipher String Decoder |
| 12 | Sign + verify payload      | advanced | 15m | Signature Verification |
| 13 | Walk a cert bundle         | advanced | 20m | Bundle Order Matters |

## How to use this lab

- Lessons are self-contained and run offline (after bootstrap) with
  throwaway certs in `certs/` — pick any one and start.
- Each lesson ends with ungraded self-check questions; answer out loud
  or in notes for retention.

## Maintenance

- Add a lesson: drop a `lessons/NN-topic.md` + add a `gen_NN_topic`
  function in `bootstrap.sh`.
- Regenerate certs: `bash bootstrap.sh --force`.
- Wipe and start over: `rm -rf certs/ && bash bootstrap.sh`.
- Lint a lesson: `bash tools/lint-lesson.sh lessons/NN-*.md`.
- Smoke-check every command in every lesson: `bash tools/run-all-commands.sh`.
