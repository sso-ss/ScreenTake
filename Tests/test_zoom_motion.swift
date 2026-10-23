import AppKit
import AVFoundation
import CoreImage

@main struct ZoomMotionChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-motion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeVideo(source)
        let recording = MouseDataRecorder.MouseRecording(positions: [], clicks: [
            .init(timestamp: 0.2, x: 0.5, y: 0.5, button: 0, isDown: true)
        ], keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(x: 0, y: 0, width: 320, height: 200)),
            scaleFactor: 1, sampleInterval: 1.0 / 60)
        let mouse = directory.appendingPathComponent("mouse.json")
        try JSONEncoder().encode(recording).write(to: mouse)
        let segment = ZoomSegment(start: 0.2, end: 1.4, zoom: 2, centerX: 0.5, centerY: 0.5, followsCursor: false)
        let initial = VideoEditSettings(backgroundEnabled: false, showCursor: false, zoomEnabled: true, zoomSegments: [segment])
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as! [String: Any]
        legacy.removeValue(forKey: "zoomTransitionMotion")
        let decoded = try JSONDecoder().decode(VideoEditSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(decoded.zoomTransitionMotion == nil, "Old projects must retain the default smooth motion")
        let package = directory.appendingPathComponent("motion.screentake")
        _ = try await EditorProjectStore.save(.init(id: UUID(), revision: 0, name: "Zoom motion", source: source,
                                                    mouse: mouse, settings: initial), to: package)
        let session = EditorSession()
        try await session.openProject(package)
        let times = [0.3, 1.55]
        let sourceFrame = try await frame(AVURLAsset(url: source), at: 0)
        let context = CIContext(options: [.cacheIntermediates: false])
        var previewSamples: [Double] = []
        for motion in ZoomTransitionMotion.allCases {
            let edits = try JSONDecoder().decode(EditorEdits.self, from: Data("{\"zoomTransitionMotion\":\"\(motion.rawValue)\"}".utf8))
            try session.updateEdits { edits.apply(to: &$0) }
            precondition(session.draft.zoomTransitionMotion == motion)
            session.undo()
            precondition(session.draft.zoomTransitionMotion != motion, "Motion change must have one Undo")
            session.redo()
            precondition(session.draft.zoomTransitionMotion == motion)
            let roundTrip = try JSONDecoder().decode(VideoEditSettings.self, from: JSONEncoder().encode(session.draft))
            precondition(roundTrip.zoomTransitionMotion == motion)
            let keyframes = ClickZoomGenerator.generate(segments: [segment], transitionMotion: motion)
            let evaluator = FrameEvaluator(keyframes: keyframes)
            let expectedProgress = motion.easing.evaluate(0.25)
            precondition(abs(evaluator.evaluate(at: times[0]).zoom - (1 + expectedProgress)) < 0.001)
            precondition(abs(evaluator.evaluate(at: times[1]).zoom - (2 - expectedProgress)) < 0.001)
            let automatic = FrameEvaluator(keyframes: ClickZoomGenerator.generate(from: recording,
                settings: .init(transitionMotion: motion)))
            precondition(abs(automatic.evaluate(at: 0.17).zoom - (1 + expectedProgress)) < 0.001,
                         "Automatic click zoom must use selected motion")
            let manual = MouseDataRecorder.MouseRecording(positions: [], clicks: [], keys: [], scrolls: [],
                zoomMarkers: [.init(timestamp: 0.2, x: 0.5, y: 0.5, isZoomIn: true)],
                screenBounds: recording.screenBounds, scaleFactor: 1, sampleInterval: 1.0 / 60)
            let manualCamera = FrameEvaluator(keyframes: ClickZoomGenerator.generate(from: manual,
                settings: .init(transitionMotion: motion)))
            precondition(abs(manualCamera.evaluate(at: 0.35).zoom - (1 + expectedProgress)) < 0.001,
                         "Recorded zoom markers must use selected motion")
            let preview = try await LiveVideoPreview.makeItem(.init(source: session.sourceURL!, audio: nil,
                mouse: session.mouseURL, webcam: nil, settings: session.draft))
            let exported = try await session.applyChanges()
            let renderer = LiveEditFrameRenderer(sourceSize: CGSize(width: 320, height: 200),
                                                settings: session.draft, keyframes: keyframes)
            for time in times {
                let previewFrame = try await frame(preview.asset, composition: preview.videoComposition, at: time)
                let exportFrame = try await frame(AVURLAsset(url: exported), at: time)
                let reference = renderer.render(CIImage(cgImage: sourceFrame), at: time)
                let expected = context.createCGImage(reference, from: reference.extent)!
                precondition(error(previewFrame, expected) < 0.015, "Preview ignored \(motion) motion at \(time)")
                precondition(error(exportFrame, expected) < 0.025, "Export ignored \(motion) motion at \(time)")
                if time == times[0] {
                    previewSamples.append(Double(NSBitmapImageRep(cgImage: previewFrame).colorAt(x: 24, y: 100)!.redComponent))
                }
            }
            try await session.saveProject(to: package)
            let saved = try await EditorProjectStore.load(from: package)
            precondition(saved.settings.zoomTransitionMotion == motion, "Project save lost zoom motion")
            print("PASS: \(motion.displayName) zoom-in/out, automatic/manual zoom, Undo/Redo, preview, export, and project persistence")
        }
        precondition(Set(previewSamples.map { Int(($0 * 1000).rounded()) }).count == 4,
                     "The four motion choices must visibly differ during the transition")
        session.close()
        print("PASS: older projects keep Smooth, and all four choices produce distinct rendered motion")
    }

    static func frame(_ asset: AVAsset, composition: AVVideoComposition? = nil, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 60000)).image
    }

    static func error(_ image: CGImage, _ reference: CGImage) -> Double {
        let result = NSBitmapImageRep(cgImage: image)
        let expected = NSBitmapImageRep(cgImage: reference)
        var sum = 0.0
        var count = 0
        for y in stride(from: 16, to: image.height - 16, by: 8) {
            for x in stride(from: 16, to: image.width - 16, by: 8) {
                sum += abs(Double(result.colorAt(x: x, y: y)!.redComponent - expected.colorAt(x: x, y: y)!.redComponent))
                count += 1
            }
        }
        return sum / Double(count)
    }

    static func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting(), "Fixture writer: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, nil, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer!)
        for y in 0..<200 { for x in 0..<320 {
            let offset = y * rowBytes + x * 4
            let level = UInt8(x * 255 / 319)
            bytes[offset] = level; bytes[offset + 1] = level; bytes[offset + 2] = level; bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        for index in 0..<120 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 60)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 60000))
        await writer.finishWriting()
        precondition(writer.status == .completed)
    }
}
