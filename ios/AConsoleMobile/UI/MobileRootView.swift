import SwiftUI
import TrackCore
import UniformTypeIdentifiers

@MainActor
public final class MobileSettings: ObservableObject {
    @Published public var loopbackHost: String {
        didSet { UserDefaults.standard.set(loopbackHost, forKey: "ac.mobile.loopback.host") }
    }
    @Published public var loopbackPortText: String {
        didSet { UserDefaults.standard.set(loopbackPortText, forKey: "ac.mobile.loopback.port") }
    }

    public init() {
        self.loopbackHost = UserDefaults.standard.string(forKey: "ac.mobile.loopback.host") ?? "10.7.0.1"
        self.loopbackPortText = UserDefaults.standard.string(forKey: "ac.mobile.loopback.port") ?? "62078"
    }

    public var loopbackPort: UInt16 {
        UInt16(loopbackPortText) ?? 62078
    }

    public var ddiDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("DDI/Restore", isDirectory: true)
    }

    public func makeSessionConfiguration() -> DeviceSession.Configuration {
        let fm = FileManager.default
        let hasManifest = fm.fileExists(atPath: ddiDirectoryURL.appendingPathComponent("BuildManifest.plist").path)
        return DeviceSession.Configuration(host: loopbackHost,
                                           port: loopbackPort,
                                           timeout: .seconds(15),
                                           ddiRestoreDirectory: hasManifest ? ddiDirectoryURL : nil)
    }
}

public struct MobileRootView: View {
    @StateObject private var engine: ReplayEngine
    @StateObject private var keepAlive = LocationKeepAlive()
    @StateObject private var settings = MobileSettings()
    @State private var preflightItems: [PreflightItem] = []
    @State private var importingTrack = false
    @State private var importingPairing = false
    @State private var pairingSummary: PairingStore.Summary?
    @State private var alertMessage: String?

    private let trackTypes = ["gpx", "kmz", "kml"].compactMap { UTType(filenameExtension: $0) } + [.xml]

    public init(connector: any DeviceBridgeConnecting) {
        let session = DeviceSession(connector: connector)
        _engine = StateObject(wrappedValue: ReplayEngine(session: session))
    }

