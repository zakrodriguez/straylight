"""buildmon CLI: `collect` (sidecar) and `watch` (TUI)."""
from __future__ import annotations
import argparse
import os
import sys
import time

def _vbox_names_fallback(profile):
    """VBox-registered machine names, offered as topology's last-resort tier-3.

    Attempted regardless of whether a profile was given: topology only actually
    uses these names when both the profile-YAML tier and the logdir tier produce
    nothing (e.g. a misspelled profile paired with an empty logdir), so gating
    this on `profile` would suppress a fallback that's still needed."""
    try:
        from vbox import list_registered
        return list(list_registered().keys()) or None
    except Exception:
        return None   # no VBoxManage / not installed → topology falls back to logdir only

def build_parser():
    p = argparse.ArgumentParser(prog="buildmon", description="Build-observability sidecar")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect", help="run the collector sidecar")
    c.add_argument("--logdir", required=True)
    c.add_argument("--profile", default=None)
    c.add_argument("--interval", type=int, default=5)
    c.add_argument("--hang-detect", type=int, default=600, dest="hang_detect")
    c.add_argument("--no-guest-probe", action="store_true", dest="no_guest_probe")
    c.add_argument("--profiles-dir", default=None, dest="profiles_dir")
    c.add_argument("--on-event", default=None, dest="on_event",
                   help="host command exec'd with one JSON event on stdin "
                        "(vm_failed/vm_hung/build_done/build_failed); "
                        "env fallback BUILDMON_ON_EVENT")
    w = sub.add_parser("watch", help="render the feed as a TUI")
    w.add_argument("--logdir", required=True)
    w.add_argument("--interval", type=int, default=2)
    w.add_argument("--plain", action="store_true")
    w.add_argument("--once", action="store_true")
    ls = sub.add_parser("list", help="list build logdirs (newest first) with profile/feed state")
    ls.add_argument("--logs-root", required=True, dest="logs_root")
    ls.add_argument("--limit", type=int, default=10)
    ls.add_argument("--profile", default=None,
                    help="only logdirs whose VMs fit this profile's component set")
    ls.add_argument("--porcelain", action="store_true",
                    help="tab-separated: logdir<TAB>profile<TAB>phase<TAB>feed<TAB>age_s<TAB>reprovision")
    ra = sub.add_parser("reset-attempts",
                        help="reset cross-run attempt counters for a profile")
    ra.add_argument("--logs-root", required=True, dest="logs_root")
    ra.add_argument("--profile", default=None)
    ra.add_argument("--stamp", default=None,
                    help="logdir timestamp cutoff (default: newest logdir under logs-root)")
    return p

