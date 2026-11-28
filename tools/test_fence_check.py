#!/usr/bin/env python3
"""围栏预检工具的单元测试。

跑法：
    python3 -m unittest discover -s tools -v

其中一条测试锁定内置校园轨迹与围栏的当前关系——它同时是一份「资产漂移」警报：
内置轨迹或围栏数据一旦被改动，这条测试会先失败，提示重新评估余量。
"""

import json
import math
import unittest
from pathlib import Path

import fence_check

REPO_ROOT = Path(__file__).resolve().parent.parent
FENCE_FILE = REPO_ROOT / "core" / "assets" / "campus-fence.json"
CAMPUS_TRACK = REPO_ROOT / "core" / "assets" / "campus.geojson"


def load_fence():
    return json.loads(FENCE_FILE.read_text(encoding="utf-8"))


class TransformTests(unittest.TestCase):
    def test_wgs84_gcj02_roundtrip(self):
        original = (117.984324, 37.387542)
        lng, lat = fence_check.wgs84_to_gcj02(*original)
        back = fence_check.gcj02_to_wgs84(lng, lat)
        self.assertLess(fence_check.haversine(original, back), 0.01)

    def test_gcj02_offset_is_hundreds_of_meters_in_binzhou(self):
        wgs = (117.984324, 37.387542)
        gcj = fence_check.wgs84_to_gcj02(*wgs)
        distance = fence_check.haversine(wgs, gcj)
        self.assertGreater(distance, 450)
        self.assertLess(distance, 600)

    def test_bd09_chain(self):
        def gcj_to_bd(lng, lat):
            x_pi = math.pi * 3000.0 / 180.0
            z = math.sqrt(lng * lng + lat * lat) + 0.00002 * math.sin(lat * x_pi)
            theta = math.atan2(lat, lng) + 0.000003 * math.cos(lng * x_pi)
            return z * math.cos(theta) + 0.0065, z * math.sin(theta) + 0.006

        gcj = (117.990000, 37.388000)
        back = fence_check.bd09_to_gcj02(*gcj_to_bd(*gcj))
        self.assertLess(fence_check.haversine(gcj, back), 0.05)
        wgs = fence_check.bd09_to_wgs84(*gcj_to_bd(*gcj))
        expected = fence_check.gcj02_to_wgs84(*gcj)
        self.assertLess(fence_check.haversine(wgs, expected), 1.0)


class CalibrationTests(unittest.TestCase):
    def test_east_offset_shifts_longitude_by_meters(self):
        points = [(117.984324, 37.387542)]
        moved = fence_check.apply_calibration(points, 100.0, 0.0)
        # 控制台用的是 111,195 的纬度比例尺，这里按同一套公式反算。
        scale = fence_check.LAT_SCALE * math.cos(math.radians(points[0][1]))
        delta = (moved[0][0] - points[0][0]) * scale
        self.assertAlmostEqual(delta, 100.0, delta=0.1)

    def test_north_offset_shifts_latitude_by_meters(self):
        points = [(117.984324, 37.387542)]
        moved = fence_check.apply_calibration(points, 0.0, -50.0)
        delta = (moved[0][1] - points[0][1]) * 111_320.0
        self.assertAlmostEqual(delta, -50.0, delta=0.1)

    def test_zero_offset_is_identity(self):
        points = [(117.984324, 37.387542)]
        self.assertEqual(fence_check.apply_calibration(points, 0.0, 0.0), points)


class FenceJudgementTests(unittest.TestCase):
    def test_point_outside_is_counted(self):
        box = load_fence()["fence"]
        inside = (117.990000, 37.388500)
        outside = (117.980000, 37.388500)
        result = fence_check.check_box([inside, outside], box)
        self.assertEqual(result["outside"], 1)
        self.assertEqual(result["inside"], 1)
        self.assertLess(result["minMargin"], 0)

    def test_shrink_moves_points_inward(self):
        points = [(117.990000, 37.388000), (117.991000, 37.389000), (117.990500, 37.388500)]
        shrunk = fence_check.shrink(points, 10.0)
        lat_ref = 37.388500
        lon_scale = fence_check.meters_per_degree_longitude(lat_ref)
        cx = sum(p[0] for p in points) / len(points)
        cy = sum(p[1] for p in points) / len(points)

        def radius(point):
            return math.hypot((point[0] - cx) * lon_scale, (point[1] - cy) * 111_320.0)

        self.assertLess(radius(shrunk[0]), radius(points[0]))


class CampusTrackTests(unittest.TestCase):
    """锁定内置轨迹与围栏的当前关系。"""

    def setUp(self):
        self.fence = load_fence()
        self.points = fence_check.read_track(CAMPUS_TRACK)
        self.reported = [fence_check.wgs84_to_gcj02(lng, lat) for lng, lat in self.points]

    def test_track_has_644_points(self):
        self.assertEqual(len(self.points), 644)

    def test_track_stays_inside_fence_but_with_tight_margin(self):
        result = fence_check.check_box(self.reported, self.fence["fence"])
        self.assertEqual(result["outside"], 0, "内置轨迹不该有出界点")
        # 当前北侧余量只有 0.38 m：这是待办，不是可以长期维持的状态。
        self.assertLess(result["minMargin"], 1.0)
        self.assertEqual(result["worstEdge"], "north")

    def test_pulled_back_datum_puts_whole_track_outside(self):
        result = fence_check.check_box(self.points, self.fence["fence"])
        self.assertEqual(result["outside"], len(self.points),
                         "回退一个基准时整条轨迹都应在围栏外")

    def test_track_reaches_beyond_measured_reachable_box(self):
        result = fence_check.check_box(self.reported, self.fence["reachable"])
        self.assertGreater(result["outside"], 0)


if __name__ == "__main__":
    unittest.main()
