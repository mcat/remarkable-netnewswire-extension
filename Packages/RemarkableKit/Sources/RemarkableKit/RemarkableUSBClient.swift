import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Uploads documents through the tablet's built-in web interface
/// (Settings › Storage › USB web interface), normally at `http://10.11.99.1`.
public struct RemarkableUSBClient {
    public static let defaultHost = "10.11.99.1"

    public var host: String
    public var session: URLSession

    public init(host: String = RemarkableUSBClient.defaultHost, session: URLSession = RemarkableUSBClient.makeSession()) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }

    public static func baseURL(forHost host: String) -> URL? {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = defaultHost }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return URL(string: "http://\(trimmed)")
    }

    public static func uploadRequest(data: Data, fileName: String, mimeType: String, host: String) throws -> URLRequest {
        guard let base = baseURL(forHost: host) else {
            throw RemarkableError.deviceUnreachable(host)
        }
        var form = MultipartFormData()
        form.addFile(fieldName: "file", fileName: fileName, mimeType: mimeType, data: data)
        var request = URLRequest(url: base.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        request.httpBody = form.encoded()
        return request
    }

    public func upload(data: Data, fileName: String, mimeType: String = "application/pdf") async throws {
        let request = try RemarkableUSBClient.uploadRequest(data: data, fileName: fileName, mimeType: mimeType, host: host)
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw RemarkableError.deviceUnreachable(host)
        }
        let (body, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw RemarkableError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RemarkableError.httpStatus(http.statusCode, String(data: body.prefix(500), encoding: .utf8) ?? "")
        }
    }
}

/// A tiny `multipart/form-data` encoder.
public struct MultipartFormData {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "SendToRemarkable-" + UUID().uuidString) {
        self.boundary = boundary
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    public mutating func addFile(fieldName: String, fileName: String, mimeType: String, data: Data) {
        let safeName = fileName.replacingOccurrences(of: "\"", with: "'")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(safeName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    public func encoded() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
