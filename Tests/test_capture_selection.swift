import AppKit
import ScreenCaptureKit
import AVFoundation

@main
struct CaptureSelectionTests {
    @MainActor
    static func main() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let content = try await ScreenCaptureManager.availableContent()
        let candidates = content.windows.filter(CaptureTarget.isSelectableWindow)
        precondition(!candidates.contains { $0.owningApplication?.bundleIdentifier == "com.apple.screencaptureui" }, "Screenshot overlay must never be selectable")
        precondition(candidates.allSatisfy { $0.windowLayer == 0 }, "System overlays must not be selectable")
        for overlay in content.windows where overlay.owningApplication?.bundleIdentifier == "com.apple.screencaptureui" {
            do {
                _ = try await ScreenCaptureManager.refreshedTarget(.window(overlay))
                preconditionFailure("Stale screenshot overlay selection must fail before recording")
            } catch CaptureError.targetNotFound {}
        }
        let overlapping: [(id: CGWindowID, frame: CGRect)] = [
            (10, CGRect(x: 0, y: 0, width: 800, height: 600)),
            (20, CGRect(x: 100, y: 100, width: 400, height: 300))
        ]
        precondition(CaptureOverlayController.windowID(at: CGPoint(x: 200, y: 200), windows: overlapping, orderedIDs: [99, 20, 10]) == 20)
        precondition(CaptureOverlayController.windowID(at: CGPoint(x: 200, y: 200), windows: overlapping, orderedIDs: [10, 20]) == 10)
        precondition(CaptureOverlayController.windowID(at: CGPoint(x: 50, y: 50), windows: overlapping, orderedIDs: [20, 10]) == 10)
        precondition(CaptureOverlayController.windowID(at: CGPoint(x: 900, y: 900), windows: overlapping, orderedIDs: [20, 10]) == nil)
        print("PASS: Screenshot overlays rejected, stale selections rejected, frontmost eligible window selected")
        let display = content.displays.first { $0.displayID == CGMainDisplayID() }!
        let selection = CaptureOverlayController()
        let border = ZoomIndicatorOverlay()
        defer {
            selection.deactivate()
            border.deactivate()
        }
        let testWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        testWindow.title = "Capture selection check"
        testWindow.backgroundColor = .systemGreen
        testWindow.orderFrontRegardless()
        defer { testWindow.orderOut(nil) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let current = try await ScreenCaptureManager.availableContent()
        let selectedWindow = current.windows.first { $0.windowID == CGWindowID(testWindow.windowNumber) }!
        precondition(CaptureTarget.isSelectableWindow(selectedWindow), "Normal application window must remain selectable")
        let ownApps = current.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        print("Own capture application matches: \(ownApps.count)")
        let filters: [(String, SCContentFilter)] = [
            ("display", SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])),
            ("window", SCContentFilter(desktopIndependentWindow: current.windows.first { $0.windowID == CGWindowID(testWindow.windowNumber) }!))
        ]
        var failures = 0
        for (name, filter) in filters {
            for phase in ["plain", "selected", "recording", "zoomed"] {
                if phase == "selected" { selection.showSelectedBorder(for: .display(display)) }
                if phase == "recording" {
                    selection.deactivate()
                    border.showBorder(captureBounds: NSScreen.screens.first {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                    }!.frame)
                }
                if phase == "zoomed" { border.enterZoom() }
                try await Task.sleep(nanoseconds: 350_000_000)
                let configuration = SCStreamConfiguration()
                configuration.width = name == "display" ? 860 : 600
                configuration.height = name == "display" ? 360 : 400
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let bitmap = NSBitmapImageRep(cgImage: image)
                var total: CGFloat = 0
                var count: CGFloat = 0
                for vertical in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                    for horizontal in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                        let color = bitmap.colorAt(x: horizontal, y: vertical)!.usingColorSpace(.sRGB)!
                        total += max(color.redComponent, color.greenComponent, color.blueComponent)
                        count += 1
                    }
                }
                let brightness = total / count
                print("\(name) \(phase): brightness=\(brightness)")
                if brightness < 0.01 { failures += 1 }
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-selection-\(name)-\(phase).png"))
            }
            border.deactivate()
        }
        precondition(failures == 0, "Selection/recording overlays blacked out capture")
        print("PASS: live display and selected-window capture remain visible through selection, recording and zoom overlays")
        let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("Screen-selected-window-\(UUID().uuidString).mov")
        let manager = ScreenCaptureManager()
        var configuration = CaptureConfiguration.forTarget(.window(selectedWindow), showsCursor: false)
        configuration.capturesAudio = false
        try await manager.startRecording(target: .window(selectedWindow), configuration: configuration,
                                         outputURL: recordingURL, showCursor: false, highlightClicks: true)
        try await Task.sleep(nanoseconds: 700_000_000)
        _ = await manager.stopRecording()
        let movieImage = try await AVAssetImageGenerator(asset: AVURLAsset(url: recordingURL))
            .image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
        let bitmap = NSBitmapImageRep(cgImage: movieImage)
        let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        precondition(center.greenComponent > 0.4 && center.greenComponent > center.redComponent * 1.3,
                     "Selected-window recording must contain the green application window")
        precondition(movieImage.width == configuration.width && movieImage.height == configuration.height,
                     "Selected-window recording must use window dimensions, not full display dimensions")
        print("PASS: production selected-window movie has correct dimensions and visible window content")
        print("VIDEO: \(recordingURL.path)")
    }
}