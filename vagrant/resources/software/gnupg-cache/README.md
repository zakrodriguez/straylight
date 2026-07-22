# gnupg-cache

Pre-staged source tarballs for the GnuPG 2.5+ PQC build chain (libgpg-error,
libgcrypt, libassuan, libksba, npth, pinentry, gnupg). The `gnupg_pqc` role
checks this directory before reaching out to gnupg.org — if a tarball is
present, the role copies it locally; otherwise it falls back to `curl`.

Populated by `scripts/cache-software.sh` from entries in
`scripts/software-manifest.yml`. Files are gitignored — only this README and
the `.gitkeep` marker are committed.

See `docs/configuration.md` for the full software-cache layout.
