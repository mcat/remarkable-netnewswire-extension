import AppKit
import RemarkableKit
import SwiftUI
import UniformTypeIdentifiers

/// State behind the settings window.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: SendSettings {
        didSet { store.save(settings) }
    }
    @Published private(set) var pairingState: PairingState = .checking
    @Published var pairingCode = ""
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false

    private let store = SettingsStore()
    private let tokenStore: TokenStore = TokenStores.forCurrentProcess()
    private let cloudClient = RemarkableCloudClient()

    init() {
        settings = store.load()
    }

    var appGroupIdentifier: String? { AppGroup.identifier }

    var isPaired: Bool { pairingState == .paired }

    /// Reads the keychain off the main thread, after the window is up, so a
    /// keychain permission prompt never blocks the app from appearing.
    func refreshPairingState() async {
        let tokenStore = tokenStore
        pairingState = await Task.detached(priority: .userInitiated) {
            PairingState.resolve { try tokenStore.deviceToken() }
        }.value
    }

    func pair() async {
        guard let code = RemarkableCloudClient.normalizePairingCode(pairingCode) else {
            setStatus("Enter the eight-character code shown on my.remarkable.com.", isError: true)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let uploader = CloudUploader(client: cloudClient, store: tokenStore)
            try await uploader.pair(code: code)
            _ = try await uploader.validUserToken()
            pairingState = .paired
            pairingCode = ""
            setStatus("Paired with your reMarkable account.", isError: false)
        } catch {
            setStatus("Pairing failed: \(error.localizedDescription)", isError: true)
        }
    }

    func unpair() {
        do {
            try CloudUploader(client: cloudClient, store: tokenStore).unpair()
            pairingState = .notPaired
            setStatus("This Mac is no longer paired. You can also remove it under “Devices” on my.remarkable.com.", isError: false)
        } catch {
            setStatus("Could not remove the stored credentials: \(error.localizedDescription)", isError: true)
        }
    }

    func sendTestPage() async {
        isBusy = true
        defer { isBusy = false }
        let pipeline = SendPipeline(settings: settings, tokenStore: tokenStore, cloudClient: cloudClient)
        do {
            let document = SendPipeline.sampleDocument()
            let rendered = try await pipeline.render(document) { _ in }
            let name = FileNaming.visibleName(for: document)
            setStatus("Sending “\(name)”…", isError: false)
            try await pipeline.upload(pdf: rendered.data, name: name)
            setStatus("Sent “\(name)” (\(rendered.pageCount) page). Check the tablet's home screen.", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    /// Renders the sample page and lets the user save it, to check the layout without a tablet.
    func saveTestPDF() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Send to reMarkable test.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rendered = try await SendPipeline(settings: settings, tokenStore: tokenStore).render(SendPipeline.sampleDocument()) { _ in }
            try rendered.data.write(to: url)
            setStatus("Saved test PDF to \(url.lastPathComponent).", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    func openPairingPage() {
        NSWorkspace.shared.open(RemarkableCloudClient.pairingPageURL)
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
