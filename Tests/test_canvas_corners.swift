import AppKit
import AVFoundation
import CoreImage

@main
struct CanvasCornerTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let context = CIContext()
        let sourceSize = CGSize(width: 390, height: 844)
        let sourceFrame = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: sourceSize))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-corners-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(VideoEditSettings.self, from: encoder.encode(VideoEditSettings(layout: .iPhone)))
        precondition(legacy.phoneCornerRadius == nil, "Older projects must retain the device's default rounding")
        for layout in [DeviceLayout.iPhone, .iPhoneDuoClosed, .iPhoneDuoUnfolded] {
            let frame = CGRect(origin: .zero, size: layout.phoneFrameSize)
            let radius = CanvasGeometry.phoneScreenRadius(frame, layout: layout, cornerRadius: nil)
            let expected = CanvasGeometry.phoneUnit(frame, layout: layout) * (layout.isFoldablePhone ? 32 : 48)
            precondition(abs(radius - expected) < 0.000001)
        }
        var settings = VideoEditSettings(ratio: .vertical, layout: .iPhone, desktopCornerRadius: 0.18,
                                         phoneCornerRadius: 0.2, showCursor: false, exportResolution: .fhd1080)
        let restored = try decoder.decode(VideoEditSettings.self, from: encoder.encode(settings))
        precondition(restored == settings)
        try settings.validate(duration: 1)
        var invalid = settings
        invalid.phoneCornerRadius = 0.21
        do {
            try invalid.validate(duration: 1)
            preconditionFailure("An out-of-range phone radius was accepted")
        } catch is EditValidationError {}
        print("PASS: independent desktop/phone values persist, older device defaults survive, and radius validation rejects overflow")

        let sourceURL = directory.appendingPathComponent("source.mov")
        let writer = try AVAssetWriter(outputURL: sourceURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(sourceSize.width), AVVideoHeightKey: Int(sourceSize.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting(), "Fixture writer failed: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for seconds in [0.0, 0.1] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, 390, 844, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
            context.render(sourceFrame, to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 0.2, preferredTimescale: 600))
        await writer.finishWriting()
        precondition(writer.status == .completed)

        func color(_ image: CIImage, at point: CGPoint) -> [UInt8] {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return pixel
        }
        func isVideo(_ pixel: [UInt8]) -> Bool { pixel[0] > 210 && pixel[1] < 35 && pixel[2] < 35 }

        for mode in PhoneContentMode.allCases {
            settings.phoneMode = mode
            for radius in [0.0, 0.2] {
                settings.phoneCornerRadius = radius
                let renderer = LiveEditFrameRenderer(sourceSize: sourceSize, settings: settings, keyframes: [])
                let preview = renderer.render(sourceFrame, at: 0)
                let frame = CanvasGeometry(size: renderer.outputSize, layout: .iPhone, sourceSize: sourceSize).phone!
                let screen = CanvasGeometry.phoneScreen(frame)
                let unit = CanvasGeometry.phoneUnit(frame)
                let output = directory.appendingPathComponent("\(mode.rawValue)-\(radius).mov")
                _ = try await ExportEngine().export(sourceURL: sourceURL, keyframes: [], configuration: .init(
                    outputURL: output, showCursor: false, canvasRatio: .vertical, deviceLayout: .iPhone,
                    desktopCornerRadius: settings.desktopCornerRadius, phoneCornerRadius: radius,
                    phoneContentMode: mode, exportResolution: .fhd1080))
                let asset = AVURLAsset(url: output)
                let exported = CIImage(cgImage: try await AVAssetImageGenerator(asset: asset).image(at: .zero).image)
                precondition(exported.extent.size == renderer.outputSize)
                for image in [preview, exported] {
                    // These samples sit in the header/footer areas previously reserved for black bars.
                    for point in [CGPoint(x: screen.midX - 90 * unit, y: screen.maxY - 22 * unit),
                                  CGPoint(x: screen.midX + 90 * unit, y: screen.minY + 10 * unit)] {
                        precondition(isVideo(color(image, at: point)), "Fixed black header/footer remains in \(mode) at \(radius)")
                    }
                    let island = color(image, at: CGPoint(x: screen.midX, y: screen.maxY - 22 * unit))
                    precondition(island.prefix(3).allSatisfy { $0 < 20 }, "The floating island was covered by video")
                    let handle = color(image, at: CGPoint(x: screen.midX, y: screen.minY + 10 * unit))
                    precondition(handle[1] > 140 && handle[2] > 140, "The floating home indicator was covered by video")
                    let corner = color(image, at: CGPoint(x: screen.minX + 4 * unit, y: screen.minY + 26 * unit))
                    precondition(isVideo(corner) == (radius == 0), "Phone mask did not follow the radius")
                    let outerCorner = color(image, at: CGPoint(x: frame.minX + 5 * unit, y: frame.minY + 26 * unit))
                    precondition((outerCorner[0] < 40 && outerCorner[1] < 40 && outerCorner[2] < 40) == (radius == 0),
                                 "Phone bezel did not follow the radius")
                }
                if mode == .fit {
                    let bitmap = NSBitmapImageRep(cgImage: context.createCGImage(preview, from: preview.extent)!)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-phone-floating-\(radius).png"))
                }
                print("PASS: \(mode.rawValue), radius \(radius): preview/export agree on rounded frame, full screen footage, floating island and home indicator")
            }
        }
        for radius in [0.0, 0.2] {
            let compositor = CanvasCompositor(size: CGSize(width: 1080, height: 1920), sourceSize: sourceSize,
                                              layout: .desktop, wallpaper: .lagoon, desktopCornerRadius: radius)
            let frame = compositor.geometry.desktop!
            let image = compositor.composite(primary: sourceFrame)
            precondition(isVideo(color(image, at: CGPoint(x: frame.minX + 3, y: frame.minY + 3))) == (radius == 0))
        }
        print("PASS: desktop mask renders the expanded 20% radius")
    }
}
