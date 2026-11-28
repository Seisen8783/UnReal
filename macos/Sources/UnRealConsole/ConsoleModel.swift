import AppKit
import Foundation

struct USBDevice: Codable, Identifiable {
    let id: String
    let name: String
    let version: String
    let detail: String
}

private struct BridgeEvent: Decodable {
    let kind: String
    var message: String?
    var devices: [USBDevice]?
    var index: Int?
    var elapsed: Double?
    var clean: Bool?
    var paused: Bool?
    var ok: Bool?
}

private enum BridgeOperation: String {
    case list, play, anchor, restore
}

final class ConsoleModel: ObservableObject {
    static let shared = ConsoleModel()

    @Published private(set) var devices: [USBDevice] = []
    @Published var deviceID = ""
    @Published private(set) var route: TrackRoute?
    @Published private(set) var paceInput = ReplayPace.format(KMLRoute.defaultPace)
    @Published private(set) var loop: LoopRoute?
    @Published private(set) var useCenterline = true
    @Published private(set) var lapsInput = "1"
    @Published var lengthMode: LengthMode = .laps
    @Published var targetKilometers: String = ""
    /// 轨迹文件使用的坐标基准。
    ///
    /// 默认 WGS-84：绝大多数 GPX/KML（GPS 手表、Garmin、Strava、OSM 导出）都是 WGS-84。
    /// 曾默认 GCJ-02，那样一份 WGS-84 的文件会被整体平移约 525 米——
    /// 症状与「非校园区域」一模一样，极难分辨。
    @Published var coordinateSystem: CoordinateSystem = .wgs84
    @Published var reportAlignment: ReportAlignment = .asIs
    @Published var calibration = CalibrationOffset.zero
    @Published var trackSource: TrackSource = .bundled
    @Published private(set) var timeline: [TrackPoint] = []
    @Published private(set) var paused = false
    @Published private(set) var hasStarted = false
    private var originalRoute: TrackRoute?
    private var seekIndex = 0
    private var geometryPace = KMLRoute.defaultPace
    private var appliedPace = KMLRoute.defaultPace
    private var trackFile: URL?
    @Published private var pendingUpdate: (points: [TrackPoint], pace: Int)?
    @Published private(set) var status = "请连接 iPhone 并选择轨迹"
    @Published private(set) var importError: String?
    @Published private(set) var error: String?
    @Published private(set) var pointIndex: Int?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var elapsedUpdatedAt = Date()
    @Published private(set) var pendingID: String?
    @Published private(set) var stopping = false
    @Published private var operation: BridgeOperation?

    private let pendingKey = "pending-device-udid"
    private var process: Process?
    private var input: FileHandle?
    private var termination: (() -> Void)?
    private var receivedResult = false
    private var lastDiagnostic: String?
    private var settingsSync: DispatchWorkItem?

    var busy: Bool { operation != nil }
    var playing: Bool { operation == .play || operation == .anchor }
    var canEditSettings: Bool { !busy || (playing && paused && !stopping) }
    var showsLap: Bool { !usesKilometers && useCenterline && loop != nil && !timeline.isEmpty }
    var timelineLaps: Int {
        guard showsLap, let route, route.points.count > 1 else { return 1 }
        return (timeline.count - 1) / (route.points.count - 1)
    }
    var currentLap: Int {
        ReplayTimeline.lap(at: pointIndex ?? 0, pointsPerLap: route?.points.count ?? 0,
                           totalLaps: timelineLaps)
    }
    var lapBelowCurrent: Bool { playing && paused && (lapCount ?? 99) < currentLap }
    var settingsChanged: Bool {
        (route?.untimedSegments != nil && ReplayPace.parse(paceInput) != appliedPace) || lapCount != timelineLaps
    }

