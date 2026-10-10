import AppKit
import AVFoundation
import CoreImage
@testable import ScreenTake

@main
struct BeautyExportChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent(".build/beauty-checks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let makeup = CommandLine.arguments.contains("--makeup") ? FaceMakeupSettings(amount: 1) : nil
        let naturalAmount = makeup == nil ? 0.8 : 0.0
        let oldPeach = Data("{\"amount\":0.7,\"lashes\":0.65}".utf8)
        let migratedPeach = try JSONDecoder().decode(FaceMakeupSettings.self,from:oldPeach)
        precondition(migratedPeach.skin == 0.9 && migratedPeach.definition == 0.65 && migratedPeach.lashes == 0.65)
        var settings = VideoEditSettings(backgroundEnabled: false, showCursor: false, webcamEnabled: true,
                                         faceBeautyAmount: naturalAmount, faceMakeup: makeup, cameraLayout: CameraLayoutSettings(layout: .fullScreen))
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(VideoEditSettings.self, from: encoded)
        precondition(decoded == settings)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "faceBeautyAmount")
        legacy.removeValue(forKey: "faceMakeup")
        let migrated = try JSONDecoder().decode(VideoEditSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(migrated.faceBeautyAmount == nil && migrated.faceMakeup == nil)
        try settings.validate(duration: 1)
        var invalid = settings; invalid.faceBeautyAmount = 2
        do { try invalid.validate(duration: 1); fatalError("Invalid intensity accepted") } catch is EditValidationError {}
        var edit = EditorEdits(); edit.faceBeautyAmount = 0
        edit.apply(to: &invalid); precondition(invalid.faceBeautyAmount == 0)
        for key in FaceMakeupSettings.keys {
            var value = FaceMakeupSettings(amount: 1); value[keyPath: key] = 2
            var invalidMakeup = settings; invalidMakeup.faceMakeup = value
            do { try invalidMakeup.validate(duration: 1); fatalError("Invalid makeup accepted") } catch is EditValidationError {}
        }
        var makeupEdit = EditorEdits(); makeupEdit.faceMakeup = FaceMakeupSettings(amount: 0)
        makeupEdit.apply(to: &invalid); precondition(invalid.faceMakeup?.amount == 0)
        print("PASS: project round trip, legacy migration, validation, edit-command off")
        let context = CIContext()
        let bounds = CGRect(x: 0, y: 0, width: 512, height: 512)
        let portrait = CIImage(contentsOf: root.appendingPathComponent("website/assets/camera-presenter.png"))!
            .transformed(by: CGAffineTransform(scaleX: 2.0/3, y: 2.0/3))
        func movie(_ name: String, camera: Bool) async throws -> URL {
            let url = directory.appendingPathComponent(name + ".mov")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 512, AVVideoHeightKey: 512, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input); precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
            let fps: Int32 = camera ? 25 : 60
            for index in 0..<Int(fps) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 512, 512, kCVPixelFormatType_32BGRA, nil, &buffer)
                let image = camera ? portrait : CIImage(color: CIColor(red: 0.1, green: 0.4, blue: 0.6)).cropped(to: bounds)
                context.render(image, to: buffer!)
                precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: fps)))
            }
            input.markAsFinished(); writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
            await writer.finishWriting(); precondition(writer.status == .completed)
            return url
        }
        let source = try await movie("beauty-screen", camera: false)
        let camera = try await movie("beauty-camera", camera: true)
        // A 25fps camera held across 60fps output must not re-run beauty work.
        let samples = OverlayVideoFrames(url: camera, preciseTiming: true)
        let compositor = WebcamCompositor(outputSize: bounds.size, position: .bottomRight, pipSize: .medium)
        let background = CIImage(color: .black).cropped(to: bounds)
        var actualTimes = Set<Double>()
        var lastFrame: OverlayVideoFrames.Frame!
        for index in 0..<60 {
            let sample = samples.frame(at: CMTime(value: Int64(index), timescale: 60))!
            actualTimes.insert(sample.time.seconds)
            _ = compositor.composite(webcamImage: sample.image, onto: background,
                                     beautyTime: sample.time.seconds, makeup: FaceMakeupSettings(amount: 1))
            lastFrame = sample
        }
        precondition(actualTimes.count == 25 && compositor.filteredFrameCount == 25,
                     "Each decoded camera frame should be filtered once, not 60 times")
        let repeated = samples.frame(at: CMTime(value: 59, timescale: 60))!
        precondition(repeated.image === lastFrame.image && repeated.time == lastFrame.time)
        _ = compositor.composite(webcamImage: repeated.image, onto: background,
                                 beautyAmount: 0.5, beautyTime: repeated.time.seconds, makeup: FaceMakeupSettings(amount: 1))
        precondition(compositor.filteredFrameCount == 26, "A slider change must invalidate the held frame")
        let seek = samples.frame(at: .zero)!
        _ = compositor.composite(webcamImage: seek.image, onto: background,
                                 beautyTime: seek.time.seconds, makeup: FaceMakeupSettings(amount: 1))
        precondition(compositor.filteredFrameCount == 27, "Seeking backward must reprocess the camera sample")
        let beforeTransition = compositor.composite(webcamImage: seek.image, onto: background,
                                settings: CameraLayoutSettings(layout: .fullScreen), beautyTime: seek.time.seconds, makeup: FaceMakeupSettings(amount: 1))
        let afterTransition = compositor.composite(webcamImage: seek.image, onto: background,
                                beautyTime: seek.time.seconds, makeup: FaceMakeupSettings(amount: 1))
        func pixel(_ image: CIImage) -> [UInt8] {
            var value = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &value, rowBytes: 4, bounds: CGRect(x: 256, y: 256, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return value
        }
        precondition(pixel(beforeTransition) != pixel(afterTransition) && compositor.filteredFrameCount == 27,
                     "Layout must update independently of the cached camera pixels")
        let replacement = CIImage(color: .green).cropped(to: bounds)
        _ = compositor.composite(webcamImage: replacement, onto: background,
                                 beautyTime: seek.time.seconds, makeup: FaceMakeupSettings(amount: 1))
        precondition(compositor.filteredFrameCount == 28, "A different source at the same timestamp must invalidate the cache")
        let size = CGSize(width: 1920, height: 1080)
        precondition(CameraBeautyPreviewRenderer.renderLongEdge(source: size, display: CGSize(width: 280, height: 280)) == 640)
        precondition(CameraBeautyPreviewRenderer.renderLongEdge(source: size, display: CGSize(width: 1280, height: 720)) == 640)
        precondition(CameraBeautyPreviewRenderer.renderLongEdge(source: size, display: CGSize(width: 1280, height: 720), beautyEnabled: false) == 960)
        print("PASS: 25 camera samples for 60 output frames, slider/source/seek invalidation, independent layout, preview size budget")
        settings.videoOverlayURL = camera
        let item = try await LiveVideoPreview.makeItem(.init(source: source, audio: nil, mouse: nil, webcam: camera, settings: settings))
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let preview = try await generator.image(at: time).image
        let engine = ExportEngine()
        let exported = try await engine.export(sourceURL: source, keyframes: [], configuration: .init(
            outputURL: directory.appendingPathComponent("beauty-export.mov"), codec: .h264,
            webcamVideoURL: camera, cameraLayout: settings.cameraLayout, faceBeautyAmount: naturalAmount, faceMakeup: makeup ?? .init(), showCursor: false))
        let exportGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        exportGenerator.requestedTimeToleranceBefore = .zero; exportGenerator.requestedTimeToleranceAfter = .zero
        let rendered = try await exportGenerator.image(at: time).image
        func bytes(_ image: CGImage) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: 512*512*4)
            context.render(CIImage(cgImage: image), toBitmap: &result, rowBytes: 512*4, bounds: bounds,
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return result
        }
        let a = bytes(preview), b = bytes(rendered)
        let error = Double(zip(a,b).map { abs(Int($0)-Int($1)) }.reduce(0,+))/Double(a.count)
        for (name, image) in [("preview",preview),("export",rendered)] {
            try context.writePNGRepresentation(of: CIImage(cgImage: image), to: directory.appendingPathComponent("\(name).png"),
                                              format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let offSettings = VideoEditSettings(backgroundEnabled: false, showCursor: false, webcamEnabled: true,
                                           cameraLayout: CameraLayoutSettings(layout: .fullScreen), videoOverlayURL: camera)
        let off = try await LiveVideoPreview.makeItem(.init(source: source, audio: nil, mouse: nil, webcam: camera, settings: offSettings))
        let offGenerator = AVAssetImageGenerator(asset: off.asset); offGenerator.videoComposition = off.videoComposition
        offGenerator.requestedTimeToleranceBefore = .zero; offGenerator.requestedTimeToleranceAfter = .zero
        let offImage = try await offGenerator.image(at: time).image
        let offPixels = bytes(offImage)
        try context.writePNGRepresentation(of: CIImage(cgImage: offImage), to: directory.appendingPathComponent("preview-off.png"),
                                          format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let effect = zip(a,offPixels).map { abs(Int($0)-Int($1)) }.reduce(0,+)
        precondition(effect > 10_000, "Preview must actually apply the filter")
        let offURL = try await engine.export(sourceURL: source, keyframes: [], configuration: .init(
            outputURL: directory.appendingPathComponent("beauty-off-export.mov"), codec: .h264,
            webcamVideoURL: camera, cameraLayout: settings.cameraLayout, showCursor: false))
        let offExport = AVAssetImageGenerator(asset: AVURLAsset(url: offURL))
        offExport.requestedTimeToleranceBefore = .zero; offExport.requestedTimeToleranceAfter = .zero
        let offExportImage = try await offExport.image(at: time).image
        let offExportPixels = bytes(offExportImage)
        try context.writePNGRepresentation(of: CIImage(cgImage: offExportImage), to: directory.appendingPathComponent("export-off.png"),
                                          format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let baseline = Double(zip(offPixels,offExportPixels).map { abs(Int($0)-Int($1)) }.reduce(0,+))/Double(a.count)
        let deltaError = Double(a.indices.map { abs((Int(a[$0])-Int(offPixels[$0]))-(Int(b[$0])-Int(offExportPixels[$0]))) }.reduce(0,+))/Double(a.count)
        let exportEffect = zip(b,offExportPixels).map { abs(Int($0)-Int($1)) }.reduce(0,+)
        print("Preview/export color baseline: \(baseline), filtered: \(error), filter-delta difference: \(deltaError); preview effect=\(effect), export effect=\(exportEffect)")
        precondition(deltaError < 0.75 && error < baseline + 0.5, "Beauty must not introduce a preview/export mismatch")
        precondition(exportEffect > 10_000, "Export must actually apply the filter")
        print("PASS: real video preview/export filter parity; effect differences preview=\(effect), export=\(exportEffect)")
    }
}
