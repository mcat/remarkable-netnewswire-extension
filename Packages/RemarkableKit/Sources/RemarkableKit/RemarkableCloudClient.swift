import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors raised by the reMarkable transports.
public enum RemarkableError: Error, LocalizedError, Equatable {
    case notPaired
    case invalidPairingCode
    case unauthorized
    case httpStatus(Int, String)
    case invalidResponse
    case deviceUnreachable(String)

    public var errorDescription: String? {
        switch self {
        case .notPaired:
            return "This Mac is not paired with a reMarkable account. Open the Send to reMarkable app to pair it."
        case .invalidPairingCode:
            return "The one-time code must be eight characters."
        case .unauthorized:
            return "reMarkable rejected the stored credentials. Pair this Mac again in the Send to reMarkable app."
        case .httpStatus(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "reMarkable returned HTTP \(code)." : "reMarkable returned HTTP \(code): \(detail.prefix(200))"
        case .invalidResponse:
            return "reMarkable returned an unexpected response."
        case .deviceUnreachable(let host):
            return "Could not reach the reMarkable at \(host). Connect it over USB and enable the USB web interface in Settings › Storage."
        }
    }
}

/// Client for the reMarkable cloud: pairing plus the simple document upload
/// endpoint used by reMarkable's own browser extension.
public struct RemarkableCloudClient {
    public static let defaultAuthHost = URL(string: "https://webapp-prod.cloud.remarkable.engineering")!
    public static let defaultUploadHost = URL(string: "https://internal.cloud.remarkable.com")!
    /// Where users obtain a one-time pairing code.
    public static let pairingPageURL = URL(string: "https://my.remarkable.com/device/browser/connect")!
    /// Sent when registering; reMarkable shows it in the account's device list.
    public static let deviceDescription = "browser-chrome"

    public struct UploadReceipt: Decodable, Equatable {
        public let docID: String
        public let hash: String
    }

    public var authHost: URL
    public var uploadHost: URL
    public var session: URLSession

    public init(session: URLSession = RemarkableCloudClient.makeSession(), authHost: URL = RemarkableCloudClient.defaultAuthHost, uploadHost: URL = RemarkableCloudClient.defaultUploadHost) {
        self.session = session
        self.authHost = authHost
        self.uploadHost = uploadHost
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    // MARK: - Request construction

    public static func normalizePairingCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard code.count == 8, code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return code
    }

    public static func registerRequest(code: String, deviceID: String, deviceDescription: String = deviceDescription, authHost: URL = defaultAuthHost) throws -> URLRequest {
        var request = URLRequest(url: authHost.appendingPathComponent("token/json/2/device/new"))
        request.httpMethod = "POST"
        request.setValue("Bearer", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["code": code, "deviceDesc": deviceDescription, "deviceID": deviceID]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    public static func userTokenRequest(deviceToken: String, authHost: URL = defaultAuthHost) -> URLRequest {
        var request = URLRequest(url: authHost.appendingPathComponent("token/json/2/user/new"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The `rm-meta` header value: base64 of a small JSON object.
    public static func uploadMetadata(fileName: String) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: ["file_name": fileName], options: [])
        return json.base64EncodedString()
    }

    public static func uploadRequest(data: Data, fileName: String, mimeType: String, userToken: String, uploadHost: URL = defaultUploadHost) throws -> URLRequest {
        var request = URLRequest(url: uploadHost.appendingPathComponent("doc/v2/files"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(try uploadMetadata(fileName: fileName), forHTTPHeaderField: "rm-meta")
        request.setValue("RoR-Browser", forHTTPHeaderField: "rm-source")
        request.httpBody = data
        return request
    }

    // MARK: - Calls

    /// Exchanges a one-time code for a long-lived device token.
    public func registerDevice(code rawCode: String, deviceID: String = UUID().uuidString.lowercased()) async throws -> String {
        guard let code = RemarkableCloudClient.normalizePairingCode(rawCode) else {
            throw RemarkableError.invalidPairingCode
        }
        let request = try RemarkableCloudClient.registerRequest(code: code, deviceID: deviceID, authHost: authHost)
        let (data, response) = try await session.data(for: request)
        try RemarkableCloudClient.check(response, data: data)
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw RemarkableError.invalidResponse
        }
        return token
    }

    /// Exchanges the device token for a short-lived user token.
    public func fetchUserToken(deviceToken: String) async throws -> String {
        let request = RemarkableCloudClient.userTokenRequest(deviceToken: deviceToken, authHost: authHost)
        let (data, response) = try await session.data(for: request)
        try RemarkableCloudClient.check(response, data: data)
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw RemarkableError.invalidResponse
        }
        return token
    }

    /// Uploads a PDF or EPUB to the root of the account's library.
    public func upload(data: Data, fileName: String, mimeType: String = "application/pdf", userToken: String) async throws -> UploadReceipt {
        let request = try RemarkableCloudClient.uploadRequest(data: data, fileName: fileName, mimeType: mimeType, userToken: userToken, uploadHost: uploadHost)
        let (body, response) = try await session.data(for: request)
        try RemarkableCloudClient.check(response, data: body)
        do {
            return try JSONDecoder().decode(UploadReceipt.self, from: body)
        } catch {
            throw RemarkableError.invalidResponse
        }
    }

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemarkableError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw RemarkableError.unauthorized
        default:
            throw RemarkableError.httpStatus(http.statusCode, String(data: data.prefix(500), encoding: .utf8) ?? "")
        }
    }
}

/// Minimal JSON Web Token inspection, used to know when a user token expires.
public enum JSONWebToken {
    public static func expiration(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }
}
