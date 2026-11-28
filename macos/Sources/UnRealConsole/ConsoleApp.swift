import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ConsoleApp: App {
    @NSApplicationDelegateAdaptor(ConsoleDelegate.self) private var delegate

    var body: some Scene {
        Window(AppInfo.name, id: "console") {
            StartupView(model: .shared)
                .frame(minWidth: 780, minHeight: 510)
        }
        .defaultSize(width: 960, height: 590)
    }
}

final class ConsoleDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ConsoleModel.shared.prepareToQuit({ sender.reply(toApplicationShouldTerminate: true) }) {
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ConsoleView: View {
    @ObservedObject var model: ConsoleModel
    @State private var importing = false
    @State private var showingGuide = false
    @State private var dragTarget = false
    @State private var scrubTime: Double?
    private let trackTypes = ["gpx", "kmz", "kml"].compactMap { UTType(filenameExtension: $0) } + [.xml]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            workspace
        }
        .sheet(isPresented: $showingGuide) {
            OnboardingView(firstLaunch: false) { showingGuide = false }
                .frame(width: 620)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: trackTypes) { result in
            if case let .success(url) = result { open(url) }
        }
        .task {
            model.loadBundledTrack()
            model.refresh()
        }
    }

    private var sidebar: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(AppInfo.name, systemImage: "location.circle.fill")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(Color.accentColor)
                Text(AppVersion.current.display)
                    .fixedSize(horizontal: true, vertical: false)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Link(destination: AppInfo.repositoryURL) {
                Label("GitHub Repository", systemImage: "arrow.up.right.square")
            }

            Button { showingGuide = true } label: {
                Label("使用引导", systemImage: "questionmark.circle")
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("USB 设备").font(.headline)
                    Spacer()
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新设备列表")
                        .accessibilityLabel("刷新设备列表")
                        .disabled(model.busy)
                }
                if model.devices.isEmpty {
                    // 未连接设备时不显示提示文字，列表区留白。
                    EmptyView()
                } else {
                    Picker("iPhone", selection: $model.deviceID) {
                        ForEach(model.devices) { device in
                            Text(device.name + " · " + String(device.id.suffix(5))).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.busy)
                    if let device = model.devices.first(where: { $0.id == model.deviceID }) {
                        Text([device.version.isEmpty ? nil : "iOS " + device.version, device.detail]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("轨迹文件").font(.headline)
                Picker("轨迹来源", selection: trackSourceBinding) {
                    ForEach(TrackSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .labelsHidden()
                .disabled(model.busy)
                .help("默认路径为内置的校园跑走廊；本地导入会打开文件选择器。")
                Picker("坐标基准", selection: Binding(get: { model.coordinateSystem },
                                                   set: { model.setCoordinateSystem($0) })) {
                    ForEach(CoordinateSystem.allCases) { system in
                        Text(system.shortName).tag(system)
                    }
                }
                .disabled(model.busy || model.trackSource == .bundled)
                .help(model.trackSource == .bundled
                      ? "内置默认轨迹的基准固定为 WGS-84。导入自己的轨迹后才能选择基准。"
                      : "轨迹文件使用的坐标系：\(model.coordinateSystem.displayName)。设备只接受 WGS-84，选错会导致位置整体偏移。")
                Picker("上报口径", selection: Binding(get: { model.reportAlignment },
                                                  set: { model.setReportAlignment($0) })) {
                    ForEach(ReportAlignment.allCases) { alignment in
                        Text(alignment.displayName).tag(alignment)
                    }
                }
                .disabled(model.busy)
                .help(model.reportAlignment.help)
                if let error = model.reportLandingErrorMeters {
                    Text("估算上报坐标与轨迹相差 \(Int(error.rounded())) 米")
                        .font(.caption)
                        .foregroundStyle(error > 50 ? .orange : .secondary)
                        .help("假设接收方将坐标转换为 GCJ-02 时的估算；实际处理方式需独立验证。")
                }
                calibrationFields
                if model.route?.untimedSegments != nil {
                    HStack {
                        Text("回放配速")
                        TextField("7:29", text: Binding(get: { model.paceInput }, set: { model.setPace($0) }))
                            .textFieldStyle(.roundedBorder)
                            .monospacedDigit()
                            .frame(width: 60)
                            .accessibilityLabel("回放配速，分秒")
                            .disabled(!model.canEditSettings)
                        Text("分/公里").foregroundStyle(.secondary)
                    }
                    if model.invalidPace {
                        Text("请输入分:秒，例如 7:29。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if let loop = model.loop {
                    Toggle("使用单圈中线", isOn: Binding(get: { model.useCenterline }, set: { model.setCenterline($0) }))
                        .disabled(model.busy)
                    if model.useCenterline {
                        Text("由 \(loop.sourceLaps) 圈拟合 · 每圈约 \(Int(loop.meters.rounded())) 米")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                lengthModeFields
                if model.paused && model.settingsChanged && !model.invalidPace &&
                    model.lapCount != nil && !model.lapBelowCurrent && !model.lapLimitExceeded {
                    Text("正在同步设置…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let issue = model.importError ?? model.route?.timingIssue {
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
            }

            Button { model.applyCampusRunPreset() } label: {
                Label("校园跑模式", systemImage: "flag.checkered")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(model.busy)
            .help("一键套用校园跑设置：内置轨迹、标定偏移 东 -17.2 / 北 -11.5、上报口径「原样」、配速 8'00\"、1.50 km")

            Spacer()
            if let serial = model.pendingID, !model.busy {
                Label("设备 …\(serial.suffix(5)) 定位状态待确认", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Button { model.locateStart() } label: { Label("接管定位权限", systemImage: "mappin.circle") }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.white)
                .disabled(!model.canAnchor)
            Button { model.restore() } label: { Label("重置位置", systemImage: "location.slash") }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.white)
                .disabled(!model.canRestore)
        }
        .padding(22)
        }
        .frame(width: 255)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }

    /// 轨迹来源下拉框。
    ///
    /// 选「本地导入」时唤起 Finder 选文件；选「默认路径」时载入内置轨迹。
    /// 选完之后下拉框回到「默认路径」——否则无法再次触发同一个选项。
    private var trackSourceBinding: Binding<TrackSource> {
        Binding(get: { model.trackSource },
                set: { source in
                    switch source {
                    case .bundled:
                        model.loadBundledTrack()
                    case .localFile:
                        importing = true
                    }
                })
    }

    /// 长度计量：下拉选「总圈数 / 公里数」，右侧填对应数值。
    ///
    /// 原来用两行复选框互斥，侧栏宽度不够时文字和输入框互相挤压；
    /// 改成一行 Picker + 一个输入框，宽度稳定，也不会出现两个都勾选的歧义。
    private var lengthModeFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("长度计量", selection: Binding(
                    get: { model.lengthMode },
                    set: { model.setLengthMode($0) })) {
                    ForEach(LengthMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 88)
                .disabled(model.busy)
                .accessibilityLabel("长度计量方式")

                if model.lengthMode == .laps {
                    TextField("1", text: Binding(get: { model.lapsInput }, set: { model.setLaps($0) }))
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .frame(width: 50)
                        .accessibilityLabel("总圈数")
                        .disabled(!model.canEditSettings)
                    Text("圈").foregroundStyle(.secondary)
                } else {
                    TextField("1.50", text: Binding(get: { model.targetKilometers },
                                                    set: { model.setTargetKilometers($0) }))
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .frame(width: 64)
                        .accessibilityLabel("目标公里数")
                        .disabled(model.busy)
                    Text("km").foregroundStyle(.secondary)
                }
            }
            if model.lengthMode == .laps {
                if model.lapBelowCurrent {
                    Text("至少为当前第 \(model.currentLap) 圈。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if model.lapCount == nil || model.lapLimitExceeded {
                    Text(model.lapLimitExceeded ? "轨迹过长，请减少圈数。" : "请输入 1 至 99 圈。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if model.invalidKilometers {
                Text("请输入 0 以上的公里数，最多 1000。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 米数进度：已模拟 / 本次总计。
    ///
    /// 格式按距离大小自适应：
    /// - 一千米以内：`111.2m/400.0m`
    /// - 超过一千米：`1.23km/1.50km`
    private var meterProgress: some View {
        Text("\(formatMeters(model.simulatedMeters))/\(formatMeters(model.totalMeters))")
            .foregroundStyle(.secondary)
            .accessibilityLabel("已模拟 \(formatMeters(model.simulatedMeters))，总计 \(formatMeters(model.totalMeters))")
    }

    /// 米数的显示格式。千米以下保留一位小数，更长的用公里。
    private func formatMeters(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "0m" }
        if meters < 1000 {
            return String(format: "%.1fm", meters)
        }
        return String(format: "%.2fkm", meters / 1000)
    }


    private var calibrationFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标定偏移（米）")
            HStack(spacing: 6) {
                TextField("东", text: eastBinding)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 62)
                    .accessibilityLabel("标定偏移东向，米")
                Text("东").foregroundStyle(.secondary)
                TextField("北", text: northBinding)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 62)
                    .accessibilityLabel("标定偏移北向，米")
                Text("北").foregroundStyle(.secondary)
            }
            .disabled(model.busy)
            Text("把轨迹平移到服务端围栏的位置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var eastBinding: Binding<String> {
        Binding(get: { format(model.calibration.eastMeters) },
                set: { value in
                    model.setCalibration(eastMeters: parse(value) ?? model.calibration.eastMeters,
                                         northMeters: model.calibration.northMeters)
                })
    }

    private var northBinding: Binding<String> {
        Binding(get: { format(model.calibration.northMeters) },
                set: { value in
                    model.setCalibration(eastMeters: model.calibration.eastMeters,
                                         northMeters: parse(value) ?? model.calibration.northMeters)
                })
    }

    private func format(_ value: Double) -> String {
        value == 0 ? "0" : String(format: "%.1f", value)
    }

    private func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, abs(value) <= 100_000 else { return nil }
        return value
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.campusRunPresetApplied {
                CampusRunChecklist()
            }
            HStack(alignment: .firstTextBaseline) {
                Text("轨迹回放").font(.title2.weight(.semibold))
                Spacer()
                if let route = model.route {
                    if model.playing && model.hasStarted && !model.paused {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("预计 \(context.date.addingTimeInterval(max(0, model.totalDuration - model.elapsed - context.date.timeIntervalSince(model.elapsedUpdatedAt))), format: .dateTime.hour().minute()) 完成")
                        }
                        .font(.callout)
                    } else if model.playing && model.paused && model.hasStarted {
                        Text("已暂停，预计时间待续播").font(.callout).foregroundStyle(.secondary)
                    }
                    if model.showsLap {
                        Text("第 \(model.currentLap) / \(model.timelineLaps) 圈")
                            .fontWeight(.semibold)
                    }
                    Text("\(model.timeline.count) 点")
                    if route.timingIssue == nil { Text(duration(model.totalDuration)) }
                    meterProgress
                }
            }
            .monospacedDigit()

            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
                if let route = model.route {
                    RouteCanvas(route: route, activeIndex: model.previewIndex)
                        .accessibilityLabel("轨迹折线预览")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("将 GPX、KMZ 或 KML 拖到这里").font(.headline)
                        Button("选择文件") { importing = true }.disabled(model.busy)
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(dragTarget ? Color.accentColor : Color(nsColor: .separatorColor))
                    .allowsHitTesting(false)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.busy, let url = urls.first, url.isFileURL else { return false }
                open(url)
                return true
            } isTargeted: { dragTarget = $0 && !model.busy }

            VStack(alignment: .leading, spacing: 7) {
                if !model.timeline.isEmpty {
                    let completed = model.pointIndex.map { $0 + 1 } ?? 0
                    Slider(value: Binding(get: { scrubTime ?? model.elapsed }, set: { value in
                        if scrubTime != nil { scrubTime = value }
                        else { model.seek(to: value) }
                    }), in: 0...max(0.001, model.totalDuration), onEditingChanged: { editing in
                        if editing {
                            scrubTime = model.elapsed
                        } else if let selected = scrubTime {
                            model.seek(to: selected)
                            scrubTime = nil
                        }
                    })
                    .disabled(!model.canSeek)
                    .accessibilityLabel("回放时间")
                    HStack {
                        Text("\(duration(scrubTime ?? model.elapsed)) / \(duration(model.totalDuration))")
                        Spacer()
                        if let index = model.pointIndex, model.timeline.indices.contains(index) {
                            let point = model.timeline[index]
                            Text(String(format: "%.6f, %.6f", point.latitude, point.longitude))
                        }
                        Text("\(completed) / \(model.timeline.count)")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                HStack {
                    if model.busy && model.pointIndex == nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.status).font(.callout)
                    Spacer()
                    if model.playing && !model.paused {
                        Button("暂停") { model.pause() }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(.white)
                            .disabled(model.stopping)
                    }
                    Button("从起点重播") { model.restart() }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(.white)
                        .disabled(!model.canRestart)
                    Button { model.start() } label: { Label(model.paused && model.hasStarted ? "继续回放" : "开始回放", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(.white)
                        .disabled(!model.canPlay)
                }
                if let error = model.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(24)
    }

    private func open(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        model.loadLocalTrack(url)
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct CampusRunChecklist: View {
    @State private var done: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("校园跑流程", systemImage: "flag.checkered")
                    .font(.headline)
                Spacer()
                Text("点一下勾掉已完成的步骤")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(CampusRunPreset.steps.enumerated()), id: \.offset) { index, step in
                Button { toggle(index) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: done.contains(index) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(done.contains(index) ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                                .strikethrough(done.contains(index))
                                .font(.callout)
                            Text(step.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(CampusRunPreset.cautions, id: \.self) { caution in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(caution)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 14) {
                setting("偏移", "东 \(format(CampusRunPreset.eastMeters)) / 北 \(format(CampusRunPreset.northMeters)) m")
                setting("口径", "原样")
                setting("配速", "\(CampusRunPreset.pace)\" / 公里")
                setting("目标", "\(CampusRunPreset.kilometers) km")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func setting(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).monospacedDigit()
        }
    }

    private func format(_ value: Double) -> String {
        value == 0 ? "0" : String(format: "%.1f", value)
    }

    private func toggle(_ index: Int) {
        if done.contains(index) { done.remove(index) } else { done.insert(index) }
    }
}

private struct RouteCanvas: View {
    let route: TrackRoute
    let activeIndex: Int?

    var body: some View {
        Canvas { context, size in
            let width = max(1, size.width - 60)
            let height = max(1, size.height - 60)
            let latitudes = route.points.map(\.latitude)
            let correction = max(0.01, cos((latitudes.min()! + latitudes.max()!) * .pi / 360))
            let firstLongitude = route.points[0].longitude
            let xs = route.points.map {
                (($0.longitude - firstLongitude + 540).truncatingRemainder(dividingBy: 360) - 180) * correction
            }
            let minX = xs.min()!, maxX = xs.max()!
            let minY = latitudes.min()!, maxY = latitudes.max()!
            let scale = min(width / max(0.000001, maxX - minX), height / max(0.000001, maxY - minY))
            let points = xs.indices.map { index in
                CGPoint(x: size.width / 2 + (xs[index] - (minX + maxX) / 2) * scale,
                        y: size.height / 2 - (latitudes[index] - (minY + maxY) / 2) * scale)
            }

            var grid = Path()
            for x in stride(from: 20.0, to: size.width, by: 24) {
                for y in stride(from: 20.0, to: size.height, by: 24) {
                    grid.addEllipse(in: CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
            context.fill(grid, with: .color(.secondary.opacity(0.18)))

            var track = Path()
            var completed = Path()
            for index in points.indices {
                if route.segmentStarts.contains(index) {
                    track.move(to: points[index])
                    if index <= (activeIndex ?? -1) { completed.move(to: points[index]) }
                } else {
                    track.addLine(to: points[index])
                    if index <= (activeIndex ?? -1) { completed.addLine(to: points[index]) }
                }
            }
            let stroke = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            context.stroke(track, with: .color(.accentColor.opacity(0.38)), style: stroke)
            context.stroke(completed, with: .color(.accentColor), style: stroke)

            let markers: [(CGPoint, Color)] = [(points[0], .green), (points[points.count - 1], .orange)]
            for (point, color) in markers {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)),
                             with: .color(color))
            }
            if let activeIndex, points.indices.contains(activeIndex) {
                let point = points[activeIndex]
                let ring = Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
                context.fill(ring, with: .color(.accentColor))
                context.stroke(ring, with: .color(.white), lineWidth: 2)
            }
        }
    }
}
