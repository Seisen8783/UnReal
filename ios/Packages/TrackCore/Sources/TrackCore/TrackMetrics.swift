import Foundation

/// 回放长度的计量方式（互斥二选一）。
///
/// 界面上是一个下拉框选「总圈数 / 公里数」，右侧填对应数值。
public enum LengthMode: String, CaseIterable, Identifiable, Sendable {
    /// 按圈数：轨迹循环若干圈。
    case laps
    /// 按公里数：轨迹循环到指定距离。
    case kilometers

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .laps: return "总圈数"
        case .kilometers: return "公里数"
        }
    }
}

/// 注入值与小程序上报值之间的基准关系。
///
/// 小程序用 `wx.startLocationUpdateBackground`（`type` 未指定，微信默认 **gcj02**）
/// 取定位：设备交付的 WGS-84 会被微信转成 GCJ-02，再原样上报给服务端。
/// 所以注入值与上报值之间隔着一次 GCJ-02 转换。
///
/// 服务端的校园围栏若按 WGS-84 标注（从 GPS/测绘数据导入的常见做法），
/// 两者就差一个基准偏移量——滨州一带约 525 米，于是明明在操场上却判「非校园区域」。
/// 「回退一个基准」就是预先做一次反解，让微信转回来正好等于文件原值。
public enum ReportAlignment: String, CaseIterable, Identifiable, Sendable {
    /// 原样：注入什么，微信转完上报什么。
    case asIs
    /// 回退一个基准：注入前多做一次 GCJ-02 → WGS-84 反解。
    case pullBackOneDatum

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .asIs: return "原样"
        case .pullBackOneDatum: return "回退一个基准"
        }
    }

    public var help: String {
        switch self {
        case .asIs:
            return "注入值经微信转换后原样上报。服务端围栏与小程序上报同基准时用这个。\n上报落点会整体偏一个基准（滨州一带约 526 米）。"
        case .pullBackOneDatum:
            return "微信把 WGS-84 转成 GCJ-02 后才上报。服务端围栏若是 WGS-84，需预先回退一次，\n否则会差一个基准偏移量（滨州一带约 525 米），导致明明在操场却判「非校园区域」。\n\n它与上面的「坐标基准」不是重复动作：坐标基准回答「文件里这个数对应地球上哪里」，\n回退一个基准回答「设备该写什么数，微信转回来才落在真实位置上」。两者叠加后上报值正好是真实位置。"
        }
    }
}

/// 轨迹的弧长测量与按距离截取。
///
/// 「支持公里数模拟」需要回答两个问题：
/// 1. 这条轨迹有多长？（米）
/// 2. 要跑 1.50 公里，该取轨迹上哪一段？
///
/// 截取按累计弧长进行，与采样点密度无关，因此结果稳定。
public enum TrackMetrics {
    /// 两点间距离（米），用 haversine。
    public static func meters(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let earthRadius = 6_371_008.8
        let rad = Double.pi / 180
        let sineLat = sin((b.latitude - a.latitude) * rad / 2)
        let sineLon = sin((b.longitude - a.longitude) * rad / 2)
        let h = sineLat * sineLat
            + cos(a.latitude * rad) * cos(b.latitude * rad) * sineLon * sineLon
        return 2 * earthRadius * asin(sqrt(min(1, max(0, h))))
    }

    /// 每个点之前的累计距离。第 0 个点为 0。
    ///
    /// 空数组直接返回空数组：`1..<0` 是非法区间，会直接崩。
    public static func cumulativeDistances(_ points: [TrackPoint]) -> [Double] {
        guard points.count > 1 else {
            return [Double](repeating: 0, count: points.count)
        }
        var result = [Double](repeating: 0, count: points.count)
        for index in 1..<points.count {
            result[index] = result[index - 1] + meters(points[index - 1], points[index])
        }
        return result
    }

