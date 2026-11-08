"""Pure tests of the perceptual bench metrics (_perceptual.py), no game needed.
Usage: python -I test_perceptual.py [ignored args]  (the battery passes the mcp.py path)
"""
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _perceptual as M  # noqa: E402


def walk(levels, dirs=None, key="w", dkey="d"):
    out = []
    for i, db in enumerate(levels):
        s = {key: db}
        if dirs is not None and dirs[i] is not None:
            s[dkey] = dirs[i]
        out.append(s)
    return out


def yaw(deg):
    return [math.cos(math.radians(deg)), math.sin(math.radians(deg)), 0.0]


class Angle(unittest.TestCase):
    def test_angle_between_unit_and_non_unit_vectors(self):
        self.assertAlmostEqual(M.angle_deg([1, 0, 0], [0, 2, 0]), 90.0, places=6)
        self.assertAlmostEqual(M.angle_deg([1, 0, 0], [-3, 0, 0]), 180.0, places=6)
        self.assertAlmostEqual(M.angle_deg(yaw(10), yaw(25)), 15.0, places=6)

    def test_missing_or_null_vector_has_no_angle(self):
        self.assertIsNone(M.angle_deg(None, [1, 0, 0]))
        self.assertIsNone(M.angle_deg([0, 0, 0], [1, 0, 0]))


class Percentile(unittest.TestCase):
    def test_same_convention_as_the_lua_benches(self):
        # sorted[ceil(n * q)] (1-based), as path_quality.lua's p90
        v = list(range(1, 21))  # 1..20
        self.assertEqual(M.percentile(v, 0.9), 18)
        self.assertEqual(M.percentile(v, 0.95), 19)
        self.assertEqual(M.percentile(v, 1.0), 20)
        self.assertEqual(M.percentile([5], 0.5), 5)
        self.assertIsNone(M.percentile([], 0.5))


class Steps(unittest.TestCase):
    def test_smooth_walk_has_no_step_over_the_jnd(self):
        m = M.step_metrics([walk([-30.0 - 0.3 * i for i in range(21)])])
        self.assertEqual(m["steps"], 20)
        self.assertEqual(m["over_jnd"], 0.0)
        self.assertEqual(m["walks_over"], 0.0)
        self.assertAlmostEqual(m["worst"], 0.3, places=6)

    def test_one_jump_is_counted_once_with_its_place(self):
        lv = [-30.0] * 10 + [-34.5] * 11  # one 4.5 dB step between samples 9 and 10
        m = M.step_metrics([walk([-20.0] * 21), walk(lv)])
        self.assertEqual(m["steps"], 40)
        self.assertAlmostEqual(m["over_jnd"], 1 / 40, places=3)
        self.assertAlmostEqual(m["walks_over"], 0.5, places=3)
        self.assertAlmostEqual(m["worst"], 4.5, places=6)
        self.assertEqual(m["worst_at"], [1, 9])  # walk 1, step from sample 9 to 10

    def test_a_step_of_exactly_the_jnd_is_not_over_it(self):
        m = M.step_metrics([walk([0.0, -1.0, -2.0])])
        self.assertEqual(m["over_jnd"], 0.0)
        m = M.step_metrics([walk([0.0, -1.01])])
        self.assertEqual(m["over_jnd"], 1.0)

    def test_the_jnd_is_a_parameter(self):
        m = M.step_metrics([walk([0.0, -2.0, -2.5])], jnd=3.0)
        self.assertEqual(m["over_jnd"], 0.0)

    def test_cold_levels_are_read_with_their_key(self):
        m = M.step_metrics([walk([0.0, -5.0], key="c")], key="c")
        self.assertAlmostEqual(m["worst"], 5.0, places=6)

    def test_direction_jumps(self):
        dirs = [yaw(0), yaw(2), yaw(4), yaw(100), yaw(102)]
        m = M.step_metrics([walk([-30.0] * 5, dirs)], dir_deg=15.0)
        self.assertEqual(m["dir_steps"], 4)
        self.assertAlmostEqual(m["dir_worst"], 96.0, places=4)
        self.assertAlmostEqual(m["dir_over"], 0.25, places=3)
        self.assertEqual(m["dir_worst_at"], [0, 2])

    def test_steps_without_a_direction_are_left_out_of_the_direction_metrics(self):
        dirs = [yaw(0), None, yaw(90), yaw(91)]
        m = M.step_metrics([walk([-30.0] * 4, dirs)])
        self.assertEqual(m["dir_steps"], 1)
        self.assertAlmostEqual(m["dir_worst"], 1.0, places=4)

    def test_stable_direction_key(self):
        m = M.step_metrics([walk([-30.0] * 2, [yaw(0), yaw(40)], dkey="s")], dir_key="s")
        self.assertAlmostEqual(m["dir_worst"], 40.0, places=4)

    def test_no_walk_gives_no_metric(self):
        self.assertEqual(M.step_metrics([])["steps"], 0)
        self.assertEqual(M.step_metrics([walk([-30.0])])["steps"], 0)


class Reciprocity(unittest.TestCase):
    def test_shares_and_worst(self):
        pairs = [(-30.0, -30.2), (-40.0, -41.5), (-50.0, -46.0), (-20.0, -20.0)]
        m = M.reciprocity_metrics(pairs)
        self.assertEqual(m["n"], 4)
        self.assertAlmostEqual(m["over_jnd"], 0.5, places=3)
        self.assertAlmostEqual(m["over3"], 0.25, places=3)
        self.assertAlmostEqual(m["worst"], 4.0, places=6)
        self.assertEqual(m["worst_at"], 2)
        self.assertAlmostEqual(m["median"], 0.2, places=6)
        self.assertAlmostEqual(m["p90"], 4.0, places=6)

    def test_empty(self):
        self.assertEqual(M.reciprocity_metrics([])["n"], 0)


class Check(unittest.TestCase):
    def test_none_limits_report_only(self):
        metrics = {"warm": {"steps": 10, "over_jnd": 0.5}}
        self.assertEqual(M.check(metrics, {("warm", "over_jnd"): None}), [])

    def test_a_limit_fails_above_and_passes_at_it(self):
        metrics = {"warm": {"steps": 10, "over_jnd": 0.5, "worst": 3.0}}
        self.assertEqual(M.check(metrics, {("warm", "over_jnd"): 0.5}), [])
        fails = M.check(metrics, {("warm", "over_jnd"): 0.4, ("warm", "worst"): 3.0})
        self.assertEqual(len(fails), 1)
        self.assertIn("over_jnd", fails[0])

    def test_a_limit_on_a_missing_metric_fails(self):
        fails = M.check({"warm": {"steps": 0}}, {("warm", "over_jnd"): 0.1})
        self.assertEqual(len(fails), 1)


if __name__ == "__main__":
    r = unittest.main(argv=[sys.argv[0]], exit=False, verbosity=1).result
    print("PASS" if r.wasSuccessful() else "FAIL")
    sys.exit(0 if r.wasSuccessful() else 1)
