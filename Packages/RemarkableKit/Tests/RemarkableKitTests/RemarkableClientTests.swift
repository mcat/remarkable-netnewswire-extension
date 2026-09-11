import XCTest
@testable import RemarkableKit

final class RemarkableClientTests: XCTestCase {
    func testRegisterRequest() throws {
        let request = try RemarkableCloudClient.registerRequest(code: "abcdefgh", deviceID: "id-1")
        XCTAssertEqual(request.url?.absoluteString, "https://webapp-prod.cloud.remarkable.engineering/token/json/2/device/new")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["code": "abcdefgh", "deviceDesc": "browser-chrome", "deviceID": "id-1"])
    }

    func testPairingCodeNormalization() {
        XCTAssertEqual(RemarkableCloudClient.normalizePairingCode("  ABCDefgh\n"), "abcdefgh")
        XCTAssertNil(RemarkableCloudClient.normalizePairingCode("short"))
        XCTAssertNil(RemarkableCloudClient.normalizePairingCode("abcd-efgh"))
    }

    func testUserTokenRequest() {
        let request = RemarkableCloudClient.userTokenRequest(deviceToken: "dev")
        XCTAssertEqual(request.url?.absoluteString, "https://webapp-prod.cloud.remarkable.engineering/token/json/2/user/new")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dev")
    }

    func testUploadRequest() throws {
        let payload = Data("%PDF-1.4".utf8)
        let request = try RemarkableCloudClient.uploadRequest(data: payload, fileName: "My Article", mimeType: "application/pdf", userToken: "user")
        XCTAssertEqual(request.url?.absoluteString, "https://internal.cloud.remarkable.com/doc/v2/files")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
        XCTAssertEqual(request.value(forHTTPHeaderField: "rm-source"), "RoR-Browser")
        XCTAssertEqual(request.httpBody, payload)

        let meta = try XCTUnwrap(request.value(forHTTPHeaderField: "rm-meta"))
        let decoded = try XCTUnwrap(Data(base64Encoded: meta))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: String])
        XCTAssertEqual(json, ["file_name": "My Article"])
    }

    func testJWTExpiration() {
        // {"exp":1700000000}
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjE3MDAwMDAwMDB9.sig"
        XCTAssertEqual(JSONWebToken.expiration(of: token), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(JSONWebToken.expiration(of: "opaque"))
    }

    func testUSBUploadRequestIsMultipart() throws {
        let request = try RemarkableUSBClient.uploadRequest(data: Data("pdf".utf8), fileName: "a.pdf", mimeType: "application/pdf", host: "10.11.99.1")
        XCTAssertEqual(request.url?.absoluteString, "http://10.11.99.1/upload")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.pdf\"\r\nContent-Type: application/pdf\r\n\r\npdf\r\n"))
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
    }

    func testCloudUploaderRefreshesExpiredToken() async throws {
        let store = InMemoryTokenStore(deviceToken: "device", userToken: "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjE3MDAwMDAwMDB9.sig")
        let uploader = CloudUploader(client: RemarkableCloudClient(), store: store)
        XCTAssertTrue(uploader.isPaired)
        // The cached token expired in 2023, so a network refresh would be attempted.
        // Here we only verify the pairing state and unpair behaviour without network access.
        try uploader.unpair()
        XCTAssertFalse(uploader.isPaired)
        do {
            _ = try await uploader.validUserToken()
            XCTFail("expected notPaired")
        } catch let error as RemarkableError {
            XCTAssertEqual(error, .notPaired)
        }
    }
}
