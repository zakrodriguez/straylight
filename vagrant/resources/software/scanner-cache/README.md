# scanner-cache

First-build artifact cache for the three `scanner1` source-build roles. Populated automatically by the first cold-build on this host; subsequent cold-builds restore from here instead of rebuilding.

| File | Source | Time saved per cold-build | Approx size |
|---|---|---|---|
| `openssl-3.5.0.tar.gz` | `openssl_35` role — built /opt/openssl-3.5/ tree | ~9 min | ~40 MB |
| `cbom-lens.bin` | `cbom_lens` role — built Go binary | ~3 min | ~20 MB |
| `cbom-sources.tar.gz` | `cbom_source_repos` role — keycloak + bc-java + ejbca-ce clones | ~3 min | ~500 MB |

**On first cold-build:** these files don't exist. The roles download dependencies, build, then save the output here.

**On subsequent cold-builds:** the roles detect the cached file and restore it instead of rebuilding. ~10-30s per artifact vs minutes.

The directory is gitignored (see `../.gitignore`). The cache is host-local — it does NOT travel with the repo and is not distributed to OSS users. New environments will rebuild on first cold-build, then enjoy fast subsequent builds.

To invalidate the cache (e.g. when bumping `openssl_35_version` or `cbom_lens` upstream commit), delete the matching file from this directory and re-provision.
