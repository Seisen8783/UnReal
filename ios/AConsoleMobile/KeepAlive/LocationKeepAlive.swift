import AVFoundation
import CoreLocation
import Foundation

/// Maintains background execution while replaying and verifies that simulated
/// coordinates are actively reflected in CoreLocation.
@MainActor
public final class LocationKeepAlive: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public private(set) var authorizationStatus: CLAuthorizationStatus
    @Published public private(set) var isRunning = false
    @Published public private(set) var usingAudioFallback = false

    private let manager = CLLocationManager()
    private var audioPlayer: AVAudioPlayer?
    private var onLocation: ((Double, Double) -> Void)?

    public override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        #endif
    }

    public func requestPermission() {
        #if os(iOS)
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        #endif
    }

    public func start(onLocation: @escaping (Double, Double) -> Void) {
        self.onLocation = onLocation
        isRunning = true
        manager.startUpdatingLocation()
    }

    public func stop() {
        isRunning = false
        onLocation = nil
        manager.stopUpdatingLocation()
        stopAudioFallback()
    }

    public func enableAudioFallback() {
        guard !usingAudioFallback else { return }
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let silence = Self.makeSilentWavData(durationSeconds: 1, sampleRate: 8000)
            let player = try AVAudioPlayer(data: silence)
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            audioPlayer = player
            usingAudioFallback = true
        } catch {
            usingAudioFallback = false
        }
        #endif
    }

    private func stopAudioFallback() {
        audioPlayer?.stop()
        audioPlayer = nil
        usingAudioFallback = false
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let lat = latest.coordinate.latitude
        let lon = latest.coordinate.longitude
        Task { @MainActor in
            self.onLocation?(lat, lon)
        }
    }

    public nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.isRunning {
                self.enableAudioFallback()
            }
        }
    }

    private static func makeSilentWavData(durationSeconds: Int, sampleRate: Int) -> Data {
        let sampleCount = durationSeconds * sampleRate
        let dataSize = UInt32(sampleCount * 2)
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(36) + dataSize)
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(1))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(sampleRate * 2))
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLE(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
