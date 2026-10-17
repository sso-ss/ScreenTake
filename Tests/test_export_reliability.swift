import AppKit
import AVFoundation
import CoreImage

@main
struct ExportReliabilityChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("export-reliability-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let context = CIContext(options: [.cacheIntermediates: false])
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        let screenImage = CIImage(color: .green).cropped(to: bounds)
        let cameraImage = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 360))
            .composited(over: CIImage(color: .blue).cropped(to: bounds))
        func movie(_ name: String, image: CIImage) async throws -> URL {
            let url = directory.appendingPathComponent(name + ".mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            precondition(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            for time in [0.0, 2.95] {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
                context.render(image, to: buffer!)
                precondition(adaptor.append(buffer!, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 600))
            await writer.finishWriting()
            precondition(writer.status == .completed)
            return url
        }
        let source = try await movie("screen", image: screenImage)
        let camera = try await movie("camera", image: cameraImage)
        let audio = directory.appendingPathComponent("audio.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)!
        tone.frameLength = tone.frameCapacity
        for i in 0..<Int(tone.frameLength) { tone.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.2) }
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: tone) }
        let withAudio = try await MediaMuxer.mux(videoURL: source, systemAudioURL: nil, micAudioURL: audio, removeSourceAudio: false)
        let mouse = directory.appendingPathComponent("mouse.json")
        let recording = MouseDataRecorder.MouseRecording(
            positions: [.init(timestamp: 0, x: 0.5, y: 0.5, velocity: 0), .init(timestamp: 3, x: 0.6, y: 0.5, velocity: 0)],
            clicks: [], keys: [], scrolls: [], zoomMarkers: [], screenBounds: .init(from: bounds), scaleFactor: 1, sampleInterval: 1 / 60)
        try JSONEncoder().encode(recording).write(to: mouse)
        func pixel(_ image: CIImage, at point: CGPoint) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: 4,
                               bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            return bytes
        }
        func isBlue(_ color: [UInt8]) -> Bool { Int(color[2]) > Int(color[0]) + 100 }
        for layout in [CameraLayout.overlay, .fullScreen] {
            for mirrored in [false, true] {
                let output = directory.appendingPathComponent("\(layout)-\(mirrored).mov")
                let engine = ExportEngine()
                let settings = VideoEditSettings(backgroundEnabled: false, webcamEnabled: true, cameraMirrored: mirrored,
                                                 cameraLayout: .init(layout: layout), videoOverlayURL: camera,
                                                 videoOverlayTiming: .init(start: 0, duration: 3))
                let item = try await LiveVideoPreview.makeItem(.init(source: withAudio, audio: nil, mouse: mouse, webcam: camera, settings: settings))
                let generator = AVAssetImageGenerator(asset: item.asset)
                generator.videoComposition = item.videoComposition
                let preview = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
                _ = try await engine.export(sourceURL: withAudio, keyframes: [], configuration: .init(
                    outputURL: output, codec: mirrored ? .hevc : .h264, outputSize: CGSize(width: 1920, height: 1080),
                    webcamVideoURL: camera, videoOverlayTiming: .init(start: 0, duration: 3), cameraMirrored: mirrored,
                    cameraLayout: .init(layout: layout), mouseDataURL: mouse, preserveSourceAudio: true))
                precondition(!engine.isExporting && engine.progress == 1)
                let asset = AVURLAsset(url: output)
                let duration = try await asset.load(.duration)
                precondition(abs(duration.seconds - 3) < 0.002)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                precondition(audioTracks.count == 1)
                let track = try await asset.loadTracks(withMediaType: .video)[0]
                let reader = try AVAssetReader(asset: asset)
                let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(frames); precondition(reader.startReading())
                var count = 0
                var last = CMTime(value: -1, timescale: 600)
                var exportPixel: [UInt8]?
                while let sample = frames.copyNextSampleBuffer() {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    precondition(pts > last, "Output timestamps must increase")
                    if pts.seconds >= 1.5, exportPixel == nil {
                        let image = CIImage(cvPixelBuffer: CMSampleBufferGetImageBuffer(sample)!)
                        let diameter = 1080 * PiPSize.medium.fraction
                        let point = layout == .fullScreen ? CGPoint(x: 1920 * 0.25, y: 540)
                            : CGPoint(x: 1920 - 24 - diameter * 0.75, y: 24 + diameter / 2)
                        exportPixel = pixel(image, at: point)
                    }
                    last = pts; count += 1
                }
                precondition(reader.status == .completed && count == 180, "Sparse capture must retain all generated 60fps frames: \(count)")
                let diameter = 360 * PiPSize.medium.fraction
                let point = layout == .fullScreen ? CGPoint(x: 160, y: 180)
                    : CGPoint(x: 640 - 24 - diameter * 0.75, y: 24 + diameter / 2)
                precondition(isBlue(pixel(CIImage(cgImage: preview), at: point)) == mirrored)
                precondition(isBlue(exportPixel!) == mirrored)
                print("PASS: \(layout), mirrored=\(mirrored): preview/export agree, 180 generated frames, 3s audio/video")
            }
        }
        let legacy = VideoEditSettings()
        var manifest = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        manifest.removeValue(forKey: "cameraMirrored")
        let migrated = try JSONDecoder().decode(VideoEditSettings.self, from: JSONSerialization.data(withJSONObject: manifest))
        precondition(migrated.cameraMirrored == nil)
        var saved = migrated; EditorEdits(cameraMirrored: true).apply(to: &saved)
        let decoded = try JSONDecoder().decode(VideoEditSettings.self, from: JSONEncoder().encode(saved))
        precondition(decoded.cameraMirrored == true)
        let shifted = cameraImage.transformed(by: CGAffineTransform(translationX: 31, y: 18))
        let flipped = WebcamCompositor.mirrored(shifted)
        precondition(flipped.extent == shifted.extent && isBlue(pixel(flipped, at: CGPoint(x: 60, y: 80))))
        print("PASS: legacy project orientation, mirroring persistence, nonzero image origin")
        func event(_ characters: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: 0, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        precondition(EditorPlaybackShortcut.action(for: event(" ")) == .togglePlayback)
        precondition(EditorPlaybackShortcut.action(for: event("j")) == .reverse)
        precondition(EditorPlaybackShortcut.action(for: event("k")) == .pause)
        precondition(EditorPlaybackShortcut.action(for: event("l")) == .play)
        precondition(EditorPlaybackShortcut.action(for: event("", code: 123)) == .step(direction: -1, seconds: false))
        precondition(EditorPlaybackShortcut.action(for: event("", code: 124, modifiers: .shift)) == .step(direction: 1, seconds: true))
        precondition(EditorPlaybackShortcut.action(for: event("", code: 123, modifiers: .command)) == .start)
        precondition(EditorPlaybackShortcut.action(for: event("l", modifiers: .command)) == nil)
        precondition(EditorPlaybackShortcut.action(for: event(" ", modifiers: .control)) == nil)
        print("PASS: playback, frame stepping and seek shortcut mappings preserve modified keys")
        let destination = directory.appendingPathComponent("keep.mov")
        let sentinel = Data("existing destination".utf8)
        try sentinel.write(to: destination)
        let engine = ExportEngine()
        let job = Task {
            try await engine.export(sourceURL: withAudio, keyframes: [], configuration: .init(
                outputURL: destination, outputSize: CGSize(width: 3840, height: 2160), webcamVideoURL: camera,
                videoOverlayTiming: .init(start: 0, duration: 3), mouseDataURL: mouse))
        }
        while !engine.isExporting || engine.progress == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        job.cancel()
        do { _ = try await job.value; preconditionFailure("Cancelled export completed") }
        catch is CancellationError { }
        let preservedData = try Data(contentsOf: destination)
        precondition(!engine.isExporting && preservedData == sentinel)
        do {
            _ = try await engine.export(sourceURL: directory.appendingPathComponent("missing.mov"), keyframes: [], configuration: .init(outputURL: destination))
            preconditionFailure("Missing source succeeded")
        } catch { }
        let dataAfterFailure = try Data(contentsOf: destination)
        precondition(!engine.isExporting && dataAfterFailure == sentinel)
        print("PASS: cancellation and failed export preserve destination and return to idle")
        let review = URL(fileURLWithPath: "/tmp/ScreenTake-editing-check.mov")
        try? manager.removeItem(at: review)
        try manager.copyItem(at: directory.appendingPathComponent("fullScreen-true.mov"), to: review)
    }
}
