import SwiftUI
import RemarkableKit

@main
struct SendToRemarkableApp: App {
    @StateObject private var model = SettingsModel()

    var body: some Scene {
        WindowGroup("Send to reMarkable") {
            SettingsView(model: model)
                .frame(minWidth: 540, idealWidth: 560, minHeight: 640)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