    public var body: some View {
        TabView {
            replayTab
                .tabItem { Label("回放", systemImage: "play.circle.fill") }
            preflightTab
                .tabItem { Label("连接预检", systemImage: "checklist") }
            OnboardingMobileView()
                .tabItem { Label("引导", systemImage: "questionmark.circle") }
            SettingsMobileView(settings: settings,
                               pairingSummary: $pairingSummary,
                               importingPairing: $importingPairing)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .task {
            engine.loadBundledTrack()
            if let data = try? PairingStore.load() {
                pairingSummary = try? PairingStore.validate(data)
            }
            await refreshPreflight()
        }
        .fileImporter(isPresented: $importingTrack, allowedContentTypes: trackTypes) { result in
            if case let .success(url) = result {
                importTrack(url)
            }
        }
        .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.data, .propertyList, .xml]) { result in
            if case let .success(url) = result {
                importPairing(url)
            }
        }
        .alert("提示", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var replayTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TrackPreviewMap(route: engine.route, activePoint: activePoint)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    statusCard

                    trackConfigSection

                    controlsSection
                }
                .padding()
            }
            .navigationTitle("A Console Mobile")
        }
    }

    private var activePoint: TrackPoint? {
        guard let index = engine.pointIndex, engine.timeline.indices.contains(index) else { return nil }
        return engine.timeline[index]
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(engine.statusMessage)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(readbackLabel)
                    .font(.caption)
                    .foregroundStyle(readbackColor)
            }
            if !engine.timeline.isEmpty {
                let completed = engine.pointIndex.map { $0 + 1 } ?? 0
                ProgressView(value: Double(completed), total: Double(max(1, engine.timeline.count)))
                HStack {
                    Text("\(TrackPipeline.formatDuration(engine.elapsed)) / \(TrackPipeline.formatDuration(engine.totalDuration))")
                    Spacer()
                    Text("\(TrackPipeline.formatMeters(engine.simulatedMeters)) / \(TrackPipeline.formatMeters(engine.totalMeters))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if let error = engine.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var trackConfigSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("默认轨迹") { engine.loadBundledTrack() }
                    .buttonStyle(.bordered)
                Button("导入文件") { importingTrack = true }
                    .buttonStyle(.bordered)
                Button("校园跑预设") { engine.applyCampusRunPreset() }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(engine.isPlayingOrPaused)

            Picker("长度模式", selection: $engine.lengthMode) {
                ForEach(LengthMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: engine.lengthMode) { _, _ in engine.rebuildRoute() }
            .disabled(engine.isPlayingOrPaused)

            HStack {
                Text("配速")
                TextField("7:29", text: $engine.paceInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .onChange(of: engine.paceInput) { _, _ in engine.rebuildRoute() }
                if engine.lengthMode == .laps {
                    Text("圈数")
                    TextField("1", text: $engine.lapsInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 54)
                        .onChange(of: engine.lapsInput) { _, _ in engine.rebuildTimeline() }
                } else {
                    Text("公里")
                    TextField("1.50", text: $engine.targetKilometers)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .onChange(of: engine.targetKilometers) { _, _ in engine.rebuildRoute() }
                }
            }
            .disabled(engine.isPlayingOrPaused)
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 10) {
            HStack {
                Button("连接会话") {
                    Task { await connectSession() }
                }
                .buttonStyle(.bordered)
                .disabled(engine.isPlayingOrPaused)

                Button("定位到起点") {
                    keepAlive.requestPermission()
                    keepAlive.start { lat, lon in
                        engine.observeReadbackLocation(latitude: lat, longitude: lon)
                    }
                    Task { await engine.locateStart() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.timeline.isEmpty || engine.isPlayingOrPaused)
            }

            HStack {
                if engine.state == .playing {
                    Button("暂停") { engine.pause() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(engine.state == .paused ? "继续回放" : "开始回放") {
                        keepAlive.requestPermission()
                        keepAlive.start { lat, lon in
                            engine.observeReadbackLocation(latitude: lat, longitude: lon)
                        }
                        engine.startPlayback()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.timeline.isEmpty)
                }

                Button("恢复真实定位", role: .destructive) {
                    Task {
                        await engine.restoreRealLocation()
                        keepAlive.stop()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var preflightTab: some View {
        NavigationStack {
            List {
                ForEach(preflightItems) { item in
                    HStack {
                        statusIcon(for: item.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.body)
                            switch item.status {
                            case .passed:
                                EmptyView()
                            case .warning(let detail), .failed(let detail):
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("连接预检")
            .toolbar {
                Button("重新检查") {
                    Task { await refreshPreflight() }
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(for status: PreflightItem.Status) -> some View {
        switch status {
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var readbackLabel: String {
        switch engine.readbackStatus {
        case .inactive: return "未校验"
        case .verifying: return "校验中"
        case .active(let m): return String(format: "生效 %.0fm", m)
        case .drifting(let m): return String(format: "偏离 %.0fm", m)
        case .unauthorized: return "未授权回读"
        }
    }

    private var readbackColor: Color {
        switch engine.readbackStatus {
        case .active: return .green
        case .drifting, .unauthorized: return .orange
        case .inactive, .verifying: return .secondary
        }
    }

    private func refreshPreflight() async {
        preflightItems = await PreflightChecker.run(
            loopbackHost: settings.loopbackHost,
            loopbackPort: settings.loopbackPort,
            locationAuth: keepAlive.authorizationStatus,
            pendingRestore: engine.pendingRecord
        )
    }

    private func connectSession() async {
        do {
            guard let pairingData = try PairingStore.load() else {
                alertMessage = "请先在「设置」中导入从桌面版导出的配对文件。"
                return
            }
            await engine.connect(pairingPlist: pairingData, configuration: settings.makeSessionConfiguration())
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func importTrack(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        engine.loadTrack(from: url, source: .localFile)
    }

    private func importPairing(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            pairingSummary = try PairingStore.save(data)
            alertMessage = "配对文件已导入钥匙串。"
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

public struct OnboardingMobileView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("首次准备（仅需连一次电脑）") {
                    Label("1. 在 Mac / Windows 上使用 A Console 导出本机配对文件（.mobiledevicepairing）", systemImage: "1.circle")
                    Label("2. 通过 AirDrop 或文件 App 传到本机，在「设置」中导入后删除原文件", systemImage: "2.circle")
                    Label("3. 在 App Store 安装并开启 LocalDevVPN", systemImage: "3.circle")
                }
                Section("户外使用注意事项") {
                    Text("• 需在「设置 → 隐私与安全性 → 开发者模式」开启开发者模式。")
                    Text("• 回放期间请保持 LocalDevVPN 开启，并不要在多任务界面划掉本应用。")
                    Text("• 若设备重启，首次使用需要联网重新挂载开发者磁盘镜像。")
                }
                Section("撤销凭证") {
                    Text("配对文件等同于受信任电脑凭证。如需彻底撤销，请前往「设置 → 通用 → 传输或还原 iPhone → 还原 → 还原位置与隐私」。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("使用引导")
        }
    }
}

public struct SettingsMobileView: View {
    @ObservedObject var settings: MobileSettings
    @Binding var pairingSummary: PairingStore.Summary?
    @Binding var importingPairing: Bool

    public init(settings: MobileSettings,
                pairingSummary: Binding<PairingStore.Summary?>,
                importingPairing: Binding<Bool>) {
        self.settings = settings
        _pairingSummary = pairingSummary
        _importingPairing = importingPairing
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("配对凭证（仅存本机钥匙串）") {
                    if let summary = pairingSummary {
                        Text("HostID: \(summary.hostIDMasked)")
                        Text("大小: \(summary.byteCount) 字节")
                        Button("替换配对文件") { importingPairing = true }
                        Button("删除配对文件", role: .destructive) {
                            try? PairingStore.delete()
                            pairingSummary = nil
                        }
                    } else {
                        Text("尚未导入配对文件").foregroundStyle(.secondary)
                        Button("导入 .mobiledevicepairing") { importingPairing = true }
                    }
                }
                Section("LocalDevVPN 回环") {
                    TextField("回环 IP", text: $settings.loopbackHost)
                    TextField("端口", text: $settings.loopbackPortText)
                }
            }
            .navigationTitle("设置")
        }
    }
}
