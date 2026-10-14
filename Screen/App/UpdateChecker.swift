import AppKit
import Combine
import Foundation
import Sparkle

/// A badge survives dismissal and offline launches; Sparkle owns version selection and installation.
struct ScreenRelease: Codable, Equatable {
    let version: String
    let build: String

    func isNewer(than installedBuild: String) -> Bool {
        guard let available = Int(build), let installed = Int(installedBuild) else { return false }
        return available > installed
    }
}

struct UpdateSafety: Equatable {
    var recording = false
    var processing = false
    var selecting = false
    var unsavedWork = false
    var setupComplete = true

    var canCheck: Bool { !recording && !processing && !selecting && setupComplete }
    var canRestart: Bool { canCheck && !unsavedWork }
    var blockingMessage: String {
        if recording { return "Finish recording before updating or quitting." }
        if processing { return "Wait for media processing to finish before updating or quitting." }
        if selecting { return "Close the capture controls before updating or quitting." }
        if unsavedWork { return "Save your project before installing the update or quitting. Exporting a video does not save the editable project." }
        return "Complete permission setup before checking for updates."
    }
}

@MainActor
final class UpdateChecker: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private let defaults: UserDefaults
    private let installedBuild: String
    private weak var appState: AppState?
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private var restartHandler: (() -> Void)?
    private var restartRequested = false

    @Published private(set) var availableRelease: ScreenRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isPresenting = false
    @Published private(set) var restartPending = false
    @Published private(set) var status: String?
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            defaults.set(automaticallyChecksForUpdates, forKey: "SUEnableAutomaticChecks")
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            defaults.set(automaticallyDownloadsUpdates, forKey: "SUAutomaticallyUpdate")
            controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    init(defaults: UserDefaults = .standard,
         installedBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") {
        self.defaults = defaults
        self.installedBuild = installedBuild
        automaticallyChecksForUpdates = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        automaticallyDownloadsUpdates = defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? false
        super.init()
        if let data = defaults.data(forKey: "updates.sparkleRelease"),
           let release = try? JSONDecoder().decode(ScreenRelease.self, from: data),
           release.isNewer(than: installedBuild) {
            availableRelease = release
        } else {
            defaults.removeObject(forKey: "updates.sparkleRelease")
        }
        defaults.removeObject(forKey: "updates.availableRelease")
    }

    var safety: UpdateSafety {
        guard let appState else { return UpdateSafety(setupComplete: false) }
        return UpdateSafety(
            recording: appState.isRecording || appState.isRecordingEditorMedia,
            processing: appState.recording.processingStage != nil || appState.isExportingVideo || appState.editorSession.isBusy,
            selecting: appState.captureToolbarCoordinator != nil || appState.isConfirmingVideoReplacement,
            unsavedWork: appState.hasUnsavedVideoWork || appState.editorSession.hasUnsavedWork,
            setupComplete: defaults.bool(forKey: "hasCompletedPermissionSetup"))
    }

    func start(appState: AppState) {
        guard controller == nil else { return }
        self.appState = appState
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.sessionInProgress, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.isChecking = updater.sessionInProgress }
            }
        ]
        do {
            try controller.updater.start()
        } catch {
            status = "Unable to start the updater. Reinstall the latest ScreenTake build."
            Log.app.error("Updater startup failed: \(error.localizedDescription)")
        }
    }

    func tick(manual: Bool = false) async {
        guard let updater = controller?.updater else { return }
        guard safety.canCheck else {
            if manual { showSafetyMessage() }
            return
        }
        if manual {
            updater.checkForUpdates()
        } else if automaticallyChecksForUpdates && updater.canCheckForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    func showAvailableUpdate() {
        Task { await tick(manual: true) }
    }

    func requestInstallationAfterSettingsClose() -> Bool {
        guard safety.canRestart, restartHandler != nil else { showSafetyMessage(); return false }
        restartRequested = true
        return true
    }

    func settingsDidClose() {
        guard restartRequested else { return }
        restartRequested = false
        // AppKit can decline termination while a sheet is attached. Resume after dismissal.
        DispatchQueue.main.async { [weak self] in self?.resumeInstallation() }
    }

    func resumeInstallation() {
        guard safety.canRestart, let handler = restartHandler else { showSafetyMessage(); return }
        restartHandler = nil
        restartPending = false
        status = nil
        handler()
    }

    func remember(_ release: ScreenRelease?) {
        availableRelease = release
        if let release {
            defaults.set(try? JSONEncoder().encode(release), forKey: "updates.sparkleRelease")
        } else {
            defaults.removeObject(forKey: "updates.sparkleRelease")
        }
    }

    func showSafetyMessage() {
        let message = safety.blockingMessage
        status = message
        let alert = NSAlert()
        alert.messageText = AppLanguage.text("ScreenTake is keeping your work safe")
        alert.informativeText = AppLanguage.text(message)
        alert.addButton(withTitle: AppLanguage.text("OK"))
        if let window = NSApplication.shared.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else if NSApplication.shared.modalWindow == nil {
            alert.runModal()
        }
    }

    // Check again at the delegate boundary: scheduled checks can begin while media is busy.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard safety.canCheck else {
            throw NSError(domain: "ScreenTake.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: AppLanguage.text(safety.blockingMessage)])
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        remember(ScreenRelease(version: item.displayVersionString, build: item.versionString))
        status = nil
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        remember(nil)
        status = "You’re up to date."
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        isPresenting = false
        if let error, (error as NSError).code != SUError.noUpdateError.rawValue {
            Log.app.error("Update check failed: \(error.localizedDescription)")
            status = "Unable to check for updates. Try again later."
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard !safety.canRestart else { return false }
        restartHandler = installHandler
        restartPending = true
        isPresenting = false // Saving and finishing current work must remain possible.
        showSafetyMessage()
        return true
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false // The persistent menu bar badge is the background reminder.
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        isPresenting = handleShowingUpdate
    }

    func standardUserDriverWillFinishUpdateSession() {
        isPresenting = false
    }
}
