# OpenPGP / GnuPG PQC status

**Summary:** GnuPG 2.5.x (through 2.5.19, latest) ships **ML-KEM
(Kyber-768) encryption** but **no ML-DSA (Dilithium) signing**.
`pqc-gnupg.yml` builds 2.5.13 to `/opt/gnupg-pqc` and provisions the
ECC+Kyber key; its encrypt/decrypt round-trip passes. PQC git-commit signing is future work.

## What works today (RFC 9580 / OpenPGP June 2024)

Lab PQC OpenPGP key on observe1:

```
pub   ed25519/...     [SC] [expires: 2028-05-10]    ← classical signing
uid   Straylight PQC Demo (observe1) <pqc@yourlab.local>
sub   ky768_bp256/... [E]  [expires: 2028-05-10]   ← Kyber-768 + Brainpool P-256 hybrid encryption
```

`ky768_bp256` = ML-KEM-768 + Brainpool P-256 composite, added in 2.5.2
(option 16 in `--full-gen-key`; algo name `kyber768` in `--quick-add-key`).
The uid embeds the hostname — `pqc-gnupg.yml` sets
`Straylight PQC Demo ({{ inventory_hostname }}) <pqc@yourlab.local>` — so
each VM gets its own key under the same email handle.

End-to-end demo:

```bash
HOMEDIR=/opt/gnupg-pqc/home
GPG=/opt/gnupg-pqc/bin/gpg

echo 'top secret' | sudo $GPG --homedir $HOMEDIR --trust-model always \
    -e -r pqc@yourlab.local -o /tmp/secret.gpg

# Inspect: shows "encrypted with ky768_bp256 key"
sudo $GPG --homedir $HOMEDIR --list-packets /tmp/secret.gpg

# Decrypt round-trips
sudo $GPG --homedir $HOMEDIR --batch --pinentry-mode loopback \
    --passphrase '' -d /tmp/secret.gpg
```

Shared probe `vagrant/scripts/lib/pqc-verify/gpg-kyber.sh`: assert an
`algo 8` (Kyber/ML-KEM) encryption subkey, encrypt a fresh nonce, decrypt,
byte-compare. Consumed by `scripts/checks/pqc-chimera.sh` (which loops it
over stepca1/ejbca1/hydra1) and by `pqc-migrate-gpg.yml`, so build and
validator cannot drift on what "Kyber works" means for those hosts.
observe1 gets a separate, more detailed inline check in the same script
that does not use the shared probe.

## What doesn't work yet

`gpg --version` Pubkey list on 2.5.13:

```
Pubkey: RSA, Kyber, ELG, DSA, ECDH, ECDSA, EDDSA
```

No PQC signature algorithm. `--quick-gen-key`/`--quick-add-key` reject
`mldsa65`, `dilithium3`, `mldsa44`; interactive `--full-gen-key` offers
only the encryption-only ECC+Kyber composite. NEWS for 2.5.0 through
2.5.19 (latest available May 2026) mentions Kyber/ML-KEM, never
ML-DSA/Dilithium. So gpg cannot ML-DSA-sign git commits: a sign-capable
primary key must be classical (Ed25519/RSA/ECDSA) in any GnuPG that
exists today; `git commit -S` +
`git config user.signingkey` uses the Ed25519 primary.

## Why the GnuPG build ships

- Kyber-wrapped files (encrypted backups, git-secrets) get a PQC session
  key: "harvest now, decrypt later" needs a quantum break of Kyber-768,
  not just a classical attack on the Brainpool P-256 half (hybrid —
  safe iff *either* half holds).
- The role + key + validate.sh check make the demo reproducible.
- When ML-DSA lands (likely 2.6.x), the role can add an ML-DSA signing
  subkey to the same key via `--quick-add-key`.

## Paths forward

1. **Wait for GnuPG 2.6.x.** ML-DSA signing is on gnupg.org's roadmap
   for the next stable branch; re-test on release.
2. **Sequoia-PGP.** Rust; experimental ML-DSA in the development branch
   as of late 2025; could install alongside GnuPG for an earlier demo.
3. **OpenPGP.js.** JavaScript implementation; ML-DSA support uncertain.
4. **Custom signer using libgcrypt 1.11 directly.** libgcrypt 1.11.2
   has ML-DSA primitives GnuPG doesn't expose; a small C program could
   ML-DSA-65-sign a git commit out-of-band, but loses OpenPGP /
   `git verify-commit` integration.

## Build notes

- Full chain builds to `/opt/gnupg-pqc`, RPATH-linked; system
  GnuPG/libgcrypt on `/usr` untouched, no ldconfig changes.
- Build deps: `build-essential gettext texinfo bzip2 libbz2-dev
  zlib1g-dev libreadline-dev libncurses-dev pkg-config`.
- Versions: libgpg-error 1.56, libgcrypt 1.11.2 (PQC primitives),
  libassuan 3.0.2, libksba 1.6.7, npth 1.8, pinentry 1.3.2, gnupg 2.5.13.
- Compile time ~6-8 min on a 2-vCPU VM.
- pinentry: --enable-pinentry-curses only (headless lab). gnupg:
  --disable-doc, --disable-gpgsm, --disable-gpgtar, --disable-wks-tools.
