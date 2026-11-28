#!/usr/bin/env python3
"""校园跑围栏预检工具。

回答一个问题：**这条轨迹回放出去，会不会在操场上被判「非校园区域」？**

判定链有三个环节，工具按同样顺序逐段核对：

1. 基准：轨迹文件是 WGS-84 / GCJ-02 / BD-09，归一化到设备要的 WGS-84；
2. 标定偏移：按米（东/北）平移，与控制台里的「标定偏移」完全一致；
3. 上报口径：小程序默认 gcj02，会把设备交付的 WGS-84 转成 GCJ-02 再上报。
   服务端围栏也是 GCJ-02，所以：
     - 「原样」     → 上报值 = GCJ-02(注入值)，与围栏同基准
     - 「回退一个基准」→ 上报值 = 注入值本身，与围栏差一个基准偏移（滨州一带约 525 m）
   两种口径都算一遍，避免选错口径后一路被判非校园区域。

用法：
    python3 tools/fence_check.py core/assets/campus.geojson
    python3 tools/fence_check.py 我的轨迹.kmz --datum gcj02 --calibration -17,-3
    python3 tools/fence_check.py 我的轨迹.kmz --target-margin 10 --json

退出码：
    0  全程在围栏内，且最小余量达标
    1  有轨迹点落在围栏外
    2  没出围栏，但余量不足（建议调整偏移或收缩轨迹）
"""

import argparse
import json
import math
import re
import sys
import zipfile
from pathlib import Path

PI = math.pi
A = 6378245.0
EE = 0.00669342162296594323

LAT_SCALE = 111_195.0
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FENCE = REPO_ROOT / "core" / "assets" / "campus-fence.json"


# ---------------------------------------------------------------- 坐标基准

def _out_of_china(lng, lat):
    return not (72.004 <= lng <= 137.8347 and 0.8293 <= lat <= 55.8271)


