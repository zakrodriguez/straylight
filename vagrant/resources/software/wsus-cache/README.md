# WSUS golden-master cache

Golden (R/O) master for WSUS patch data, consumed by the `wsus_server` role.

- `SUSDB.mdf` / `SUSDB_log.ldf` — the WSUS catalog database (metadata). Restored at
  provision start (skips the 30–45 min catalog sync) and **auto-captured** at provision
  end (floor-guarded; `WSUS_CACHE_CAPTURE=false` to disable). A healthy synced `SUSDB.mdf` is ~45 MB; capture is floor-guarded at 20 MB to skip a failed/empty build.
- `WsusContent/` — the patch binaries (~118 GB). Restored at provision start via
  `robocopy /MIR`. Captured by an **explicit** step (content downloads asynchronously
  and isn't complete when the provision ends):

      LAB_PROFILE=<profile-with-wsus1> scripts/cache-wsus.sh

The running WSUS service works on its own `D:\WSUS` + WID copy (R/W); this cache is
R/O at runtime, written only by the capture steps. All files here are gitignored.
`WSUS_CACHE_RESTORE=false` forces a fresh sync instead of restoring.
