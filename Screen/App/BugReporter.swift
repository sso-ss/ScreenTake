import AppKit
import Foundation

enum BugReporter {
    static let issueEndpoint = URL(string: "https://github.com/sso-ss/ScreenTake/issues/new")!

    static func issueURL(
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
        buildVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> URL? {
        var components = URLComponents(url: issueEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: "body", value: """
            ## What happened?
            Describe the problem.

            ## Steps to reproduce
            1. Describe your first step.

            ## What did you expect?
            Describe what you expected to happen.

            ## Diagnostics
            - ScreenTake version: \(appVersion) (\(buildVersion))
            - macOS: \(operatingSystem)
            """)
        ]
        return components?.url
    }

    @MainActor
    static func open() {
        guard let url = issueURL() else { return }
        NSWorkspace.shared.open(url)
    }
}
