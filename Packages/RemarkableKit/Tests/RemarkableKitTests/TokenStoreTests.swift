import XCTest
@testable import RemarkableKit

final class TokenStoreTests: XCTestCase {
    // MARK: - Choosing the keychain

    func testFactoryUsesLoginKeychainWithoutAccessGroup() {
        let store = TokenStores.make(service: "com.mcat.SendToRemarkable", accessGroup: nil)
        XCTAssertTrue(store is LoginKeychainStore)
    }

    func testFactoryUsesDataProtectionKeychainWithAccessGroup() throws {
        let store = TokenStores.make(service: "com.mcat.SendToRemarkable", accessGroup: "TEAMID.com.mcat.SendToRemarkable")
        let dataProtection = try XCTUnwrap(store as? DataProtectionKeychainStore)
        XCTAssertEqual(dataProtection.accessGroup, "TEAMID.com.mcat.SendToRemarkable")
    }

    // MARK: - Login keychain round trip

    /// Unsigned builds use the login keychain. A store created later, such as
    /// the one the extension creates, must read what another instance wrote.
    func testFreshLoginKeychainStoreReadsTokenWrittenByAnotherInstance() throws {
        let service = "com.mcat.SendToRemarkable.tests." + UUID().uuidString
        let writer = LoginKeychainStore(service: service)
        defer { try? writer.setDeviceToken(nil) }
        try writer.setDeviceToken("device-token-123")

        let reader = LoginKeychainStore(service: service)
        XCTAssertEqual(try reader.deviceToken(), "device-token-123")
    }

    func testLoginKeychainStoreDeletesTokenWhenSetToNil() throws {
        let service = "com.mcat.SendToRemarkable.tests." + UUID().uuidString
        let store = LoginKeychainStore(service: service)
        try store.setUserToken("user-token")
        try store.setUserToken(nil)
        XCTAssertNil(try store.userToken())
    }

    // MARK: - Pairing state

    func testPairingStateIsPairedWhenATokenIsStored() {
        XCTAssertEqual(PairingState.resolve { "device-token" }, .paired)
    }

    func testPairingStateIsNotPairedWhenNoTokenIsStored() {
        XCTAssertEqual(PairingState.resolve { nil }, .notPaired)
        XCTAssertEqual(PairingState.resolve { "" }, .notPaired)
    }

    func testPairingStateIsUnavailableWhenTheKeychainRefuses() {
        struct Refused: LocalizedError { var errorDescription: String? { "Keychain error: User interaction is not allowed." } }
        let state = PairingState.resolve { throw Refused() }
        XCTAssertEqual(state, .unavailable(reason: "Keychain error: User interaction is not allowed."))
    }
}
