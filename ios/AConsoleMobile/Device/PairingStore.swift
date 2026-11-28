import Foundation
import Security

public enum PairingStoreError: LocalizedError, Sendable {
    case invalidPlist
    case missingRequiredFields([String])
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidPlist:
            return "配对文件格式无效，请选择 .mobiledevicepairing 或 .plist 文件。"
        case .missingRequiredFields(let fields):
            return "配对文件缺少必要字段：\(fields.joined(separator: ", "))。"
        case .keychainError(let status):
            return "钥匙串操作失败（OSStatus \(status)）。"
        }
    }
}

/// Validates and stores the iPhone lockdown pairing plist in the local Keychain.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background replay
/// reconnects can read credentials while the device stays locked and never syncs to iCloud.
public enum PairingStore {
    private static let service = "com.unreal.console.mobile.pairing"
    private static let account = "device-pairing-plist"
    private static let requiredKeys = [
        "HostID",
        "SystemBUID",
        "HostCertificate",
        "HostPrivateKey",
        "RootCertificate",
        "DeviceCertificate",
    ]

    public struct Summary: Sendable, Equatable {
        public let hostIDMasked: String
        public let systemBUID: String
        public let byteCount: Int
    }

    public static func validate(_ data: Data) throws -> Summary {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else {
            throw PairingStoreError.invalidPlist
        }
        let missing = requiredKeys.filter { dict[$0] == nil }
        guard missing.isEmpty else {
            throw PairingStoreError.missingRequiredFields(missing)
        }
        let hostID = dict["HostID"] as? String ?? ""
        let buid = dict["SystemBUID"] as? String ?? ""
        let masked = hostID.count > 4 ? "…\(hostID.suffix(4))" : hostID
        return Summary(hostIDMasked: masked, systemBUID: buid, byteCount: data.count)
    }

    public static func save(_ data: Data) throws -> Summary {
        let summary = try validate(data)
        try delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PairingStoreError.keychainError(status)
        }
        return summary
    }

    public static func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw PairingStoreError.keychainError(status)
        }
        return result as? Data
    }

    public static func hasPairing() -> Bool {
        (try? load()) != nil
    }

    public static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingStoreError.keychainError(status)
        }
    }
}
