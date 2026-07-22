#!/usr/bin/env bash
# Produces a byte-deterministic tarball.tar.gz for the integrated exercise.
# Determinism comes from --mtime, --owner, --group, sort, and gzip -n.
set -euo pipefail

ROOT="$1"
cd "$ROOT/inputs"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
echo "alpha file" > "$tmpdir/alpha.txt"
echo "bravo file" > "$tmpdir/bravo.txt"
echo "charlie file" > "$tmpdir/charlie.txt"

( cd "$tmpdir" && \
  tar --mtime='2026-01-01 00:00:00 UTC' \
      --owner=0 --group=0 --numeric-owner \
      --null --files-from=<(find . -type f -print0 | sort -z) \
      -cf - ) | gzip -n > tarball.tar.gz

sha256sum tarball.tar.gz | tee tarball.tar.gz.sha256
