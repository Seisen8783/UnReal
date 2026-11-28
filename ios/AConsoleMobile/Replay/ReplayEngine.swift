import Foundation
import TrackCore

public enum ReplayState: Equatable, Sendable {
    case idle
    case preflight
    case blocked(String)
    case ready
    case atStart
    case playing
    case paused
    case reconnecting
    case finished
    case restoring
    case pendingRestore
}

public enum ReadbackStatus: Equatable, Sendable {
    case inactive
    case verifying
    case active(accuracyMeters: Double)
    case drifting(metersApart: Double)
    case unauthorized
}

/// Coordinates track preparation, monotonic-clock playback, pause keep-alive,
/// seek jumps, return-to-start, and pending-restore recovery on iOS.
@MainActor
public final class ReplayEngine: ObservableObject {
    @Published public private(set) var state: ReplayState = .idle
    @Published public private(set) var route: TrackRoute?
    @Published public private(set) var loop: LoopRoute?
    @Published public private(set) var timeline: [TrackPoint] = []
    @Published public private(set) var timelineCumulative: [Double] = []
    @Published public private(set) var pointIndex: Int?
    @Published public private(set) var elapsed: Double = 0
    @Published public private(set) var statusMessage = "请先完成连接检查并选择轨迹"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var pendingRecord: PendingRestoreRecord?
    @Published public private(set) var readbackStatus: ReadbackStatus = .inactive

    @Published public var trackSource: TrackSource = .bundled
    @Published public var coordinateSystem: CoordinateSystem = .wgs84
    @Published public var reportAlignment: ReportAlignment = .asIs
    @Published public var calibration: CalibrationOffset = .zero
    @Published public var useCenterline: Bool = true
    @Published public var lengthMode: LengthMode = .laps
    @Published public var paceInput: String = ReplayPace.format(KMLRoute.defaultPace)
    @Published public var lapsInput: String = "1"
    @Published public var targetKilometers: String = ""

    private let session: DeviceSession
    private let pendingStore: any PendingRestoreStoring
    private var originalRoute: TrackRoute?
    private var geometryPace = KMLRoute.defaultPace
    private var appliedPace = KMLRoute.defaultPace
    private var playbackTask: Task<Void, Never>?
    private var lastWrittenPoint: TrackPoint?
    private var lastMatchedAt: ContinuousClock.Instant?

    public init(session: DeviceSession, pendingStore: any PendingRestoreStoring = UserDefaultsPendingRestoreStore()) {
        self.session = session
        self.pendingStore = pendingStore
        self.pendingRecord = pendingStore.load()
        if pendingRecord != nil {
            self.state = .pendingRestore
            self.statusMessage = "检测到上次模拟未正常结束，请先恢复真实定位"
        }
    }

    public var isPlayingOrPaused: Bool {
        state == .playing || state == .paused || state == .reconnecting
    }

    public var totalDuration: Double { timeline.last?.offset ?? 0 }

    public var totalMeters: Double {
        if let target = targetMeters { return target }
        return TrackMetrics.length(route?.points ?? []) * Double(lapCount ?? 1)
    }

    public var simulatedMeters: Double {
        guard !timeline.isEmpty, !timelineCumulative.isEmpty else { return 0 }
        let idx = min(max(0, pointIndex ?? 0), min(timeline.count, timelineCumulative.count) - 1)
        return timelineCumulative[idx]
    }

    public var targetMeters: Double? {
        guard lengthMode == .kilometers else { return nil }
        let trimmed = targetKilometers.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite, value > 0, value <= 1000 else {
            return nil
        }
        return (value * 1000).rounded()
    }

    public var lapCount: Int? {
        if lengthMode == .kilometers { return 1 }
        guard useCenterline, loop != nil else { return 1 }
        guard let value = Int(lapsInput), (1...99).contains(value) else { return nil }
        return value
    }

    public func loadBundledTrack() {
        guard let url = TrackSource.bundledURL else {
            errorMessage = "找不到内置默认轨迹。"
            return
        }
        trackSource = .bundled
        loadTrack(from: url)
    }

