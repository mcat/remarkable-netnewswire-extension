import SwiftUI
import RemarkableKit

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            connectionSection
            documentSection
            testSection
            usageSection
        }
        .formStyle(.grouped)
        .navigationTitle("Send to reMarkable")
        .task { await model.refreshPairingState() }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            Picker("Send via", selection: $model.settings.transport) {
                ForEach(SendTransport.allCases) { transport in
                    Text(transport.displayName).tag(transport)
                }
            }

            if model.settings.transport == .cloud {
                LabeledContent("Account") {
                    HStack {
                        switch model.pairingState {
                        case .checking:
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        case .paired:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                            Text("Paired")
                        case .notPaired:
                            Image(systemName: "xmark.circle").foregroundStyle(Color.secondary)
                            Text("Not paired")
                        case .unavailable:
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                            Text("Keychain unavailable")
                        }
                    }
                }
                switch model.pairingState {
                case .checking:
                    EmptyView()
                case .paired:
                    Button("Unpair this Mac", role: .destructive) { model.unpair() }
                        .disabled(model.isBusy)
                case .notPaired, .unavailable:
                    if case .unavailable(let reason) = model.pairingState {
                        Text("\(reason) Relaunch and click Allow when macOS asks, or pair again below.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        TextField("One-time code", text: $model.pairingCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                            .onSubmit { Task { await model.pair() } }
                        Button("Pair") { Task { await model.pair() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isBusy || model.pairingCode.trimmingCharacters(in: .whitespaces).count != 8)
                        Button("Get a code…") { model.openPairingPage() }
                    }
                    Text("Sign in at my.remarkable.com, choose “Connect a device”, and enter the eight-character code here. The pairing is stored in your keychain and shared with the NetNewsWire share extension.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField("Tablet address", text: $model.settings.usbHost, prompt: Text(RemarkableUSBClient.defaultHost))
                Text("Enable “USB web interface” on the tablet under Settings › Storage, then connect it with a USB cable. The default address is \(RemarkableUSBClient.defaultHost).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Connection")
        }
    }

    private var documentSection: some View {
        Section("Document") {
            Picker("Page size", selection: $model.settings.pageSizeID) {
                ForEach(PageSizePreset.allCases) { preset in
                    Text(preset.displayName).tag(preset.id)
                }
            }
            Toggle("Include images", isOn: $model.settings.includeImages)
            Toggle("Convert images to grayscale", isOn: $model.settings.grayscaleImages)
                .disabled(!model.settings.includeImages)
            Toggle("Prefix the document name with the site name", isOn: $model.settings.prefixSourceName)
            LabeledContent("Text size") {
                HStack {
                    Slider(value: $model.settings.fontScale, in: 0.8...1.6, step: 0.05)
                        .frame(maxWidth: 220)
                    Text(String(format: "%.0f%%", model.settings.fontScale * 100))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
    }

    private var testSection: some View {
        Section("Test") {
            HStack {
                Button("Send a test page") { Task { await model.sendTestPage() } }
                    .disabled(model.isBusy || (model.settings.transport == .cloud && !model.isPaired))
                Button("Save test PDF…") { Task { await model.saveTestPDF() } }
                    .disabled(model.isBusy)
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            if let message = model.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var usageSection: some View {
        Section("Using it in NetNewsWire") {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Select an article in NetNewsWire and click the Share button in the toolbar.")
                Text("2. Choose “Send to reMarkable”. The article is laid out as a PDF sized for your tablet, images included, and uploaded.")
                Text("3. If the entry is missing, choose “Edit Extensions…” at the bottom of the Share menu and enable Send to reMarkable under Sharing.")
                if model.appGroupIdentifier == nil {
                    Text("This build is not signed with a development team, so the app and the extension cannot share settings or the pairing. Set your team in Xcode's Signing & Capabilities tab and rebuild.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
        }
    }
}