    var canAnchor: Bool { !busy && (pendingID == nil || pendingID == deviceID) && !deviceID.isEmpty && !timeline.isEmpty }
    var canRestore: Bool { playing ? !stopping : !busy && !restoreDeviceID.isEmpty }
    var lapCount: Int? {
        // 公里数模式优先，此时「圈数」由目标长度决定。
        if usesKilometers { return 1 }
        guard useCenterline && loop != nil else { return 1 }
        guard let value = Int(lapsInput), (1...99).contains(value) else { return nil }
        return value
    }
    var canSeek: Bool {
        (!busy || playing) && !stopping && pendingUpdate == nil && route?.timingIssue == nil && totalDuration > 0
    }
    var lapLimitExceeded: Bool {
        guard let lapCount, let route, lapCount > 1 else { return false }
        if usesKilometers { return false }
        return route.points.count * lapCount > 200_000
    }
    var totalDuration: Double { timeline.last?.offset ?? 0 }
    var previewIndex: Int? {
        guard let index = pointIndex, let route else { return nil }
        let length = route.points.count - 1
        return index == 0 || length == 0 ? 0 : (index - 1) % length + 1
    }
    var canPlay: Bool {
        (canAnchor || (playing && paused && !stopping))
            && route?.timingIssue == nil && importError == nil && !timeline.isEmpty
            && canApplySettings && !lapBelowCurrent
    }
    var canRestart: Bool {
        playing ? !stopping && pendingUpdate == nil && (!paused || canApplySettings) : canPlay
    }
    private var canApplySettings: Bool { !invalidPace && !invalidKilometers && lapCount != nil && !lapLimitExceeded && pendingUpdate == nil }
    var invalidPace: Bool { route?.untimedSegments != nil && ReplayPace.parse(paceInput) == nil }
    var restoreDeviceID: String { pendingID ?? deviceID }

    /// 目标公里数（米）。仅在公里数模式下有效。
    var targetMeters: Double? {
        guard lengthMode == .kilometers else { return nil }
        let trimmed = targetKilometers.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        guard value <= 1000 else { return nil }
        return (value * 1000).rounded()
    }

    /// 公里数输入是否非法（非空但解析不出合法正数）。
    var invalidKilometers: Bool {
        guard lengthMode == .kilometers else { return false }
        let trimmed = targetKilometers.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let value = Double(trimmed), value.isFinite else { return true }
        return value <= 0 || value > 1000
    }

    /// 当前按公里数模式工作。
    var usesKilometers: Bool { lengthMode == .kilometers }

    /// 单圈中线长度（米），用于展示与换算。
    var lapMeters: Double {
        guard let route else { return 0 }
        return TrackMetrics.length(route.points)
    }

    /// 本次总计长度（米）：公里数模式下是目标值，否则是圈数 × 单圈。
    var totalMeters: Double {
        if let target = targetMeters { return target }
        return lapMeters * Double(lapCount ?? 1)
    }

    /// 已模拟的米数（按当前播放位置）。
    var simulatedMeters: Double {
        simulatedMeters(at: pointIndex)
    }

    /// 指定位置处的已模拟米数。传 `nil` 表示当前播放位置。
    ///
    /// 两个数组历史上会脱节（`timeline` 被整体替换时忘了同步累计距离），
    /// 于是这里按新长度取下标就越界崩溃。现在两处都做钳制：
    /// 写入统一走 `setTimeline(_:)`，读取再按累计距离的实际长度兜一次底。
    func simulatedMeters(at index: Int?) -> Double {
        guard !timeline.isEmpty, !timelineCumulative.isEmpty else { return 0 }
        let clamped = min(max(0, index ?? 0), min(timeline.count, timelineCumulative.count) - 1)
        return timelineCumulative[clamped]
    }

    /// 时间轴的累计距离，随时间轴重建时更新。
    ///
    /// 必须与 `timeline` 等长——两者永远成对更新，只能经由 `setTimeline(_:)` 写入。
    private(set) var timelineCumulative: [Double] = []

    /// 唯一的写入口：替换时间轴，并同步它的累计距离。
    ///
    /// 以前有 5 处直接给 `timeline` 赋值，其中「应用新设置」那处漏了累计距离，
    /// 导致 `simulatedMeters` 越界（SIGTRAP / Index out of range）。
    func setTimeline(_ points: [TrackPoint]) {
        timeline = points
        timelineCumulative = TrackMetrics.cumulativeDistances(points)
    }

    private init() {
        pendingID = UserDefaults.standard.string(forKey: pendingKey)
    }

