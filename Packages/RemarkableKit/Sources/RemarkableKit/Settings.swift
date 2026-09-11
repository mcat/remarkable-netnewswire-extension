import Foundation
#if os(macOS)
import Security
#endif

/// How a document reaches the tablet.
public enum SendTransport: String, Codable, CaseIterable, Identifiable {
    case cloud
    case usb

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cloud: return "reMarkable Cloud"
        case .usb: return "USB / Wi-Fi web interface"
        }
    }
}

/// User-configurable options, shared between the app and the extension.
public struct SendSettings: Codable, Equatable {
    public var transport: SendTransport = .cloud
    public var usbHost: String = RemarkableUSBClient.defaultHost
    public var includeImages: Bool = true
    public var grayscaleImages: Bool = true
    public var pageSizeID: String = PageSizePreset.remarkable2.id
    /// Multiplier applied to every font size. 1.0 is the default.
    public var fontScale: Double = 1.0
    /// Prefix the document name with the feed or site name.
    public var prefixSourceName: Bool = false
    public var maxImages: Int = 40

    public init() {}

    public var pageSize: PageSizePreset {
        get { PageSizePreset.preset(withID: pageSizeID) }
        set { pageSizeID = newValue.id }
    }

    enum CodingKeys: String, CodingKey {
        case transport, usbHost, includeImages, grayscaleImages, pageSizeID, fontScale, prefixSourceName, maxImages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SendSettings()
        transport = try container.decodeIfPresent(SendTransport.self, forKey: .transport) ?? defaults.transport
        usbHost = try container.decodeIfPresent(String.self, forKey: .usbHost) ?? defaults.usbHost
        includeImages = try container.decodeIfPresent(Bool.self, forKey: .includeImages) ?? defaults.includeImages
        grayscaleImages = try container.decodeIfPresent(Bool.self, forKey: .grayscaleImages) ?? defaults.grayscaleImages
        pageSizeID = try container.decodeIfPresent(String.self, forKey: .pageSizeID) ?? defaults.pageSizeID
        fontScale = try container.decodeIfPresent(Double.self, forKey: .fontScale) ?? defaults.fontScale
        prefixSourceName = try container.decodeIfPresent(Bool.self, forKey: .prefixSourceName) ?? defaults.prefixSourceName
        maxImages = try container.decodeIfPresent(Int.self, forKey: .maxImages) ?? defaults.maxImages
    }
}

/// Persists ``SendSettings`` in the app group's defaults so the share
/// extension sees what the app configured.
public struct SettingsStore {
    public static let key = "SendSettings"

    public var defaults: UserDefaults

    public init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    public func load() -> SendSettings {
        guard let data = defaults.data(forKey: SettingsStore.key),
              let settings = try? JSONDecoder().decode(SendSettings.self, from: data) else {
            return SendSettings()
        }
        return settings
    }

    public func save(_ settings: SendSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: SettingsStore.key)
        }
    }
}

/// The app group shared by the app and its extension, read from the code
/// signature so the team identifier never has to be hard-coded.
public enum AppGroup {
    public static let identifier: String? = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String],
              let first = groups.first else {
            return nil
        }
        return first
        #else
        return nil
        #endif
    }()

    public static let defaults: UserDefaults = {
        if let identifier, let suite = UserDefaults(suiteName: identifier) {
            return suite
        }
        return .standard
    }()
}

/// Storage for the reMarkable credentials.
public protocol TokenStore: AnyObject {
    func deviceToken() throws -> String?
    func setDeviceToken(_ token: String?) throws
    func userToken() throws -> String?
    func setUserToken(_ token: String?) throws
}

public final class InMemoryTokenStore: TokenStore {
    private var device: String?
    private var user: String?

    public init(deviceToken: String? = nil, userToken: String? = nil) {
        device = deviceToken
        user = userToken
    }

    public func deviceToken() throws -> String? { device }
    public func setDeviceToken(_ token: String?) throws { device = token }
    public func userToken() throws -> String? { user }
    public func setUserToken(_ token: String?) throws { user = token }
}
