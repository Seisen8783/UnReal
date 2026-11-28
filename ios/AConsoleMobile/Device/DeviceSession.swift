import Foundation

/// Serializes device session operations and handles exponential-backoff reconnection
/// on transient loopback or RemoteXPC tunnel drops.
public actor DeviceSession {
    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16
        public var timeout: Duration
        public var ddiRestoreDirectory: URL?

        public init(host: String = "10.7.0.1",
                    port: UInt16 = 62078,
                    timeout: Duration = .seconds(15),
                    ddiRestoreDirectory: URL? = nil) {
            self.host = host
            self.port = port
            self.timeout = timeout
            self.ddiRestoreDirectory = ddiRestoreDirectory
        }
    }

    private let connector: any DeviceBridgeConnecting
    private var configuration: Configuration
    private var pairingPlist: Data?
    private var handle: (any DeviceBridgeSessionHandle)?
    private var channelOpen = false

    public init(connector: any DeviceBridgeConnecting, configuration: Configuration = .init()) {
        self.connector = connector
        self.configuration = configuration
    }

    public func updateConfiguration(_ configuration: Configuration, pairingPlist: Data?) {
        self.configuration = configuration
        self.pairingPlist = pairingPlist
    }

    public func connect(pairingPlist: Data) async throws -> BridgeDeviceInfo {
        self.pairingPlist = pairingPlist
        await close()

        let session = try await connector.openLoopbackSession(host: configuration.host,
                                                              port: configuration.port,
                                                              pairingPlist: pairingPlist,
                                                              timeout: configuration.timeout)
        self.handle = session
        var info = try await session.deviceInfo()
        guard info.developerMode else {
            await close()
            throw BridgeError(code: .developerModeDisabled, message: "请在 iPhone「设置 → 隐私与安全性」开启开发者模式。")
        }

        if !info.ddiMounted, let ddiDir = configuration.ddiRestoreDirectory {
            try await session.mountDDI(restoreDirectory: ddiDir, timeout: .seconds(90))
            info = try await session.deviceInfo()
        }

        try await session.openLocationChannel()
        channelOpen = true
        return info
    }

    public func setLocation(latitude: Double, longitude: Double) async throws {
        if let handle, channelOpen {
            do {
                try await handle.setLocation(latitude: latitude, longitude: longitude)
                return
            } catch let error as BridgeError where error.isTransientConnectionError {
                try await reconnectWithBackoff()
            }
        } else {
            try await reconnectWithBackoff()
        }

        guard let handle else {
            throw BridgeError(code: .tunnel, message: "设备会话未连接。")
        }
        try await handle.setLocation(latitude: latitude, longitude: longitude)
    }

    public func clearLocation() async throws {
        if handle == nil {
            try await reconnectWithBackoff()
        }
        guard let handle else {
            throw BridgeError(code: .tunnel, message: "无法连接设备以恢复真实定位。")
        }
        if !channelOpen {
            try await handle.openLocationChannel()
            channelOpen = true
        }
        try await handle.clearLocation()
    }

    public func ping() async throws {
        guard let handle else {
            throw BridgeError(code: .tunnel, message: "设备会话未连接。")
        }
        try await handle.ping()
    }

    public func close() async {
        channelOpen = false
        if let handle {
            self.handle = nil
            await handle.close()
        }
    }

    private func reconnectWithBackoff() async throws {
        guard let pairingPlist else {
            throw BridgeError(code: .pairing, message: "缺少配对文件，请重新导入。")
        }
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]
        var lastError: Error?

        for delay in delays {
            try Task.checkCancellation()
            do {
                _ = try await connect(pairingPlist: pairingPlist)
                return
            } catch let error as BridgeError where !error.isTransientConnectionError {
                throw error
            } catch {
                lastError = error
                try await Task.sleep(for: delay)
            }
        }
        throw lastError ?? BridgeError(code: .unreachable, message: "回环重连失败，请确认 LocalDevVPN 与 Wi-Fi 已连接。")
    }
}
