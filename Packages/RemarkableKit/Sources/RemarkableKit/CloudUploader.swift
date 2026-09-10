import Foundation

/// Uploads to the reMarkable cloud, managing the short-lived user token.
public final class CloudUploader {
    public let client: RemarkableCloudClient
    public let store: TokenStore

    public init(client: RemarkableCloudClient = RemarkableCloudClient(), store: TokenStore) {
        self.client = client
        self.store = store
    }

    public var isPaired: Bool {
        (try? store.deviceToken()).flatMap { $0 } != nil
    }

    /// Pairs this Mac using a one-time code from ``RemarkableCloudClient/pairingPageURL``.
    public func pair(code: String) async throws {
        let deviceToken = try await client.registerDevice(code: code)
        try store.setDeviceToken(deviceToken)
        try store.setUserToken(nil)
    }

    public func unpair() throws {
        try store.setDeviceToken(nil)
        try store.setUserToken(nil)
    }

    /// A user token that is valid for at least a few more minutes.
    public func validUserToken(forceRefresh: Bool = false) async throws -> String {
        guard let deviceToken = try store.deviceToken(), !deviceToken.isEmpty else {
            throw RemarkableError.notPaired
        }
        if !forceRefresh, let cached = try store.userToken(), !cached.isEmpty {
            if let expiry = JSONWebToken.expiration(of: cached), expiry.timeIntervalSinceNow > 10 * 60 {
                return cached
            }
        }
        let fresh = try await client.fetchUserToken(deviceToken: deviceToken)
        try store.setUserToken(fresh)
        return fresh
    }

    @discardableResult
    public func upload(data: Data, fileName: String, mimeType: String = "application/pdf") async throws -> RemarkableCloudClient.UploadReceipt {
        let token = try await validUserToken()
        do {
            return try await client.upload(data: data, fileName: fileName, mimeType: mimeType, userToken: token)
        } catch RemarkableError.unauthorized {
            // The cached token may have been revoked; refresh once and retry.
            let refreshed = try await validUserToken(forceRefresh: true)
            return try await client.upload(data: data, fileName: fileName, mimeType: mimeType, userToken: refreshed)
        }
    }
}
