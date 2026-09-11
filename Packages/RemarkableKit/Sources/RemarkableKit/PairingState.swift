import Foundation

/// Whether this Mac holds a reMarkable device token, as shown in the app.
public enum PairingState: Equatable {
    /// The keychain has not been consulted yet.
    case checking
    case paired
    case notPaired
    /// The keychain refused or failed; `reason` is the error's description.
    case unavailable(reason: String)

    /// Derives the state from a token read, keeping "no token" apart from
    /// "could not read", so a denied keychain prompt is not mistaken for an
    /// unpaired Mac.
    public static func resolve(_ read: () throws -> String?) -> PairingState {
        do {
            let token = try read()
            return token?.isEmpty == false ? .paired : .notPaired
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }
}
