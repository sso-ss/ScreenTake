import AppKit
import AVFoundation
import CoreImage
import QuartzCore

@main struct PixelAlignmentChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let crop = CaptureConfiguration.pixelAlignedCrop(size: CGSize(width: 601, height: 401), scaleFactor: 1)!
        precondition(crop == CGRect(x: 0, y: 0, width: 600, height: 400))
        precondition(CaptureConfiguration.pixelAlignedCrop(size: CGSize(width: 602, height: 402), scaleFactor: 1) == nil)
        precondition(CaptureConfiguration.pixelAlignedCrop(size: CGSize(width: 601, height: 401), scaleFactor: 2) == nil)
        let retinaCrop = CaptureConfiguration.pixelAlignedCrop(size: CGSize(width: 601.5, height: 401.5), scaleFactor: 2)!
        precondition(retinaCrop.size == CGSize(width: 601, height: 401))
        let capture = CaptureConfiguration(width: 600, height: 400, scaleFactor: 1, capturesShadow: false, sourceRect: crop)
        let stream = capture.createStreamConfiguration()
        precondition(stream.width == 600 && stream.height == 400 && !stream.scalesToFit && stream.sourceRect == crop)
        precondition(capture.mouseBounds(in: CGRect(x: 100, y: 200, width: 601, height: 401)) == CGRect(x: 100, y: 201, width: 600, height: 400))
        let browser = capture.croppedBrowserRect(CGRect(x: 0, y: 50.0 / 401, width: 1, height: 351.0 / 401), windowSize: CGSize(width: 601, height: 401))!
        precondition(abs(browser.minY - 0.125) < 0.000001 && browser.width == 1 && abs(browser.height - 0.875) < 0.000001)
        print("PASS: native crop retains encoder dimensions and correct cursor/browser coordinates at 1x and Retina scale")

        let sourceSize = CGSize(width: 640, height: 400)
        let settings = VideoEditSettings(ratio: .landscape, showCursor: false)
        let outputSize = settings.outputSize(source: sourceSize)
        let oldGeometry = CanvasGeometry(size: outputSize, layout: .desktop, sourceSize: sourceSize)
        let geometry = CanvasGeometry(size: outputSize, layout: .desktop, sourceSize: sourceSize, preserveSourcePixels: true)
        precondition(geometry.desktop!.size == sourceSize && geometry.desktop!.origin.x.rounded() == geometry.desktop!.minX && geometry.desktop!.origin.y.rounded() == geometry.desktop!.minY)
        let capped = LiveEditFrameRenderer(sourceSize: CGSize(width: 1824, height: 1236), settings: settings, keyframes: [])
        precondition(capped.outputSize == CGSize(width: 2560, height: 1440))
        print("PASS: Preserve source uses integer 1x desktop placement; preview cap is unchanged")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pixel-alignment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(origin: .zero, size: sourceSize))
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 80, to: 560, by: 2) { bitmap.fill(CGRect(x: x, y: 80, width: 1, height: 240)) }
        let image = CIImage(cgImage: bitmap.makeImage()!)
        let context = CIContext()
        func contrast(_ image: CGImage, rect: CGRect) -> Double {
            let decoded = NSBitmapImageRep(cgImage: image)
            var sum = 0.0
            for x in 100..<540 {
                let point = Int((rect.minX + CGFloat(x) * rect.width / sourceSize.width).rounded())
                sum += abs(Double(decoded.colorAt(x: point, y: decoded.pixelsHigh / 2)!.usingColorSpace(.sRGB)!.redComponent) - 0.5)
            }
            return sum / 440
        }
        var values: [Double] = []
        for aligned in [false, true] {
            let compositor = CanvasCompositor(size: outputSize, sourceSize: sourceSize, layout: .desktop, wallpaper: .ember, preserveSourcePixels: aligned)
            let rendered = compositor.composite(primary: image)
            values.append(contrast(context.createCGImage(rendered, from: rendered.extent)!, rect: compositor.geometry.desktop!))
        }
        precondition(values[1] > 0.48 && values[1] > values[0] + 0.05, "Pixel alignment must recover fine-bar contrast: \(values)")

        let source = directory.appendingPathComponent("source.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 640, AVVideoHeightKey: 400, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input); precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for i in 0..<15 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 400, kCVPixelFormatType_32BGRA, nil, &pixel)
            context.render(image, to: pixel!)
            precondition(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(i), timescale: 30)))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 1, timescale: 2)); await writer.finishWriting()
        precondition(writer.status == .completed)
        let original = try Data(contentsOf: source)
        let export = try await ExportEngine().export(sourceURL: source, keyframes: [], configuration: .init(
            outputURL: directory.appendingPathComponent("aligned.mov"), showCursor: false, canvasRatio: .landscape, forceCanvas: true))
        let asset = AVURLAsset(url: export)
        let size = try await asset.loadTracks(withMediaType: .video).first!.load(.naturalSize)
        precondition(size == outputSize)
        let frame = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(value: 1, timescale: 5)).image
        let encodedContrast = contrast(frame, rect: geometry.desktop!)
        precondition(encodedContrast > 0.47, "HEVC must retain the aligned fine detail: \(encodedContrast)")
        let item = try await LiveVideoPreview.makeItem(.init(source: source, audio: source, mouse: nil, webcam: nil, settings: settings))
        let generator = AVAssetImageGenerator(asset: item.asset); generator.videoComposition = item.videoComposition
        let preview = try await generator.image(at: CMTime(value: 1, timescale: 5)).image
        precondition(contrast(preview, rect: geometry.desktop!) > 0.47)
        let retained = try Data(contentsOf: source); precondition(retained == original)
        print("PASS: one-pixel bar contrast \(values[0]) -> \(values[1]); HEVC=\(encodedContrast); preview/export native geometry and original preserved (old rect \(oldGeometry.desktop!))")
    }
}
