import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from timefmt import iso_utc, parse_iso, dur_s  # noqa: E402

class TestTimefmt(unittest.TestCase):
    def test_iso_utc_is_z_suffixed(self):
        # 2026-07-01T20:29:47Z  == epoch 1782937787
        self.assertEqual(iso_utc(1782937787), "2026-07-01T20:29:47Z")

    def test_roundtrip(self):
        self.assertAlmostEqual(parse_iso("2026-07-01T20:29:47Z"), 1782937787.0, places=3)

    def test_dur_s_is_nonnegative_int(self):
        self.assertEqual(dur_s(100.0, 107.9), 7)
        self.assertEqual(dur_s(200.0, 100.0), 0)  # clamped, never negative

if __name__ == "__main__":
    unittest.main()
