import Foundation

public struct PendingRestoreRecord: Codable, Equatable, Sendable {
    public let writtenAt: Date
    public let latitude: Double
    public let longitude: Double

    public init(writtenAt: Date, latitude: Double, longitude: Double) {
        self.writtenAt = writtenAt
        self.latitude = latitude
        self.longitude = longitude
    }
}

public protocol PendingRestoreStoring: Sendable {
    func load() -> PendingRestoreRecord?
    func save(_ record: PendingRestoreRecord)
    func clear()
}

public final class UserDefaultsPendingRestoreStore: PendingRestoreStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "ac.mobile.pending-restore") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PendingRestoreRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingRestoreRecord.self, from: data)
    }

    public func save(_ record: PendingRestoreRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
