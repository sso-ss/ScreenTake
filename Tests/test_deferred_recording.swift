import AppKit
import AVFoundation
import CoreImage
import QuartzCore

@main
struct DeferredRecordingChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deferred-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let camera = directory.appendingPathComponent("camera.mov")
        try await makeVideo(source, camera: false)
        try await makeVideo(camera, camera: true)
        let mic = try makeAudio(directory.appendingPathComponent("mic.caf"), frequency: 440)
        let system = try makeAudio(directory.appendingPathComponent("system.caf"), frequency: 880)
        let original = try Data(contentsOf: source)
        let micBytes = try Data(contentsOf: mic)
        let systemBytes = try Data(contentsOf: system)
        let mouseURL = directory.appendingPathComponent("mouse.json")
        let mouse = MouseDataRecorder.MouseRecording(
            positions: [.init(timestamp: 0, x: 0.5, y: 0.5, velocity: 0)], clicks: [], keys: [], scrolls: [],
            zoomMarkers: [], screenBounds: .init(from: CGRect(x: 0, y: 0, width: 640, height: 400)),
            scaleFactor: 1, sampleInterval: 1.0 / 60)
        try JSONEncoder().encode(mouse).write(to: mouseURL)
        let app = AppState.shared
        app.capture.canvasRatio = .landscape
        app.capture.showCursor = true
        app.capture.faceBeautyAmount = 0
        app.capture.faceMakeup = .init(amount: 0)
        let recording = app.recording
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let start = CACurrentMediaTime()
        recording.acceptCompletedRecording(.init(videoURL: source, mouseDataURL: mouseURL,
            micAudioURL: mic, systemAudioURL: system, webcamVideoURL: camera,
            micAudioStartOffset: EditorAudio.time(0.25), systemAudioStartOffset: EditorAudio.time(0.1)))
        precondition(recording.processingStage == nil && recording.lastRecordingURL == source)
        precondition(recording.lastAppliedEdits == nil && recording.lastSourceRecordingURL == source)
        let after = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(after == before,
                     "Completion must not write an exported movie")
        let session = app.editorSession
        try await session.openVideo(source)
        let readySeconds = CACurrentMediaTime() - start
        precondition(session.previewReady && !session.isBusy && session.hasEditChanges && session.hasUnsavedWork)
        precondition(session.sourceURL == source && session.audioURL != source && session.hasEditableAudio)
        precondition(session.draft.ratio == .landscape && session.draft.showCursor && session.draft.webcamEnabled)
        precondition(session.draft.exportResolution == .preserveSource)
        precondition(recording.lastAppliedEdits == nil, "Opening the editor must not trigger an export")
        let audioAsset = AVURLAsset(url: session.audioURL!)
        let audioVideos = try await audioAsset.loadTracks(withMediaType: .video)
        precondition(audioVideos.isEmpty)
        let tracks = try await audioAsset.loadTracks(withMediaType: .audio)
        precondition(tracks.count == 2)
        let offsets = try await tracks.asyncStarts()
        precondition(abs(offsets[0] - 0.1) < 0.002 && abs(offsets[1] - 0.25) < 0.002,
                     "Audio-only preview must retain sidecar offsets: \(offsets)")
        let previewTracks = try await session.player!.currentItem!.asset.loadTracks(withMediaType: .audio)
        precondition(previewTracks.count == 2)
        print("PASS: completion opens a live preview in \(readySeconds)s without video export; both audio tracks retain offsets")

        let package = directory.appendingPathComponent("draft.screentake")
        try await session.saveProject(to: package)
        let reopened = EditorSession()
        try await reopened.openProject(package)
        precondition(reopened.hasEditableAudio && reopened.previewReady && reopened.hasEditChanges)
        let reopenedAudio = try await AVURLAsset(url: reopened.audioURL!).loadTracks(withMediaType: .audio)
        precondition(reopenedAudio.count == 2)
        let previewDuration = try await reopened.player!.currentItem!.asset.load(.duration).seconds
        precondition(abs(previewDuration - 1) < 0.002)
        print("PASS: an unrendered project reopens with synchronized audio, camera and original screen")
        reopened.close()
        session.close()
        try await session.openVideo(source)
        do {
            try await session.saveVideo(to: source)
            preconditionFailure("Download overwrote retained source")
        } catch EditorSession.SessionError.retainedMediaDestination {}
        session.draft.trim = .init(start: 0.2, end: 0.8)
        await session.waitForPreview()
        let destination = directory.appendingPathComponent("download.mov")
        try await session.saveVideo(to: destination)
        precondition(session.videoURL == destination && !session.hasEditChanges && !session.hasUnsavedWork)
        let exported = AVURLAsset(url: destination)
        let size = try await exported.loadTracks(withMediaType: .video).first!.load(.naturalSize)
        precondition(size == session.draft.outputSize(source: CGSize(width: 640, height: 400)))
        let exportedDuration = try await exported.load(.duration).seconds
        precondition(abs(exportedDuration - 0.6) < 0.002)
        let exportedAudio = try await exported.loadTracks(withMediaType: .audio)
        precondition(exportedAudio.count == 2)
        let retainedSource = try Data(contentsOf: source), retainedMic = try Data(contentsOf: mic), retainedSystem = try Data(contentsOf: system)
        precondition(retainedSource == original && retainedMic == micBytes && retainedSystem == systemBytes)
        print("PASS: Download renders pending edits, preserves native output dimensions, cut duration, audio and original files")
        session.close()

        let engine = ExportEngine()
        func export(_ name: String, changes: [CameraLayoutChange] = [], webcam: URL? = camera) async throws -> Int {
            let result = try await engine.export(sourceURL: source, keyframes: [], configuration: .init(
                outputURL: directory.appendingPathComponent(name + ".mov"), webcamVideoURL: webcam,
                cameraLayout: .init(layout: .fullScreen), cameraLayoutChanges: changes,
                mouseDataURL: mouseURL, showCursor: true))
            return try await decodedFrames(result)
        }
        let hiddenFrames = try await export("hidden")
        let mixedFrames = try await export("mixed", changes: [.init(start: 0.5, settings: .init(layout: .overlay))])
        let shortCamera = directory.appendingPathComponent("short-camera.mov")
        try await makeVideo(shortCamera, camera: true, duration: 0.5)
        let uncoveredFrames = try await export("uncovered", webcam: shortCamera)
        precondition(hiddenFrames < 60 && hiddenFrames >= 30)
        precondition(mixedFrames == 60 && uncoveredFrames == 60,
                     "Visible cursor and layout transitions must retain 60 fps")
        print("PASS: continuous full-screen camera uses \(hiddenFrames) frames; mixed layouts and short cameras retain \(mixedFrames)/\(uncoveredFrames) frames")
    }

    static func makeAudio(_ url: URL, frequency: Double) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        samples.frameLength = samples.frameCapacity
        for index in 0..<48000 { samples.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * frequency / 48000) * 0.2) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: samples)
        return url
    }
    static func makeVideo(_ url: URL, camera: Bool, duration: Double = 1) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 640, AVVideoHeightKey: 400, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input); precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for index in 0..<Int(duration * 30) {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 400, kCVPixelFormatType_32BGRA, nil, &buffer)
            context.render(CIImage(color: camera ? .green : .blue), to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: EditorAudio.time(duration)); await writer.finishWriting()
        precondition(writer.status == .completed)
    }
    static func decodedFrames(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try await asset.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); precondition(reader.startReading())
        var count = 0, previous = CMTime.invalid
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            precondition(!previous.isValid || time > previous); previous = time; count += 1
        }
        precondition(reader.status == .completed)
        return count
    }
}
private extension Array where Element == AVAssetTrack {
    func asyncStarts() async throws -> [Double] {
        var result: [Double] = []
        for track in self {
            let segments = try await track.load(.segments)
            result.append(segments.first { !$0.isEmpty }!.timeMapping.target.start.seconds)
        }
        return result
    }
}
