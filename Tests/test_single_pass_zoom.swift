import AppKit
import AVFoundation
import CoreImage

@main
struct SinglePassZoomTests {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Screen-single-pass-check")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = CIContext(options: [.cacheIntermediates: false])
        let sourceSize = CGSize(width: 1400, height: 900)
        let outputSize = CGSize(width: 1920, height: 1080)
        let bitmap = CGContext(data: nil, width: 1400, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(origin: .zero, size: sourceSize))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        for row in 0..<38 {
            let text = "\(row + 1)  let recording = originalFrame  // Keep text detail at 2x zoom"
            (text as NSString).draw(at: CGPoint(x: 24, y: 20 + row * 23), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.black
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        let sourceImage = CIImage(cgImage: bitmap.makeImage()!)
        func video(_ image: CIImage, name: String) async throws -> URL {
            let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(image.extent.width), AVVideoHeightKey: Int(image.extent.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000]
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            precondition(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<30 {
                while !input.isReadyForMoreMediaData { await Task.yield() }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA, nil, &buffer)
                context.render(image, to: buffer!)
                precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
            await writer.finishWriting()
            precondition(writer.status == .completed)
            return url
        }
        func frame(_ url: URL, seconds: Double = 0.5) async throws -> CGImage {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        }
        func save(_ image: CGImage, name: String) throws {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        let source = try await video(sourceImage, name: "source")
        let decoded = CIImage(cgImage: try await frame(source))
        let camera = CameraTransform(zoom: 2, centerX: 0.35, centerY: 0.5)
        let keyframes = [CameraKeyframe(time: 0, transform: camera), CameraKeyframe(time: 1, transform: camera)]
        let canvas = CanvasCompositor(size: outputSize, sourceSize: sourceSize, layout: .desktop, wallpaper: .sonoma)
        let reference = canvas.composite(primary: decoded, camera: camera)
        let intermediate = TransformApplicator.apply(camera, to: decoded, sourceSize: sourceSize)
        let legacy = canvas.composite(primary: CIImage(cgImage: context.createCGImage(intermediate, from: intermediate.extent)!))
        let before = try await video(legacy, name: "two-resizes")
        let after = try await ExportEngine().export(sourceURL: source, keyframes: keyframes, configuration: .init(
            outputURL: directory.appendingPathComponent("single-resize-\(UUID().uuidString).mov"), showCursor: false,
            canvasRatio: .landscape, forceCanvas: true, exportResolution: .fhd1080))
        let beforeFrame = try await frame(before)
        let afterFrame = try await frame(after)
        let ideal = NSBitmapImageRep(cgImage: context.createCGImage(reference, from: reference.extent)!)
        let content = CanvasGeometry(size: outputSize, layout: .desktop, sourceSize: sourceSize).desktop!.insetBy(dx: 30, dy: 30)
        func error(_ frame: CGImage) -> Double {
            let result = NSBitmapImageRep(cgImage: frame)
            var sum: Double = 0
            var count = 0
            for vertical in stride(from: Int(outputSize.height - content.maxY), to: Int(outputSize.height - content.minY), by: 2) {
                for horizontal in stride(from: Int(content.minX), to: Int(content.maxX), by: 2) {
                    let actual = result.colorAt(x: horizontal, y: vertical)!.usingColorSpace(.sRGB)!.redComponent
                    let expected = ideal.colorAt(x: horizontal, y: vertical)!.usingColorSpace(.sRGB)!.redComponent
                    sum += abs(Double(actual - expected))
                    count += 1
                }
            }
            return sum / Double(count)
        }
        let oldError = error(beforeFrame)
        let newError = error(afterFrame)
        print("Text render mean error: two resizes=\(oldError), single resize=\(newError)")
        precondition(newError < oldError * 0.9, "Single-pass export did not reduce resampling error")
        try save(beforeFrame, name: "text-before")
        try save(afterFrame, name: "text-after")
        var settings = VideoEditSettings(ratio: .landscape, showCursor: false, zoomEnabled: true, exportResolution: .fhd1080)
        settings.wallpaper = .sonoma
        let preview = LiveEditFrameRenderer(sourceSize: sourceSize, settings: settings, keyframes: keyframes).render(decoded, at: 0.5)
        let previewFrame = context.createCGImage(preview, from: preview.extent)!
        precondition(error(previewFrame) < 0.001, "Preview is not using the same direct render")
        print("PASS: actual encoded text retains more detail, and preview matches the single-pass reference")
        if CommandLine.arguments.count == 3 {
            if let wallpaper = NSImage(contentsOfFile: "Screen/Assets.xcassets/WallpaperLagoon.imageset/wallpaper.png") {
                wallpaper.setName("WallpaperLagoon")
            }
            let realSource = URL(fileURLWithPath: CommandLine.arguments[1])
            let mouse = URL(fileURLWithPath: CommandLine.arguments[2])
            let originalBytes = try Data(contentsOf: realSource)
            let realKeyframes = try await ClickZoomGenerator.generate(from: mouse, sourceVideoURL: realSource)
            let result = try await ExportEngine().export(sourceURL: realSource, keyframes: realKeyframes, configuration: .init(
                outputURL: directory.appendingPathComponent("recording-single-pass-\(UUID().uuidString).mov"),
                mouseDataURL: mouse, showCursor: true, canvasRatio: .landscape, wallpaper: .lagoon, forceCanvas: true))
            try save(try await frame(result, seconds: 3), name: "recording-after")
            let retainedBytes = try Data(contentsOf: realSource)
            precondition(retainedBytes == originalBytes)
            print("USER COMPARISON:", result.path)
        }
        print("COMPARISON IMAGES:", directory.path)
    }
}