    func load(_ url: URL) {
        guard !busy else { return }
        do {
            let loaded = try TrackRoute.load(url)
            originalRoute = loaded
            loop = LoopRoute.fit(loaded)
            useCenterline = true
            lapsInput = "1"
            importError = nil
            rebuildRoute()
            // 换了轨迹，若公里数是自动预填的（用户没手动改），按新轨迹重算。
            if lengthMode == .kilometers, !kilometersEditedByUser {
                let meters = max(totalMeters, 1)
                targetKilometers = String(format: "%.2f", meters / 1000)
                rebuildRoute()
            }
        } catch {
            originalRoute = nil
            loop = nil
            route = nil
            setTimeline([])
            pointIndex = nil
            elapsed = 0
            importError = error.localizedDescription
        }
    }

    /// 内置默认轨迹的坐标基准固定为 WGS-84。
    ///
    /// 该文件与 `core/assets/campus.geojson` 逐点一致，而后者在 README 中
    /// 明确声明为 WGS-84。若按 GCJ-02 解读，整条轨迹会平移约 475 米。
    static let bundledCoordinateSystem: CoordinateSystem = .wgs84

    /// 当前生效的坐标基准。
    ///
    /// 内置默认轨迹用固定基准；本地导入的轨迹用用户选择的。
    var effectiveCoordinateSystem: CoordinateSystem {
        trackSource == .bundled ? Self.bundledCoordinateSystem : coordinateSystem
    }

    /// 上报落点与真实位置之间的偏差（米）。
    ///
    /// 上报值 = 微信对注入值做的那一次 WGS-84 → GCJ-02 转换。
    /// 「原样」口径下两者整体差一个基准（滨州一带约 526 米）；
    /// 「回退一个基准」下应当归零——这正是这个读数存在的意义：
    /// 把「会不会多出一次转换」从猜变成看得见的数字。
    var reportLandingErrorMeters: Double? {
        guard let first = route?.points.first, let origin = originalRoute?.points.first else { return nil }
        // 真实位置：文件原值按其基准归一化到 WGS-84，再叠加标定偏移。
        let truePoint = calibration.apply(to: effectiveCoordinateSystem.normalized(origin))
        // 上报落点：微信把注入值转成 GCJ-02 之后的样子。
        let reported = CoordinateTransform.wgs84ToGCJ02(longitude: first.longitude,
                                                         latitude: first.latitude)
        return TrackMetrics.meters(truePoint,
                                   TrackPoint(latitude: reported.1, longitude: reported.0,
                                              offset: truePoint.offset))
    }

    /// 载入内置默认轨迹。
    func loadBundledTrack() {
        guard !busy else { return }
        guard let url = Bundle.module.url(forResource: TrackSource.bundledFileName,
                                          withExtension: "kmz") else {
            importError = "找不到内置默认轨迹。"
            return
        }
        trackSource = .bundled
        load(url)
        status = "已载入默认轨迹"
    }

    /// 套用校园跑预设：内置轨迹 + 标定偏移 + 上报口径 + 配速 + 目标公里数。
    ///
    /// 站在操场边刷脸的时候不方便现调参数，这套设置都是实测出来的，
    /// 一次套用即可。偏移值来自围栏预检，配速刻意贴近真实步速。
    func applyCampusRunPreset() {
        guard !busy else { return }
        if trackSource != .bundled { loadBundledTrack() }
        calibration = CalibrationOffset(eastMeters: CampusRunPreset.eastMeters,
                                        northMeters: CampusRunPreset.northMeters)
        reportAlignment = .asIs
        if let seconds = ReplayPace.parse(CampusRunPreset.pace) {
            geometryPace = seconds
            appliedPace = seconds
            paceInput = CampusRunPreset.pace
        }
        lengthMode = .kilometers
        // 用户手动填过的公里数不覆盖——那个值直接决定上报的距离，是成绩数据。
        if !kilometersEditedByUser {
            targetKilometers = CampusRunPreset.kilometers
        }
        rebuildRoute()
        campusRunPresetApplied = true
        status = "校园跑预设已套用：先去桩前刷脸，再点「开始回放」"
    }

