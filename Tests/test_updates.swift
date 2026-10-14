import AppKit
import Foundation
import Sparkle

@main
struct UpdateCheckerTests {
    @MainActor
    static func main() throws {
        let suite = "ScreenTake.UpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let checker = UpdateChecker(defaults: defaults, installedBuild: "18")
        precondition(checker.automaticallyChecksForUpdates)
        precondition(!checker.automaticallyDownloadsUpdates)
        checker.automaticallyChecksForUpdates = false
        checker.automaticallyDownloadsUpdates = true
        let relaunched = UpdateChecker(defaults: defaults, installedBuild: "18")
        precondition(!relaunched.automaticallyChecksForUpdates && relaunched.automaticallyDownloadsUpdates)
        print("PASS: check defaults, opt-in automatic installs, and persisted preferences")

        let newer = ScreenRelease(version: "0.1.17", build: "19")
        checker.remember(newer)
        precondition(UpdateChecker(defaults: defaults, installedBuild: "18").availableRelease == newer)
        precondition(UpdateChecker(defaults: defaults, installedBuild: "19").availableRelease == nil)
        defaults.set(Data("corrupt".utf8), forKey: "updates.sparkleRelease")
        precondition(UpdateChecker(defaults: defaults, installedBuild: "18").availableRelease == nil)
        precondition(!ScreenRelease(version: "invalid", build: "beta").isNewer(than: "18"))
        precondition(!ScreenRelease(version: "0.1.16", build: "18").isNewer(than: "18"))
        checker.remember(newer)
        checker.remember(nil)
        precondition(defaults.data(forKey: "updates.sparkleRelease") == nil)
        print("PASS: available badge survives relaunch, installed/withdrawn badge clears, corrupt cache rejected")

        precondition(UpdateSafety().canCheck && UpdateSafety().canRestart)
        let dirty = UpdateSafety(unsavedWork: true)
        precondition(dirty.canCheck && !dirty.canRestart)
        for unsafe in [UpdateSafety(recording: true), UpdateSafety(processing: true),
                       UpdateSafety(selecting: true), UpdateSafety(setupComplete: false)] {
            precondition(!unsafe.canCheck && !unsafe.canRestart)
        }
        print("PASS: recording, export/processing, capture selection, onboarding and unsaved restart protection")

        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Screen/Info.plist")), format: nil) as! [String: Any]
        precondition(info["SUFeedURL"] as? String == "https://sso-ss.github.io/ScreenTake/appcast.xml")
        precondition(info["SUPublicEDKey"] as? String == "8ZGF+YBJisBtZCmLfs6sY+87Y2zJaqzN0Kolz70lmbE=")
        precondition(info["SURequireSignedFeed"] as? Bool == true)
        precondition(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        precondition(info["SUAutomaticallyUpdate"] as? Bool == false)
        for selector in ["updater:mayPerformUpdateCheck:error:", "updater:didFindValidUpdate:",
                         "updaterDidNotFindUpdate:error:", "updater:didFinishUpdateCycleForUpdateCheck:error:",
                         "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
                         "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
                         "standardUserDriverWillHandleShowingUpdate:forUpdate:state:"] {
            precondition(checker.responds(to: NSSelectorFromString(selector)), "Missing Sparkle callback: \(selector)")
        }
        precondition(checker.supportsGentleScheduledUpdateReminders)
        print("PASS: pinned HTTPS feed/key, required signed feeds and archives, non-interrupting background reminders")
    }
}