    /// 轨迹总长（米）。
    public static func length(_ points: [TrackPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        return cumulativeDistances(points).last ?? 0
    }

    /// 按累计弧长取点：距离 `meters` 处对应的坐标。
    /// `meters` 超界时钳制到两端。
    public static func point(atMeters meters: Double, points: [TrackPoint],
                             cumulative: [Double]) -> TrackPoint {
        guard points.count > 1 else { return points.first ?? TrackPoint(latitude: 0, longitude: 0, offset: 0) }
        if meters <= 0 { return points[0] }
        let total = cumulative.last ?? 0
        if meters >= total { return points.last! }

        var low = 0
        var high = cumulative.count - 1
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] <= meters { low = mid + 1 } else { high = mid }
        }
        let upper = max(1, min(low, points.count - 1))
        let lower = upper - 1
        let span = cumulative[upper] - cumulative[lower]
        let fraction = span > 0 ? (meters - cumulative[lower]) / span : 0
        let from = points[lower]
        let to = points[upper]
        return TrackPoint(latitude: from.latitude + fraction * (to.latitude - from.latitude),
                          longitude: from.longitude + fraction * (to.longitude - from.longitude),
                          offset: from.offset)
    }

    /// 从轨迹起点截取指定长度（米），末点按弧长精确落在目标距离上。
    ///
    /// 长度超过轨迹全长时返回整条轨迹（不循环补足），
    /// 是否补足由调用方按圈数决定。
    public static func prefix(meters target: Double, points: [TrackPoint]) -> [TrackPoint] {
        guard points.count > 1, target > 0 else { return points }
        let cumulative = cumulativeDistances(points)
        let total = cumulative.last ?? 0
        guard target < total else { return points }

        var result: [TrackPoint] = []
        result.reserveCapacity(points.count)
        for index in points.indices {
            if cumulative[index] <= target {
                result.append(points[index])
            } else {
                break
            }
        }
        let tail = point(atMeters: target, points: points, cumulative: cumulative)
        // 末点替换成精确落点，时间戳按比例插值。
        let base = result.last?.offset ?? 0
        let ratio = total > 0 ? target / total : 0
        let span = points.last!.offset - base
        result.append(TrackPoint(latitude: tail.latitude, longitude: tail.longitude,
                                 offset: base + span * ratio))
        return result
    }

    /// 把轨迹按目标长度循环延展：不足则重复拼接，超出则截断。
    ///
    /// 用于「按公里数模拟」——用户给 1.50 公里，
    /// 轨迹本身是 450 米的一圈，就要绕 3 圈多再截断。
    ///
    /// 实现要点：按累计弧长均匀重采样，而不是简单拼接点列表。
    /// 真实轨迹常常不闭合（末点与首点差十几米），简单拼接会在圈与圈之间
    /// 留下跳变；按弧长采样则让每圈的起点严格落在轨迹的同一位置，
    /// 圈与圈之间自然连续。
    /// 未计时的分段（offset 全为 0）也必须支持——那正是 UnReal Console 默认的输入形态。
    /// 此时按弧长比例合成时间戳，单圈时长由 `paceSecondsPerKilometer` 决定。
    public static func expand(toMeters target: Double, points: [TrackPoint],
                              paceSecondsPerKilometer: Double = 0) -> [TrackPoint] {
        guard points.count > 1, target > 0 else { return points }
        let cumulative = cumulativeDistances(points)
        let single = cumulative.last ?? 0
        guard single > 0 else { return points }

        let first = points.first!
        let last = points.last!
        let originalSpan = last.offset - first.offset
        // 原始时间戳退化时（未计时分段），按弧长比例合成单圈时长。
        let lapDuration = originalSpan > 0
            ? originalSpan
            : single * paceSecondsPerKilometer / 1000

        // 采样步长与原轨迹疏密相当，避免凭空加密。
        let step = max(1.0, single / Double(max(1, points.count - 1)), target / 199_999)
        let sampleCount = max(1, Int(ceil(target / step)))

        var result: [TrackPoint] = []
        result.reserveCapacity(sampleCount + 1)
        // 每圈时长固定，回放在时间轴上是连续的：第 N 圈的时间戳 = N × 单圈时长 + 圈内偏移。
        for index in 0...sampleCount {
            let meters = min(target, Double(index) * step)
            let lap = Int(meters / single)
            let lapMeters = meters - Double(lap) * single
            let position = point(atMeters: lapMeters, points: points, cumulative: cumulative)

            let within: Double
            if originalSpan > 0 {
                // 有真实时间戳：在圈内按弧长插值。
                within = timeOffset(atMeters: lapMeters, points: points, cumulative: cumulative) - first.offset
            } else {
                // 无时间戳：按弧长比例分配单圈时长。
                within = lapDuration * (lapMeters / single)
            }
            // 跨圈时叠加整圈时长，保持全局单调递增。
            let offset = Double(lap) * lapDuration + within
            result.append(TrackPoint(latitude: position.latitude, longitude: position.longitude,
                                     offset: offset))
        }
        return result
    }

    /// 弧长对应的原始时间戳（按比例插值）。
    private static func timeOffset(atMeters meters: Double, points: [TrackPoint],
                                   cumulative: [Double]) -> Double {
        guard points.count > 1 else { return 0 }
        let first = points.first!
        let last = points.last!
        let span = last.offset - first.offset
        guard span > 0 else { return first.offset }
        let total = cumulative.last ?? 0
        guard total > 0 else { return first.offset }
        return first.offset + span * (meters / total)
    }
}
