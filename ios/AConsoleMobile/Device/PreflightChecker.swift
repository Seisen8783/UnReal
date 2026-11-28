import CoreLocation
import Foundation
import Network

public struct PreflightItem: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case passed
        case warning(String)
        case failed(String)
    }

    public let id: String
    public let title: String
    public let status: Status

    public init(id: String, title: String, status: Status) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public enum PreflightChecker {
    public static func run(loopbackHost: String = "10.7.0.1",
                           loopbackPort: UInt16 = 62078,
                           locationAuth: CLAuthorizationStatus,
                           pendingRestore: PendingRestoreRecord?) async -> [PreflightItem] {
        var items: [PreflightItem] = []

        let osOK = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 0)
        )
        items.append(PreflightItem(
            id: "ios-version",
            title: "系统版本 ≥ 17.4",
            status: osOK ? .passed : .failed("当前系统版本低于要求，建议使用桌面版。")
        ))

        let hasPairing = PairingStore.hasPairing()
        items.append(PreflightItem(
            id: "pairing",
            title: "配对凭证",
            status: hasPairing ? .passed : .failed("未导入配对文件，请先从桌面版导出并导入。")
        ))

        let wifiReady = await checkWiFiInterface()
        items.append(PreflightItem(
            id: "wifi",
            title: "Wi-Fi 接口",
            status: wifiReady ? .passed : .warning("未检测到 Wi-Fi 连接；户外实测建议连接热点以稳定本地回环。")
        ))

        let reachable = await probeLoopback(host: loopbackHost, port: loopbackPort)
        items.append(PreflightItem(
            id: "loopback",
            title: "LocalDevVPN 回环 (\(loopbackHost):\(loopbackPort))",
            status: reachable ? .passed : .failed("无法连上本机回环，请先打开 LocalDevVPN。")
        ))

        let authOK: Bool
        #if os(iOS)
        authOK = locationAuth == .authorizedAlways || locationAuth == .authorizedWhenInUse
        #else
        authOK = locationAuth == .authorizedAlways || locationAuth == .authorized
        #endif
        items.append(PreflightItem(
            id: "location-auth",
            title: "定位权限（后台保活与回读）",
            status: authOK ? .passed : .warning("未授权定位权限，后台保活与生效回读将受限。")
        ))

        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            items.append(PreflightItem(
                id: "low-power",
                title: "低电量模式",
                status: .warning("低电量模式可能限制后台保活，建议回放期间关闭。")
            ))
        }

        if pendingRestore != nil {
            items.append(PreflightItem(
                id: "pending-restore",
                title: "上次模拟恢复状态",
                status: .warning("上次模拟未正常退出，请先点击「恢复真实定位」。")
            ))
        }

        return items
    }

    private static func checkWiFiInterface() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.unreal.console.mobile.wifi-check")
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.usesInterfaceType(.wifi))
            }
            monitor.start(queue: queue)
        }
    }

    public static func probeLoopback(host: String, port: UInt16, timeoutSeconds: Double = 2.0) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.unreal.console.mobile.loopback-probe")
            var finished = false

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: false)
            }
            timer.resume()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !finished else { return }
                    finished = true
                    timer.cancel()
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    guard !finished else { return }
                    finished = true
                    timer.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}
