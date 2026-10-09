// swiftc -parse-as-library Screen/Models/CaptureTarget.swift Screen/Core/Capture/BrowserContentDetector.swift test_browser_toolbar_detection.swift -o /tmp/browser-toolbar-checks
import AppKit
import AVFoundation

@main
struct BrowserToolbarDetectionChecks {
    @MainActor
    static func main() async throws {
        for dark in [false, true] {
            for scale in [1.0, 1.5] {
                for toolbar in [100, 136] {
                    let image = fixture(dark: dark, scale: scale, toolbar: toolbar)
                    guard let rect = try BrowserContentDetector.detect(image: image) else {
                        fatalError("Sharing indicator not recognized: dark=\(dark), scale=\(scale), toolbar=\(toolbar)")
                    }
                    precondition(abs(rect.minY * 800 - CGFloat(toolbar)) < 5)
                }
            }
            let normal = try BrowserContentDetector.detect(image: fixture(dark: dark, controls: true))
            precondition(normal != nil, "Existing traffic-light detection regressed")
            for image in [fixture(dark: dark, badge: false),
                          fixture(dark: dark, navigation: false),
                          fixture(dark: dark, glyph: false),
                          fixture(dark: dark, address: "Project overview"),
                          fixture(dark: dark, boundary: false)] {
                let result = try BrowserContentDetector.detect(image: image)
                precondition(result == nil, "Accepted incomplete browser evidence")
            }
        }
        print("PASS: light/dark sharing indicators, two scales, bookmarks bar, traffic lights, five negative cases")
        // Optional local regression video. Never include private recording frames in the repository.
        if CommandLine.arguments.count > 1 {
            let rect = try await BrowserContentDetector.detect(in: URL(fileURLWithPath: CommandLine.arguments[1]), at: 0)
            precondition((0.10...0.13).contains(rect.minY), "Unexpected crop for the Chrome regression recording")
            print("PASS: actual Chrome recording agrees across all three samples: \(rect)")
        }
    }

    @MainActor
    static func fixture(dark: Bool, scale: Double = 1, toolbar: Int = 100, controls: Bool = false,
                        badge: Bool = true, navigation: Bool = true, glyph: Bool = true,
                        address: String = "https://example.com/dashboard", boundary: Bool = true) -> CGImage {
        let w = Int(1200 * scale), h = Int(800 * scale)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        let background = NSColor(white: dark ? 0.16 : 0.87, alpha: 1)
        (boundary ? (dark ? NSColor.white : NSColor(white: 0.12, alpha: 1)) : background).setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
        background.setFill()
        NSRect(x: 0, y: 800 - toolbar, width: 1200, height: toolbar).fill()
        let ink = NSColor(white: dark ? 0.8 : 0.35, alpha: 1)
        if controls {
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 20 + index * 22, y: 773, width: 13, height: 13)).fill()
            }
        } else if badge {
            let capsule = NSBezierPath(roundedRect: NSRect(x: 18, y: 773, width: 44, height: 18), xRadius: 9, yRadius: 9)
            NSColor(white: dark ? 0.3 : 0.76, alpha: 1).setFill()
            capsule.fill()
            if glyph {
                ink.setStroke()
                let screen = NSBezierPath(roundedRect: NSRect(x: 34, y: 777, width: 13, height: 10), xRadius: 1, yRadius: 1)
                screen.lineWidth = 1.5
                screen.stroke()
                ink.setFill()
                NSBezierPath(ovalIn: NSRect(x: 44, y: 780, width: 4, height: 4)).fill()
                NSBezierPath(roundedRect: NSRect(x: 42, y: 775, width: 8, height: 4), xRadius: 2, yRadius: 2).fill()
            }
        }
        if navigation {
            ink.setStroke()
            for (index, direction) in [-1.0, 1.0].enumerated() {
                let x = 20.0 + Double(index) * 31
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: x - direction * 5, y: 745))
                arrow.line(to: NSPoint(x: x + direction * 5, y: 745))
                arrow.line(to: NSPoint(x: x, y: 750))
                arrow.move(to: NSPoint(x: x + direction * 5, y: 745))
                arrow.line(to: NSPoint(x: x, y: 740))
                arrow.lineWidth = 1.5
                arrow.stroke()
            }
            let reload = NSBezierPath(ovalIn: NSRect(x: 77, y: 740, width: 10, height: 10))
            reload.lineWidth = 1.5
            reload.stroke()
        }
        NSColor(white: dark ? 0.25 : 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 110, y: 729, width: 920, height: 32), xRadius: 16, yRadius: 16).fill()
        (address as NSString).draw(at: NSPoint(x: 140, y: 736), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: dark ? NSColor.white : NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage!
    }
}
