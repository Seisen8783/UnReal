import Foundation

public struct BridgeDeviceInfo: Sendable, Equatable {
    public let productVersion: String
    public let deviceName: String
    public let developerMode: Bool
    public let ddiMounted: Bool

    public init(productVersion: String, deviceName: String, developerMode: Bool, ddiMounted: Bool) {
        self.productVersion = productVersion
        self.deviceName = deviceName
        self.developerMode = developerMode
        self.ddiMounted = ddiMounted
    }
}

public enum BridgeErrorCode: Int32, Sendable {
    case ok = 0
    case unreachable = 1
    case pairing = 2
    case developerModeDisabled = 3
    case ddi = 4
    case tunnel = 5
    case dvt = 6
    case timeout = 7
    case invalidArgument = 8
}

public struct BridgeError: LocalizedError, Sendable {
    public let code: BridgeErrorCode
    public let message: String

    public init(code: BridgeErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        message
    }

    public var isTransientConnectionError: Bool {
        switch code {
        case .unreachable, .tunnel, .dvt, .timeout:
            return true
        case .ok, .pairing, .developerModeDisabled, .ddi, .invalidArgument:
            return false
        }
    }
}

/// Abstraction over the native Rust `ACBridge` C FFI so replay logic and state machines
/// can be unit-tested deterministically without a physical device.
public protocol DeviceBridgeSessionHandle: Sendable {
    func deviceInfo() async throws -> BridgeDeviceInfo
    func mountDDI(restoreDirectory: URL, timeout: Duration) async throws
    func openLocationChannel() async throws
    func setLocation(latitude: Double, longitude: Double) async throws
    func clearLocation() async throws
    func ping() async throws
    func close() async
}

public protocol DeviceBridgeConnecting: Sendable {
    func openLoopbackSession(host: String, port: UInt16, pairingPlist: Data, timeout: Duration) async throws -> any DeviceBridgeSessionHandle
}

#if canImport(ACBridge)
import ACBridge

public final class ACBridgeConnector: DeviceBridgeConnecting {
    public init() {}

    public func openLoopbackSession(host: String, port: UInt16, pairingPlist: Data, timeout: Duration) async throws -> any DeviceBridgeSessionHandle {
        try await Task.detached(priority: .userInitiated) {
            var raw: OpaquePointer?
            let millis = UInt32(clamping: timeout.components.seconds * 1000)
            let status = host.withCString { hostPtr in
                pairingPlist.withUnsafeBytes { rawBuf in
                    let bytesPtr = rawBuf.bindMemory(to: UInt8.self).baseAddress
                    return ac_session_open(hostPtr, port, bytesPtr, pairingPlist.count, millis, &raw)
                }
            }
            try Self.check(status)
            guard let raw else {
                throw BridgeError(code: .tunnel, message: "未能建立设备会话。")
            }
            return ACBridgeHandle(raw: raw)
        }.value
    }

    fileprivate static func check(_ status: ac_status) throws {
        guard status != AC_OK else { return }
        let msg = ac_last_error().map { String(cString: $0) } ?? "未知桥接错误"
        let code = BridgeErrorCode(rawValue: Int32(status.rawValue)) ?? .tunnel
        throw BridgeError(code: code, message: msg)
    }
}

private final class ACBridgeHandle: DeviceBridgeSessionHandle, @unchecked Sendable {
    private var raw: OpaquePointer?
    private let queue = DispatchQueue(label: "com.unreal.console.mobile.acbridge")

    init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        if let raw {
            ac_session_close(raw)
        }
    }

    func deviceInfo() async throws -> BridgeDeviceInfo {
        try await run { ptr in
            var info = ac_device_info()
            try ACBridgeConnector.check(ac_device_info_get(ptr, &info))
            let version = withUnsafePointer(to: &info.product_version) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            let name = withUnsafePointer(to: &info.device_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }
            return BridgeDeviceInfo(productVersion: version,
                                    deviceName: name,
                                    developerMode: info.developer_mode,
                                    ddiMounted: info.ddi_mounted)
        }
    }

    func mountDDI(restoreDirectory: URL, timeout: Duration) async throws {
        try await run { ptr in
            let millis = UInt32(clamping: timeout.components.seconds * 1000)
            try restoreDirectory.path.withCString { dirPtr in
                try ACBridgeConnector.check(ac_ddi_mount(ptr, dirPtr, millis))
            }
        }
    }

    func openLocationChannel() async throws {
        try await run { ptr in
            try ACBridgeConnector.check(ac_location_open(ptr))
        }
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        try await run { ptr in
            try ACBridgeConnector.check(ac_location_set(ptr, latitude, longitude))
        }
    }

    func clearLocation() async throws {
        try await run { ptr in
            try ACBridgeConnector.check(ac_location_clear(ptr))
        }
    }

    func ping() async throws {
        try await run { ptr in
            try ACBridgeConnector.check(ac_session_ping(ptr))
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let ptr = self.raw {
                    self.raw = nil
                    ac_session_close(ptr)
                }
                continuation.resume()
            }
        }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let ptr = self.raw else {
                    continuation.resume(throwing: BridgeError(code: .tunnel, message: "会话已关闭。"))
                    return
                }
                do {
                    continuation.resume(returning: try body(ptr))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif
