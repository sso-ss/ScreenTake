import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct CustomBackgroundChecks {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("custom-background-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = CIContext()
        let imageURL = directory.appendingPathComponent("background.png")
        // Distinct outer bands prove that Fill crops centrally instead of stretching.
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 100)
        let background = CIImage(color: .green).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 100))
            .composited(over: CIImage(color: .red).cropped(to: bounds))
        try context.writePNGRepresentation(of: background, to: imageURL, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let data = try CustomBackgroundImage.load(from: imageURL)
        let decoded = CIImage(data: data)!
        precondition(decoded.extent.size == bounds.size)
        let invalid = directory.appendingPathComponent("invalid.png")
        try Data("invalid".utf8).write(to: invalid)
        do {
            _ = try CustomBackgroundImage.load(from: invalid)
            preconditionFailure("Invalid image was accepted")
        } catch is CustomBackgroundImage.ImportError {}
        let large = directory.appendingPathComponent("large.png")
        try context.writePNGRepresentation(of: CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 5000, height: 100)),
                                          to: large, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let resized = CIImage(data: try CustomBackgroundImage.load(from: large))!
        precondition(resized.extent.width == 4096 && resized.extent.height < 100)
        let rotated = directory.appendingPathComponent("rotated.jpg")
        let destination = CGImageDestinationCreateWithURL(rotated as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.createCGImage(background, from: bounds)!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let oriented = try CustomBackgroundImage.load(from: rotated)
        precondition(CIImage(data: oriented)!.extent.size == CGSize(width: 100, height: 600))
        print("PASS: PNG import, photo orientation, large-image resizing, and invalid-image rejection")

        let capture = CaptureSettings()
        let original = capture.customBackgroundImage
        defer { capture.customBackgroundImage = original }
        capture.customBackgroundImage = data
        precondition(CaptureSettings().customBackgroundImage == data && capture.usesCanvas)
        precondition(capture.backgroundStyle == .image(data))
        capture.customBackgroundImage = nil
        precondition(capture.backgroundStyle == .wallpaper(capture.selectedWallpaper))
        print("PASS: recording preferences persist and restore preset backgrounds")

        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var settings = VideoEditSettings(ratio: .square, customBackgroundImage: data, showCursor: false)
        let restored = try decoder.decode(VideoEditSettings.self, from: encoder.encode(settings))
        precondition(restored == settings)
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(settings)) as! [String: Any]
        legacy.removeValue(forKey: "customBackgroundImage")
        let legacySettings = try decoder.decode(VideoEditSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacySettings.customBackgroundImage == nil)
        EditorEdits(wallpaper: .ocean).apply(to: &settings)
        precondition(settings.customBackgroundImage == nil && settings.wallpaper == .ocean)
        settings.customBackgroundImage = data
        print("PASS: project compatibility and preset selection")

        let source = directory.appendingPathComponent("source.mov")
        let sourceSize = CGSize(width: 320, height: 200)
        let frame = CIImage(color: .blue).cropped(to: CGRect(origin: .zero, size: sourceSize))
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 200])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for seconds in [0.0, 0.1] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
            context.render(frame, to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 0.2, preferredTimescale: 600))
        await writer.finishWriting()
        precondition(writer.status == .completed)

        let session = EditorSession()
        try await session.openVideo(source)
        session.draft = settings
        session.undo()
        precondition(session.draft.customBackgroundImage == nil)
        session.redo()
        precondition(session.draft.customBackgroundImage == data)
        let package = directory.appendingPathComponent("Custom.\(ScreenProject.packageExtension)")
        let project = EditorProject(id: UUID(), revision: 1, name: "Custom", source: source, settings: settings)
        _ = try await EditorProjectStore.save(project, to: package)
        try FileManager.default.removeItem(at: imageURL)
        let reopened = try await EditorProjectStore.load(from: package)
        precondition(reopened.settings.customBackgroundImage == data)
        print("PASS: Undo/Redo and saved projects retain the image after the original is removed")

        func pixel(_ image: CGImage, x: Int, y: Int) -> NSColor {
            NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        }
        let renderer = LiveEditFrameRenderer(sourceSize: sourceSize, settings: settings, keyframes: [])
        let preview = renderer.render(frame, at: 0)
        let rendered = context.createCGImage(preview, from: preview.extent)!
        let mock = CanvasCompositor.preview(size: renderer.outputSize, layout: .desktop, wallpaper: .sonoma, customBackgroundImage: data)!
        for image in [rendered, mock] {
            let color = pixel(image, x: 4, y: 4)
            precondition(color.greenComponent > 0.9 && color.redComponent < 0.1, "Background must fill with centered crop")
        }
        let output = directory.appendingPathComponent("export.mov")
        _ = try await ExportEngine().export(sourceURL: source, keyframes: [], configuration: .init(outputURL: output,
            canvasRatio: .square, customBackgroundImage: data, forceCanvas: true))
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.appliesPreferredTrackTransform = true
        let exported = try await generator.image(at: .zero).image
        let color = pixel(exported, x: 4, y: 4)
        precondition(color.greenComponent > 0.85 && color.redComponent < 0.15, "Export lost custom background")
        print("PASS: mock preview, live preview, and actual video export share the centered image fill")
        session.close()
    }
}
