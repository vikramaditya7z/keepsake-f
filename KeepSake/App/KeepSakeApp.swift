import SwiftUI

@main
struct KeepSakeApp: App {
    @StateObject private var browserViewModel = PhotoBrowserViewModel()
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: browserViewModel)
        }
        .defaultSize(width: 960, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Photo Folder…") {
                    browserViewModel.chooseFolder()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Rescan Library") {
                    browserViewModel.triggerManualRescan()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(browserViewModel.selectedFolderURL == nil)
            }

            CommandMenu("Developer") {
                Toggle("Developer Mode", isOn: $settings.developerModeEnabled)
                    .keyboardShortcut("d", modifiers: [.option, .command])
            }
        }

        Settings {
            SettingsView(browserViewModel: browserViewModel)
        }
    }
}
