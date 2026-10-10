import AppKit
import Combine
import Foundation

struct ScreenRelease: Codable, Equatable {
    struct Asset: Codable, Equatable {
        let name: String
    }

    let tag_name: String
    let html_url: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    var version: String {
        tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
    }

    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            result.append(value)
        }
        return result + Array(repeating: 0, count: 4 - result.count)
    }

    func isNewer(than installed: String) -> Bool {
        guard !draft, !prerelease,
              html_url.scheme == "https", html_url.host == "github.com",
              html_url.user == nil, html_url.password == nil, html_url.port == nil,
              html_url.path == "/sso-ss/screen-recorder-mac/releases/tag/\(tag_name)",
              assets.contains(where: { asset in
                  ["Screen-share-", "ScreenTake-share-"].contains(where: { asset.name.hasPrefix("\($0)\(version)-build") })
                      && asset.name.hasSuffix(".zip")
              }),
              let available = Self.components(version),
              let current = Self.components(installed) else { return false }
        return current.lexicographicallyPrecedes(available)
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let interval: TimeInterval = 24 * 60 * 60
    static let endpoint = URL(string: "https://api.github.com/repos/sso-ss/screen-recorder-mac/releases/latest")!

    private let defaults: UserDefaults
    private let installedVersion: String
    private let fetch: () async throws -> ScreenRelease
    private let now: () -> Date
    // Availability outlives a dismissed reminder, including across app launches.
    @Published private(set) var availableRelease: ScreenRelease?
    private(set) var pendingRelease: ScreenRelease?
    private(set) var feedback: String?
    private(set) var isChecking = false
    private(set) var isPresenting = false
    private var timer: Timer?
    private weak var appState: AppState?

    init(
        defaults: UserDefaults = .standard,
        installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        now: @escaping () -> Date = Date.init,
        fetch: @escaping () async throws -> ScreenRelease = UpdateChecker.fetchLatest
    ) {
        self.defaults = defaults
        self.installedVersion = installedVersion
        self.now = now
        self.fetch = fetch
        if let data = defaults.data(forKey: "updates.availableRelease"),
           let release = try? JSONDecoder().decode(ScreenRelease.self, from: data),
           release.isNewer(than: installedVersion) {
            availableRelease = release
        } else {
            defaults.removeObject(forKey: "updates.availableRelease")
        }
    }

    nonisolated static func fetchLatest() async throws -> ScreenRelease {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Screen-Update-Checker", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ScreenRelease.self, from: data)
    }

    var isDue: Bool {
        guard let previous = defaults.object(forKey: "updates.lastCheck") as? Date else { return true }
        return now().timeIntervalSince(previous) >= Self.interval
    }

    func check(manual: Bool = false) async {
        guard !isChecking, !isPresenting, manual || isDue else { return }
        isChecking = true
        defaults.set(now(), forKey: "updates.lastCheck")
        defer { isChecking = false }
        do {
            let release = try await fetch()
            if release.isNewer(than: installedVersion) {
                availableRelease = release
                defaults.set(try? JSONEncoder().encode(release), forKey: "updates.availableRelease")
                pendingRelease = release
                feedback = nil
            } else {
                availableRelease = nil
                pendingRelease = nil
                defaults.removeObject(forKey: "updates.availableRelease")
                if manual {
                    feedback = "No newer downloadable test build was found. You are running ScreenTake \(installedVersion)."
                }
            }
        } catch {
            if manual {
                feedback = "Unable to check for updates. Check your internet connection and try again later."
            }
        }
    }

    func dismissUpdate() {
        defaults.set(now(), forKey: "updates.lastCheck")
        pendingRelease = nil
    }

    func start(appState: AppState) {
        guard timer == nil else { return }
        self.appState = appState
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    func tick(manual: Bool = false) async {
        // A background app can discover releases without bringing up a window.
        guard let appState, Self.canPresent(
            active: true,
            recording: appState.isRecording || appState.isRecordingEditorMedia,
            processing: appState.recording.processingStage != nil || appState.isExportingVideo,
            selecting: appState.captureToolbarCoordinator != nil,
            setupComplete: defaults.bool(forKey: "hasCompletedPermissionSetup")
        ) else { return }
        await check(manual: manual)
        presentIfPossible()
    }

    func showAvailableUpdate() {
        guard let availableRelease else { return }
        pendingRelease = availableRelease
        feedback = nil
        presentIfPossible()
    }

    static func canPresent(active: Bool, recording: Bool, processing: Bool, selecting: Bool, setupComplete: Bool) -> Bool {
        active && !recording && !processing && !selecting && setupComplete
    }

    static func makeUpdateAlert(release: ScreenRelease, installedVersion: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "ScreenTake \(release.version) is available"
        alert.informativeText = "Installed: \(installedVersion)"
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.string = String((release.body ?? "A new test build is available.").prefix(12000))
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        let downloadButton = alert.addButton(withTitle: "Download Update")
        downloadButton.keyEquivalent = "\r"
        downloadButton.bezelColor = .controlAccentColor
        alert.addButton(withTitle: "Remind Me Later").keyEquivalent = "\u{1b}"
        return alert
    }

    private func presentIfPossible() {
        guard !isPresenting, let appState,
              Self.canPresent(active: NSApplication.shared.isActive,
                              recording: appState.isRecording || appState.isRecordingEditorMedia,
                              processing: appState.recording.processingStage != nil || appState.isExportingVideo,
                              selecting: appState.captureToolbarCoordinator != nil,
                              setupComplete: defaults.bool(forKey: "hasCompletedPermissionSetup")),
              let window = NSApplication.shared.keyWindow,
              window.isVisible, window.level == .normal, window.attachedSheet == nil,
              pendingRelease != nil || feedback != nil else { return }
        let release = pendingRelease
        let alert = release.map { Self.makeUpdateAlert(release: $0, installedVersion: installedVersion) } ?? NSAlert()
        if release == nil {
            alert.messageText = "Check for Updates"
            alert.informativeText = feedback ?? ""
            alert.addButton(withTitle: "OK")
        }
        isPresenting = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if let release {
                if response == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(release.html_url)
                }
                self.dismissUpdate()
            }
            self.feedback = nil
            self.isPresenting = false
        }
    }
}