def _t_lat(x, y):
    r = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
    r += (20.0 * math.sin(6.0 * x * PI) + 20.0 * math.sin(2.0 * x * PI)) * 2.0 / 3.0
    r += (20.0 * math.sin(y * PI) + 40.0 * math.sin(y / 3.0 * PI)) * 2.0 / 3.0
    r += (160.0 * math.sin(y / 12.0 * PI) + 320 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0
    return r


def _t_lng(x, y):
    r = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(abs(x))
    r += (20.0 * math.sin(6.0 * x * PI) + 20.0 * math.sin(2.0 * x * PI)) * 2.0 / 3.0
    r += (20.0 * math.sin(x * PI) + 40.0 * math.sin(x / 3.0 * PI)) * 2.0 / 3.0
    r += (150.0 * math.sin(x / 12.0 * PI) + 300.0 * math.sin(x / 30.0 * PI)) * 2.0 / 3.0
    return r


def wgs84_to_gcj02(lng, lat):
    if _out_of_china(lng, lat):
        return lng, lat
    d_lat = _t_lat(lng - 105.0, lat - 35.0)
    d_lng = _t_lng(lng - 105.0, lat - 35.0)
    rad = lat / 180.0 * PI
    magic = 1 - EE * math.sin(rad) ** 2
    sqrt_magic = math.sqrt(magic)
    d_lat = (d_lat * 180.0) / ((A * (1 - EE)) / (magic * sqrt_magic) * PI)
    d_lng = (d_lng * 180.0) / (A / sqrt_magic * math.cos(rad) * PI)
    return lng + d_lng, lat + d_lat


def gcj02_to_wgs84(lng, lat):
    if _out_of_china(lng, lat):
        return lng, lat
    guess_lng, guess_lat = lng, lat
    for _ in range(12):
        shifted = wgs84_to_gcj02(guess_lng, guess_lat)
        error_lng = lng - shifted[0]
        error_lat = lat - shifted[1]
        guess_lng += error_lng
        guess_lat += error_lat
        if abs(error_lng) < 1e-9 and abs(error_lat) < 1e-9:
            break
    return guess_lng, guess_lat


def bd09_to_gcj02(lng, lat):
    x_pi = PI * 3000.0 / 180.0
    x, y = lng - 0.0065, lat - 0.006
    z = math.sqrt(x * x + y * y) - 0.00002 * math.sin(y * x_pi)
    theta = math.atan2(y, x) - 0.000003 * math.cos(x * x_pi)
    return z * math.cos(theta), z * math.sin(theta)


def bd09_to_wgs84(lng, lat):
    gcj = bd09_to_gcj02(lng, lat)
    return gcj02_to_wgs84(gcj[0], gcj[1])


def normalize(points, datum):
    """把轨迹归一化到 WGS-84（设备交付的目标基准）。"""
    if datum == "wgs84":
        return list(points)
    if datum == "gcj02":
        return [gcj02_to_wgs84(lng, lat) for lng, lat in points]
    if datum == "bd09":
        return [bd09_to_wgs84(lng, lat) for lng, lat in points]
    raise ValueError(f"未知坐标基准：{datum}")


def apply_calibration(points, east_meters, north_meters):
    """按米平移，与控制台的「标定偏移」同一套公式。"""
    if abs(east_meters) < 0.5 and abs(north_meters) < 0.5:
        return list(points)
    result = []
    for lng, lat in points:
        lon_scale = LAT_SCALE * math.cos(lat * PI / 180.0)
        if lon_scale <= 1:
            result.append((lng, lat))
            continue
        result.append((lng + east_meters / lon_scale, lat + north_meters / LAT_SCALE))
    return result


# ---------------------------------------------------------------- 轨迹读取

def _read_kmz(path):
    with zipfile.ZipFile(path) as archive:
        names = [n for n in archive.namelist() if n.lower().endswith(".kml")]
        if not names:
            raise ValueError("KMZ 里没有 KML")
        text = archive.read(names[0]).decode("utf-8", "ignore")
    return _read_kml_text(text)


def _read_kml_text(text):
    points = []
    for block in re.findall(r"<coordinates>([^<]+)</coordinates>", text):
        for match in re.findall(r"([-\d.]+),([-\d.]+)(?:,[-\d.]+)?", block):
            points.append((float(match[0]), float(match[1])))
    return points


def _read_gpx(path):
    text = Path(path).read_text(encoding="utf-8", errors="ignore")
    points = []
    for tag in re.finditer(r"<(?:trkpt|rtept|wpt)\b[^>]*?lat=\"([-\d.]+)\"[^>]*?lon=\"([-\d.]+)\"", text):
        points.append((float(tag.group(2)), float(tag.group(1))))
    return points


def _read_geojson(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    points = []
    features = data.get("features") if isinstance(data, dict) else None
    if features is None:
        features = [{"geometry": data}]
    for feature in features:
        geometry = feature.get("geometry", {})
        kind = geometry.get("type")
        coordinates = geometry.get("coordinates", [])
        if kind == "Point":
            coordinates = [coordinates]
        for pair in coordinates:
            points.append((float(pair[0]), float(pair[1])))
    return points


def read_track(path):
    suffix = Path(path).suffix.lower()
    if suffix == ".kmz":
        return _read_kmz(path)
    if suffix == ".kml":
        return _read_kml_text(Path(path).read_text(encoding="utf-8", errors="ignore"))
    if suffix == ".gpx":
        return _read_gpx(path)
    if suffix in (".geojson", ".json"):
        return _read_geojson(path)
    raise ValueError(f"不支持的轨迹格式：{suffix}")


# ---------------------------------------------------------------- 几何判定

def haversine(a, b):
    radius = 6_371_008.8
    rad = PI / 180.0
    s1 = math.sin((b[1] - a[1]) * rad / 2)
    s2 = math.sin((b[0] - a[0]) * rad / 2)
    h = s1 * s1 + math.cos(a[1] * rad) * math.cos(b[1] * rad) * s2 * s2
    return 2 * radius * math.asin(math.sqrt(min(1.0, max(0.0, h))))


def path_length(points):
    return sum(haversine(points[i - 1], points[i]) for i in range(1, len(points)))


def bbox(points):
    lons = [p[0] for p in points]
    lats = [p[1] for p in points]
    return {
        "minLongitude": min(lons), "maxLongitude": max(lons),
        "minLatitude": min(lats), "maxLatitude": max(lats),
    }


def meters_per_degree_longitude(latitude):
    return 111_320.0 * math.cos(math.radians(latitude))


def margins(points, box):
    """每个点到矩形四边的余量（米）。正值在框内。"""
    lat_ref = (box["minLatitude"] + box["maxLatitude"]) / 2
    lon_scale = meters_per_degree_longitude(lat_ref)
    west, east = [], []
    south, north = [], []
    for lng, lat in points:
        west.append((lng - box["minLongitude"]) * lon_scale)
        east.append((box["maxLongitude"] - lng) * lon_scale)
        south.append((lat - box["minLatitude"]) * 111_320.0)
        north.append((box["maxLatitude"] - lat) * 111_320.0)
    return {"west": west, "east": east, "south": south, "north": north}


def check_box(points, box):
    """返回该轨迹相对矩形框的判定结果。"""
    edge = margins(points, box)
    worst = {name: min(values) for name, values in edge.items()}
    outside = sum(1 for i in range(len(points))
                  if edge["west"][i] < 0 or edge["east"][i] < 0
                  or edge["south"][i] < 0 or edge["north"][i] < 0)
    inside = len(points) - outside
    return {
        "minMargin": round(min(worst.values()), 2),
        "worstEdge": min(worst, key=lambda k: worst[k]),
        "margins": {k: round(v, 1) for k, v in worst.items()},
        "outside": outside,
        "inside": inside,
        "total": len(points),
        "withinTarget": sum(1 for i in range(len(points))
                            if min(edge[k][i] for k in edge) >= 0),
    }


def shrink(points, meters):
    """把轨迹朝质心收缩 meters 米（各点沿质心方向等比内移）。"""
    if meters <= 0:
        return list(points)
    lat_ref = sum(p[1] for p in points) / len(points)
    lon_scale = meters_per_degree_longitude(lat_ref)
    cx = sum(p[0] for p in points) / len(points)
    cy = sum(p[1] for p in points) / len(points)
    result = []
    for lng, lat in points:
        dx = (lng - cx) * lon_scale
        dy = (lat - cy) * 111_320.0
        distance = math.hypot(dx, dy)
        if distance <= meters:
            result.append((lng, lat))
            continue
        ratio = 1 - meters / distance
        result.append((cx + dx * ratio / lon_scale, cy + dy * ratio / 111_320.0))
    return result


def center_offset(points, box):
    """把轨迹平移到矩形框中心所需的标定偏移（东/北，米）。"""
    lat_ref = sum(p[1] for p in points) / len(points)
    lon_scale = meters_per_degree_longitude(lat_ref)
    track = bbox(points)
    box_lon = (box["minLongitude"] + box["maxLongitude"]) / 2
    box_lat = (box["minLatitude"] + box["maxLatitude"]) / 2
    track_lon = (track["minLongitude"] + track["maxLongitude"]) / 2
    track_lat = (track["minLatitude"] + track["maxLatitude"]) / 2
    return round((box_lon - track_lon) * lon_scale, 1), round((box_lat - track_lat) * 111_320.0, 1)


# ---------------------------------------------------------------- 输出

def format_box(box):
    return (f"经度 {box['minLongitude']:.6f}..{box['maxLongitude']:.6f}  "
            f"纬度 {box['minLatitude']:.6f}..{box['maxLatitude']:.6f}")


def main():
    parser = argparse.ArgumentParser(description="校园跑围栏预检")
    parser.add_argument("track", help="轨迹文件（KMZ / KML / GPX / GeoJSON）")
    parser.add_argument("--datum", default="wgs84", choices=("wgs84", "gcj02", "bd09"),
                        help="轨迹文件用的坐标基准，默认 wgs84")
    parser.add_argument("--calibration", default="0,0",
                        help="标定偏移「东,北」米，默认 0,0")
    parser.add_argument("--fence", default=str(DEFAULT_FENCE), help="围栏数据文件")
    parser.add_argument("--target-margin", type=float, default=5.0,
                        help="要求的最小余量（米），默认 5")
    parser.add_argument("--json", action="store_true", help="只输出 JSON")
    args = parser.parse_args()

    try:
        east, north = (float(v) for v in args.calibration.split(","))
    except ValueError:
        print("标定偏移格式应为「东,北」，例如 -17,-3", file=sys.stderr)
        return 1

    fence_data = json.loads(Path(args.fence).read_text(encoding="utf-8"))
    fence_box = fence_data["fence"]
    reachable_box = fence_data.get("reachable")

    raw = read_track(args.track)
    if len(raw) < 2:
        print("轨迹点少于 2 个，无法判定", file=sys.stderr)
        return 1

    injected = apply_calibration(normalize(raw, args.datum), east, north)

    # 上报口径一：原样 —— 微信把 WGS-84 转成 GCJ-02 后上报
    reported_as_is = [wgs84_to_gcj02(lng, lat) for lng, lat in injected]
    # 上报口径二：回退一个基准 —— 上报值就是注入值本身
    reported_pulled_back = injected

    as_is = check_box(reported_as_is, fence_box)
    pulled_back = check_box(reported_pulled_back, fence_box)
    reachable = check_box(reported_as_is, reachable_box) if reachable_box else None

    track_box = bbox(reported_as_is)
    length = path_length(reported_as_is)

    suggestions = {}
    if as_is["minMargin"] < args.target_margin:
        suggestion_meters = max(0.0, args.target_margin - as_is["minMargin"]) + 1.0
        shrunk = shrink(reported_as_is, suggestion_meters)
        shrunk_check = check_box(shrunk, fence_box)
        offset_east, offset_north = center_offset(reported_as_is, fence_box)
        suggestions = {
            "shrinkMeters": round(suggestion_meters, 1),
            "shrinkResult": {
                "minMargin": shrunk_check["minMargin"],
                "lengthMeters": round(path_length(shrunk), 1),
                "outside": shrunk_check["outside"],
            },
            "centerOffset": {"eastMeters": offset_east, "northMeters": offset_north},
        }

    report = {
        "track": str(args.track),
        "datum": args.datum,
        "calibration": {"eastMeters": east, "northMeters": north},
        "points": len(raw),
        "lengthMeters": round(length, 1),
        "reportedBoxGCJ02": track_box,
        "asIs": as_is,
        "pulledBackOneDatum": pulled_back,
        "reachable": reachable,
        "targetMargin": args.target_margin,
        "suggestions": suggestions,
    }

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"轨迹：{args.track}")
        print(f"基准 {args.datum} → 归一化 WGS-84 → 标定偏移 东 {east} m / 北 {north} m")
        print(f"点数 {len(raw)} · 总长 {length:.1f} m · 上报值包围盒 {format_box(track_box)}")
        print()
        print(f"【上报口径：原样】上报值 = GCJ-02(注入值)，与服务端围栏同基准")
        print(f"  服务端围栏 {format_box(fence_box)}")
        print(f"  四边最小余量：西 {as_is['margins']['west']} ｜ 东 {as_is['margins']['east']} ｜ "
              f"南 {as_is['margins']['south']} ｜ 北 {as_is['margins']['north']} m")
        print(f"  最小余量 {as_is['minMargin']} m（{as_is['worstEdge']} 侧）· "
              f"落在围栏外 {as_is['outside']} 点 / {as_is['total']} 点")
        print()
        print(f"【上报口径：回退一个基准】上报值 = 注入值本身，与围栏差一个基准偏移")
        print(f"  最小余量 {pulled_back['minMargin']} m · 落在围栏外 {pulled_back['outside']} 点")
        if pulled_back["outside"]:
            print("  → 这个口径下整条轨迹都在围栏外，必然被判「非校园区域」。校园跑请用「原样」。")
        if reachable:
            print()
            print(f"【实测可达区（用户现场跑出的极限）】{format_box(reachable_box)}")
            print(f"  最小余量 {reachable['minMargin']} m · 落在区外 {reachable['outside']} 点")
            print("  → 落在区外不是错误：模拟位置不必等于人身位置，但手机放哪要考虑这一点。")
        print()
        if as_is["outside"]:
            print("✗ 有轨迹点落在围栏外 —— 这部分会被判「非校园区域」。")
        elif as_is["minMargin"] < args.target_margin:
            print(f"✗ 余量不足：要求 {args.target_margin} m，实际 {as_is['minMargin']} m。"
                  f"围栏是反推值，残差 ±7 m，随时可能被判「非校园区域」。")
            if suggestions:
                print(f"  → 建议一：标定偏移 设为 东 {suggestions['centerOffset']['eastMeters']} m / "
                      f"北 {suggestions['centerOffset']['northMeters']} m（把轨迹挪到围栏中心）")
                print(f"  → 建议二：轨迹向内收缩 {suggestions['shrinkMeters']} m，"
                      f"余量变 {suggestions['shrinkResult']['minMargin']} m，"
                      f"总长 {suggestions['shrinkResult']['lengthMeters']} m")
        else:
            print(f"✓ 全程在围栏内，最小余量 {as_is['minMargin']} m（要求 {args.target_margin} m）。")

    if as_is["outside"]:
        return 1
    if as_is["minMargin"] < args.target_margin:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