def cmd_collect(args):
    import time
    from clock import Clock
    from model import StatusModel
    from feed import FeedWriter
    from logtail import LogTailer
    from vbox import VBoxPoller
    from guestpool import GuestProbePool
    from guest import GuestProber
    from collector import Collector
    import creds as creds_mod
    from alerts import AlertDispatcher
    import topology
    if not os.path.isdir(args.logdir):
        print(f"buildmon: --logdir {args.logdir!r} is not a directory — expected a build's "
              "log dir like vagrant/logs/<timestamp>/ (beware: `ls -t` puts files like "
              "ansible.log first)", file=sys.stderr)
        return 2
    clock = Clock()
    profiles_dir = args.profiles_dir or _default_profiles_dir(args.logdir)
    outdir = os.path.join(args.logdir, "buildmon")
    os.makedirs(outdir, exist_ok=True)
    logger = _make_logger(os.path.join(outdir, "buildmon.log"))
    vbox_names = _vbox_names_fallback(args.profile)
    profile = args.profile
    if not profile:
        # Multi-lab: without a profile, VBox machine names (straylight-<profile>-<vm>)
        # can't be resolved and same-stem VMs across concurrent labs are ambiguous.
        # Infer it from the logdir's VM set (create-logs give the full set early).
        profile = topology.infer_profile(args.logdir, profiles_dir, vbox_names=vbox_names,
                                         now_epoch=clock.now())
        if profile:
            msg = f"buildmon: inferred profile '{profile}' from logdir contents"
            logger(msg)
            print(msg, file=sys.stderr)
    vms = topology.resolve(profile, args.logdir,
                           vbox_names=vbox_names,
                           profiles_dir=profiles_dir)
    if not vms:
        msg = (f"buildmon: resolved 0 VMs (logdir={args.logdir!r}, profile={profile!r}) — "
               "check the logdir path and profile name")
        logger(msg)
        print(msg, file=sys.stderr)
    # Warn when the logdir's actual VM logs disagree with the resolved set —
    # the classic symptom of a wrong --profile. The collector auto-adopts these, but
    # the operator should know their profile assumption is off.
    logdir_vms = set(topology.logdir_vm_stems(args.logdir))
    extra = sorted(logdir_vms - {v[0] for v in vms})
    if extra:
        msg = (f"buildmon: logdir has logs for VMs outside the resolved topology: "
               f"{', '.join(extra)} (profile={profile!r}) — auto-adopting them; "
               "check your --profile")
        logger(msg)
        print(msg, file=sys.stderr)
    model = StatusModel(profile or "unknown", args.logdir, time.time(), clock)
    tailers = {}
    for name, role, idx in vms:
        model.add_vm(name, role=role, order_index=idx)
        tailers[name] = LogTailer(os.path.join(args.logdir, f"{name}.log"), clock)
    name_map = topology.vbox_name_map(profile, [v[0] for v in vms]) if profile else {}
    vboxpoller = VBoxPoller(name_map, clock=clock)
    vagrant_root = os.path.dirname(os.path.dirname(os.path.abspath(args.logdir)))
    prober_factory = None
    if not args.no_guest_probe:
        def prober_factory(name, prof, _root=vagrant_root):
            d = creds_mod.resolve(name, prof, _root)
            if d.get("available"):
                return GuestProber(name, d["transport"], d)
            logger(f"guest probe dark for {name}: {d.get('reason')}")
            return None
    probers = {}
    if prober_factory and profile:
        for name, _role, _idx in vms:
            p = prober_factory(name, profile)
            if p is not None:
                probers[name] = p
    guestpool = GuestProbePool(probers, clock=clock, enabled=bool(probers))
    logger(f"guest probes enabled for {len(probers)} VM(s)" if probers
           else "guest probes disabled (no resolvable descriptors yet"
                " — re-wired on adoption/late-inference)")
    on_event = args.on_event or os.environ.get("BUILDMON_ON_EVENT")
    dispatcher = AlertDispatcher(on_event, logger=logger) if on_event else None
    col = Collector(args.logdir, profile, model, feed=FeedWriter(outdir),
                    tailers=tailers, vboxpoller=vboxpoller, guestpool=guestpool,
                    clock=clock, pid_map={}, hang_threshold_s=args.hang_detect,
                    profiles_dir=profiles_dir, logger=logger, alerts=dispatcher,
                    prober_factory=prober_factory)
    col.load_attempts_and_stamp()
    guestpool.start()
    col.run(interval_s=args.interval)
    return 0

def cmd_watch(args):
    import tui
    return tui.run(args.logdir, interval_s=args.interval, plain=args.plain, once=args.once)

_FEED_LIVE_S = 15   # collector default tick is 5s; a feed older than this is stale

def _profile_components(profiles_dir, profile):
    import topology
    path = os.path.join(profiles_dir, f"{profile}.yml")
    if not os.path.isfile(path):
        return None
    return set(topology._from_profile_yaml(path))

