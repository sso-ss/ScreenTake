import AppKit
import AVFoundation
import CoreImage
import SwiftUI

@main struct ZoomRegionChecks {
    @MainActor static func main() {
        setbuf(stdout, nil)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let region = ZoomRegion(zoom: 2, center: CGPoint(x: 0.5, y: 1))
        precondition(region.rect == CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
        let moved = region.moved(by: CGSize(width: 4, height: -4))
        precondition(moved.rect == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        for corner in PhoneCrop.Corner.allCases {
            for delta in [CGSize(width: 5, height: -5), CGSize(width: -5, height: 5), CGSize(width: 0.1, height: 0.1)] {
                let resized = region.resized(by: delta, corner: corner)
                let rect = resized.rect
                precondition(abs(rect.width - rect.height) < 0.000001)
                precondition(rect.width >= 0.125 && rect.width <= 1)
                precondition(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1)
                let left = corner == .topLeft || corner == .bottomLeft
                let top = corner == .topLeft || corner == .topRight
                precondition(abs((left ? rect.maxX : rect.minX) - (left ? region.rect.maxX : region.rect.minX)) < 0.000001)
                precondition(abs((top ? rect.maxY : rect.minY) - (top ? region.rect.maxY : region.rect.minY)) < 0.000001)
            }
        }
        print("PASS: box movement, aspect-preserving corner resizing, fixed opposite anchors, and 1–8× bounds")
        for sourceSize in [CGSize(width: 1440, height: 900), CGSize(width: 320, height: 1280)] {
            for layout in [DeviceLayout.iPhone, .iPhoneDuoClosed, .iPhoneDuoUnfolded] {
                let viewport = ZoomRegion.viewport(sourceSize: sourceSize, layout: layout, mode: .fill)
                let screen = CanvasGeometry.phoneContent(CGRect(origin: .zero, size: layout.phoneFrameSize), layout: layout)
                for area in [region, ZoomRegion(zoom: 6, center: CGPoint(x: 0.7, y: 0.4))] {
                    let visible = area.visibleRect(in: viewport)
                    precondition(abs(visible.width * sourceSize.width / (visible.height * sourceSize.height)
                                     - screen.width / screen.height) < 0.000001)
                    for corner in PhoneCrop.Corner.allCases {
                        for delta in [CGSize(width: 0.05, height: -0.03), CGSize(width: -2, height: -2), CGSize(width: 2, height: 2)] {
                            let resized = area.resized(by: delta, corner: corner, viewport: viewport)
                            let box = resized.visibleRect(in: viewport)
                            let left = corner == .topLeft || corner == .bottomLeft
                            let top = corner == .topLeft || corner == .topRight
                            precondition(abs((left ? box.maxX : box.minX) - (left ? visible.maxX : visible.minX)) < 0.000001)
                            precondition(abs((top ? box.maxY : box.minY) - (top ? visible.maxY : visible.minY)) < 0.000001)
                            precondition(resized.magnification >= 1 && resized.magnification <= 8.000001)
                            precondition(box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1)
                        }
                    }
                }
                precondition(ZoomRegion.viewport(sourceSize: sourceSize, layout: layout, mode: .fit) == CGSize(width: 1, height: 1))
            }
        }
        print("PASS: phone Fill selection matches screen aspect with anchored resizing; Fit retains the full source")
        var fixed = ZoomSegment(start: 0.1, end: 1.5, zoom: 2, centerX: 0.5, centerY: 0.5)
        fixed.manualRegion = region
        let positions = stride(from: 0.0, through: 2.0, by: 1.0 / 60).map {
            MouseDataRecorder.MousePosition(timestamp: $0, x: $0 / 2, y: $0 / 2, velocity: 1)
        }
        let followed = ClickZoomGenerator.generate(segments: [fixed], positions: positions, paddingRatio: 0.08)
        for time in [0.8, 1.2, 1.5] {
            let camera = FrameEvaluator(keyframes: followed).evaluate(at: time)
            precondition(abs(camera.zoom - 2) < 0.001 && abs(camera.centerY - 0.75) < 0.001,
                         "A manual area must stay fixed despite cursor movement and window padding")
        }
        print("PASS: fixed areas ignore cursor motion and retain top-left coordinates with padded recordings")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-region-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("mobile.mov")
        try await makeVideo(source)
        // Compare against the same video color pipeline at 1×, so this checks
        // the selected pixels independently of AVFoundation color conversion.
        let baseline = try await LiveVideoPreview.makeItem(.init(source: source, audio: nil, mouse: nil, webcam: nil,
            settings: VideoEditSettings(backgroundEnabled: false, showCursor: false)))
        let original = try await frame(baseline.asset, composition: baseline.videoComposition)
        let context = CIContext()
        let phoneScreen = CanvasGeometry.phoneContent(CGRect(origin: .zero, size: DeviceLayout.iPhone.phoneFrameSize))
        let phoneBounds = CGRect(origin: .zero, size: phoneScreen.size)
        for sourceImage in [original, original.cropping(to: CGRect(x: 0, y: 190, width: 320, height: 180))!] {
            let size = CGSize(width: sourceImage.width, height: sourceImage.height)
            // Use the same Core Image output color space for both sides.
            let reference = context.createCGImage(CIImage(cgImage: sourceImage), from: CGRect(origin: .zero, size: size))!
            for mode in PhoneContentMode.allCases {
                let viewport = ZoomRegion.viewport(sourceSize: size, layout: .iPhone, mode: mode)
                for area in [region, ZoomRegion(zoom: 6, center: CGPoint(x: 0.6, y: 0.4))] {
                    let rendered = CanvasCompositor.fitted(CIImage(cgImage: sourceImage), in: phoneBounds,
                                                           mode: mode, camera: area.camera(in: PhoneCrop()))
                    let content = mode == .fill ? phoneBounds : CanvasGeometry.fit(size, in: phoneBounds)
                    let result = context.createCGImage(rendered, from: content)!
                    let visible = area.visibleRect(in: viewport)
                    let pixels = CGRect(x: visible.minX * size.width, y: visible.minY * size.height,
                                        width: visible.width * size.width, height: visible.height * size.height)
                    assertArea(result, matches: reference, area: pixels, tolerance: 0.06,
                               label: "phone \(mode) at \(area.magnification)×", avoidEdges: true)
                }
            }
        }
        print("PASS: mobile selection matches rendered phone pixels in Fill and Fit for landscape and portrait sources")
        let baselineExportURL = directory.appendingPathComponent("baseline.mov")
        _ = try await ExportEngine().export(sourceURL: source, keyframes: [], configuration: .init(
            outputURL: baselineExportURL, showCursor: false, forceCanvas: false))
        let exportOriginal = try await frame(AVURLAsset(url: baselineExportURL))
        let session = EditorSession()
        try await session.openVideo(source)
        precondition(session.mouseURL == nil, "Fixture must represent an imported mobile video")

        for crop in [PhoneCrop(), PhoneCrop(rect: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.5))] {
            for area in [region, ZoomRegion(zoom: 6, center: CGPoint(x: 0, y: 0))] {
                var segment = ZoomSegment(start: 0.1, end: 1.8, zoom: 2, centerX: 0.5, centerY: 0.5)
                segment.manualRegion = area
                // A selected area takes precedence even if old cursor-follow metadata is true.
                let settings = VideoEditSettings(backgroundEnabled: false, crop: crop, showCursor: false,
                                                 zoomEnabled: true, zoomLevel: 3, zoomSegments: [segment])
                try settings.validate(duration: 2)
                let frames = try await ClickZoomGenerator.generate(from: nil, sourceVideoURL: source,
                    settings: .init(zoomLevel: 3), segments: [segment], crop: crop)
                let camera = FrameEvaluator(keyframes: frames).evaluate(at: 1)
                precondition(abs(camera.zoom - area.magnification) < 0.001, "Box size must override global zoom")
                let previous = session.draft
                session.draft = settings
                session.undo()
                precondition(session.draft == previous, "One Undo must restore all prior settings")
                session.redo()
                precondition(session.draft == settings)
                await session.waitForPreview()
                let item = session.player!.currentItem!
                let preview = try await frame(item.asset, composition: item.videoComposition)
                let output = try await session.applyChanges()
                let exported = try await frame(AVURLAsset(url: output))
                let sourceCrop = crop.normalized
                let selected = area.rect
                let sourceArea = CGRect(x: (sourceCrop.minX + selected.minX * sourceCrop.width) * CGFloat(original.width),
                                        y: (sourceCrop.minY + selected.minY * sourceCrop.height) * CGFloat(original.height),
                                        width: selected.width * sourceCrop.width * CGFloat(original.width),
                                        height: selected.height * sourceCrop.height * CGFloat(original.height))
                assertArea(preview, matches: original, area: sourceArea, tolerance: 0.06, label: "preview")
                assertArea(exported, matches: exportOriginal, area: sourceArea, tolerance: 0.06, label: "export")
                let package = directory.appendingPathComponent("area.screentake")
                try await session.saveProject(to: package)
                let saved = try await EditorProjectStore.load(from: package)
                precondition(saved.settings.zoomSegments?.first?.manualRegion == area)
                print("PASS: \(Int(area.magnification))× area with crop \(crop.normalized), no mouse data, preview/export pixels, Undo/Redo, and project save")
            }
        }

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.draft)) as! [String: Any]
        var segments = legacy["zoomSegments"] as! [[String: Any]]
        segments[0].removeValue(forKey: "manualRegion")
        legacy["zoomSegments"] = segments
        let restored = try JSONDecoder().decode(VideoEditSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(restored.zoomSegments?.first?.manualRegion == nil)
        var invalid = session.draft
        invalid.zoomSegments![0].manualRegion!.rect = CGRect(x: 0, y: 0, width: 0.01, height: 0.5)
        do { try invalid.validate(duration: 2); preconditionFailure("Malformed zoom boxes must be rejected") }
        catch is EditValidationError { }
        print("PASS: old project compatibility and malformed area validation")
        session.close()
    }

