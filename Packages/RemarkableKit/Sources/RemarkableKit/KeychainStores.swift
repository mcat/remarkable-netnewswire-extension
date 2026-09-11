#if os(macOS)
import Foundation
import Security

/// A `SecItem` call failed.
public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain error: \(message)"
    }
}

/// Picks the keychain a process can actually use.
///
/// The data-protection keychain needs a keychain access group, which only a
/// build signed with a team and an app group has. Its lookups answer "not
/// found" rather than "missing entitlement" when the group is absent, so the
/// choice is made here, once, instead of from an error code at run time.
public enum TokenStores {
    public static let defaultService = "com.mcat.SendToRemarkable"

    /// The store for this process: shared with the extension through the app
    /// group when signed, the login keychain otherwise.
    public static func forCurrentProcess(service: String = defaultService) -> TokenStore {
        make(service: service, accessGroup: AppGroup.identifier)
    }

    public static func make(service: String, accessGroup: String?) -> TokenStore {
        if let accessGroup {
            return DataProtectionKeychainStore(service: service, accessGroup: accessGroup)
        }
        return LoginKeychainStore(service: service)
    }
}

/// Tokens in the data-protection keychain, shared between the app and the
/// extension through their common access group. Never prompts.
public final class DataProtectionKeychainStore: TokenStore {
    public let service: String
    public let accessGroup: String
    private let items: KeychainItems

    public init(service: String = TokenStores.defaultService, accessGroup: String) {
        self.service = service
        self.accessGroup = accessGroup
        items = KeychainItems(baseQuery: [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecUseDataProtectionKeychain: true,
            kSecAttrAccessGroup: accessGroup,
        ])
    }

    public func deviceToken() throws -> String? { try items.read(account: KeychainItems.deviceAccount) }
    public func setDeviceToken(_ token: String?) throws { try items.write(token, account: KeychainItems.deviceAccount) }
    public func userToken() throws -> String? { try items.read(account: KeychainItems.userAccount) }
    public func setUserToken(_ token: String?) throws { try items.write(token, account: KeychainItems.userAccount) }
}

/// Tokens in the user's login keychain, for builds without an access group.
/// Access is bound to the signing identity, so a re-signed binary may prompt.
public final class LoginKeychainStore: TokenStore {
    public let service: String
    private let items: KeychainItems

    public init(service: String = TokenStores.defaultService) {
        self.service = service
        items = KeychainItems(baseQuery: [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ])
    }

    public func deviceToken() throws -> String? { try items.read(account: KeychainItems.deviceAccount) }
    public func setDeviceToken(_ token: String?) throws { try items.write(token, account: KeychainItems.deviceAccount) }
    public func userToken() throws -> String? { try items.read(account: KeychainItems.userAccount) }
    public func setUserToken(_ token: String?) throws { try items.write(token, account: KeychainItems.userAccount) }
}

/// The `SecItem` plumbing both stores share. The base query names the keychain;
/// the account names the token.
struct KeychainItems {
    static let deviceAccount = "remarkable-device-token"
    static let userAccount = "remarkable-user-token"

    let baseQuery: [CFString: Any]

    func read(account: String) throws -> String? {
        var query = baseQuery
        query[kSecAttrAccount] = account
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = result as? Data else {
            throw KeychainError(status: errSecDecode)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored value; `nil` removes it.
    func write(_ value: String?, account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount] = account
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError(status: deleteStatus)
        }
        guard let value else { return }
        query[kSecValueData] = Data(value.utf8)
        query[kSecAttrLabel] = "Send to reMarkable"
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }
}
#endif
