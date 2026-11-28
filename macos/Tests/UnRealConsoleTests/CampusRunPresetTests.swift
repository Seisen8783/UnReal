import XCTest
@testable import UnRealConsole

/// 校园跑预设：数值与效果都要锁住。
///
/// 预设里的偏移值来自 `tools/fence_check.py` 的围栏预检，
/// 一旦有人改了内置轨迹或围栏数据，这里的断言会先失败。
final class CampusRunPresetTests: XCTestCase {
    /// 服务端围栏（GCJ-02），与 `core/assets/campus-fence.json` 一致。
    private let fence = (west: 117.989623, east: 117.991280,
                         south: 37.387973, north: 37.389754)

    /// 实测可达区（GCJ-02），用户现场跑出的极限。
    private let reachable = (west: 117.990000, east: 117.991111,
                             south: 37.388056, north: 37.389722)

    private func bundledTrack() throws -> TrackRoute {
        // #filePath → 文件 → UnRealConsoleTests → Tests → macos → 仓库根
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repo = repo.deletingLastPathComponent() }
        let url = repo.appendingPathComponent(
            "macos/Sources/UnRealConsole/Resources/default-track.kmz")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "内置轨迹不在本机，跳过。")
        return try KMLRoute.load(url)
    }

    /// 上报值 = 微信对注入值做的那一次 WGS-84 → GCJ-02 转换。
    private func reportedPoints(_ points: [TrackPoint]) -> [(Double, Double)] {
        points.map {
            let gcj = CoordinateTransform.wgs84ToGCJ02(longitude: $0.longitude,
                                                        latitude: $0.latitude)
            return (gcj.0, gcj.1)
        }
    }

    /// 点集到矩形四边的最小余量（米）。
    private func minimumMargin(_ points: [(Double, Double)],
                                box: (west: Double, east: Double,
                                       south: Double, north: Double)) -> Double {
        let latitude = (box.south + box.north) / 2
        let longitudeScale = 111_320.0 * cos(latitude * .pi / 180)
        return points.map { longitude, latitude in
            let west = (longitude - box.west) * longitudeScale
            let east = (box.east - longitude) * longitudeScale
            let south = (latitude - box.south) * 111_320.0
            let north = (box.north - latitude) * 111_320.0
            return min(west, east, south, north)
        }.min() ?? -.greatestFiniteMagnitude
    }

    func testPresetValuesAreLocked() {
        XCTAssertEqual(CampusRunPreset.eastMeters, -17.2, accuracy: 0.01)
        XCTAssertEqual(CampusRunPreset.northMeters, -11.5, accuracy: 0.01)
        XCTAssertEqual(ReplayPace.parse(CampusRunPreset.pace), 420)
        XCTAssertEqual(CampusRunPreset.kilometers, "1.50")
    }

    /// 预设配速必须落在「正常跑步」区间：不快到非人类，也不慢到像走路。
    func testPresetPaceIsPlausible() {
        let seconds = ReplayPace.parse(CampusRunPreset.pace) ?? 0
        XCTAssertGreaterThan(seconds, 240, "快于 4'00\" / 公里会被显示成非人类配速")
        XCTAssertLessThan(seconds, 540, "慢于 9'00\" / 公里可能被判无效")
    }

    /// 套用预设后：全程在围栏内、余量够、且每圈长度不变。
    func testPresetKeepsTrackInsideFenceWithMargin() throws {
        let route = try bundledTrack()
        let offset = CalibrationOffset(eastMeters: CampusRunPreset.eastMeters,
                                       northMeters: CampusRunPreset.northMeters)
        let moved = offset.apply(to: route.points)
        let reported = reportedPoints(moved)

        let margin = minimumMargin(reported, box: fence)
        XCTAssertGreaterThanOrEqual(margin, 10.0,
                                    "预设偏移后围栏余量应至少 10 m，实际 \(margin) m")
        XCTAssertEqual(TrackMetrics.length(route.points), TrackMetrics.length(moved),
                       accuracy: 0.01, "平移不应改变每圈长度")
    }

    /// 套用预设后，轨迹也应当落进用户实测能站到的范围。
    func testPresetAlsoFitsMeasuredReachableArea() throws {
        let route = try bundledTrack()
        let offset = CalibrationOffset(eastMeters: CampusRunPreset.eastMeters,
                                       northMeters: CampusRunPreset.northMeters)
        let reported = reportedPoints(offset.apply(to: route.points))
        XCTAssertGreaterThan(minimumMargin(reported, box: reachable), 0,
                             "预设偏移后不应再有轨迹点落在实测可达区之外")
    }

    /// 不套预设时余量薄到近乎贴边——这正是预设存在的理由。
    func testWithoutPresetMarginIsTight() throws {
        let route = try bundledTrack()
        let margin = minimumMargin(reportedPoints(route.points), box: fence)
        XCTAssertLessThan(margin, 1.0, "内置轨迹原本的北侧余量应当极小，实际 \(margin) m")
    }
}