    public func loadTrack(from url: URL, source: TrackSource? = nil) {
        if let source { trackSource = source }
        do {
            let loaded = try TrackRoute.load(url)
            originalRoute = loaded
            loop = LoopRoute.fit(loaded)
            errorMessage = nil
            rebuildRoute()
            statusMessage = "已载入轨迹：\(loaded.name)"
        } catch {
            originalRoute = nil
            loop = nil
            route = nil
            setTimeline([])
            errorMessage = error.localizedDescription
        }
    }

    public func applyCampusRunPreset() {
        loadBundledTrack()
        calibration = CalibrationOffset(eastMeters: CampusRunPreset.eastMeters,
                                        northMeters: CampusRunPreset.northMeters)
        reportAlignment = .asIs
        if let pace = ReplayPace.parse(CampusRunPreset.pace) {
            geometryPace = pace
            appliedPace = pace
            paceInput = CampusRunPreset.pace
        }
        lengthMode = .kilometers
        if targetKilometers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targetKilometers = CampusRunPreset.kilometers
        }
        rebuildRoute()
        statusMessage = "已套用校园跑预设"
    }

    public func rebuildRoute() {
        guard let originalRoute else { return }
        if let parsedPace = ReplayPace.parse(paceInput) {
            geometryPace = parsedPace
            appliedPace = parsedPace
        }
        let effectiveSystem: CoordinateSystem = trackSource == .bundled ? .wgs84 : coordinateSystem
        let built = TrackPipeline.build(original: originalRoute,
                                        coordinateSystem: effectiveSystem,
                                        reportAlignment: reportAlignment,
                                        calibration: calibration,
                                        useCenterline: useCenterline,
                                        geometryPaceSeconds: geometryPace,
                                        targetMeters: targetMeters)
        if let fitted = built.loop {
            loop = fitted
        }
        route = built.route
        rebuildTimeline()
    }

    public func rebuildTimeline() {
        pointIndex = nil
        elapsed = 0
        guard let route, !route.points.isEmpty else {
            setTimeline([])
            return
        }
        let laps = lengthMode == .kilometers ? 1 : (lapCount ?? 1)
        setTimeline(ReplayTimeline.build(route, laps: max(1, laps),
                                         scale: Double(appliedPace) / Double(geometryPace)))
    }

    public func connect(pairingPlist: Data, configuration: DeviceSession.Configuration) async {
        state = .preflight
        errorMessage = nil
        statusMessage = "正在通过本机回环连接设备…"
        await session.updateConfiguration(configuration, pairingPlist: pairingPlist)
        do {
            let info = try await session.connect(pairingPlist: pairingPlist)
            state = pendingRecord == nil ? .ready : .pendingRestore
            statusMessage = "已连接 \(info.deviceName) (iOS \(info.productVersion))"
        } catch {
            state = .blocked(error.localizedDescription)
            errorMessage = error.localizedDescription
            statusMessage = "连接失败"
        }
    }

    public func locateStart() async {
        guard let first = timeline.first else { return }
        errorMessage = nil
        do {
            try await writePoint(first)
            pointIndex = 0
            elapsed = 0
            state = .atStart
            statusMessage = "已定位到轨迹起点"
        } catch {
            handleWriteFailure(error)
        }
    }

    public func startPlayback(fromIndex startIdx: Int? = nil) {
        guard !timeline.isEmpty else { return }
        playbackTask?.cancel()
        let begin = min(max(0, startIdx ?? pointIndex ?? 0), timeline.count - 1)
        state = .playing
        errorMessage = nil
        statusMessage = "正在回放轨迹"

        playbackTask = Task { [weak self] in
            await self?.runPlaybackLoop(from: begin)
        }
    }

    public func pause() {
        guard state == .playing else { return }
        playbackTask?.cancel()
        state = .paused
        statusMessage = "已暂停（保持当前位置）"
        let current = timeline[min(max(0, pointIndex ?? 0), timeline.count - 1)]
        playbackTask = Task { [weak self] in
            await self?.runPauseKeepAlive(holding: current)
        }
    }

    public func seek(to seconds: Double) async {
        guard !timeline.isEmpty else { return }
        var lo = 0
        var hi = timeline.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if timeline[mid].offset < seconds { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 && seconds - timeline[lo - 1].offset < timeline[lo].offset - seconds { lo -= 1 }
        pointIndex = lo
        elapsed = timeline[lo].offset
        if isPlayingOrPaused || state == .atStart {
            if state == .playing {
                startPlayback(fromIndex: lo)
            } else {
                try? await writePoint(timeline[lo])
            }
        }
    }

    public func restoreRealLocation() async {
        playbackTask?.cancel()
        playbackTask = nil
        state = .restoring
        statusMessage = "正在恢复真实定位…"
        do {
            try await session.clearLocation()
            pendingStore.clear()
            pendingRecord = nil
            lastWrittenPoint = nil
            readbackStatus = .inactive
            pointIndex = nil
            elapsed = 0
            state = .ready
            statusMessage = "已恢复真实定位"
        } catch {
            state = .pendingRestore
            errorMessage = error.localizedDescription
            statusMessage = "恢复失败，请重试"
        }
    }

    public func observeReadbackLocation(latitude: Double, longitude: Double) {
        guard let target = lastWrittenPoint else { return }
        let readback = TrackPoint(latitude: latitude, longitude: longitude, offset: 0)
        let delta = TrackMetrics.meters(readback, target)
        let now = ContinuousClock.now
        if delta <= 15 {
            lastMatchedAt = now
            readbackStatus = .active(accuracyMeters: delta)
        } else if let lastMatchedAt, now - lastMatchedAt > .seconds(10) {
            readbackStatus = .drifting(metersApart: delta)
        } else {
            readbackStatus = .verifying
        }
    }

    private func runPlaybackLoop(from startIndex: Int) async {
        let clock = ContinuousClock()
        let baseOffset = timeline[startIndex].offset
        let t0 = clock.now
        var cursor = startIndex

        while !Task.isCancelled && cursor < timeline.count {
            let targetElapsed = baseOffset + durationSeconds(clock.now - t0)
            while cursor + 1 < timeline.count && timeline[cursor + 1].offset <= targetElapsed {
                cursor += 1
            }

            let point = timeline[cursor]
            do {
                try await writePoint(point)
                pointIndex = cursor
                elapsed = point.offset
                if state != .playing { state = .playing }
            } catch {
                if Task.isCancelled { return }
                handleWriteFailure(error)
                return
            }

            if cursor == timeline.count - 1 {
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }

        guard !Task.isCancelled else { return }
        if let first = timeline.first {
            try? await writePoint(first)
            pointIndex = 0
            elapsed = 0
        }
        state = .finished
        statusMessage = "回放结束，已返回起点（点击「恢复真实定位」结束模拟）"
    }

    private func runPauseKeepAlive(holding point: TrackPoint) async {
        while !Task.isCancelled && state == .paused {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled || state != .paused { break }
            do {
                try await writePoint(point)
            } catch {
                if !Task.isCancelled {
                    handleWriteFailure(error)
                }
                return
            }
        }
    }

    private func writePoint(_ point: TrackPoint) async throws {
        let record = PendingRestoreRecord(writtenAt: Date(),
                                          latitude: point.latitude,
                                          longitude: point.longitude)
        pendingStore.save(record)
        pendingRecord = record
        lastWrittenPoint = point
        if readbackStatus == .inactive {
            readbackStatus = .verifying
        }
        try await session.setLocation(latitude: point.latitude, longitude: point.longitude)
    }

    private func handleWriteFailure(_ error: Error) {
        errorMessage = error.localizedDescription
        state = .pendingRestore
        statusMessage = "连接中断，请保持 LocalDevVPN 开启后重连或恢复定位"
    }

    private func setTimeline(_ points: [TrackPoint]) {
        timeline = points
        timelineCumulative = TrackMetrics.cumulativeDistances(points)
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
