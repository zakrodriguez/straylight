# Optional nightly sweep timer

User units that run `az700.sh sweep --delete` at 23:00 local, deleting any
AZ-700 resource group older than 8 hours — the "closed the laptop with a VPN
gateway running" safety net. Never installed automatically; opt in with:

```bash
mkdir -p ~/.config/systemd/user
cp azure/scripts/systemd/az700-sweep.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now az700-sweep.timer
```

Requires a logged-in az CLI (`az login` tokens refresh for ~90 days). Edit the
`ExecStart` path in the service unit if the repo is not at `~/straylight`.
Disable with `systemctl --user disable --now az700-sweep.timer`.
