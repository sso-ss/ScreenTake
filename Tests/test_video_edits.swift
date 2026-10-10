import AppKit
import AVFoundation
import CoreImage
import SwiftUI

@main
struct VideoEditTests {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("video-edits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let size = CGSize(width: 320, height: 200)
        let context = CIContext()

        func makeVideo(_ name: String, webcam: Bool) async throws -> URL {
            let url = directory.appendingPathComponent(name + ".mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            precondition(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            let bounds = CGRect(origin: .zero, size: size)
            let base = CIImage(color: webcam ? CIColor(red: 0, green: 1, blue: 0) : CIColor(red: 0.7, green: 0.7, blue: 0.7)).cropped(to: bounds)
            let image = webcam ? base : CIImage(color: CIColor(red: 1, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: 80, height: 200)).composited(over: base)
            for time in [0.0, 0.95] {
                while !input.isReadyForMoreMediaData { await Task.yield() }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, nil, &buffer)
                context.render(image, to: buffer!)
                precondition(adaptor.append(buffer!, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
            await writer.finishWriting()
            precondition(writer.status == .completed)
            return url
        }

        let source = try await makeVideo("source", webcam: false)
        let originalData = try Data(contentsOf: source)
        let webcam = try await makeVideo("webcam", webcam: true)
        let audio = directory.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        samples.frameLength = 44100
        for index in 0..<44100 { samples.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44100) * 0.2) }
        do { try AVAudioFile(forWriting: audio, settings: format.settings).write(from: samples) }
        let mouse = directory.appendingPathComponent("source.mouse.json")
        let recording = MouseDataRecorder.MouseRecording(
            positions: [], clicks: [.init(timestamp: 0.2, x: 0.5, y: 0.5, button: 0, isDown: true)],
            keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(origin: .zero, size: size)), scaleFactor: 1, sampleInterval: 1.0 / 60)
        try JSONEncoder().encode(recording).write(to: mouse)
        let state = RecordingState()
        state.lastMicAudioURL = audio
        state.lastWebcamVideoURL = webcam
        var settings = VideoEditSettings(backgroundEnabled: false, showCursor: false)

        func render(_ draft: VideoEditSettings) async throws -> URL {
            await state.applyAutoZoom(videoURL: source, mouseDataURL: mouse, generateZoom: draft.zoomEnabled, edits: draft)
            precondition(state.processingError == nil, state.processingError ?? "")
            precondition(state.processingStage == nil && state.lastAppliedEdits == draft)
            let result = state.lastRecordingURL!
            let asset = AVURLAsset(url: result)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let expectedDuration = try draft.trim.timeline(duration: CMTime(seconds: 1, preferredTimescale: 600)).duration.seconds
            precondition(abs(duration.seconds - expectedDuration) < 0.05)
            let expectedAudioTracks = draft.audioEnabled || (draft.voiceOverEnabled && !draft.voiceOvers.isEmpty) ? 1 : 0
            precondition(tracks.count == expectedAudioTracks)
            let retainedData = try Data(contentsOf: source)
            precondition(retainedData == originalData)
            precondition(FileManager.default.fileExists(atPath: audio.path))
            return result
        }

        func bitmap(_ url: URL) async throws -> NSBitmapImageRep {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            let image = try generator.copyCGImage(at: CMTime(seconds: 0.8, preferredTimescale: 600), actualTime: nil)
            return NSBitmapImageRep(cgImage: image)
        }

        settings.trim = VideoTrim(start: 0.2, end: 0.7, cuts: [.init(start: 0.3, end: 0.4)])
        _ = try await render(settings)
        let preview = try await LiveVideoPreview.makeItem(.init(source: source, audio: state.lastUntrimmedRecordingURL,
                                       mouse: mouse, webcam: webcam, settings: settings))
        let previewDuration = try await preview.asset.load(.duration)
        precondition(abs(previewDuration.seconds - 0.4) < 0.002)
        let retainedAudio = state.lastUntrimmedRecordingURL
        settings.audioEnabled = false
        _ = try await render(settings)
        precondition(state.lastUntrimmedRecordingURL == retainedAudio)
        settings.audioEnabled = true
        let reopenedPreview = try await LiveVideoPreview.makeItem(.init(source: source, audio: state.lastUntrimmedRecordingURL,
                                           mouse: mouse, webcam: webcam, settings: settings))
        let reopenedAudio = try await reopenedPreview.asset.loadTracks(withMediaType: .audio)
        precondition(reopenedAudio.count == 1)
        settings.trim = VideoTrim()
        _ = try await render(settings)
        let previousTrimResult = state.lastRecordingURL
        let previousTrimSettings = state.lastAppliedEdits
        settings.trim = VideoTrim(start: 0.8, end: 0.2)
        await state.applyAutoZoom(videoURL: source, mouseDataURL: mouse, generateZoom: false, edits: settings)
        precondition(state.processingError != nil && state.lastRecordingURL == previousTrimResult
                 && state.lastAppliedEdits == previousTrimSettings)
        settings.trim = VideoTrim()
        print("PASS: recording trim, preview duration, reset from original and failed trim preserves result")
        if CommandLine.arguments.contains("--trim-only") { return }

        settings.zoomEnabled = true
        let zoomed = try await bitmap(render(settings))
        settings.zoomEnabled = false
        let unzoomedURL = try await render(settings)
        let unzoomed = try await bitmap(unzoomedURL)
        precondition(zoomed.colorAt(x: 30, y: 100)!.greenComponent > 0.5)
        precondition(unzoomed.colorAt(x: 30, y: 100)!.greenComponent < 0.2)
        print("PASS: zoom on then off restores original framing")

        settings.backgroundEnabled = true
        settings.wallpaper = .blossom
        let first = try await bitmap(render(settings))
        settings.wallpaper = .ocean
        let second = try await bitmap(render(settings))
        let firstColor = first.colorAt(x: 4, y: 4)!.usingColorSpace(.sRGB)!
        let secondColor = second.colorAt(x: 4, y: 4)!.usingColorSpace(.sRGB)!
        precondition(abs(firstColor.redComponent - secondColor.redComponent) > 0.1)
        settings.backgroundEnabled = false
        let plain = try await bitmap(render(settings))
        precondition(plain.colorAt(x: 4, y: 4)!.redComponent > 0.8)
        precondition(plain.colorAt(x: 4, y: 4)!.greenComponent < 0.2)
        print("PASS: original-ratio backgrounds replace and remove without nesting")

        state.lastWebcamVideoURL = nil
        settings.videoOverlayURL = webcam
        settings.webcamEnabled = true
        let visibleWebcam = try await bitmap(render(settings))
        settings.webcamEnabled = false
        let hiddenWebcam = try await bitmap(render(settings))
        let diameter = size.height * PiPSize.medium.fraction
        let center = CGPoint(x: size.width - 24 - diameter / 2, y: size.height - 24 - diameter / 2)
        for offset in [-5, 0, 5] {
            let horizontal = Int(center.x) + offset
            let vertical = Int(center.y)
            let visible = visibleWebcam.colorAt(x: horizontal, y: vertical)!.usingColorSpace(.sRGB)!
            let hidden = hiddenWebcam.colorAt(x: horizontal, y: vertical)!.usingColorSpace(.sRGB)!
            let original = plain.colorAt(x: horizontal, y: vertical)!.usingColorSpace(.sRGB)!
            precondition(visible.greenComponent > visible.redComponent + 0.3 && visible.greenComponent > visible.blueComponent + 0.3)
            precondition(abs(visible.greenComponent - hidden.greenComponent) > 0.15)
            precondition(abs(hidden.redComponent - original.redComponent) < 0.03)
            precondition(abs(hidden.greenComponent - original.greenComponent) < 0.03)
            precondition(abs(hidden.blueComponent - original.blueComponent) < 0.03)
        }
        print("PASS: imported video overlay can be shown and hidden")
        settings.voiceOvers = [VoiceOverClip(url: audio, duration: 1, sourceDuration: 1)]
        settings.audioEnabled = true
        let voiceOverResult = try await render(settings)
        let voiceOverTracks = try await AVURLAsset(url: voiceOverResult).loadTracks(withMediaType: .audio)
        precondition(voiceOverTracks.count == 1)
        print("PASS: voice-over is added without replacing original audio")
        settings.voiceOvers = []
        settings.audioEnabled = false
        _ = try await render(settings)
        settings.audioEnabled = true
        _ = try await render(settings)
        print("PASS: audio mute/unmute, duration and raw files survive repeated edits")

        let previous = state.lastRecordingURL
        let applied = state.lastAppliedEdits
        state.lastMicAudioURL = directory.appendingPathComponent("missing.wav")
        await state.applyAutoZoom(videoURL: source, mouseDataURL: mouse, generateZoom: false, edits: settings)
        precondition(state.processingError != nil && state.lastRecordingURL == previous && state.lastAppliedEdits == applied)
        print("PASS: failed apply retains last successful result and settings")
        if CommandLine.arguments.contains("--no-ui") { return }

        let app = AppState.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(app))
        window.center()
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 150_000_000)
        NotificationCenter.default.post(name: .openVideoFile, object: nil, userInfo: ["url": unzoomedURL])
        for (name, dimensions) in [("normal", CGSize(width: 1000, height: 850)), ("minimum", CGSize(width: 800, height: 500))] {
            window.setContentSize(dimensions)
            try await Task.sleep(nanoseconds: 350_000_000)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", "\(window.windowNumber)", "/tmp/Screen-edit-\(name).png"]
            try capture.run()
            capture.waitUntilExit()
            precondition(capture.terminationStatus == 0)
            print("PASS: imported edit panel screenshot at \(dimensions)")
        }
        window.orderOut(nil)
    }
}
