#if os(macOS)
import Foundation
import Security

/// Stores reMarkable tokens in the data-protection keychain, shared with the
/// extension through the app group.
public final class KeychainTokenStore: TokenStore {
    public struct KeychainError: Error, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }

    static let deviceAccount = "remarkable-device-token"
    static let userAccount = "remarkable-user-token"

    public let service: String
    public let accessGroup: String?
    /// Whether to use the data-protection keychain. It needs an access group,
    /// which only signed builds with an app group have; every other build uses
    /// the login keychain. Reads there report "not found" rather than "missing
    /// entitlement", so this cannot be decided lazily from the error code.
    private var useDataProtection: Bool

    public init(service: String = "com.mcat.SendToRemarkable", accessGroup: String? = AppGroup.identifier) {
        self.service = service
        self.accessGroup = accessGroup
        useDataProtection = accessGroup != nil
    }

    public func deviceToken() throws -> String? { try read(KeychainTokenStore.deviceAccount) }
    public func setDeviceToken(_ token: String?) throws { try write(token, account: KeychainTokenStore.deviceAccount) }
    public func userToken() throws -> String? { try read(KeychainTokenStore.userAccount) }
    public func setUserToken(_ token: String?) throws { try write(token, account: KeychainTokenStore.userAccount) }

    // MARK: - Private

    private func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain] = true
            if let accessGroup {
                query[kSecAttrAccessGroup] = accessGroup
            }
        }
        return query
    }

    private func read(_ account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement, useDataProtection {
            useDataProtection = false
            return try read(account)
        }
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = result as? Data else {
            status = errSecDecode
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String?, account: String) throws {
        let deleteStatus = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if deleteStatus == errSecMissingEntitlement, useDataProtection {
            useDataProtection = false
            return try write(value, account: account)
        }
        guard let value else { return }
        var query = baseQuery(account: account)
        query[kSecValueData] = Data(value.utf8)
        query[kSecAttrLabel] = "Send to reMarkable"
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement, useDataProtection {
            useDataProtection = false
            return try write(value, account: account)
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }
}
#endif
