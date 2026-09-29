import AppKit
import AVFoundation
import CoreImage
import SwiftUI

@MainActor
final class ZoomEditorFixture: ObservableObject {
    @Published var trim = VideoTrim()
    @Published var zoomSegments: [ZoomSegment]?
    @Published var selectedZoomID: UUID?
    @Published var automaticZooms: [ZoomSegment] = []
    @Published var zoomHistory: [[ZoomSegment]?] = []
    @Published var zoomPadding: CGFloat = 0
}

@main
struct ZoomEditorChecks {
    @MainActor
    static func main() {
        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                try await runChecks()
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor
    static func runChecks() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("recording.mov")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<120 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
            context.render(CIImage(color: frame < 60 ? .red : .blue), to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 4, preferredTimescale: 60000))
        await writer.finishWriting()
        precondition(writer.status == .completed)

        let mouse = directory.appendingPathComponent("recording.mouse.json")
        let recording = MouseDataRecorder.MouseRecording(
            positions: [],
            clicks: [
                .init(timestamp: 0.5, x: 0.25, y: 0.5, button: 0, isDown: true),
                .init(timestamp: 2, x: 0.75, y: 0.5, button: 0, isDown: true)
            ],
            keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(x: 0, y: 0, width: 320, height: 180)),
            scaleFactor: 1, sampleInterval: 1.0 / 60
        )
        try JSONEncoder().encode(recording).write(to: mouse)

        let fixture = ZoomEditorFixture()
        let player = AVPlayer(url: video)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: ZoomEditorPreview(
            fixture: fixture, player: player, video: video, mouse: mouse
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", "\(window.windowNumber)", "/tmp/Screen-zoom-editor.png"]
        try capture.run()
        capture.waitUntilExit()
        precondition(capture.terminationStatus == 0)
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(nanoseconds: 250_000_000)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: 28, y: 308),
                                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1)!
            application.postEvent(event, atStart: false)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(fixture.trim.splits.count == 1, "Clicking Split should divide the filmstrip at the playhead")
        let gap = CGPoint(x: 34, y: 253)
        let originalPointer = CGEvent(source: nil)?.location
        let screenPoint = window.convertPoint(toScreen: gap)
        let screenHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let target = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
        precondition(CGWarpMouseCursorPosition(target) == .success)
        defer { if let originalPointer { CGWarpMouseCursorPosition(originalPointer) } }
        let hover = NSEvent.mouseEvent(with: .mouseMoved, location: gap,
                                       modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 0, pressure: 0)!
        application.postEvent(hover, atStart: false)
        try await Task.sleep(nanoseconds: 250_000_000)
        let placeholder = Process()
        placeholder.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        placeholder.arguments = ["-x", "-l", "\(window.windowNumber)", "/tmp/Screen-zoom-editor-hover.png"]
        try placeholder.run()
        placeholder.waitUntilExit()
        precondition(placeholder.terminationStatus == 0)
        func click(_ point: CGPoint) async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1)!
                application.postEvent(event, atStart: false)
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        func sendMouse(_ type: NSEvent.EventType, at point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
            application.postEvent(event, atStart: false)
        }
        sendMouse(.leftMouseDown, at: gap)
        try await Task.sleep(nanoseconds: 50_000_000)
        for step in 1...8 {
            sendMouse(.leftMouseDragged, at: CGPoint(x: gap.x + Double(step) * 7, y: gap.y))
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let dragPreview = Process()
        dragPreview.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        dragPreview.arguments = ["-x", "-l", "\(window.windowNumber)", "/tmp/Screen-zoom-editor-drag.png"]
        try dragPreview.run()
        dragPreview.waitUntilExit()
        precondition(dragPreview.terminationStatus == 0)
        sendMouse(.leftMouseUp, at: CGPoint(x: gap.x + 56, y: gap.y))
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(fixture.zoomSegments?.count == 3, "Dragging in an empty section should create a zoom")
        guard let forwardZoom = fixture.zoomSegments?.first(where: { $0.start < 0.5 }) else {
            preconditionFailure("Drag should create a zoom in the empty section")
        }
        precondition(forwardZoom.start < 0.12 && forwardZoom.end > 0.27 && forwardZoom.end < 0.45,
                     "Drag endpoints should set the zoom interval instead of filling the gap")
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil,
                          characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                          isARepeat: false, keyCode: 51)!
        application.postEvent(delete, atStart: false)
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(fixture.zoomSegments?.count == 2, "Delete should remove the dragged zoom")
        let dragEnd = CGPoint(x: gap.x + 56, y: gap.y)
        sendMouse(.leftMouseDown, at: dragEnd)
        try await Task.sleep(nanoseconds: 50_000_000)
        for step in 1...8 {
            sendMouse(.leftMouseDragged, at: CGPoint(x: dragEnd.x - Double(step) * 7, y: gap.y))
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        sendMouse(.leftMouseUp, at: gap)
        try await Task.sleep(nanoseconds: 250_000_000)
        guard let backwardZoom = fixture.zoomSegments?.first(where: { $0.start < 0.5 }) else {
            preconditionFailure("Backward drag should create a zoom")
        }
        precondition(abs(backwardZoom.start - forwardZoom.start) < 0.07 &&
                     abs(backwardZoom.end - forwardZoom.end) < 0.07,
                     "Backward drag should create the same interval")
        try await click(CGPoint(x: 245, y: 253))
        try await Task.sleep(nanoseconds: 500_000_000)
        let selected = Process()
        selected.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        selected.arguments = ["-x", "-l", "\(window.windowNumber)", "/tmp/Screen-zoom-editor-selected.png"]
        try selected.run()
        selected.waitUntilExit()
        precondition(selected.terminationStatus == 0)
        print("PASS: zoom editor displays auto-generated blocks in the native timeline")
    }
}

struct ZoomEditorPreview: View {
    @ObservedObject var fixture: ZoomEditorFixture
    let player: AVPlayer
    let video: URL
    let mouse: URL

    var body: some View {
        VideoTrimControls(trim: $fixture.trim, zoomSegments: $fixture.zoomSegments,
                          zoomEnabled: true, zoomLevel: 2, mouse: mouse,
                          duration: 4, player: player, source: video,
                          selectedZoomID: $fixture.selectedZoomID,
                          automaticZooms: $fixture.automaticZooms,
                          zoomHistory: $fixture.zoomHistory,
                          zoomPadding: $fixture.zoomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}