import AppKit
import AVFoundation
import CoreImage
import SwiftUI
@testable import ScreenTake

@main
struct BrowserCropChecks {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: "/tmp/screentake-browser-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Page bounds are relative to the recorded window, including secondary
        // displays and Edge's vertical tabs/sidebar, not the current desktop.
        let window = CGRect(x: -1400, y: 70, width: 1200, height: 800)
        let page = CGRect(x: -1200, y: 180, width: 950, height: 690)
        let edge = BrowserContentDetector.normalizedContent(page, in: window)!
        precondition(abs(edge.minX - 1.0 / 6) < 0.001 && abs(edge.minY - 0.1375) < 0.001)
        precondition(abs(edge.maxX - 1150.0 / 1200) < 0.001 && edge.maxY == 1)
        precondition(BrowserContentDetector.browsers.contains("com.microsoft.edgemac"))
        precondition(BrowserContentDetector.normalizedContent(window, in: window) == nil)
        precondition(!BrowserContentDetector.valid(CGRect(x: 0, y: 0.9, width: 1, height: 0.1)))
        precondition(BrowserContentDetector.isAddress("google.com/?q=test"))
        precondition(BrowserContentDetector.isAddress("edge://newtab"))
        precondition(!BrowserContentDetector.isAddress("Visit google.com"))
        print("PASS: Edge sidebars, secondary-display coordinates, and invalid bounds")

        for (name, toolbar, dark) in [("chrome", 100, false), ("edge-favorites", 136, false), ("safari-dark", 84, true)] {
            let image = fixture(toolbar: toolbar, dark: dark)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
            guard let detected = try BrowserContentDetector.detect(image: image) else {
                fatalError("No browser bounds detected for \(name)")
            }
            precondition(abs(detected.minY * 800 - CGFloat(toolbar)) < 5, "Wrong toolbar boundary: \(name): \(detected)")
        }
        let withoutControls = try BrowserContentDetector.detect(image: fixture(toolbar: 100, controls: false))
        precondition(withoutControls == nil)
        let withoutAddress = try BrowserContentDetector.detect(image: fixture(toolbar: 100, address: "Project overview"))
        precondition(withoutAddress == nil)
        print("PASS: OCR detection for light/dark toolbars and favorites, non-browser rejection")

        let source = directory.appendingPathComponent("browser.mov")
        try? FileManager.default.removeItem(at: source)
        try await makeVideo(source, frames: [fixture(toolbar: 100), fixture(toolbar: 100)])
        let original = try Data(contentsOf: source)
        let session = EditorSession()
        try await session.openVideo(source)
        await session.setBrowserToolbarHidden(true)
        precondition(session.draft.crop.normalized.minY > 0.12, session.browserCropMessage ?? "No result")
        precondition(session.canUndo && !session.isBusy && session.draft.isBrowserToolbarHidden)
        await session.waitForPreview()
        let applied = session.draft.crop
        session.undo()
        precondition(session.draft.crop == PhoneCrop() && !session.draft.isBrowserToolbarHidden)
        session.redo()
        precondition(session.draft.crop == applied && session.draft.isBrowserToolbarHidden)
        await session.waitForPreview()
        await session.setBrowserToolbarHidden(true)
        precondition(session.draft.crop == applied, "Repeated detection must not progressively crop")
        await session.waitForPreview()
        await session.setBrowserToolbarHidden(false)
        precondition(session.draft.crop == PhoneCrop() && !session.draft.isBrowserToolbarHidden)
        session.undo()
        precondition(session.draft.crop == applied && session.draft.isBrowserToolbarHidden)
        session.redo()
        precondition(session.draft.crop == PhoneCrop() && !session.draft.isBrowserToolbarHidden)
        await session.waitForPreview()
        print("PASS: imported-video toggle, on/off, undo/redo, idempotency")

