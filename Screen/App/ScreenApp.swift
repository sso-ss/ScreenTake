import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: ScreenTakeMenuBarController?
    var openMainWindow: (() -> Void)?
    private var pendingMainWindowAction: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: AppAppearance.defaultsKey) ?? "") ?? .system
        appearance.apply()
        AppState.shared.editorConnection.startIfEnabled()
        menuBarController = ScreenTakeMenuBarController(appState: .shared) { [weak self] completion in
            self?.showMainWindow(completion: completion)
        }
        AppState.shared.updates.start(appState: .shared)
        // Refresh the Dock icon when macOS has cached a placeholder for a local build.
        if let icon = AppBrand.icon {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.remove()
        AppState.shared.editorConnection.stop()
    }

    func mainWindowDidAppear() {
        let action = pendingMainWindowAction
        pendingMainWindowAction = nil
        DispatchQueue.main.async { action?() }
    }

    private func showMainWindow(completion: @escaping () -> Void) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: {
            $0.styleMask.contains(.titled) && $0.level == .normal && !($0 is NSPanel)
        }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            completion()
        } else {
            pendingMainWindowAction = completion
            openMainWindow?()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        let ext = url.pathExtension.lowercased()
        if ScreenProject.readablePackageExtensions.contains(ext) {
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

// MARK: - Menu Bar

@MainActor
final class ScreenTakeMenuBarController: NSObject, NSMenuDelegate {
    private let appState: AppState
    private let showWindow: (@escaping () -> Void) -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: 40)
    private let badge = MenuBarUpdateBadge(frame: NSRect(x: 33, y: 9, width: 6, height: 6))
    private var updateSubscription: AnyCancellable?
    private let recordItem = NSMenuItem(title: "", action: #selector(startRecording), keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "", action: #selector(showUpdate), keyEquivalent: "")
    private let checkItem = NSMenuItem(title: "", action: #selector(checkForUpdates), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "")

    init(appState: AppState, showWindow: @escaping (@escaping () -> Void) -> Void) {
        self.appState = appState
        self.showWindow = showWindow
        super.init()
        if let button = statusItem.button {
            button.image = AppBrand.menuBarIcon
            button.imagePosition = .imageOnly
            button.addSubview(badge)
            // Anchor the colored badge independently of the template image.
            badge.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                badge.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: 6),
                badge.heightAnchor.constraint(equalToConstant: 6)
            ])
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let showItem = NSMenuItem(title: AppLanguage.text("Show ScreenTake"), action: #selector(showApp), keyEquivalent: "")
        for item in [showItem, recordItem, updateItem, checkItem, quitItem] { item.target = self }
        menu.addItem(showItem)
        menu.addItem(recordItem)
        menu.addItem(.separator())
        menu.addItem(updateItem)
        menu.addItem(checkItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
        updateSubscription = appState.updates.$availableRelease
            .receive(on: RunLoop.main)
            .sink { [weak self] release in self?.updateBadge(release) }
        updateBadge(appState.updates.availableRelease)
    }

    private var isBusy: Bool {
        appState.isRecording || appState.isRecordingEditorMedia ||
        appState.recording.processingStage != nil || appState.isExportingVideo ||
        appState.captureToolbarCoordinator != nil || appState.updates.isPresenting ||
        appState.isConfirmingVideoReplacement || NSApplication.shared.modalWindow != nil ||
        NSApplication.shared.windows.contains(where: { $0.attachedSheet != nil })
    }

    private var canUseActions: Bool {
        !isBusy && UserDefaults.standard.bool(forKey: "hasCompletedPermissionSetup")
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first?.title = AppLanguage.text("Show ScreenTake")
        recordItem.title = AppLanguage.text("Start Recording")
        recordItem.isEnabled = canUseActions
        updateItem.isHidden = appState.updates.availableRelease == nil
        if let release = appState.updates.availableRelease {
            updateItem.title = "ScreenTake \(release.version) — \(AppLanguage.text("Update Available…"))"
        }
        updateItem.isEnabled = canUseActions
        checkItem.title = AppLanguage.text(appState.updates.isChecking ? "Checking for Updates…" : "Check for Updates...")
        checkItem.isEnabled = canUseActions && !appState.updates.isChecking
        quitItem.title = AppLanguage.text("Quit ScreenTake")
        quitItem.isEnabled = !isBusy
    }

    private func updateBadge(_ release: ScreenRelease?) {
        badge.isHidden = release == nil
        let label = release.map { "ScreenTake — \($0.version) update available" } ?? "ScreenTake"
        statusItem.button?.toolTip = label
        statusItem.button?.setAccessibilityLabel(label)
    }

    @objc private func showApp() { showWindow({}) }

    @objc private func startRecording() {
        guard canUseActions else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { await appState.showCaptureToolbar() }
    }

    @objc private func showUpdate() {
        guard canUseActions else { return }
        showWindow { [weak self] in self?.appState.updates.showAvailableUpdate() }
    }

    @objc private func checkForUpdates() {
        guard canUseActions else { return }
        showWindow { [weak self] in
            guard let self else { return }
            Task { await self.appState.updates.tick(manual: true) }
        }
    }

    @objc private func quit() {
        guard !isBusy else { return }
        NSApplication.shared.terminate(nil)
    }

    func remove() {
        updateSubscription = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

/// A separate view preserves red when macOS tints the monochrome status icon.
private final class MenuBarUpdateBadge: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

/// Screen app entry point
@main
struct ScreenApp: App {

    // MARK: - State

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system
    @AppStorage(AppLanguage.defaultsKey) private var language: AppLanguage = .system
    @Environment(\.openWindow) private var openWindow

    // MARK: - Body

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
                .accentColor(DesignColors.accent)
                .environment(\.locale, language.locale)
                .frame(minWidth: 800, minHeight: 500)
                .onChange(of: appearance) { $0.apply() }
                .onAppear {
                    appDelegate.openMainWindow = { openWindow(id: "main") }
                    appDelegate.mainWindowDidAppear()
                    appearance.apply()
                    GlobalHotkeyManager.shared.registerHotkeys()
                    appState.updates.start(appState: appState)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(AppLanguage.text("About ScreenTake")) {
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
                    if let icon = AppBrand.icon { options[.applicationIcon] = icon }
                    NSApplication.shared.orderFrontStandardAboutPanel(options: options)
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button(AppLanguage.text("Settings…")) {
                    NotificationCenter.default.post(name: .openAppSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button(AppLanguage.text("AI Connection…")) { appState.editorConnection.showSetup() }

                Button(AppLanguage.text("Report a Bug…")) {
                    BugReporter.open()
                }

                Button(AppLanguage.text("Check for Updates...")) {
                    Task { await appState.updates.tick(manual: true) }
                }
                .disabled(appState.isRecording || appState.recording.processingStage != nil || appState.isExportingVideo || appState.captureToolbarCoordinator != nil)
            }

            CommandGroup(replacing: .newItem) {
                Button(AppLanguage.text("Open Video…")) {
                    openVideoFile()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(appState.isRecordingEditorMedia)

                Button(AppLanguage.text("Open Project…")) {
                    openProjectFile()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(appState.isRecordingEditorMedia)
            }

            CommandGroup(after: .newItem) {
                Button(AppLanguage.text("Save Project…")) { saveProjectFile() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(appState.editorSession.videoURL == nil || appState.editorSession.isBusy)
                Divider()

                Button(AppLanguage.text("Start Recording")) {
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
        panel.allowedContentTypes = ScreenProject.readablePackageExtensions.compactMap { UTType(filenameExtension: $0) }
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
        panel.allowedContentTypes = [UTType(filenameExtension: ScreenProject.packageExtension) ?? .package]
        panel.canCreateDirectories = true
        let name = session.projectURL?.deletingPathExtension().lastPathComponent ?? session.projectName
        panel.nameFieldStringValue = "\(name).\(ScreenProject.packageExtension)"
        panel.directoryURL = session.projectURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do { try await session.saveProject(to: url) }
            catch { session.saveError = error.localizedDescription }
        }
    }
}
