import AppKit
import AVFoundation
import CoreImage
import SwiftUI

@MainActor
final class TimelineReorderFixture: ObservableObject {
    @Published var trim = VideoTrim(splits: [1, 2])
}

@main
struct TimelineReorderChecks {
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-reorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("colors.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &buffer)
            let color: CIColor = frame < 30 ? .red : (frame < 60 ? .green : .blue)
            context.render(CIImage(color: color), to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 60000))
        await writer.finishWriting()
        precondition(writer.status == .completed)

        let fixture = TimelineReorderFixture()
        let player = AVPlayer(url: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: TimelineReorderPreview(fixture: fixture, player: player, source: source))
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 800_000_000)

        var receivedEvents = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            if event.windowNumber == window.windowNumber { receivedEvents += 1 }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }

        func send(_ type: NSEvent.EventType, at point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
            application.postEvent(event, atStart: false)
        }
        func screenshot(_ name: String) throws {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", "\(window.windowNumber)", "/tmp/Screen-timeline-\(name).png"]
            try capture.run()
            capture.waitUntilExit()
            precondition(capture.terminationStatus == 0)
        }
        try screenshot("before-reorder")
        let start = CGPoint(x: 24 + 652 * 5.0 / 6, y: 82)
        let end = CGPoint(x: 24 + 652 / 6.0, y: 82)
        send(.leftMouseDown, at: start)
        try await Task.sleep(nanoseconds: 50_000_000)
        for step in 1...12 {
            let fraction = Double(step) / 12
            send(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try screenshot("drag-insertion")
        send(.leftMouseUp, at: end)
        try await Task.sleep(nanoseconds: 200_000_000)
        let duration = CMTime(seconds: 3, preferredTimescale: 60000)
        let ordered = try fixture.trim.segments(duration: duration)
        precondition(receivedEvents == 14, "Test mouse events did not reach the window")
        precondition(ordered.map { $0.start.seconds } == [2, 0, 1], "Native drag did not reorder clips")
        try screenshot("after-reorder")
        print("PASS: native strip drag moves the last clip before the first")

        send(.leftMouseDown, at: end)
        try await Task.sleep(nanoseconds: 50_000_000)
        for step in 1...12 {
            let fraction = Double(step) / 12
            send(.leftMouseDragged, at: CGPoint(x: end.x + (start.x - end.x) * fraction, y: end.y))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        send(.leftMouseUp, at: start)
        try await Task.sleep(nanoseconds: 200_000_000)
        let forward = try fixture.trim.segments(duration: duration)
        precondition(forward.map { $0.start.seconds } == [0, 1, 2], "Dragging forward must place the clip after the target")
        func click(_ point: CGPoint) async throws {
            send(.leftMouseDown, at: point)
            try await Task.sleep(nanoseconds: 30_000_000)
            send(.leftMouseUp, at: point)
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        try await click(CGPoint(x: 228, y: 152))
        let undone = try fixture.trim.segments(duration: duration)
        precondition(undone.map { $0.start.seconds } == [2, 0, 1], "Undo must restore the previous clip order")
        print("PASS: native forward drag and Undo restore clip order")
        try await click(CGPoint(x: 350, y: 82))
        try await click(CGPoint(x: 198, y: 152))
        try await Task.sleep(nanoseconds: 200_000_000)
        let joined = try fixture.trim.timeline(duration: duration)
        precondition(joined.duration.seconds == 2 && joined.ranges.map { $0.start.seconds } == [2, 1])
        try screenshot("ripple-cut")
        window.setContentSize(CGSize(width: 500, height: 180))
        try await Task.sleep(nanoseconds: 200_000_000)
        try screenshot("ripple-compact")
        print("PASS: ripple deletion leaves two adjacent clips at normal and compact sizes")
    }
}

struct TimelineReorderPreview: View {
    @ObservedObject var fixture: TimelineReorderFixture
    let player: AVPlayer
    let source: URL

    var body: some View {
        VideoTrimControls(trim: $fixture.trim, duration: 3, player: player, source: source)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DesignColors.controlBackground)
    }
}