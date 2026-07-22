import os, sys, threading, time, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from clock import Clock  # noqa: E402
from guestpool import GuestProbePool  # noqa: E402

class _FakeProber:
    def __init__(self, result=None, block_event=None):
        self._result = result or {"reachable": True, "note": None}
        self._block = block_event
    def probe(self):
        if self._block:
            self._block.wait(timeout=2)
        return self._result

class TestGuestProbePool(unittest.TestCase):
    def test_backoff_gate(self):
        pool = GuestProbePool({"dc1": _FakeProber()}, clock=Clock(), enabled=True)
        self.assertFalse(pool.should_probe("dc1", "poweroff", False))
        self.assertFalse(pool.should_probe("dc1", "running", True))   # reboot task active
        self.assertTrue(pool.should_probe("dc1", "running", False))
        pool2 = GuestProbePool({"dc1": _FakeProber()}, clock=Clock(), enabled=False)
        self.assertFalse(pool2.should_probe("dc1", "running", False))

    def test_semaphore_caps_concurrency(self):
        import threading as _t
        peak = {"now": 0, "max": 0}
        gate = _t.Lock()
        block = _t.Event()
        class _Counting:
            def probe(self_inner):
                with gate:
                    peak["now"] += 1
                    peak["max"] = max(peak["max"], peak["now"])
                block.wait(timeout=1)
                with gate:
                    peak["now"] -= 1
                return {"reachable": True, "note": None}
        pool = GuestProbePool({f"vm{i}": _Counting() for i in range(4)},
                              clock=Clock(), period_s=0, jitter_s=0, max_concurrent=2)
        pool.start()
        try:
            time.sleep(0.5)
            block.set()
            time.sleep(0.3)
            self.assertLessEqual(peak["max"], 2)   # never more than the cap in flight
            self.assertGreaterEqual(peak["max"], 1)
        finally:
            block.set()
            pool.stop()

    def test_isolation_hung_probe_does_not_block_others(self):
        block = threading.Event()
        pool = GuestProbePool(
            {"slow": _FakeProber(block_event=block), "fast": _FakeProber({"reachable": True, "note": None})},
            clock=Clock(), period_s=0, jitter_s=0, max_concurrent=2)
        pool.start()
        try:
            deadline = time.time() + 2
            while pool.latest("fast") is None and time.time() < deadline:
                time.sleep(0.02)
            self.assertIsNotNone(pool.latest("fast"))   # fast returned while slow is blocked
        finally:
            block.set()
            pool.stop()

if __name__ == "__main__":
    unittest.main()


class TestDynamicProberRegistration(unittest.TestCase):
    def test_add_prober_enables_empty_pool_and_spawns_thread(self):
        # A pool that started with zero probers (collector attached before
        # the profile was known) must come alive when a prober is wired
        # later — previously it stayed dark for the whole run.
        from clock import Clock

        class _Stub:
            def probe(self):
                return {"reachable": True, "last_boot": None, "pending_reboot": None,
                        "cpu_pct": None, "mem_pct": None, "note": "stub"}

        pool = GuestProbePool({}, clock=Clock(), enabled=False,
                              period_s=0.01, jitter_s=0)
        pool.start()
        self.assertFalse(pool.enabled)
        self.assertFalse(pool.has("web1"))
        pool.add_prober("web1", _Stub())
        self.assertTrue(pool.enabled)
        self.assertTrue(pool.has("web1"))
        try:
            deadline = time.time() + 5
            while time.time() < deadline and pool.latest("web1") is None:
                time.sleep(0.02)
            got = pool.latest("web1")
            self.assertIsNotNone(got)
            self.assertTrue(got["reachable"])
        finally:
            pool.stop()

    def test_add_prober_idempotent(self):
        from clock import Clock
        sentinel = object()
        pool = GuestProbePool({"dc1": sentinel}, clock=Clock(), enabled=True,
                              period_s=0.01, jitter_s=0)
        pool.add_prober("dc1", object())   # must not replace
        self.assertIs(pool.probers["dc1"], sentinel)
