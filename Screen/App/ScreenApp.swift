import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.editorConnection.startIfEnabled()
        // Refresh the Dock icon when macOS has cached a placeholder for a local build.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.editorConnection.stop()
    }

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
                .accentColor(DesignColors.accent)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    GlobalHotkeyManager.shared.registerHotkeys()
                    appState.updates.start(appState: appState)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("AI Connection…") { appState.editorConnection.showSetup() }

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
                .disabled(appState.isRecordingEditorMedia)

                Button("Open Project…") {
                    openProjectFile()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(appState.isRecordingEditorMedia)
            }

            CommandGroup(after: .newItem) {
                Button("Save Project…") { saveProjectFile() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(appState.editorSession.videoURL == nil || appState.editorSession.isBusy)
                Divider()

                Button("Start Recording") {
                    Task {
                        await appState.showCaptureToolbar()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isRecording || appState.isRecordingEditorMedia)
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
        panel.allowedContentTypes = [UTType(filenameExtension: "screenize") ?? .package]
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

    private func saveProjectFile() {
        let session = appState.editorSession
        guard session.videoURL != nil, !session.isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "Save Project"
        panel.allowedContentTypes = [UTType(filenameExtension: "screenize") ?? .package]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = session.projectURL?.lastPathComponent ?? "\(session.projectName).screenize"
        panel.directoryURL = session.projectURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do { try await session.saveProject(to: url) }
            catch { session.saveError = error.localizedDescription }
        }
    }
}
