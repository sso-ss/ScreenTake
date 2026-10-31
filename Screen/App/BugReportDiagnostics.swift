import AppKit
import OSLog
import ImageIO
import UniformTypeIdentifiers

enum BugReportDiagnostics {
    /// Collect only this process's ScreenTake messages, never other applications' logs.
    static func collect(now: Date = Date()) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: now.addingTimeInterval(-300))
            let predicate = NSPredicate(format: "subsystem == %@", Bundle.main.bundleIdentifier ?? "com.screen.Screen")
            let entries = try store.getEntries(at: position, matching: predicate)
            let formatter = ISO8601DateFormatter()
            var lines: [String] = []
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                lines.append("\(formatter.string(from: log.date)) [\(log.category)] \(redact(log.composedMessage))")
                if lines.count > 100 { lines.removeFirst() }
            }
            return lines.isEmpty ? "No recent ScreenTake logs are available." : String(lines.joined(separator: "\n").suffix(12_000))
        } catch {
            return "Recent ScreenTake logs could not be read. The error and app information are still included."
        }
    }

    static func redact(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [redacted]"),
            (#"(?i)\b(authorization|password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|secret|token)\b[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;&]+)"#, "$1=[redacted]"),
            (#"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
            (#"(?:file://)?/(?:Users|Volumes|private|tmp|var|Applications|Library|System|opt|usr|dev)/[^\n\"'<>]*"#, "[path]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[address]")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }
}

enum BugReportScreenshot {
    static let maximumDimension: CGFloat = 2_400

    /// Decode and rasterize a single frame. Source metadata and extra frames are discarded.
    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), let flattened = flatten(image) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return flattened
    }

    /// Rectangles use normalized, top-left coordinates, matching the screenshot editor.
    static func flatten(_ image: CGImage, masks: [CGRect] = []) -> CGImage? {
        let scale = min(1, maximumDimension / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for mask in masks {
            let rect = mask.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !rect.isNull else { continue }
            context.fill(CGRect(x: rect.minX * CGFloat(width), y: (1 - rect.maxY) * CGFloat(height),
                                width: rect.width * CGFloat(width), height: rect.height * CGFloat(height)).integral)
        }
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func mask(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(start.x - end.x), height: abs(start.y - end.y))
            .intersection(CGRect(origin: .zero, size: size))
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return nil }
        return CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                      width: rect.width / size.width, height: rect.height / size.height)
    }
}
