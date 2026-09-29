import AppKit
import AVFoundation
import CoreImage
import SwiftUI

@main
struct LiveEditPreviewTests {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--recording" {
            try await verifyRecording(URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = CIContext()
        let sourceSize = CGSize(width: 640, height: 400)
        func makeVideo(_ name: String, webcam: Bool) async throws -> URL {
            let url = directory.appendingPathComponent(name + ".mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 400
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            precondition(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            for index in 0..<30 {
                while !input.isReadyForMoreMediaData { await Task.yield() }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 640, 400, kCVPixelFormatType_32BGRA, nil, &buffer)
                let base = CIImage(color: webcam ? CIColor(red: 0, green: 1, blue: 0) : CIColor(red: 0, green: 0, blue: 1))
                    .cropped(to: CGRect(origin: .zero, size: sourceSize))
                let image = webcam ? base : CIImage(color: CIColor(red: 1, green: 0, blue: 0))
                    .cropped(to: CGRect(x: 0, y: 0, width: 160 + index * 2, height: 400)).composited(over: base)
                context.render(image, to: buffer!)
                precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
            await writer.finishWriting()
            precondition(writer.status == .completed)
            return url
        }
        let source = try await makeVideo("source", webcam: false)
        let webcam = try await makeVideo("webcam", webcam: true)
        let mouseURL = directory.appendingPathComponent("mouse.json")
        let mouse = MouseDataRecorder.MouseRecording(
            positions: [.init(timestamp: 0, x: 0.5, y: 0.5, velocity: 0)],
            clicks: [.init(timestamp: 0.1, x: 0.5, y: 0.5, button: 0, isDown: true)],
            keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(origin: .zero, size: sourceSize)), scaleFactor: 1, sampleInterval: 1.0 / 60)
        try JSONEncoder().encode(mouse).write(to: mouseURL)
        var settings = VideoEditSettings(backgroundEnabled: false, showCursor: false)
        func item(_ draft: VideoEditSettings) async throws -> AVPlayerItem {
            let result = try await LiveVideoPreview.makeItem(.init(source: source, audio: source, mouse: mouseURL, webcam: webcam, settings: draft))
            precondition(result.videoComposition?.frameDuration == CMTime(value: 1, timescale: 60))
            precondition(result.videoComposition?.sourceTrackIDForFrameTiming == kCMPersistentTrackID_Invalid)
            return result
        }
        func frame(_ draft: VideoEditSettings, time: Double = 0.7) async throws -> NSBitmapImageRep {
            let playerItem = try await item(draft)
            let generator = AVAssetImageGenerator(asset: playerItem.asset)
            generator.videoComposition = playerItem.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            return NSBitmapImageRep(cgImage: image)
        }
        func color(_ image: NSBitmapImageRep, _ horizontal: Int, _ vertical: Int) -> NSColor {
            image.colorAt(x: horizontal, y: vertical)!.usingColorSpace(.sRGB)!
        }
        let plain = try await frame(settings)
        precondition(plain.pixelsWide == 640 && plain.pixelsHigh == 400)
        precondition(color(plain, 50, 200).redComponent > 0.8)
        precondition(color(plain, 500, 200).blueComponent > 0.8)
        settings.zoomEnabled = true
        let zoomed = try await frame(settings)
        precondition(color(zoomed, 160, 200).blueComponent > 0.8)
        precondition(color(plain, 160, 200).redComponent > 0.8)
        settings.zoomLevel = 1.25
        let subtleZoom = try await frame(settings)
        settings.zoomLevel = 3
        let strongZoom = try await frame(settings)
        precondition(color(subtleZoom, 100, 200).redComponent > 0.8)
        precondition(color(strongZoom, 100, 200).blueComponent > 0.8)
        print("PASS: manual zoom magnification updates the live preview")
        settings.zoomEnabled = false
        settings.backgroundEnabled = true
        settings.wallpaper = .blossom
        let background = try await frame(settings)
        settings.wallpaper = .ocean
        let changed = try await frame(settings)
        precondition(abs(color(background, 4, 4).redComponent - color(changed, 4, 4).redComponent) > 0.1)
        print("PASS: playback composition updates zoom and background on the same paused timestamp")
        settings.ratio = .portrait
        let portrait = try await frame(settings)
        precondition(portrait.pixelsWide == 1080 && portrait.pixelsHigh == 1350)
        let geometry = CanvasGeometry(size: CGSize(width: 1080, height: 1350), layout: .desktop, sourceSize: sourceSize)
        let rect = geometry.desktop!
        precondition(color(portrait, Int(rect.minX + rect.width * 0.1), 675).redComponent > 0.8)
        precondition(color(portrait, Int(rect.minX + rect.width * 0.9), 675).blueComponent > 0.8)
        print("PASS: resized canvas retains source proportions and both source edges")
        settings.layout = .iPhone
        settings.crop = PhoneCrop(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        settings.phoneMode = .fill
        let phone = try await frame(settings)
        precondition(color(phone, 540, 675).blueComponent > 0.8)
        print("PASS: live iPhone crop and Fill preview")
        settings = VideoEditSettings(backgroundEnabled: false, showCursor: false, webcamEnabled: true)
        let webcamFrame = try await frame(settings)
        let diameter = CGFloat(400) * PiPSize.medium.fraction
        let horizontal = Int(640 - 24 - diameter / 2)
        let vertical = Int(400 - 24 - diameter / 2)
        try webcamFrame.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-live-webcam-check.png"))
        precondition(color(webcamFrame, horizontal, vertical).greenComponent > 0.8)
        settings.webcamShape = .roundedSquare
        let roundedSquare = try await frame(settings)
        let left = Int(640 - 24 - diameter)
        let top = Int(400 - 24 - diameter)
        try roundedSquare.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-live-webcam-rounded-square-check.png"))
        precondition(abs(color(roundedSquare, left + 1, top + 1).greenComponent
                 - color(plain, left + 1, top + 1).greenComponent) < 0.03,
                 "Rounded-square outer corner should reveal the screen")
        precondition(color(roundedSquare, left + 12, top + 12).greenComponent > 0.8,
                 "Rounded-square inset corner should contain the webcam")
        print("PASS: rounded-square webcam mask preserves rounded corners")
        settings.webcamEnabled = false
        let noWebcam = try await frame(settings)
        let restoredColor = color(noWebcam, horizontal, vertical)
        let originalColor = color(plain, horizontal, vertical)
        precondition(abs(restoredColor.greenComponent - originalColor.greenComponent) < 0.02)
        precondition(abs(restoredColor.blueComponent - originalColor.blueComponent) < 0.02)
        print("PASS: webcam show/hide in live playback composition")
        settings.showCursor = true
        settings.cursorShape = .circle
        let cursorFrame = try await frame(settings)
        precondition(color(cursorFrame, 320, 200).redComponent > 0.15 &&
                 color(cursorFrame, 320, 200).blueComponent > 0.8)
        print("PASS: live cursor style at recorded position")
        settings.showCursor = false
        let early = try await frame(settings, time: 0)
        let late = try await frame(settings, time: 0.9)
        precondition(color(early, 190, 200).blueComponent > 0.8 && color(late, 190, 200).redComponent > 0.8)
        print("PASS: composition renders changing video frames, not only a still")

        for effects in [false, true] {
            settings.zoomEnabled = effects
            settings.showCursor = effects
            settings.webcamEnabled = effects
            settings.trim = VideoTrim()
            let originalFrame = try await frame(settings, time: 0.7)
            settings.trim = VideoTrim(start: 0.5, end: 0.9)
            let trimmedItem = try await item(settings)
            let trimmedDuration = try await trimmedItem.asset.load(.duration)
            precondition(abs(trimmedDuration.seconds - 0.4) < 0.002)
            let trimmedFrame = try await frame(settings, time: 0.2)
            for vertical in stride(from: 10, to: 400, by: 20) {
                for horizontal in stride(from: 10, to: 640, by: 20) {
                    let expected = color(originalFrame, horizontal, vertical)
                    let actual = color(trimmedFrame, horizontal, vertical)
                    precondition(abs(expected.redComponent - actual.redComponent) < 0.03)
                    precondition(abs(expected.greenComponent - actual.greenComponent) < 0.03)
                    precondition(abs(expected.blueComponent - actual.blueComponent) < 0.03)
                }
            }
        }
        print("PASS: trimmed preview matches original video, zoom, cursor and webcam timestamps")

        settings.trim = VideoTrim()
        let beforeCuts = try await frame(settings, time: 0.7)
        settings.trim = VideoTrim(cuts: [.init(start: 0.1, end: 0.2), .init(start: 0.3, end: 0.5)])
        let afterCuts = try await frame(settings, time: 0.4)
        for vertical in stride(from: 10, to: 400, by: 20) {
            for horizontal in stride(from: 10, to: 640, by: 20) {
                let expected = color(beforeCuts, horizontal, vertical)
                let actual = color(afterCuts, horizontal, vertical)
                precondition(abs(expected.redComponent - actual.redComponent) < 0.03)
                precondition(abs(expected.greenComponent - actual.greenComponent) < 0.03)
                precondition(abs(expected.blueComponent - actual.blueComponent) < 0.03)
            }
        }
        print("PASS: multiple middle cuts preserve zoom, cursor and webcam source timestamps")

        settings.trim = VideoTrim()
        let reorderReference = try await frame(settings, time: 0.7)
        precondition(settings.trim.split(at: 0.5, duration: CMTime(seconds: 1, preferredTimescale: 60000)))
        precondition(settings.trim.moveSegment(from: 1, to: 0, duration: CMTime(seconds: 1, preferredTimescale: 60000)))
        let reorderedFrame = try await frame(settings, time: 0.2)
        for vertical in stride(from: 10, to: 400, by: 20) {
            for horizontal in stride(from: 10, to: 640, by: 20) {
                let expected = color(reorderReference, horizontal, vertical)
                let actual = color(reorderedFrame, horizontal, vertical)
                precondition(abs(expected.redComponent - actual.redComponent) < 0.03)
                precondition(abs(expected.greenComponent - actual.greenComponent) < 0.03)
                precondition(abs(expected.blueComponent - actual.blueComponent) < 0.03)
            }
        }
        settings.trim = VideoTrim(cuts: [.init(start: 0.1, end: 0.2), .init(start: 0.3, end: 0.5)])
        print("PASS: reordered preview preserves source video, zoom, cursor and webcam timestamps")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(AppState.shared))
        window.center()
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 150_000_000)
        NotificationCenter.default.post(name: .openVideoFile, object: nil, userInfo: ["url": source])
        for (name, dimensions) in [("normal", CGSize(width: 1000, height: 850)), ("minimum", CGSize(width: 800, height: 500))] {
            window.setContentSize(dimensions)
            try await Task.sleep(nanoseconds: 500_000_000)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", "\(window.windowNumber)", "/tmp/Screen-live-edit-\(name).png"]
            try capture.run()
            capture.waitUntilExit()
            precondition(capture.terminationStatus == 0)
        }
        window.orderOut(nil)
        let cutsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
        cutsWindow.appearance = NSAppearance(named: .darkAqua)
        let audioURL = directory.appendingPathComponent("cleanup.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        audio.frameLength = 48000
        for index in 0..<48000 {
            audio.floatChannelData![0][index] = index < 4800 ? Float(sin(Double(index) / 48000 * 440 * 2 * .pi) * 0.2) : 0
        }
        do { try AVAudioFile(forWriting: audioURL, settings: format.settings).write(from: audio) }
        let review = SilenceReview()
        let retainedTrim = VideoTrim(cuts: [.init(start: 0.4, end: 0.5)])
        review.analyze(audio: audioURL, trim: retainedTrim, duration: 1)
        for _ in 0..<200 where review.analyzing { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!review.analyzing && review.suggestions.count == 2)
        precondition(review.suggestions.allSatisfy { $0.end <= 0.4 || $0.start >= 0.5 })
        precondition(retainedTrim.cuts.count == 1, "Detection must not apply cuts")
        review.selected = []
        precondition(review.applying(to: retainedTrim, duration: 1) == nil)
        review.selected = Set(review.suggestions.map(\.id))
        let accepted = review.applying(to: retainedTrim, duration: 1)!
        let acceptedTimeline = try accepted.timeline(duration: CMTime(seconds: 1, preferredTimescale: 60000))
        precondition(accepted.cuts.count == 3 && abs(acceptedTimeline.duration.seconds - 0.25) < 0.025)
        let reviewPlayer = AVPlayer(playerItem: try await LiveVideoPreview.makeItem(.init(source: source, audio: audioURL, mouse: nil, webcam: nil, settings: .init(backgroundEnabled: false, showCursor: false))))
        let reviewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        reviewWindow.appearance = NSAppearance(named: .darkAqua)
        reviewWindow.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            NativeVideoPlayerView(player: reviewPlayer, showsControls: false).frame(height: 80)
            VideoTrimControls(trim: .constant(retainedTrim), duration: 1, player: reviewPlayer, source: source, audio: audioURL, silence: review)
        })
        reviewWindow.center()
        reviewWindow.orderFrontRegardless()
        for width in [700, 500] {
            reviewWindow.setContentSize(CGSize(width: width, height: 260))
            try await Task.sleep(nanoseconds: 500_000_000)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", "\(reviewWindow.windowNumber)", "/tmp/Screen-silence-timeline-\(width).png"]
            try capture.run()
            capture.waitUntilExit()
            precondition(capture.terminationStatus == 0)
        }
        reviewWindow.orderOut(nil)
        review.analyze(audio: audioURL, trim: retainedTrim, duration: 1)
        review.clear()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!review.analyzing && review.suggestions.isEmpty && review.message == nil)
        print("PASS: inline silence review clips existing cuts, requires acceptance, supports deselection and cancellation; screenshots at 700/500 widths")
        cutsWindow.contentView = NSHostingView(rootView: VideoCutEditor(trim: .constant(settings.trim), duration: 1,
            request: .init(source: source, audio: audioURL, mouse: mouseURL, webcam: webcam, settings: settings), hasAudio: true))
        cutsWindow.center()
        cutsWindow.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 500_000_000)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", "\(cutsWindow.windowNumber)", "/tmp/Screen-cuts-cleanup.png"]
        try capture.run()
        capture.waitUntilExit()
        precondition(capture.terminationStatus == 0)
        print("PASS: native cut editor screenshot; button automation requires an external accessibility client")
        cutsWindow.orderOut(nil)
        print("PASS: native edit player previewed at normal and minimum sizes")
    }

    @MainActor
    static func verifyRecording(_ source: URL) async throws {
        let item = try await LiveVideoPreview.makeItem(.init(
            source: source, audio: nil,
            mouse: source.deletingPathExtension().appendingPathExtension("mouse.json"), webcam: nil,
            settings: .init(backgroundEnabled: false, showCursor: true, zoomEnabled: true)
        ))
        let tracks = try await item.asset.loadTracks(withMediaType: .video)
        let duration = try await item.asset.load(.duration)
        let reader = try AVAssetReader(asset: item.asset)
        let frames = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        frames.videoComposition = item.videoComposition
        reader.add(frames)
        precondition(reader.startReading())
        var count = 0
        var previous = 0.0
        var minimumGap = Double.infinity
        var maximumGap = 0.0
        var savedFrame = false
        while let sample = frames.copyNextSampleBuffer() {
            try autoreleasepool {
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if count > 0 {
                    minimumGap = min(minimumGap, seconds - previous)
                    maximumGap = max(maximumGap, seconds - previous)
                }
                if !savedFrame, seconds >= duration.seconds / 2,
                   let buffer = CMSampleBufferGetImageBuffer(sample) {
                    let image = CIImage(cvPixelBuffer: buffer)
                    let bitmap = CIContext().createCGImage(image, from: image.extent)!
                    try NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])!
                        .write(to: URL(fileURLWithPath: "/tmp/Screen-recent-live-preview.png"))
                    savedFrame = true
                }
                previous = seconds
                count += 1
            }
        }
        precondition(reader.status == .completed, reader.error?.localizedDescription ?? "Preview reader failed")
        precondition(count > 1 && minimumGap > 0.015 && maximumGap < 0.018, "Uneven preview cadence")
        precondition(duration.seconds - previous < 0.018, "Preview ended early")
        print("PASS: real preview \(count) frames, gap range \(minimumGap)...\(maximumGap)s, duration \(duration.seconds)s")
    }
}