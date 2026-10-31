import AppKit
import Foundation
import SwiftUI

enum BugReporter {
    static let issueEndpoint = URL(string: "https://github.com/sso-ss/ScreenTake/issues/new")!

    static func issueURL(
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
        buildVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString,
        error: String? = nil,
        details: String = "",
        diagnostics: String = "",
        includesScreenshot: Bool = false
    ) -> URL? {
        let title = error.map { "[Bug] " + String(BugReportDiagnostics.redact($0).replacingOccurrences(of: "\n", with: " ").prefix(100)) } ?? "[Bug] "
        var components = URLComponents(url: issueEndpoint, resolvingAgainstBaseURL: false)
        // Leave room for browser and GitHub request limits, including percent-encoded Unicode.
        let suffix = "\n\n[Report shortened to fit GitHub. Add more details in the issue editor.]"
        let sanitizedLogs = BugReportDiagnostics.redact(diagnostics)
        let sanitizedError = error.map(BugReportDiagnostics.redact)
        var recentLogs = String(sanitizedLogs.suffix(12_000))
        var description = String(details.prefix(1_500))
        var errorMessage = sanitizedError.map { String($0.prefix(800)) }
        var shortened = recentLogs.count < sanitizedLogs.count || description.count < details.count || (errorMessage?.count ?? 0) < (sanitizedError?.count ?? 0)
        while true {
            let body = reportBody(appVersion: appVersion, buildVersion: buildVersion,
                                  operatingSystem: operatingSystem, error: errorMessage, details: description,
                                  diagnostics: recentLogs, includesScreenshot: includesScreenshot) + (shortened ? suffix : "")
            components?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
            guard let url = components?.url else { return nil }
            if url.absoluteString.utf8.count <= 7_000 { return url }
            shortened = true
            // Keep the newest logs and preserve the error, app information, and screenshot instructions.
            if !recentLogs.isEmpty { recentLogs = String(recentLogs.dropFirst(200)) }
            else if !description.isEmpty { description = String(description.dropLast(100)) }
            else if let message = errorMessage, !message.isEmpty { errorMessage = String(message.dropLast(100)) }
            else { return nil }
        }
    }

    static func reportBody(
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
        buildVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString,
        error: String? = nil, details: String = "", diagnostics: String = "", includesScreenshot: Bool = false
    ) -> String {
        var body = """
            ## What happened?
            \(details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Describe the problem." : details)

            ## App information
            - ScreenTake version: \(appVersion) (\(buildVersion))
            - macOS: \(operatingSystem)
            """
        if let error, !error.isEmpty { body += "\n\n## Error\n" + BugReportDiagnostics.redact(error) }
        if includesScreenshot { body += "\n\n## Screenshot\nPaste the reviewed screenshot here (Command-V)." }
        if !diagnostics.isEmpty {
            body += "\n\n## Recent ScreenTake logs\n" + BugReportDiagnostics.redact(diagnostics)
                .split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        }
        return body
    }

    @MainActor
    private static var controller: BugReportWindowController?

    @MainActor
    static func open(error: String? = nil) {
        if let controller, controller.window?.isVisible == true {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let source = NSApplication.shared.keyWindow.flatMap { $0 is NSPanel ? nil : $0 }
            ?? NSApplication.shared.windows.first { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
        let report = BugReportWindowController(error: error, sourceWindow: source)
        controller = report
        report.showWindow(nil)
        report.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
