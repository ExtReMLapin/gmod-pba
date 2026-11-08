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


def job_result():
    """A raw result as path_perceptual.lua returns it: 2 source walks (one with a lost measure), 1
    listener walk, 3 reciprocity pairs (one lost)."""
    def smp(c, w, d, s=None, err=False):
        x = {"c": c, "w": w, "d": d, "s": s or d, "k": "portal"}
        if err:
            x["err"] = True
        return x
    return {
        "pairs": 3, "seconds": 12, "skipped": {"visible": 4, "nowalkS": 1, "nowalkL": 2},
        "walksS": [
            {"S": "0 0 12", "L": "500 0 12", "dir": "1 0 0", "s": [
                smp(-30, -30, yaw(0)), smp(-31, -30.5, yaw(1)), smp(-36, -33.5, yaw(60), yaw(2))]},
            {"S": "9 9 9", "L": "1 1 1", "dir": "0 1 0", "s": [smp(-20, -20, yaw(0)), smp(-240, -240, None, err=True)]},
        ],
        "walksL": [
            {"S": "0 0 12", "L": "500 0 12", "dir": "0 1 0", "s": [smp(-40, -40, yaw(0)), smp(-40.2, -40.1, yaw(3))]},
        ],
        "recip": [
            {"S": "a", "L": "b", "ab": smp(-30, -30, yaw(0)), "ba": smp(-33, -31.5, yaw(0))},
            {"S": "c", "L": "d", "ab": smp(-30, -30, yaw(0)), "ba": smp(-30, -30.5, yaw(0))},
            {"S": "e", "L": "f", "ab": smp(-30, -30, yaw(0)), "ba": smp(-240, -240, None, err=True)},
        ],
    }


class Summarize(unittest.TestCase):
    def test_groups_from_a_raw_job_result(self):
        out, rec = M.summarize(job_result())
        self.assertEqual(out["S_walks"], 1)  # the walk with a lost measure is dropped
        self.assertEqual(out["L_walks"], 1)
        self.assertEqual(out["errors"], 2)
        self.assertEqual(out["S_warm"]["steps"], 2)
        self.assertAlmostEqual(out["S_warm"]["worst"], 3.0, places=6)  # -30.5 -> -33.5
        self.assertAlmostEqual(out["S_cold"]["worst"], 5.0, places=6)  # -31 -> -36
        self.assertAlmostEqual(out["S_warm"]["dir_worst"], 59.0, places=4)  # raw dominant voice
        self.assertAlmostEqual(out["S_stable"]["dir_worst"], 1.0, places=4)  # through P.Stable
        self.assertNotIn("worst", out["S_stable"])  # direction only
        self.assertEqual(out["recip_warm"]["n"], 2)
        self.assertAlmostEqual(out["recip_warm"]["worst"], 1.5, places=6)
        self.assertAlmostEqual(out["recip_cold"]["worst"], 3.0, places=6)
        self.assertEqual(len(rec), 2)

    def test_details_point_at_the_worst_places(self):
        v = job_result()
        out, rec = M.summarize(v)
        d = M.details(v, out, rec)
        self.assertEqual(d["S_level"]["step"], 1)
        self.assertEqual(d["S_level"]["to"]["w"], -33.5)
        self.assertEqual(d["S_dir"]["step"], 0)  # stable direction: 1 degree, first step
        self.assertEqual(d["recip"]["S"], "a")


if __name__ == "__main__":
    r = unittest.main(argv=[sys.argv[0]], exit=False, verbosity=1).result
    print("PASS" if r.wasSuccessful() else "FAIL")
    sys.exit(0 if r.wasSuccessful() else 1)
