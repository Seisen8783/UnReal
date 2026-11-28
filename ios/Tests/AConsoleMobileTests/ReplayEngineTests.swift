import Foundation
import TrackCore
import XCTest
@testable import AConsoleMobileKit

final class ReplayEngineTests: XCTestCase {
    private final class MockHandle: DeviceBridgeSessionHandle, @unchecked Sendable {
        let info: BridgeDeviceInfo
        var setCalls: [(Double, Double)] = []
        var clearCalls = 0
        var closeCalls = 0
        var failNextSetWithTransient = false

        init(info: BridgeDeviceInfo) {
            self.info = info
        }

        func deviceInfo() async throws -> BridgeDeviceInfo { info }
        func mountDDI(restoreDirectory: URL, timeout: Duration) async throws {}
        func openLocationChannel() async throws {}

        func setLocation(latitude: Double, longitude: Double) async throws {
            if failNextSetWithTransient {
                failNextSetWithTransient = false
                throw BridgeError(code: .tunnel, message: "simulated drop")
            }
            setCalls.append((latitude, longitude))
        }

        func clearLocation() async throws {
            clearCalls += 1
        }

        func ping() async throws {}

        func close() async {
            closeCalls += 1
        }
    }

    private final class MockConnector: DeviceBridgeConnecting, @unchecked Sendable {
        var handles: [MockHandle] = []
        var openCalls = 0

        func openLoopbackSession(host: String, port: UInt16, pairingPlist: Data, timeout: Duration) async throws -> any DeviceBridgeSessionHandle {
            openCalls += 1
            let handle = MockHandle(info: BridgeDeviceInfo(productVersion: "18.3",
                                                           deviceName: "Test iPhone",
                                                           developerMode: true,
                                                           ddiMounted: true))
            handles.append(handle)
            return handle
        }
    }

    private final class MemoryPendingStore: PendingRestoreStoring, @unchecked Sendable {
        var record: PendingRestoreRecord?
        func load() -> PendingRestoreRecord? { record }
        func save(_ record: PendingRestoreRecord) { self.record = record }
        func clear() { self.record = nil }
    }

    func testPairingStoreValidationRejectsIncompletePlist() throws {
        let incomplete = try PropertyListSerialization.data(fromPropertyList: ["HostID": "abc"],
                                                            format: .xml,
                                                            options: 0)
        XCTAssertThrowsError(try PairingStore.validate(incomplete))

        let validDict: [String: Any] = [
            "HostID": "HOST-1234-ABCD",
            "SystemBUID": "BUID-5678",
            "HostCertificate": Data([1, 2, 3]),
            "HostPrivateKey": Data([4, 5, 6]),
            "RootCertificate": Data([7, 8, 9]),
            "DeviceCertificate": Data([10, 11, 12]),
        ]
        let valid = try PropertyListSerialization.data(fromPropertyList: validDict, format: .xml, options: 0)
        let summary = try PairingStore.validate(valid)
        XCTAssertEqual(summary.hostIDMasked, "…ABCD")
        XCTAssertEqual(summary.systemBUID, "BUID-5678")
    }

    @MainActor
    func testLocateStartReplayAndRestoreLifecycle() async throws {
        let connector = MockConnector()
        let session = DeviceSession(connector: connector)
        let pendingStore = MemoryPendingStore()
        let engine = ReplayEngine(session: session, pendingStore: pendingStore)
        engine.loadBundledTrack()

        XCTAssertFalse(engine.timeline.isEmpty)

        await engine.connect(pairingPlist: Data([1]), configuration: .init())
        XCTAssertEqual(engine.state, .ready)

        await engine.locateStart()
        XCTAssertEqual(engine.state, .atStart)
        XCTAssertNotNil(pendingStore.load())
        XCTAssertEqual(connector.handles.last?.setCalls.count, 1)

        // Simulate readback matching written start coordinate.
        let startPoint = try XCTUnwrap(engine.timeline.first)
        engine.observeReadbackLocation(latitude: startPoint.latitude, longitude: startPoint.longitude)
        if case let .active(accuracy) = engine.readbackStatus {
            XCTAssertLessThan(accuracy, 1.0)
        } else {
            XCTFail("Expected active readback status, got \(engine.readbackStatus)")
        }

        // Simulate transient connection drop triggering automatic reconnect on next write.
        connector.handles.last?.failNextSetWithTransient = true
        await engine.seek(to: engine.totalDuration / 2)
        XCTAssertEqual(connector.openCalls, 2)
        XCTAssertEqual(connector.handles.last?.setCalls.count, 1)

        await engine.restoreRealLocation()
        XCTAssertEqual(engine.state, .ready)
        XCTAssertNil(pendingStore.load())
        XCTAssertEqual(connector.handles.last?.clearCalls, 1)
    }
}
