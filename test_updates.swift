import AppKit
import Foundation

@main
struct UpdateCheckerTest {
    static func release(_ version: String, host: String = "github.com", prerelease: Bool = false, draft: Bool = false, asset: Bool = true, assetPrefix: String = "Screen-share-") -> ScreenRelease {
        ScreenRelease(tag_name: "v\(version)", html_url: URL(string: "https://\(host)/sso-ss/screen-recorder-mac/releases/tag/v\(version)")!, body: "Update notes", draft: draft, prerelease: prerelease,
                      assets: asset ? [.init(name: "\(assetPrefix)\(version)-build4.zip")] : [])
    }

    @MainActor
    static func main() async throws {
        let suite = "ScreenUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var requests = 0
        var latest = release("0.1.3")
        let checker = UpdateChecker(defaults: defaults, installedVersion: "0.1.2", now: { date }, fetch: {
            requests += 1
            return latest
        })
        precondition(release("0.1.10").isNewer(than: "0.1.9"))
        precondition(release("0.1.6", assetPrefix: "ScreenTake-share-").isNewer(than: "0.1.5"))
        precondition(!release("0.1.2").isNewer(than: "0.1.2"))
        precondition(!release("0.1.1").isNewer(than: "0.1.2"))
        precondition(!release("0.1.2.0").isNewer(than: "0.1.2"))
        for version in ["1..2", "1.2-beta", "1.2.3.4.5", "999999999999999999999999"] {
            precondition(!release(version).isNewer(than: "0.1.2"))
        }
        precondition(!release("0.1.3", host: "example.com").isNewer(than: "0.1.2"))
        precondition(!release("0.1.3", prerelease: true).isNewer(than: "0.1.2"))
        precondition(!release("0.1.3", draft: true).isNewer(than: "0.1.2"))
        precondition(!release("0.1.3", asset: false).isNewer(than: "0.1.2"))
        print("PASS: numeric version comparison, malformed releases, trusted links, downloadable assets")

        await checker.check()
        precondition(requests == 1 && checker.pendingRelease == latest)
        await checker.check()
        precondition(requests == 1)
        checker.dismissUpdate(skip: false)
        date.addTimeInterval(UpdateChecker.interval - 1)
        await checker.check()
        precondition(requests == 1 && checker.pendingRelease == nil)
        date.addTimeInterval(1)
        await checker.check()
        precondition(requests == 2 && checker.pendingRelease == latest)
        checker.dismissUpdate(skip: true)
        date.addTimeInterval(UpdateChecker.interval)
        let restarted = UpdateChecker(defaults: defaults, installedVersion: "0.1.2", now: { date }, fetch: { latest })
        await restarted.check()
        precondition(restarted.pendingRelease == nil)
        await restarted.check(manual: true)
        precondition(restarted.pendingRelease == latest)
        restarted.dismissUpdate(skip: true)
        latest = release("0.1.4")
        date.addTimeInterval(UpdateChecker.interval)
        await restarted.check()
        precondition(restarted.pendingRelease == latest)
        print("PASS: daily throttle, reminder, persisted skip, manual override, subsequent releases")

        let offline = UpdateChecker(defaults: defaults, installedVersion: "0.1.2", fetch: { throw URLError(.notConnectedToInternet) })
        defaults.removeObject(forKey: "updates.lastCheck")
        await offline.check()
        precondition(offline.feedback == nil && !offline.isChecking)
        await offline.check(manual: true)
        precondition(offline.feedback?.contains("Unable") == true)
        let upToDate = UpdateChecker(defaults: defaults, installedVersion: "0.1.4", fetch: { release("0.1.4") })
        await upToDate.check(manual: true)
        precondition(upToDate.pendingRelease == nil && upToDate.feedback?.contains("No newer") == true)
        print("PASS: silent automatic network failure and manual error/up-to-date feedback")

        precondition(UpdateChecker.canPresent(active: true, recording: false, processing: false, selecting: false, setupComplete: true))
        precondition(!UpdateChecker.canPresent(active: false, recording: false, processing: false, selecting: false, setupComplete: true))
        precondition(!UpdateChecker.canPresent(active: true, recording: true, processing: false, selecting: false, setupComplete: true))
        precondition(!UpdateChecker.canPresent(active: true, recording: false, processing: true, selecting: false, setupComplete: true))
        precondition(!UpdateChecker.canPresent(active: true, recording: false, processing: false, selecting: true, setupComplete: true))
        precondition(!UpdateChecker.canPresent(active: true, recording: false, processing: false, selecting: false, setupComplete: false))
        print("PASS: inactive, recording, export, capture selection, and onboarding safety gates")

        if CommandLine.arguments.contains("--live") {
            let live = try await UpdateChecker.fetchLatest()
            precondition(live.html_url.host == "github.com" && !live.assets.isEmpty)
            print("PASS: live GitHub release \(live.tag_name)")
        }
        if CommandLine.arguments.contains("--preview") {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let alert = UpdateChecker.makeUpdateAlert(release: release("0.1.3"), installedVersion: "0.1.2")
            alert.messageText += " (Preview)"
            alert.layout()
            alert.window.center()
            alert.window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let content = alert.window.contentView!
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-update-preview.png"))
            alert.window.orderOut(nil)
            print("PASS: native update dialog preview at /tmp/Screen-update-preview.png")
        }
    }
}