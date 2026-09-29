import SwiftUI
import Combine

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        let ext = url.pathExtension.lowercased()
        if ext == "screenize" {
            NotificationCenter.default.post(
                name: .openProjectFile,
                object: nil,
                userInfo: ["url": url]
            )
        } else if ["mov", "mp4", "m4v"].contains(ext) {
            NotificationCenter.default.post(
                name: .openVideoFile,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Screen app entry point
@main
struct ScreenApp: App {

    // MARK: - State

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    GlobalHotkeyManager.shared.registerHotkeys()
                    appState.updates.start(appState: appState)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Report a Bug…") {
                    BugReporter.open()
                }

                Button("Check for Updates...") {
                    Task { await appState.updates.tick(manual: true) }
                }
                .disabled(appState.isRecording || appState.recording.processingStage != nil || appState.isExportingVideo || appState.captureToolbarCoordinator != nil)
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Video…") {
                    openVideoFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open Project…") {
                    openProjectFile()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandGroup(after: .newItem) {
                Divider()

                Button("Start Recording") {
                    Task {
                        await appState.showCaptureToolbar()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isRecording)
            }
        }
    }

    // MARK: - File Opening

    private func openVideoFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            NotificationCenter.default.post(
                name: .openVideoFile,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }

    private func openProjectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            NotificationCenter.default.post(
                name: .openProjectFile,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }
}
