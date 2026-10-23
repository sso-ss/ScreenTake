import AppKit
import AVFoundation
import CoreImage

@main
struct PersonCutoutChecks {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let camera = root.appendingPathComponent(".build/occlusion-checks/Peach eye and hand review.screenize/media/camera.mov")
        guard FileManager.default.fileExists(atPath: camera.path) else {
            print("SKIP: real camera clip is unavailable")
            return
        }
        let output = root.appendingPathComponent(".build/cutout-checks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: camera)
        let duration = try await asset.load(.duration).seconds
        precondition(duration > 0.5)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let context = CIContext()
        let segmentation = PersonCutout()
        let times = [0.2, min(1.0, duration / 3), min(2.0, duration / 2)]
        for (index, seconds) in times.enumerated() {
            let cgImage = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let original = CIImage(cgImage: cgImage)
            let scale = min(1, 640 / max(original.extent.width, original.extent.height))
            let frame = original.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let cutout = segmentation.apply(to: frame, source: frame, at: seconds)
            let width = Int(frame.extent.width), height = Int(frame.extent.height)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                context.render(cutout, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
                               bounds: frame.extent, format: .RGBA8,
                               colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            let alphas = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
            let transparent = alphas.filter { $0 < 20 }.count
            let opaque = alphas.filter { $0 > 230 }.count
            precondition(transparent > width * height / 20 && opaque > width * height / 20,
                         "Frame \(index) must contain both removed background and presenter")
            if index == 0 {
                try context.writePNGRepresentation(of: cutout, to: output.appendingPathComponent("real-video-cutout.png"),
                                                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                let screen = CIImage(color: CIColor(red: 0.1, green: 0.3, blue: 0.8))
                    .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
                let composited = WebcamCompositor(outputSize: screen.extent.size, position: .center,
                                                   pipSize: .large, shape: .cutout)
                    .composite(webcamImage: frame, onto: screen, beautyTime: seconds)
                try context.writePNGRepresentation(of: composited, to: output.appendingPathComponent("real-video-composite.png"),
                                                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            print("PASS: real video frame \(index) has \(transparent) transparent and \(opaque) opaque pixels")
        }
        let style = try JSONDecoder().decode(PiPShape.self, from: JSONEncoder().encode(PiPShape.cutout))
        precondition(style == .cutout)

        let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        let source = output.appendingPathComponent("screen.mov")
        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let screen = CIImage(color: CIColor(red: 0.1, green: 0.3, blue: 0.8)).cropped(to: bounds)
        for index in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
            context.render(screen, to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        await writer.finishWriting()
        precondition(writer.status == .completed)

        let settings = VideoEditSettings(backgroundEnabled: false, showCursor: false, webcamEnabled: true,
                                         webcamShape: .cutout)
        let item = try await LiveVideoPreview.makeItem(.init(source: source, audio: nil, mouse: nil,
                                                              webcam: camera, settings: settings))
        let previewGenerator = AVAssetImageGenerator(asset: item.asset)
        previewGenerator.videoComposition = item.videoComposition
        previewGenerator.requestedTimeToleranceBefore = .zero
        previewGenerator.requestedTimeToleranceAfter = .zero
        let timestamp = CMTime(seconds: 0.5, preferredTimescale: 600)
        let preview = try await previewGenerator.image(at: timestamp).image
        let exported = try await ExportEngine().export(sourceURL: source, keyframes: [], configuration: .init(
            outputURL: output.appendingPathComponent("export.mov"), codec: .h264, outputSize: bounds.size,
            webcamVideoURL: camera, pipShape: .cutout, showCursor: false))
        let exportGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        exportGenerator.requestedTimeToleranceBefore = .zero
        exportGenerator.requestedTimeToleranceAfter = .zero
        let render = try await exportGenerator.image(at: timestamp).image
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 640 * 360 * 4)
            data.withUnsafeMutableBytes { bytes in
                context.render(CIImage(cgImage: image), toBitmap: bytes.baseAddress!, rowBytes: 640 * 4,
                               bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            return data
        }
        let a = pixels(preview), b = pixels(render)
        let difference = Double(zip(a, b).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(a.count)
        print("Preview/export mean channel difference: \(difference)")
        precondition(difference < 12, "Background removal must look consistent in preview and export")
        for (name, image) in [("preview", preview), ("export", render)] {
            try context.writePNGRepresentation(of: CIImage(cgImage: image),
                                               to: output.appendingPathComponent("\(name).png"),
                                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        print("PASS: real video background removal in editor preview and export")
    }
}
