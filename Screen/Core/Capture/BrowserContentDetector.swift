import AppKit
import ApplicationServices
import AVFoundation
import Vision
import ScreenCaptureKit

/// Browser bounds use normalized, top-left source coordinates, like PhoneCrop.
/// No browser URLs or page text are retained.
enum BrowserContentDetector {
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"
    ]

    static func recordedBounds(for target: CaptureTarget) async -> CGRect? {
        guard case .window(let window) = target,
              let owner = window.owningApplication, browsers.contains(owner.bundleIdentifier),
              AXIsProcessTrusted() else { return nil }
        let pid = owner.processID
        let bounds = window.frame
        let title = window.title
        return await Task.detached(priority: .utility) {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.15)
            let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let matches = windows.filter { element in
                guard let frame = frame(element) else { return false }
                return abs(frame.minX - bounds.minX) < 2 && abs(frame.minY - bounds.minY) < 2
                    && abs(frame.width - bounds.width) < 2 && abs(frame.height - bounds.height) < 2
            }
            let selected = matches.count == 1 ? matches.first : matches.first {
                title != nil && (attribute($0, kAXTitleAttribute) as? String) == title
            }
            guard let selected else { return nil }
            var queue = [selected]
            var index = 0
            var candidates: [CGRect] = []
            let deadline = Date().addingTimeInterval(0.8)
            while index < queue.count && index < 250 && Date() < deadline {
                let element = queue[index]
                index += 1
                if (attribute(element, kAXRoleAttribute) as? String) == "AXWebArea" {
                    if let web = frame(element), let rect = normalizedContent(web, in: bounds) {
                        candidates.append(rect)
                    }
                    // Stop at the page root; nested frames are not browser viewports.
                    continue
                }
                queue += (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            }
            return candidates.max { $0.width * $0.height < $1.width * $1.height }
        }.value
    }

    static func normalizedContent(_ content: CGRect, in window: CGRect) -> CGRect? {
        guard window.width > 0, window.height > 0 else { return nil }
        let visible = content.intersection(window)
        guard !visible.isNull else { return nil }
        let rect = CGRect(x: (visible.minX - window.minX) / window.width,
                          y: (visible.minY - window.minY) / window.height,
                          width: visible.width / window.width, height: visible.height / window.height)
        return valid(rect) ? rect : nil
    }

    static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect)
            && rect.width >= 0.45 && rect.height >= 0.4
            && rect.minY >= 0.015 && rect.minY < 0.35
    }

    static func agree(_ first: CGRect, _ second: CGRect, tolerance: CGFloat = 0.008) -> Bool {
        zip([first.minX, first.minY, first.maxX, first.maxY],
            [second.minX, second.minY, second.maxX, second.maxY])
            .allSatisfy { abs($0 - $1) <= tolerance }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    /// Imported videos have no accessibility metadata. Require a URL, macOS
    /// window controls, and a strong toolbar boundary at the same height in
    /// multiple frames. Uncertain results leave the user's crop alone.
    static func detect(in source: URL, at time: Double) async throws -> CGRect {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: source)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw DetectionError.notFound }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1600, height: 1600)
            // Default tolerances can return the same keyframe for every sample,
            // hiding a toolbar/layout change later in the recording.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let end = max(0, duration - 0.05)
            let seconds = [min(end, max(0, time)), min(end, duration * 0.25), min(end, duration * 0.75)]
            var results: [CGRect] = []
            for second in seconds {
                try Task.checkCancellation()
                let image = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image
                guard let rect = try detect(image: image) else { throw DetectionError.notFound }
                results.append(rect)
            }
            guard let first = results.first, results.allSatisfy({ agree(first, $0) }) else {
                throw DetectionError.changingLayout
            }
            return first
        }.value
    }

    static func detect(image: CGImage) throws -> CGRect? {
        guard let pixels = Pixels(image), pixels.hasWindowControls else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.regionOfInterest = CGRect(x: 0, y: 0.70, width: 1, height: 0.30)
        try VNImageRequestHandler(cgImage: image).perform([request])
        let addresses = (request.results ?? []).compactMap { observation -> CGRect? in
            guard let text = observation.topCandidates(1).first, text.confidence >= 0.5,
                  isAddress(text.string) else { return nil }
            let box = observation.boundingBox
            // Vision returns bounds relative to the request's region of interest.
            let top = CGRect(x: box.minX, y: (1 - box.maxY) * 0.30,
                             width: box.width, height: box.height * 0.30)
            guard top.minX > 0.035, top.minX < 0.65, top.minY < 0.24,
                  top.width > 0.045, top.height > 0.006 else { return nil }
            return top
        }.sorted { $0.minY < $1.minY }
        for address in addresses {
            if let bottom = pixels.toolbarBottom(below: address) {
                let rect = CGRect(x: 0, y: bottom, width: 1, height: 1 - bottom)
                if valid(rect) { return rect }
            }
        }
        return nil
    }

    static func isAddress(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.contains(" ") else { return false }
        return value.range(of: #"^(https?://|file:///|edge://|chrome://|about:|localhost[:/]|(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[/:?#]|$))"#,
                           options: .regularExpression) != nil
    }

    private struct Pixels {
        let width: Int
        let height: Int
        var bytes: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            guard width >= 240, height >= 180 else { return nil }
            bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { memory -> Bool in
                guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
        }

        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }

        var hasWindowControls: Bool {
            // Look for the red/yellow/green control sequence, not arbitrary page URLs.
            for y in stride(from: 4, to: max(5, height / 8), by: 2) {
                var centers: [Int?] = [nil, nil, nil]
                for x in 4..<max(5, width / 5) {
                    let (r, g, b) = rgb(x, y)
                    if r > 200 && g > 45 && g < 140 && b < 140 { centers[0] = x }
                    if centers[0] != nil && r > 200 && g > 145 && b < 110 { centers[1] = x }
                    if centers[1] != nil && r < 100 && g > 145 && b < 150 { centers[2] = x }
                    if let red = centers[0], let yellow = centers[1], let green = centers[2],
                       red < yellow, yellow < green, green - red < width / 8,
                       abs((yellow - red) - (green - yellow)) < max(6, width / 100) { return true }
                }
            }
            return false
        }

        func toolbarBottom(below address: CGRect) -> CGFloat? {
            let textHeight = address.height * CGFloat(height)
            let start = Int(address.maxY * CGFloat(height) + textHeight * 0.45)
            let end = min(height - 4, Int(min(0.34 * CGFloat(height), address.maxY * CGFloat(height) + textHeight * 5)))
            guard start < end else { return nil }
            let step = max(1, width / 180)
            let xs = Array(stride(from: width / 30, to: width * 29 / 30, by: step))
            for y in start..<end {
                var changed = 0
                var quiet = 0
                for x in xs {
                    let a = rgb(x, max(0, y - 2)), line = rgb(x, y), b = rgb(x, y + 2), c = rgb(x, y + 3)
                    let difference = max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2),
                                         abs(line.0 - b.0), abs(line.1 - b.1), abs(line.2 - b.2))
                    if difference >= 10 { changed += 1 }
                    if max(abs(b.0 - c.0), abs(b.1 - c.1), abs(b.2 - c.2)) < 8 { quiet += 1 }
                }
                // The address pill itself can span most of a window. Require a
                // boundary across almost the entire width, beyond that pill.
                if Double(changed) / Double(xs.count) > 0.92 && Double(quiet) / Double(xs.count) > 0.8 {
                    return CGFloat(y + 3) / CGFloat(height)
                }
            }
            return nil
        }
    }

    enum DetectionError: LocalizedError {
        case notFound, changingLayout
        var errorDescription: String? {
            switch self {
            case .notFound: return "Couldn’t confidently detect the browser toolbar. Use Crop Screen to adjust it manually."
            case .changingLayout: return "The browser layout changes during this video. Use Crop Screen to choose a crop."
            }
        }
    }
}
