import AppKit
import AVFoundation
import CoreImage
import SwiftUI

@main
struct EditorOverlayTypeChecks {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editor-overlay-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frame = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
        let context = CIContext()
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, nil, &buffer)
            context.render(frame, to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        await writer.finishWriting()
        precondition(writer.status == .completed)

        let session = EditorSession()
        try await session.openVideo(url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 850),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SettingsView(session: session).environmentObject(AppState.shared))
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 400_000_000)

        func click(x: CGFloat, top: CGFloat) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 850 - top),
                                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
        }
        click(x: 965, top: 201)
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: ".build/editor-overlay-type-check.png"))
        click(x: 883, top: 480)
        precondition(session.draft.webcamShape == .cutout)
        print("PASS: Background Removed is selectable in the editor before adding a camera take")

        session.draft.videoOverlayURL = url
        session.draft.webcamEnabled = true
        session.draft.cameraLayout.layout = .fullScreen
        session.draft.webcamShape = .circle
        try await Task.sleep(nanoseconds: 400_000_000)
        host.layoutSubtreeIfNeeded()
        let fullScreenBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: fullScreenBitmap)
        try fullScreenBitmap.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: ".build/editor-overlay-fullscreen.png"))
        click(x: 870, top: 583)
        precondition(session.draft.webcamShape == .cutout && session.draft.cameraLayout.layout == .overlay)
        print("PASS: Background Removed switches a full screen camera section to Overlay")
        window.orderOut(nil)
    }
}
