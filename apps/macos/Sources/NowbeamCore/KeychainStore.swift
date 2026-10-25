import Foundation
import Security

public struct KeychainStore: Sendable {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func load(account: String) throws -> String? {
        var query = identity(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = value as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return secret
    }

    public func save(_ secret: String, account: String) throws {
        let query = identity(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        let added = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil)
        if added == errSecDuplicateItem {
            let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updated == errSecSuccess else { throw KeychainError(status: updated) }
        } else if added != errSecSuccess {
            throw KeychainError(status: added)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(identity(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func identity(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed:
            "无法访问钥匙串，请解锁后重试。"
        case errSecUserCanceled:
            "钥匙串访问已取消。"
        case errSecDecode:
            "钥匙串中的凭证无法读取，请重新授权。"
        default:
            "钥匙串操作失败，凭证没有写入普通设置文件。"
        }
    }
}