    /// 是否已套用校园跑预设。套用后侧栏显示流程清单。
    @Published private(set) var campusRunPresetApplied = false

    /// 载入本地导入的轨迹，沿用用户选择的坐标基准。
    ///
    /// 导入时保留当前选择的上报口径。
    func loadLocalTrack(_ url: URL) {
        trackSource = .localFile
        // 换了轨迹，校园跑预设的偏移量就不再适用了。
        campusRunPresetApplied = false
        load(url)
    }

    /// 轨迹文件声明的坐标基准。导入后若改变，需重新归一化。
    ///
    /// 内置默认轨迹的基准是固定的（WGS-84），此时改选择不会有效果。
    func setCoordinateSystem(_ value: CoordinateSystem) {
        guard !busy, value != coordinateSystem else { return }
        coordinateSystem = value
        guard trackSource != .bundled else { return }
        rebuildRoute()
    }

    /// 位置标定偏移（米）。用于把整条轨迹平移到目标位置。
    func setCalibration(eastMeters: Double, northMeters: Double) {
        guard !busy else { return }
        let updated = CalibrationOffset(eastMeters: eastMeters, northMeters: northMeters)
        guard updated != calibration else { return }
        calibration = updated
        rebuildRoute()
    }

    /// 目标公里数。留空表示按圈数走。
    func setTargetKilometers(_ text: String) {
        guard !busy else { return }
        guard text != targetKilometers else { return }
        targetKilometers = text
        // 用户手动改过之后，换轨迹不再自动覆盖。
        kilometersEditedByUser = true
        // 输入过程中可能暂时非法，此时不重建，等输入合法再说。
        guard !invalidKilometers else { return }
        rebuildRoute()
    }

    /// 切换上报口径（原样 ↔ 回退一个基准）。
    func setReportAlignment(_ alignment: ReportAlignment) {
        guard !busy, alignment != reportAlignment else { return }
        reportAlignment = alignment
        rebuildRoute()
    }

