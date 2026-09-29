import AppKit
import AVFoundation
import CoreImage

@main
struct PointerFollowExportTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Screen-pointer-follow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.mov")
        let mouseURL = directory.appendingPathComponent("source.mouse.json")
        let output = directory.appendingPathComponent("follow.mov")
        let size = CGSize(width: 640, height: 400)
        func point(_ time: Double) -> (x: Double, y: Double) {
            let progress = min(1, max(0, (time - 1.5) / 1.2))
            return (0.3 + progress * 0.62, 0.5 + progress * 0.3)
        }
        let recording = MouseDataRecorder.MouseRecording(
            positions: (0...240).map { index in
                let time = Double(index) / 60
                let pointer = point(time)
                return .init(timestamp: time, x: pointer.x, y: pointer.y, velocity: 0)
            },
            clicks: [.init(timestamp: 1, x: 0.3, y: 0.5, button: 0, isDown: true)],
            keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(origin: .zero, size: size)), scaleFactor: 1, sampleInterval: 1.0 / 60
        )
        try JSONEncoder().encode(recording).write(to: mouseURL)
        let context = CIContext()
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 400
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<120 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 400, kCVPixelFormatType_32BGRA, nil, &buffer)
            let image = CIImage(color: CIColor(red: 0.6, green: 0.7, blue: 0.65))
                .cropped(to: CGRect(origin: .zero, size: size))
            context.render(image, to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 4, preferredTimescale: 600))
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let keyframes = try await ClickZoomGenerator.generate(from: mouseURL, sourceVideoURL: source)
        let evaluator = FrameEvaluator(keyframes: keyframes)
        _ = try await ExportEngine().export(sourceURL: source, keyframes: keyframes, configuration: .init(
            outputURL: output, mouseDataURL: mouseURL, cursorShape: .circle, showCursor: true
        ))
        var settings = VideoEditSettings(backgroundEnabled: false, showCursor: true)
        settings.zoomEnabled = true
        settings.cursorShape = .circle
        let item = try await LiveVideoPreview.makeItem(.init(source: source, audio: source, mouse: mouseURL, webcam: nil, settings: settings))
        let preview = AVAssetImageGenerator(asset: item.asset)
        preview.videoComposition = item.videoComposition
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        for generator in [preview, exported] {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        for time in [1.2, 1.8, 2.4, 2.9, 3.4] {
            let camera = evaluator.evaluate(at: time)
            let pointer = point(time)
            let expectedX = ((pointer.x - camera.centerX) * camera.zoom + 0.5) * size.width
            let expectedY = ((1 - pointer.y - camera.centerY) * camera.zoom + 0.5) * size.height
            for (name, generator) in [("preview", preview), ("export", exported)] {
                let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
                let bitmap = NSBitmapImageRep(cgImage: image)
                var totalX = 0.0
                var totalY = 0.0
                var count = 0.0
                for vertical in 0..<bitmap.pixelsHigh {
                    for horizontal in 0..<bitmap.pixelsWide {
                        let color = bitmap.colorAt(x: horizontal, y: vertical)!.usingColorSpace(.sRGB)!
                        if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.18 {
                            totalX += Double(horizontal)
                            totalY += Double(vertical)
                            count += 1
                        }
                    }
                }
                precondition(count > 50, "\(name) lost the pointer at \(time)")
                precondition(abs(totalX / count - expectedX) < 3, "\(name) horizontal pointer alignment at \(time)")
                precondition(abs(totalY / count - expectedY) < 3, "\(name) vertical pointer alignment at \(time)")
                if time == 2.4 {
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
                }
            }
        }
        print("PASS: rendered preview and exported cursor remain visible and aligned during zoom-in, follow, and zoom-out")
        print("PREVIEW: \(directory.path)")
    }
}