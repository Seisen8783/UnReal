import SwiftUI

@main
struct AConsoleMobileApp: App {
    var body: some Scene {
        WindowGroup {
            #if canImport(ACBridge)
            MobileRootView(connector: ACBridgeConnector())
            #else
            MobileRootView(connector: UnsupportedBridgeConnector())
            #endif
        }
    }
}

private struct UnsupportedBridgeConnector: DeviceBridgeConnecting {
    func openLoopbackSession(host: String, port: UInt16, pairingPlist: Data, timeout: Duration) async throws -> any DeviceBridgeSessionHandle {
        throw BridgeError(code: .unreachable, message: "未链接 ACBridge 原生静态库。")
    }
}
