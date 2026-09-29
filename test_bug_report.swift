import Foundation

@main
struct BugReporterTest {
    static func main() {
        let url = BugReporter.issueURL(
            appVersion: "0.1.3",
            buildVersion: "4",
            operatingSystem: "macOS 15.6.1 (Build 24G90)"
        )
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let query = Dictionary(uniqueKeysWithValues: components?.queryItems?.compactMap { item in
            item.value.map { (item.name, $0) }
        } ?? [])

        precondition(components?.scheme == "https")
        precondition(components?.host == "github.com")
        precondition(components?.path == "/sso-ss/screen-recorder-mac/issues/new")
        precondition(query["title"] == "[Bug] ")
        precondition(query["body"]?.contains("Screen version: 0.1.3 (4)") == true)
        precondition(query["body"]?.contains("macOS 15.6.1 (Build 24G90)") == true)
        print("PASS: bug report URL, template, and diagnostics")
    }
}