import Foundation
import Security
import os
import QuartetEngine

public enum KeychainError: Error, LocalizedError, Equatable {
    case osStatus(OSStatus)
    case unexpectedData

    public var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        case .unexpectedData:
            return "Keychain returned data that is not a UTF-8 string."
        }
    }
}

/// One generic-password item per provider under service "tv.affirmi.quartetdesk".
public struct KeychainStore: Sendable {
    public static let service = "tv.affirmi.quartetdesk"
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "keychain")

    public init() {}

    public func key(for provider: ProviderKind) throws -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            Self.logger.error("Keychain read failed for \(provider.rawValue, privacy: .public): OSStatus \(status)")
            throw KeychainError.osStatus(status)
        }
    }

    public func setKey(_ key: String, for provider: ProviderKind) throws {
        let data = Data(key.utf8)
        let query = baseQuery(for: provider)
        let update: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                Self.logger.error("Keychain add failed for \(provider.rawValue, privacy: .public): OSStatus \(addStatus)")
                throw KeychainError.osStatus(addStatus)
            }
        default:
            Self.logger.error("Keychain update failed for \(provider.rawValue, privacy: .public): OSStatus \(updateStatus)")
            throw KeychainError.osStatus(updateStatus)
        }
    }

    public func deleteKey(for provider: ProviderKind) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Self.logger.error("Keychain delete failed for \(provider.rawValue, privacy: .public): OSStatus \(status)")
            throw KeychainError.osStatus(status)
        }
    }

    private func baseQuery(for provider: ProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}