    static func assertArea(_ result: CGImage, matches source: CGImage, area: CGRect, tolerance: Double, label: String,
                           avoidEdges: Bool = false) {
        let actual = NSBitmapImageRep(cgImage: result)
        let expected = NSBitmapImageRep(cgImage: source)
        var checked = 0
        // Sample stripe interiors in all four crops, away from boundaries where
        // scaling and H.264 chroma interpolation blend neighboring colors.
        for y in (avoidEdges ? [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8] : [0.27, 0.43, 0.7]) {
            for x in (avoidEdges ? [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8] : [0.3, 0.43, 0.6]) {
            let a = actual.colorAt(x: Int(x * Double(result.width)), y: Int(y * Double(result.height)))!.usingColorSpace(.deviceRGB)!
            let b = expected.colorAt(x: Int(area.minX + x * area.width), y: Int(area.minY + y * area.height))!.usingColorSpace(.deviceRGB)!
            if avoidEdges {
                let px = Int(area.minX + x * area.width), py = Int(area.minY + y * area.height)
                let neighbors = [(-3, 0), (3, 0), (0, -3), (0, 3)].map { dx, dy in
                    expected.colorAt(x: min(source.width - 1, max(0, px + dx)),
                                     y: min(source.height - 1, max(0, py + dy)))!.usingColorSpace(.deviceRGB)!
                }
                if neighbors.contains(where: { abs($0.redComponent - b.redComponent) > 0.02 || abs($0.greenComponent - b.greenComponent) > 0.02 }) { continue }
            }
            checked += 1
            precondition(abs(a.redComponent - b.redComponent) < tolerance && abs(a.greenComponent - b.greenComponent) < tolerance,
                         "Selected source area differs from \(label) at \(x),\(y): \(a) vs \(b)")
        } }
        precondition(checked >= 4, "Insufficient stable sample pixels for \(label)")
    }

    static func frame(_ asset: AVAsset, composition: AVVideoComposition? = nil) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 60000)).image
    }

    static func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 640,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 640, kCVPixelFormatType_32BGRA, nil, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer!)
        for y in 0..<640 { for x in 0..<320 {
            let offset = y * stride + x * 4
            // Binary stripes make a wrong crop or vertical flip unmistakable,
            // while remaining insensitive to codec transfer-function changes.
            bytes[offset] = 100; bytes[offset + 1] = UInt8((y / 64) % 2 * 255)
            bytes[offset + 2] = UInt8((x / 40) % 2 * 255); bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        for index in 0..<60 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 60000))
        await writer.finishWriting()
        precondition(writer.status == .completed)
    }
}
