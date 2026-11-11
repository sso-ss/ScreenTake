import AppKit
import AVFoundation
import CoreImage

@main struct SmoothCursorChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let samples = (0..<10).map { MouseDataRecorder.MousePosition(timestamp: Double($0) / 60, x: Double($0) / 10, y: 0.5, velocity: 0) }
        for sigma in [0, -0.06, .nan, .infinity, -.infinity] {
            let result = MouseDataRecorder.smoothedPositions(samples, sigma: sigma)
            precondition(result.count == samples.count && result.allSatisfy { $0.x.isFinite && $0.y.isFinite },
                         "Invalid sigma \(sigma) must not crash or produce NaN positions")
        }
        for sigma in [0, -0.06, 0.01, 0.3, .nan, .infinity] {
            var settings = VideoEditSettings()
            settings.smoothCursorSigma = sigma
            do {
                try settings.validate(duration: 2)
                preconditionFailure("Sigma \(sigma) must be rejected")
            } catch is EditValidationError {}
        }
        for sigma in [0.02, 0.06, 0.25] {
            var settings = VideoEditSettings()
            settings.smoothCursorSigma = sigma
            try settings.validate(duration: 2)
        }
        print("PASS: invalid smoothing sigma is guarded and rejected by validation")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smooth-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeVideo(source)
        // Positions are normalized. Alternating samples jitter between x=0.2 and x=0.8; smoothing settles near 0.5.
        let positions = (0..<120).map { index -> MouseDataRecorder.MousePosition in
            let x: Double = index % 2 == 0 ? 0.2 : 0.8
            return MouseDataRecorder.MousePosition(timestamp: Double(index) / 60, x: x, y: 0.5, velocity: 0)
        }
        let recording = MouseDataRecorder.MouseRecording(positions: positions, clicks: [], keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(x: 0, y: 0, width: 320, height: 200)), scaleFactor: 1, sampleInterval: 1.0 / 60)
        let mouse = directory.appendingPathComponent("mouse.json")
        try JSONEncoder().encode(recording).write(to: mouse)
        let initial = VideoEditSettings(backgroundEnabled: false, showCursor: true, cursorShape: .circle, cursorScale: 2)
        let package = directory.appendingPathComponent("smooth.screentake")
        _ = try await EditorProjectStore.save(.init(id: UUID(), revision: 0, name: "Smooth cursor", source: source,
                                                    mouse: mouse, settings: initial), to: package)
        let session = EditorSession()
        try await session.openProject(package)
        let time = 1.0
        var previews: [CGImage] = []
        var exports: [CGImage] = []
        for smooth in [false, true] {
            try session.updateEdits { $0.smoothCursor = smooth; $0.smoothCursorSigma = 0.2 }
            let preview = try await LiveVideoPreview.makeItem(.init(source: session.sourceURL!, audio: nil,
                mouse: session.mouseURL, webcam: nil, settings: session.draft))
            previews.append(try await frame(preview.asset, composition: preview.videoComposition, at: time))
            exports.append(try await frame(AVURLAsset(url: session.applyChanges()), at: time))
        }
        precondition(differing(previews[0], previews[1]) > 1000, "Smoothing must change the preview")
        precondition(differing(exports[0], exports[1]) > 1000, "Smoothing must change a reopened project's export")
        // Unsmoothed jitter flips sides every sample, so sub-frame timing alone moves the cursor; only compare smoothed output.
        precondition(differing(previews[1], exports[1]) < 300, "Smoothed export must match the smoothed preview")
        print("PASS: smoothing changes preview and reopened-project export, and they match")

        try session.updateEdits { $0.smoothCursor = true; $0.smoothCursorSigma = 0.2 }
        try await session.saveProject(to: package)
        let saved = try await EditorProjectStore.load(from: package)
        precondition(saved.settings.smoothCursor && saved.settings.smoothCursorSigma == 0.2, "Project save lost smoothing")
        session.close()
        print("PASS: smoothing settings persist in saved projects")
    }

    static func differing(_ image: CGImage, _ reference: CGImage) -> Int {
        let result = NSBitmapImageRep(cgImage: image)
        let expected = NSBitmapImageRep(cgImage: reference)
        var count = 0
        for y in 0..<min(image.height, reference.height) {
            for x in 0..<min(image.width, reference.width) {
                if abs(result.colorAt(x: x, y: y)!.redComponent - expected.colorAt(x: x, y: y)!.redComponent) > 0.1 { count += 1 }
            }
        }
        return count
    }

    static func frame(_ asset: AVAsset, composition: AVVideoComposition? = nil, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 60000)).image
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