        let previousManual = PhoneCrop(rect: CGRect(x: 0.1, y: 0.03, width: 0.85, height: 0.9))
        try session.updateEdits { $0.crop = previousManual; $0.recordedBrowserContentRect = edge }
        await session.waitForPreview()
        await session.setBrowserToolbarHidden(true)
        precondition(BrowserContentDetector.agree(session.draft.crop.normalized, previousManual.normalized.intersection(edge), tolerance: 0.000001))
        await session.waitForPreview()
        let project = directory.appendingPathComponent("browser.screentake")
        try await session.saveProject(to: project)
        let reopened = EditorSession()
        try await reopened.openProject(project)
        precondition(reopened.draft.recordedBrowserContentRect == edge && reopened.draft.crop == session.draft.crop)
        precondition(reopened.draft.isBrowserToolbarHidden)
        let hiddenCrop = reopened.draft.crop
        await reopened.setBrowserToolbarHidden(false)
        precondition(reopened.draft.crop == previousManual && !reopened.draft.isBrowserToolbarHidden)
        reopened.undo()
        precondition(reopened.draft.crop == hiddenCrop && reopened.draft.isBrowserToolbarHidden)
        await reopened.waitForPreview()
        let count = reopened.undoEdits.count
        try reopened.updateEdits { $0.crop = PhoneCrop(rect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)) }
        precondition(!reopened.draft.isBrowserToolbarHidden && reopened.undoEdits.count == count + 1)
        reopened.undo()
        precondition(reopened.draft.crop == hiddenCrop && reopened.draft.isBrowserToolbarHidden)
        await reopened.waitForPreview()
        print("PASS: reopened toggle restores prior manual crop; manual changes switch off and undo restores")
        let retained = try Data(contentsOf: source)
        precondition(retained == original, "Original media changed")
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.draft)) as! [String: Any]
        oldJSON.removeValue(forKey: "recordedBrowserContentRect")
        oldJSON.removeValue(forKey: "browserToolbarCrop")
        let old = try JSONDecoder().decode(VideoEditSettings.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        precondition(old.recordedBrowserContentRect == nil && !old.isBrowserToolbarHidden)
        print("PASS: recorded Edge page bounds, saved-project round trip, old-project compatibility, original retained")

        let changing = directory.appendingPathComponent("changing.mov")
        try? FileManager.default.removeItem(at: changing)
        try await makeVideo(changing, frames: [fixture(toolbar: 100), fixture(toolbar: 136)])
        do {
            _ = try await BrowserContentDetector.detect(in: changing, at: 0)
            fatalError("Accepted changing toolbar height")
        } catch BrowserContentDetector.DetectionError.changingLayout { }
        print("PASS: changing toolbar layout rejected")
        let plain = directory.appendingPathComponent("plain.mov")
        try? FileManager.default.removeItem(at: plain)
        try await makeVideo(plain, frames: [fixture(toolbar: 100, controls: false)])
        try await session.openVideo(plain)
        try session.updateEdits { $0.crop = PhoneCrop(rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)) }
        await session.waitForPreview()
        let manualCrop = session.draft.crop
        let history = session.undoEdits.count
        await session.setBrowserToolbarHidden(true)
        precondition(session.draft.crop == manualCrop && session.undoEdits.count == history)
        precondition(!session.isBusy && session.browserCropMessage != nil && !session.draft.isBrowserToolbarHidden)
        print("PASS: uncertain detection preserves manual crop and undo history")

        let previewWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 780),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SettingsView(session: reopened).environmentObject(AppState.shared))
        previewWindow.contentView = host
        previewWindow.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("canvas.png"))
        }
        previewWindow.orderOut(nil)
    }

    @MainActor
    static func fixture(toolbar: Int, dark: Bool = false, controls: Bool = true, address: String = "https://example.com/dashboard") -> CGImage {
        let image = NSImage(size: NSSize(width: 1200, height: 800))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(calibratedRed: 0.85, green: 0.90, blue: 0.97, alpha: 1)).setFill()
        NSRect(x: 0, y: 800 - toolbar, width: 1200, height: toolbar).fill()
        if controls {
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 20 + index * 22, y: 773, width: 13, height: 13)).fill()
            }
        }
        (dark ? NSColor(white: 0.25, alpha: 1) : .white).setFill()
        NSBezierPath(roundedRect: NSRect(x: 125, y: 725, width: 920, height: 32), xRadius: 16, yRadius: 16).fill()
        (address as NSString).draw(at: NSPoint(x: 160, y: 732), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: dark ? NSColor.white : NSColor.black])
        ("Sample webpage" as NSString).draw(at: NSPoint(x: 180, y: 420), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    static func makeVideo(_ url: URL, frames: [CGImage]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1200, AVVideoHeightKey: 800])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (index, image) in frames.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1200, 800, kCVPixelFormatType_32BGRA, nil, &buffer)
            let frame = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 1200 / CGFloat(image.width), y: 800 / CGFloat(image.height)))
            CIContext().render(frame, to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(seconds: Double(index), preferredTimescale: 600)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: Double(frames.count), preferredTimescale: 600))
        await writer.finishWriting()
        precondition(writer.status == .completed)
    }
}
