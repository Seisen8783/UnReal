import Foundation

/// 坐标基准。
///
/// iOS 的 `LocationSimulation` 与 CoreLocation 交付的都是 **WGS-84**，
/// 微信小程序 `wx.getLocation` 在此基础上再转一次 GCJ-02。
/// 所以注入设备的目标基准永远是 WGS-84；轨迹文件本身的基准则可能不是。
public enum CoordinateSystem: String, CaseIterable, Identifiable, Sendable {
    /// 轨迹文件已是 WGS-84（GPS 导出、OSM 导出）。直接使用。
    case wgs84
    /// 轨迹文件是 GCJ-02（腾讯/高德地图描点、国产地图导出）。
    /// 国内需要转成 WGS-84 才能正确注入。
    case gcj02
    /// 轨迹文件是 BD-09（百度地图）。
    case bd09

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wgs84: return "WGS-84（GPS / OSM 导出）"
        case .gcj02: return "GCJ-02（腾讯 / 高德地图）"
        case .bd09: return "BD-09（百度地图）"
        }
    }

    public var shortName: String {
        switch self {
        case .wgs84: return "WGS-84"
        case .gcj02: return "GCJ-02"
        case .bd09: return "BD-09"
        }
    }

    /// 把本基准的坐标归一化到 WGS-84（注入设备的目标基准）。
    public func normalized(_ point: TrackPoint) -> TrackPoint {
        switch self {
        case .wgs84:
            return point
        case .gcj02:
            let (lon, lat) = CoordinateTransform.gcj02ToWGS84(longitude: point.longitude,
                                                               latitude: point.latitude)
            return TrackPoint(latitude: lat, longitude: lon, offset: point.offset)
        case .bd09:
            let (lon, lat) = CoordinateTransform.bd09ToWGS84(longitude: point.longitude,
                                                               latitude: point.latitude)
            return TrackPoint(latitude: lat, longitude: lon, offset: point.offset)
        }
    }

    public func normalized(_ points: [TrackPoint]) -> [TrackPoint] {
        points.map { normalized($0) }
    }

    /// 归一化整条路线（含未计时分段）。
    public func normalized(route: TrackRoute) -> TrackRoute {
        let normalizedPoints: [TrackPoint] = normalized(route.points)
        let normalizedSegments: [[TrackPoint]]? = route.untimedSegments.map { segments in
            segments.map { segment -> [TrackPoint] in normalized(segment) }
        }
        return TrackRoute(name: route.name,
                          points: normalizedPoints,
                          segmentStarts: route.segmentStarts,
                          timingIssue: route.timingIssue,
                          untimedSegments: normalizedSegments)
    }
}

/// WGS-84 / GCJ-02 / BD-09 之间的坐标转换。
///
/// 算法为公开的国测局偏移公式，不含任何加密或授权逻辑；
/// GCJ-02 反解 WGS-84 用迭代逼近，误差在厘米级。
public enum CoordinateTransform {
    private static let semiMajorAxis = 6378245.0
    private static let eccentricitySquared = 0.00669342162296594323
    private static let pi = Double.pi

    /// 该点是否落在中国境外。境外不做偏移，否则会越偏越远。
    public static func isOutsideChina(longitude: Double, latitude: Double) -> Bool {
        !(72.004...137.8347).contains(longitude) || !(0.8293...55.8271).contains(latitude)
    }

    // MARK: - WGS-84 → GCJ-02

    public static func wgs84ToGCJ02(longitude: Double, latitude: Double) -> (longitude: Double, latitude: Double) {
        guard !isOutsideChina(longitude: longitude, latitude: latitude) else { return (longitude, latitude) }
        let dLat = transformLatitude(x: longitude - 105.0, y: latitude - 35.0)
        let dLon = transformLongitude(x: longitude - 105.0, y: latitude - 35.0)
        let radLat = latitude / 180.0 * pi
        var magic = sin(radLat)
        magic = 1 - eccentricitySquared * magic * magic
        let sqrtMagic = sqrt(magic)
        let dLatOffset = (dLat * 180.0) / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * sqrtMagic) * pi)
        let dLonOffset = (dLon * 180.0) / (semiMajorAxis / sqrtMagic * cos(radLat) * pi)
        return (longitude + dLonOffset, latitude + dLatOffset)
    }

    // MARK: - GCJ-02 → WGS-84

    public static func gcj02ToWGS84(longitude: Double, latitude: Double) -> (longitude: Double, latitude: Double) {
        guard !isOutsideChina(longitude: longitude, latitude: latitude) else { return (longitude, latitude) }
        var lon = longitude
        var lat = latitude
        // 迭代逼近：每次用当前估计值算偏移，减去该偏移。
        for _ in 0..<12 {
            let (shiftedLon, shiftedLat) = wgs84ToGCJ02(longitude: lon, latitude: lat)
            let errorLon = longitude - shiftedLon
            let errorLat = latitude - shiftedLat
            lon += errorLon
            lat += errorLat
            if abs(errorLon) < 1e-9 && abs(errorLat) < 1e-9 { break }
        }
        return (lon, lat)
    }

    // MARK: - BD-09 互转

    public static func bd09ToGCJ02(longitude: Double, latitude: Double) -> (longitude: Double, latitude: Double) {
        let x = longitude - 0.0065
        let y = latitude - 0.006
        let z = sqrt(x * x + y * y) - 0.00002 * sin(y * x_pi)
        let theta = atan2(y, x) - 0.000003 * cos(x * x_pi)
        return (z * cos(theta), z * sin(theta))
    }

    public static func gcj02ToBD09(longitude: Double, latitude: Double) -> (longitude: Double, latitude: Double) {
        let z = sqrt(longitude * longitude + latitude * latitude) + 0.00002 * sin(latitude * x_pi)
        let theta = atan2(latitude, longitude) + 0.000003 * cos(longitude * x_pi)
        return (z * cos(theta) + 0.0065, z * sin(theta) + 0.006)
    }

    public static func bd09ToWGS84(longitude: Double, latitude: Double) -> (longitude: Double, latitude: Double) {
        let (lon, lat) = bd09ToGCJ02(longitude: longitude, latitude: latitude)
        return gcj02ToWGS84(longitude: lon, latitude: lat)
    }

    // MARK: - 辅助

    private static let x_pi = pi * 3000.0 / 180.0

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * pi) + 320 * sin(y * pi / 30.0)) * 2.0 / 3.0
        return result
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        // 注意：正弦项一律用 x（经差），不是 y。权威实现见
        // googollee/eviltransform javascript/transform.js 的 transform()。
        // 曾经把后两项写成 y，滨州一带会少算约 57 米东向偏移。
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0
        return result
    }
}
