import Foundation
import AppKit
import ImageIO

@main
struct BugReporterTest {
    @MainActor
    static func main() throws {
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
        precondition(components?.path == "/sso-ss/ScreenTake/issues/new")
        precondition(query["title"] == "[Bug] ")
        precondition(query["body"]?.contains("ScreenTake version: 0.1.3 (4)") == true)
        precondition(query["body"]?.contains("macOS 15.6.1 (Build 24G90)") == true)
        let privateLog = """
        Export failed for /Users/Someone/My private project/source.mov
        Email someone@example.com, address 192.168.1.12
        Authorization: Bearer abcXYZ123
        api_key=secretValue&other=ok
        {"password": "private password", "token": "privateToken"}
        """
        let redacted = BugReportDiagnostics.redact(privateLog)
        for secret in ["Someone", "source.mov", "someone@example.com", "192.168.1.12", "abcXYZ123", "secretValue", "private password", "privateToken"] {
            precondition(!redacted.contains(secret), "Leaked \(secret): \(redacted)")
        }
        precondition(redacted.contains("Export failed"))
        let report = BugReporter.issueURL(error: privateLog, details: "내보내기가 멈췄어요.",
                                          diagnostics: privateLog, includesScreenshot: true)!
        let reportBody = URLComponents(url: report, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "body" }!.value!
        precondition(reportBody.contains("내보내기가 멈췄어요."))
        precondition(reportBody.contains("## Error"))
        precondition(reportBody.contains("## Recent ScreenTake logs"))
        precondition(reportBody.contains("Command-V"))
        precondition(!reportBody.contains("someone@example.com"))
        let longReport = BugReporter.issueURL(details: String(repeating: "한국어 🧑🏽‍💻", count: 4_000),
                                              diagnostics: String(repeating: privateLog, count: 200))!
        precondition(longReport.absoluteString.utf8.count <= 7_000)
        let longLogs = BugReporter.issueURL(error: "Export failed", diagnostics: String(repeating: "old log line\n", count: 2_000) + "RECENT_FAILURE_END",
                                            includesScreenshot: true)!
        let shortenedBody = URLComponents(url: longLogs, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "body" }!.value!
        precondition(shortenedBody.contains("RECENT_FAILURE_END"))
        precondition(shortenedBody.contains("## App information"))
        precondition(shortenedBody.contains("Export failed"))
        precondition(shortenedBody.contains("Command-V"))
        precondition(shortenedBody.contains("Report shortened"))
        let withoutLogs = BugReporter.issueURL(diagnostics: "")!
        precondition(!withoutLogs.absoluteString.contains("Recent%20ScreenTake%20logs"))

        // Reverse drags, letterboxed image coordinates, and out-of-bounds drags.
        let mask = BugReportScreenshot.mask(from: CGPoint(x: 80, y: 40), to: CGPoint(x: 20, y: 10),
                                             in: CGSize(width: 100, height: 100))!
        precondition(mask == CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.3))
        precondition(BugReportScreenshot.mask(from: .zero, to: CGPoint(x: 1, y: 1), in: CGSize(width: 100, height: 100)) == nil)
        let clamped = BugReportScreenshot.mask(from: CGPoint(x: -20, y: -30), to: CGPoint(x: 120, y: 110),
                                                in: CGSize(width: 100, height: 100))!
        precondition(clamped == CGRect(x: 0, y: 0, width: 1, height: 1))
        let context = CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let original = context.makeImage()!
        let flattened = BugReportScreenshot.flatten(original, masks: [CGRect(x: 0, y: 0, width: 0.5, height: 0.25)])!
        let bitmap = NSBitmapImageRep(cgImage: flattened)
        precondition(bitmap.colorAt(x: 10, y: 10)!.redComponent == 0, "Top-left mask must be opaque black")
        precondition(bitmap.colorAt(x: 10, y: 70)!.redComponent > 0.9, "Bottom-left must stay visible")
        precondition(bitmap.colorAt(x: 80, y: 10)!.redComponent > 0.9, "Outside mask must stay visible")
        precondition(NSBitmapImageRep(cgImage: original).colorAt(x: 10, y: 10)!.redComponent > 0.9)
        let data = BugReportScreenshot.png(flattened)!
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        precondition(CGImageSourceGetCount(source) == 1)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        // ImageIO may generate an EXIF dictionary containing harmless pixel dimensions.
        precondition((properties[kCGImagePropertyExifDictionary] as? NSDictionary)?[kCGImagePropertyExifUserComment] == nil)
        precondition(properties[kCGImagePropertyGPSDictionary] == nil)
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(NSBitmapImageRep(cgImage: decoded).colorAt(x: 10, y: 10)!.redComponent == 0)
        let fullyCovered = BugReportScreenshot.flatten(original, masks: [clamped])!
        precondition(NSBitmapImageRep(cgImage: fullyCovered).colorAt(x: 99, y: 79)!.redComponent == 0)

        // An imported photograph must lose its identifying metadata and honor its orientation.
        let fixtureData = NSMutableData()
        let fixture = CGImageDestinationCreateWithData(fixtureData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(fixture, original, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE_METADATA_NOTE"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "PRIVATE_METADATA_OWNER"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 49.28, kCGImagePropertyGPSLatitudeRef: "N",
                                          kCGImagePropertyGPSLongitude: 123.12, kCGImagePropertyGPSLongitudeRef: "W"]
        ] as CFDictionary)
        precondition(CGImageDestinationFinalize(fixture))
        let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("report-metadata-\(UUID()).jpg")
        try (fixtureData as Data).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let imported = try BugReportScreenshot.load(fixtureURL)
        precondition(imported.width == 80 && imported.height == 100)
        let importedSource = CGImageSourceCreateWithData(BugReportScreenshot.png(imported)! as CFData, nil)!
        let importedProperties = CGImageSourceCopyPropertiesAtIndex(importedSource, 0, nil)! as NSDictionary
        precondition(importedProperties[kCGImagePropertyGPSDictionary] == nil)
        precondition(!importedProperties.description.contains("PRIVATE_METADATA"))
        let logs = BugReportDiagnostics.collect()
        precondition(!logs.isEmpty)
        print("PASS: GitHub diagnostics, sensitive-log filtering, Unicode URL limits, mask coordinates, opaque PNG pixels and metadata removal")
    }
}