    /// 切换长度计量方式（圈数 ↔ 公里数）。    ///
    /// 切到公里数时，若输入框还是空的，按当前总长度自动填一个值，
    /// 免得用户面对空框不知道该填多少。
    func setLengthMode(_ mode: LengthMode) {
        guard !busy, mode != lengthMode else { return }
        // 先按旧模式算出总长度，再切换——否则 lapCount 已经变了，预填值会偏小。
        let previousTotal = totalMeters
        lengthMode = mode
        if mode == .kilometers, targetKilometers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let meters = previousTotal > 0 ? previousTotal : lapMeters
            targetKilometers = String(format: "%.2f", max(meters, 1) / 1000)
            kilometersEditedByUser = false
        }
        rebuildRoute()
    }

    /// 公里数是否被用户手动改过。改过之后换轨迹就不自动重算。
    private var kilometersEditedByUser = false

    func setPace(_ text: String) {
        guard canEditSettings, let route, route.untimedSegments != nil else { return }
        paceInput = text
        if playing { scheduleSettingsSync(); return }
        guard !busy, let seconds = ReplayPace.parse(text),
              seconds != geometryPace || seconds != appliedPace else { return }
        geometryPace = seconds
        appliedPace = seconds
        rebuildRoute()
    }

    func setCenterline(_ value: Bool) {
        guard !busy else { return }
        useCenterline = value
        rebuildRoute()
    }

    func setLaps(_ value: String) {
        guard canEditSettings else { return }
        lapsInput = value
        if !busy { rebuildTimeline() }
        else if playing { scheduleSettingsSync() }
    }

    private func rebuildRoute() {
        guard var source = originalRoute else { return }
        // 内置默认轨迹的基准是确定的，不随用户的「坐标基准」选择改变；
        // 本地导入的轨迹才用用户选的那个。
        let system = effectiveCoordinateSystem
        // 先归一化坐标基准，再套用标定偏移。顺序不能反：
        // 偏移是米制平移，必须在经纬度空间做；基准转换是非线性变换，必须先做。
        source = system.normalized(route: source)
        // 「回退一个基准」：再做一次 GCJ-02 反解，让微信转回来正好等于文件原值。
        if reportAlignment == .pullBackOneDatum {
            source = CoordinateSystem.gcj02.normalized(route: source)
        }
        let shiftedPoints: [TrackPoint] = calibration.apply(to: source.points)
        let shiftedSegments: [[TrackPoint]]? = source.untimedSegments.map { segments in
            segments.map { calibration.apply(to: $0) }
        }
        source = TrackRoute(name: source.name,
                            points: shiftedPoints,
                            segmentStarts: source.segmentStarts,
                            timingIssue: source.timingIssue,
                            untimedSegments: shiftedSegments)
        if useCenterline, let fitted = LoopRoute.fit(source) {
            // 中线必须在归一化之后拟合，否则会与点集错开一个基准。
            loop = fitted
            source.untimedSegments = [fitted.centerline]
        }
        route = KMLRoute.withPace(source, secondsPerKilometer: geometryPace)

        // 公里数模式：把轨迹按目标长度循环延展并截断。
        if let target = targetMeters, let built = route {
            route = Self.expand(toMeters: target, route: built,
                                paceSecondsPerKilometer: Double(geometryPace))
        }
        rebuildTimeline()
    }

    /// 按目标长度扩展轨迹：不足则循环拼接，超出则按弧长截断。
    private static func expand(toMeters target: Double, route: TrackRoute,
                               paceSecondsPerKilometer: Double) -> TrackRoute? {
        guard route.points.count > 1 else { return route }
        let single = TrackMetrics.length(route.points)
        guard single > 0 else { return route }

        // 未计时分段：按同样的圈数延展。
        var untimed: [[TrackPoint]]? = nil
        if let segments = route.untimedSegments {
            untimed = segments.map {
                TrackMetrics.expand(toMeters: target, points: $0,
                                    paceSecondsPerKilometer: paceSecondsPerKilometer)
            }
        }

        // 已带时间戳的轨迹：直接按弧长循环。
        var points = route.points
        if route.untimedSegments == nil {
            points = TrackMetrics.expand(toMeters: target, points: points,
                                         paceSecondsPerKilometer: paceSecondsPerKilometer)
        }

        return TrackRoute(name: route.name,
                          points: points,
                          segmentStarts: [0],
                          timingIssue: route.timingIssue,
                          untimedSegments: untimed)
    }

    private func rebuildTimeline() {
        pointIndex = nil
        seekIndex = 0
        elapsed = 0
        guard let route, !route.points.isEmpty, !lapLimitExceeded else {
            setTimeline([])
            return
        }
        // 公里数模式下轨迹已按目标长度扩展，直接跑一遍即可。
        let laps = usesKilometers ? 1 : (lapCount ?? 1)
        guard laps > 0 else {
            setTimeline([])
            return
        }
        setTimeline(ReplayTimeline.build(route, laps: laps,
                                         scale: Double(appliedPace) / Double(geometryPace)))
    }

    func refresh() { launch(.list) }

    func locateStart() {
        guard canAnchor else { return }
        pointIndex = nil
        elapsed = 0
        seekIndex = 0
        launchTrack(.anchor, points: timeline)
    }

    func start() {
        guard canPlay else { return }
        if playing {
            continueSession(restarting: false)
        } else {
            prepareNewTimeline()
            // 重建后时间轴可能变短（比如圈数调小），旧的 seekIndex 要钳到新长度内。
            let from = timeline.isEmpty ? 0 : min(max(0, seekIndex), timeline.count - 1)
            seekIndex = 0
            pointIndex = from == 0 ? nil : from
            elapsed = from == 0 ? 0 : timeline[from].offset
            launchTrack(.play, points: timeline, from: from)
        }
    }

    func restart() {
        guard canRestart else { return }
        if playing {
            if paused { continueSession(restarting: true) }
            else { send("seek 0\nresume") }
        } else if canPlay {
            pointIndex = nil
            seekIndex = 0
            elapsed = 0
            start()
        }
    }

    private func prepareNewTimeline() {
        guard let route, let laps = lapCount else { return }
        appliedPace = ReplayPace.parse(paceInput) ?? geometryPace
        setTimeline(ReplayTimeline.build(route, laps: laps,
                                         scale: Double(appliedPace) / Double(geometryPace)))
    }

    private func scheduleSettingsSync() {
        settingsSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.playing, self.paused, self.pendingUpdate == nil,
                  self.canApplySettings, !self.lapBelowCurrent, self.settingsChanged else { return }
            self.applySessionSettings(restarting: false, resume: false)
        }
        settingsSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func continueSession(restarting: Bool) {
        settingsSync?.cancel()
        if !settingsChanged && !restarting {
            send("resume")
            return
        }
        applySessionSettings(restarting: restarting, resume: true)
    }

    private func applySessionSettings(restarting: Bool, resume: Bool) {
        guard let route, let trackFile, let laps = lapCount else { return }
        let nextPace = ReplayPace.parse(paceInput) ?? geometryPace
        let history = restarting ? timeline.prefix(0) : timeline.prefix((pointIndex ?? 0) + 1)
        let updated = ReplayTimeline.build(route, laps: laps,
                                           scale: Double(nextPace) / Double(geometryPace), keeping: history)
        guard !updated.isEmpty else { return }

        do {
            try JSONEncoder().encode(updated).write(to: trackFile, options: .atomic)
            pendingUpdate = (updated, nextPace)
            if !send(restarting ? "apply-restart" : (resume ? "apply" : "apply-hold")) { pendingUpdate = nil }
        } catch {
            self.error = "无法更新回放设置。\(error.localizedDescription)"
        }
    }

    func seek(to seconds: Double) {
        guard canSeek, !timeline.isEmpty else { return }
        var lo = 0
        var hi = timeline.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if timeline[mid].offset < seconds { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 && seconds - timeline[lo - 1].offset < timeline[lo].offset - seconds { lo -= 1 }
        if playing {
            send("seek \(lo)")
        } else {
            pointIndex = lo
            seekIndex = lo
            elapsed = timeline[lo].offset
        }
    }

    private func launchTrack(_ action: BridgeOperation, points: [TrackPoint], from index: Int = 0) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        do {
            try JSONEncoder().encode(points).write(to: file, options: .atomic)
            launch(action, serial: deviceID, file: file, index: index)
        } catch {
            self.error = "无法准备轨迹文件。\(error.localizedDescription)"
        }
    }

    func restore() {
        guard canRestore else { return }
        if playing {
            stopping = true
            status = "正在重置位置"
            if !send("reset") { stopping = false }
        } else {
            launch(.restore, serial: restoreDeviceID)
        }
    }

    func pause() {
        guard playing, !paused, !stopping else { return }
        send("pause")
    }

    @discardableResult
    private func send(_ command: String) -> Bool {
        guard let input else { return false }
        do {
            try input.write(contentsOf: Data((command + "\n").utf8))
            return true
        } catch {
            self.error = "无法发送回放命令。\(error.localizedDescription)"
            return false
        }
    }

    private func endSimulation() {
        guard playing, !stopping else { return }
        stopping = true
        status = "正在返回轨迹起点"
        try? input?.close()
        input = nil
    }

    func prepareToQuit(_ reply: @escaping () -> Void) -> Bool {
        guard busy else { return false }
        termination = reply
        endSimulation()
        return true
    }

    private func recordPending(_ serial: String?) {
        pendingID = serial
        UserDefaults.standard.set(serial, forKey: pendingKey)
    }

    private func launch(_ action: BridgeOperation, serial: String? = nil, file: URL? = nil, index: Int = 0) {
        guard !busy else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        error = nil
        lastDiagnostic = nil
        receivedResult = false
        guard let executable = Self.bridgeLauncher, let bridge = Bundle.module.url(forResource: "device_bridge",
                                                                 withExtension: "py") else {
            if let file { try? FileManager.default.removeItem(at: file) }
            error = "找不到设备连接工具。请重新安装 A Console。"
            return
        }
        let task = Process()
        let output = Pipe()
        let commands = Pipe()
        task.executableURL = executable.url
        task.arguments = executable.prefix + ["-I", "-B", "-u", bridge.path, action.rawValue] + [serial, file?.path].compactMap { $0 }
        if action == .play { task.arguments?.append(contentsOf: ["--index", String(index)]) }
        task.standardOutput = output
        task.standardError = output
        task.standardInput = commands
        status = action == .list ? "正在查找 USB 设备" : "正在启动设备桥接"
        operation = action
        trackFile = file
        process = task
        input = commands.fileHandleForWriting
        let previousPending = pendingID
        if let serial { recordPending(serial) }

        do {
            try task.run()
        } catch {
            recordPending(previousPending)
            if let file { try? FileManager.default.removeItem(at: file) }
            finish()
            self.error = "无法启动设备桥接。\(error.localizedDescription)"
            return
        }

        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer.prefix(upTo: newline))
                    buffer.removeSubrange(...newline)
                    DispatchQueue.main.async { [weak self] in self?.consume(line) }
                }
            }
            if !buffer.isEmpty {
                let lastLine = buffer
                DispatchQueue.main.async { [weak self] in self?.consume(lastLine) }
            }
            task.waitUntilExit()
            let code = task.terminationStatus
            if let file { try? FileManager.default.removeItem(at: file) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !receivedResult && (code != 0 || action != .list) {
                    status = "设备桥接已退出"
                    error = lastDiagnostic ?? "设备桥接异常退出（\(code)）。"
                }
                finish()
            }
        }
    }

    private func consume(_ line: Data) {
        guard let event = try? JSONDecoder().decode(BridgeEvent.self, from: line) else {
            if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                lastDiagnostic = String(text.prefix(400))
            }
            return
        }
        switch event.kind {
        case "devices":
            devices = event.devices ?? []
            if !devices.contains(where: { $0.id == deviceID }) {
                deviceID = devices.first(where: { $0.id == pendingID })?.id ?? devices.first?.id ?? ""
            }
            status = devices.isEmpty ? "未发现 USB iPhone" : "USB 设备列表已更新"
        case "state":
            if let message = event.message { status = message }
        case "mode":
            if let value = event.paused {
                paused = value
                if !value { hasStarted = true; elapsedUpdatedAt = Date() }
            }
            if let message = event.message { status = message }
        case "updated":
            if let pendingUpdate {
                // 这里以前只换 timeline、不换累计距离，两个数组长度脱节，
                // 紧接着的界面刷新就会在 simulatedMeters 越界崩溃。
                setTimeline(pendingUpdate.points)
                appliedPace = pendingUpdate.pace
            }
            pendingUpdate = nil
            if event.index == nil {
                pointIndex = nil
                elapsed = 0
            }
            if event.paused == false { paused = false; hasStarted = true; elapsedUpdatedAt = Date() }
            error = nil
            if paused && settingsChanged { scheduleSettingsSync() }
        case "update-error":
            pendingUpdate = nil
            error = event.message
        case "point":
            pointIndex = event.index
            elapsed = event.elapsed ?? 0
            elapsedUpdatedAt = Date()
        case "cleared":
            recordPending(nil)
        case "result":
            receivedResult = true
            if operation == .restore && event.clean == true { recordPending(nil) }
            if event.ok == true {
                status = event.message ?? "操作完成"
            } else {
                status = "操作失败"
                error = event.message
            }
        default:
            break
        }
    }

    private func finish() {
        try? input?.close()
        input = nil
        process = nil
        let hadSession = playing
        operation = nil
        trackFile = nil
        pendingUpdate = nil
        settingsSync?.cancel()
        if hadSession && settingsChanged && canApplySettings {
            pointIndex = nil
            elapsed = 0
            seekIndex = 0
            prepareNewTimeline()
        }
        paused = false
        hasStarted = false
        stopping = false
        let reply = termination
        termination = nil
        reply?()
    }

    private static var bridgeLauncher: (url: URL, prefix: [String])? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let python = Bundle.main.resourceURL?.appendingPathComponent("python/bin/python3"),
                  FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
            return (python, [])
        }

        // SwiftPM development builds use the developer's installed uvx.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let directories = path + ["\(home)/.local/bin", "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let uvx = directories.map { URL(fileURLWithPath: $0).appendingPathComponent("uvx") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        return uvx.map { ($0, ["--from", "pymobiledevice3==11.61.0", "--python", "3.14", "python"]) }
    }
}
