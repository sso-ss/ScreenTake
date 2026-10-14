import AppKit
import AVFoundation
import CoreImage
import Darwin

/// Exercises the imported-project path with a long recording and dense manual zooms.
/// SCREENTAKE_STRESS_SECONDS / SCREENTAKE_STRESS_FPS allow quick and VFR variants.
@main
struct LongImportExportChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let environment = ProcessInfo.processInfo.environment
        let seconds = Double(environment["SCREENTAKE_STRESS_SECONDS"] ?? "900")!
        let rates: [Int32]
        if let rate = environment["SCREENTAKE_STRESS_FPS"] { rates = [Int32(rate)!] }
        else { rates = [30, 1] }
        for fps in rates { try await check(seconds: seconds, fps: fps) }
    }

    @MainActor static func check(seconds: Double, fps: Int32) async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("long-import-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recorded.mov")
        let context = CIContext(options: [.cacheIntermediates: false])
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 360))
            .composited(over: CIImage(color: .blue).cropped(to: bounds))
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        context.render(image, to: buffer!)
        for index in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData {
                precondition(writer.status == .writing)
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: EditorAudio.time(seconds))
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let audio = directory.appendingPathComponent("tone.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        chunk.frameLength = chunk.frameCapacity
        for i in 0..<48000 { chunk.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.1) }
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            for _ in 0..<Int(seconds) { try file.write(from: chunk) }
        }
        let withAudio = try await MediaMuxer.mux(videoURL: source, systemAudioURL: nil, micAudioURL: audio, removeSourceAudio: false)
        let mouse = directory.appendingPathComponent("mouse.json")
        let recording = MouseDataRecorder.MouseRecording(positions: [
            .init(timestamp: 0, x: 0.25, y: 0.5, velocity: 0),
            .init(timestamp: seconds, x: 0.25, y: 0.5, velocity: 0)
        ], clicks: [], keys: [], scrolls: [],
            zoomMarkers: [], screenBounds: .init(from: bounds), scaleFactor: 1, sampleInterval: 1 / 60)
        try JSONEncoder().encode(recording).write(to: mouse)
        let segments = stride(from: 0.2, to: seconds - 0.6, by: 3).map {
            ZoomSegment(start: $0, end: min(seconds - 0.6, $0 + 1.8), zoom: 2,
                        centerX: 0.25, centerY: 0.5, followsCursor: false)
        }
        var settings = VideoEditSettings(backgroundEnabled: false, showCursor: false, zoomEnabled: true,
                                         zoomSegments: segments)
        settings.exportResolution = .fhd1080
        let project = EditorProject(id: UUID(), revision: 0, name: "Imported long video",
                                    source: withAudio, audio: withAudio, mouse: mouse, settings: settings)
        let package = directory.appendingPathComponent("imported.screentake")
        _ = try await EditorProjectStore.save(project, to: package)
        let session = EditorSession()
        try await session.openProject(package)
        precondition(session.previewReady && session.hasEditableAudio && !session.editingRecording)
        func redPixel(_ asset: AVAsset, composition: AVVideoComposition?, time: Double) async throws -> Bool {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.videoComposition = composition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: EditorAudio.time(time)).image
            var color = [UInt8](repeating: 0, count: 4)
            color.withUnsafeMutableBytes {
                context.render(CIImage(cgImage: frame), toBitmap: $0.baseAddress!, rowBytes: 4,
                    bounds: CGRect(x: CGFloat(frame.width) * 0.75, y: CGFloat(frame.height) / 2, width: 1, height: 1),
                    format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            return Int(color[0]) > Int(color[2]) + 100
        }
        let preview = session.player!.currentItem!
        let previewZoomed = try await redPixel(preview.asset, composition: preview.videoComposition, time: 1.2)
        precondition(previewZoomed, "Imported project preview must apply manual zooms")
        print("Fixture: \(seconds)s, \(fps)fps, \(segments.count) zooms, audio, export 1920x1080", terminator: "\n")
        let start = Date()
        let monitor = Task { @MainActor in
            var lastBucket = -1
            while !Task.isCancelled {
                let bucket = Int(session.exportEngine.progress * 10)
                if bucket != lastBucket {
                    var usage = rusage()
                    getrusage(RUSAGE_SELF, &usage)
                    print("Export \(bucket * 10)% after \(Int(Date().timeIntervalSince(start)))s; peak RSS \(usage.ru_maxrss / 1_048_576) MiB")
                    lastBucket = bucket
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { monitor.cancel(); session.close() }
        let result = try await session.applyChanges()
        defer { try? manager.removeItem(at: result) }
        let exported = AVURLAsset(url: result)
        let duration = try await exported.load(.duration)
        let video = try await exported.loadTracks(withMediaType: .video)[0]
        let size = try await video.load(.naturalSize)
        let audioTracks = try await exported.loadTracks(withMediaType: .audio)
        precondition(abs(duration.seconds - seconds) < 0.002 && size == CGSize(width: 1920, height: 1080))
        precondition(audioTracks.count == 1)
        let audioRange = try await audioTracks[0].load(.timeRange)
        precondition(abs(audioRange.end.seconds - seconds) < 0.05)
        for time in [1.2, floor((seconds / 2) / 3) * 3 + 1.2, floor((seconds - 3) / 3) * 3 + 1.2] {
            let zoomed = try await redPixel(exported, composition: nil, time: time)
            precondition(zoomed, "Zoom missing at \(time)s")
        }
        let reader = try AVAssetReader(asset: exported)
        // HEVC passthrough includes dependency and empty marker samples. Count
        // decoded presentation frames, just as playback consumes them.
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        precondition(reader.startReading())
        var count = 0
        var last = CMTime.negativeInfinity
        while autoreleasepool(invoking: { () -> Bool in
            guard let sample = output.copyNextSampleBuffer() else { return false }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            precondition(pts.isNumeric && pts > last, "Presentation timestamps must increase")
            if last.isNumeric { precondition((pts - last).seconds <= 1 / 30.0 + 0.001, "Missing zoom animation frames") }
            last = pts; count += 1
            return true
        }) { }
        precondition(reader.status == .completed && count == Int(seconds * 30), "Expected all 30fps output frames, got \(count)")
        precondition(last.seconds > seconds - 1 && !session.isBusy && session.exportEngine.progress == 1)
        print("PASS: imported \(seconds)s recording with \(segments.count) zooms: \(count) frames, full audio/video, zoom pixels, \(Int(Date().timeIntervalSince(start)))s export")
    }
}