def _list_rows(logs_root, limit, profile_filter, vbox_names, now_epoch, profiles_dir=None):
    """Build logdirs under logs_root, newest first (dir names are UTC timestamps).
    Non-build dirs (validate-only runs) are skipped. Each row:
    (logdir, profile-or-None, phase-or-None, feed 'live'|'stale'|'none', age_s-or-None,
     max_attempt) — max_attempt is the highest per-VM `attempt` in the feed (1 if none/absent)."""
    import json
    import calendar
    import time as _t
    import topology
    profiles_dir = profiles_dir or os.path.join(
        os.path.dirname(os.path.abspath(logs_root).rstrip("/")), "profiles")
    want = _profile_components(profiles_dir, profile_filter) if profile_filter else None
    rows = []
    try:
        entries = sorted(os.listdir(logs_root), reverse=True)
    except OSError:
        return rows
    for name in entries:
        d = os.path.join(logs_root, name)
        if not os.path.isdir(d):
            continue
        stems = topology.logdir_vm_stems(d)
        if not stems:
            continue
        if want is not None and not set(stems) <= want:
            continue
        profile = topology.infer_profile(d, profiles_dir, vbox_names=vbox_names,
                                         now_epoch=time.time())
        if profile is None and profile_filter:
            profile = profile_filter   # stems fit the requested profile; trust the ask
        phase, feed, age = None, "none", None
        max_attempt = 1
        try:
            with open(os.path.join(d, "buildmon", "status.json")) as fh:
                status = json.load(fh)
            feed_profile = status.get("build", {}).get("profile")
            if feed_profile and feed_profile != "unknown":
                profile = feed_profile   # the collector knows; beats re-inference
            phase = status.get("build", {}).get("phase")
            updated = status.get("build", {}).get("updated_at")
            if updated:
                age = int(now_epoch - calendar.timegm(_t.strptime(updated, "%Y-%m-%dT%H:%M:%SZ")))
                feed = "live" if age <= _FEED_LIVE_S else "stale"
            max_attempt = max((v.get("attempt", 1)
                               for v in (status.get("vms") or {}).values()), default=1)
        except (OSError, ValueError, KeyError):
            pass
        rows.append((d, profile, phase, feed, age, max_attempt))
        if len(rows) >= limit:
            break
    return rows

def cmd_list(args):
    import time
    rows = _list_rows(args.logs_root, args.limit, args.profile,
                      _vbox_names_fallback(None), time.time())
    if args.porcelain:
        for d, profile, phase, feed, age, max_attempt in rows:
            reprovision = f"reprovision({max_attempt})" if max_attempt > 1 else "-"
            print("\t".join([d, profile or "-", phase or "-", feed,
                             "-" if age is None else str(age), reprovision]))
        return 0
    if not rows:
        print("no build logdirs found" + (f" for profile {args.profile}" if args.profile else ""))
        return 1
    for d, profile, phase, feed, age, max_attempt in rows:
        feed_str = {"live": f"feed live ({age}s)", "stale": f"feed stale ({age}s)",
                    "none": "no feed"}[feed]
        line = (f"{os.path.basename(d):<18} profile={profile or '?':<20} "
                f"phase={phase or '-':<20} {feed_str}")
        if max_attempt > 1:
            line += f" reprovision({max_attempt})"
        print(line)
    return 0

def cmd_reset_attempts(args):
    import history, topology
    logs_root = args.logs_root
    try:
        dirs = sorted(d for d in os.listdir(logs_root)
                      if history.LOGDIR_RE.match(d)
                      and os.path.isdir(os.path.join(logs_root, d)))
    except OSError:
        dirs = []
    profile = args.profile
    if not profile and dirs:
        newest = os.path.join(logs_root, dirs[-1])
        profile = topology.infer_profile(newest, _default_profiles_dir(newest),
                                         vbox_names=_vbox_names_fallback(args.profile),
                                         now_epoch=time.time())
    if not profile:
        print("buildmon: cannot resolve a profile (pass --profile)", file=sys.stderr)
        return 2
    stamp = args.stamp or (dirs[-1] if dirs else None)
    if not stamp:
        print("buildmon: no logdir found and no --stamp given", file=sys.stderr)
        return 2
    path = history.write_reset_marker(logs_root, profile, stamp)
    print(f"reset attempts for profile '{profile}' at cutoff {stamp}\n  marker: {path}")
    return 0

def _default_profiles_dir(logdir):
    # logs/<ts> → repo vagrant/profiles
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(logdir))), "profiles")

def _make_logger(path):
    def _log(msg):
        from timefmt import iso_utc
        import time as _t
        try:
            with open(path, "a") as fh:
                fh.write(f"{iso_utc(_t.time())} {msg}\n")
        except OSError:
            pass
    return _log

def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.cmd == "collect":
        return cmd_collect(args)
    if args.cmd == "watch":
        return cmd_watch(args)
    if args.cmd == "list":
        return cmd_list(args)
    if args.cmd == "reset-attempts":
        return cmd_reset_attempts(args)
    return 2
