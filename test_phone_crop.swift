import Foundation
import CoreImage
import AppKit
import AVFoundation
import SwiftUI
#if SCREEN_APP_MODULE
@testable import ScreenTake
#endif

@main
struct PhoneCropTests {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let sourceSize = CGSize(width: 400, height: 800)
        let crop = PhoneCrop(rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.75))
        precondition(crop.pixelRect(in: sourceSize) == CGRect(x: 40, y: 120, width: 320, height: 600))
        precondition(PhoneCrop(rect: CGRect(x: -1, y: 2, width: 2, height: 0.5)).normalized == CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        precondition(PhoneCrop(rect: .zero).normalized == PhoneCrop().normalized)
        let moved = crop.dragged(by: CGSize(width: 2, height: -2)).normalized
        precondition(abs(moved.minX - 0.2) < 0.000001 && moved.minY == 0 && moved.width == 0.8 && moved.height == 0.75)
        for corner in PhoneCrop.Corner.allCases {
            let resized = crop.dragged(by: CGSize(width: 2, height: -2), corner: corner).normalized
            precondition(resized.width >= 0.019 && resized.height >= 0.019)
            precondition(CGRect(x: 0, y: 0, width: 1, height: 1).contains(resized))
        }
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        let target = CGRect(x: 0, y: 0, width: 100, height: 200)
        let fitted = CanvasCompositor.fitted(image, in: target)
        let filled = CanvasCompositor.fitted(image, in: target, mode: .fill)
        let context = CIContext()
        func alpha(_ image: CIImage, at point: CGPoint) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return pixel[3]
        }
        precondition(alpha(fitted, at: CGPoint(x: 50, y: 10)) == 0)
        precondition(alpha(fitted, at: CGPoint(x: 50, y: 100)) == 255)
        precondition(alpha(filled, at: CGPoint(x: 50, y: 10)) == 255)
        print("PASS: normalized crop bounds, top-left conversion, Fit letterboxing, and Fill coverage")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let selectedCrop = PhoneCrop(rect: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.4))
        let sourceRect = selectedCrop.pixelRect(in: sourceSize)
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 400, AVVideoHeightKey: 800
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for seconds in [0.0, 0.95] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 400, 800, kCVPixelFormatType_32BGRA, nil, &buffer)
            let green = CIImage(color: .green).cropped(to: sourceRect)
            let frame = green.composited(over: CIImage(color: .red))
            context.render(frame, to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let capture = CaptureSettings()
        capture.setPhoneCrop(selectedCrop, for: source)
        precondition(capture.phoneCrop(for: source) == selectedCrop)
        precondition(capture.phoneCrop(for: directory.appendingPathComponent("other.mov")) == PhoneCrop())

        let mouseURL = directory.appendingPathComponent("source.mouse.json")
        let mouse = MouseDataRecorder.MouseRecording(
            positions: [.init(timestamp: 0, x: 0.4, y: 0.65, velocity: 0)],
            clicks: [], keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(origin: .zero, size: sourceSize)), scaleFactor: 1, sampleInterval: 1.0 / 60)
        try JSONEncoder().encode(mouse).write(to: mouseURL)
        for background in [false, true] {
            let settings = VideoEditSettings(layout: .desktop, backgroundEnabled: background,
                                             crop: selectedCrop, showCursor: false)
            let renderer = LiveEditFrameRenderer(sourceSize: sourceSize, settings: settings, keyframes: [])
            let expectedSize = background ? sourceSize : CGSize(width: 320, height: 320)
            precondition(renderer.outputSize == expectedSize, "Desktop preview must use cropped dimensions when Background is off")
            let frame = CIImage(color: .green).cropped(to: sourceRect).composited(over: CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: sourceSize)))
            let preview = renderer.render(frame, at: 0)
            let output = directory.appendingPathComponent("desktop-\(background).mov")
            _ = try await ExportEngine().export(sourceURL: source, keyframes: [], configuration: .init(
                outputURL: output, showCursor: false, deviceLayout: .desktop,
                phoneCrop: selectedCrop, forceCanvas: background))
            let asset = AVURLAsset(url: output)
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let exportedSize = try await track.load(.naturalSize)
            precondition(exportedSize == expectedSize, "Desktop export dimensions must match the crop preview")
            let exportedDuration = try await asset.load(.duration).seconds
            precondition(abs(exportedDuration - 1) < 0.05)
            let exported = CIImage(cgImage: try await AVAssetImageGenerator(asset: asset).image(at: .zero).image)
            let content = background ? CanvasGeometry(size: expectedSize, layout: .desktop, sourceSize: sourceRect.size).desktop! : CGRect(origin: .zero, size: expectedSize)
            for (imageIndex, image) in [preview, exported].enumerated() {
                for x in [content.minX + content.width * 0.1, content.midX, content.maxX - content.width * 0.1] {
                    var pixel = [UInt8](repeating: 0, count: 4)
                    context.render(image, toBitmap: &pixel, rowBytes: 4,
                                   bounds: CGRect(x: x, y: content.midY, width: 1, height: 1),
                                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                    precondition(pixel[1] > 180 && Int(pixel[1]) - Int(pixel[0]) > 100, "Desktop crop must remove excluded red borders: background=\(background), image=\(imageIndex), point=\(x), pixel=\(pixel)")
                }
            }
            print("PASS: Desktop crop with Background \(background ? "on" : "off") matches preview/export dimensions and excludes borders")
        }
        for (layout, mode) in DeviceLayout.allCases.filter(\.isPhone).flatMap({ layout in PhoneContentMode.allCases.map { (layout, $0) } }) {
            let decodedLayout = try JSONDecoder().decode(DeviceLayout.self, from: JSONEncoder().encode(layout))
            precondition(decodedLayout == layout)
            let output = directory.appendingPathComponent("\(layout.rawValue)-\(mode.rawValue).mov")
            _ = try await ExportEngine().export(sourceURL: source, keyframes: [], configuration: .init(
                outputURL: output, mouseDataURL: mouseURL, cursorShape: .circle,
                canvasRatio: .portrait, deviceLayout: layout, phoneCrop: selectedCrop, phoneContentMode: mode))
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration)
            precondition(abs(duration.seconds - 1) < 0.05)
            let bitmap = NSBitmapImageRep(cgImage: try await AVAssetImageGenerator(asset: asset).image(at: .zero).image)
            let frame = CanvasGeometry(size: CGSize(width: 1080, height: 1350), layout: layout, sourceSize: sourceSize).phone!
            let content = CanvasGeometry.phoneContent(frame, layout: layout)
            precondition(abs(frame.width / frame.height - layout.phoneFrameSize.width / layout.phoneFrameSize.height) < 0.0001)
            precondition(CGRect(x: 0, y: 0, width: 1080, height: 1350).contains(frame))
            func pixel(_ point: CGPoint) -> NSColor {
                bitmap.colorAt(x: Int(point.x), y: bitmap.pixelsHigh - 1 - Int(point.y))!.usingColorSpace(.sRGB)!
            }
            let middle = pixel(CGPoint(x: content.midX + 80, y: content.midY))
            precondition(middle.greenComponent > 0.7 && middle.redComponent < 0.2, "Crop retained excluded red borders")
            let edge = pixel(content.width > content.height
                ? CGPoint(x: content.minX + 20, y: content.midY)
                : CGPoint(x: content.midX, y: content.maxY - 20))
            precondition(mode == .fill ? edge.greenComponent > 0.7 : edge.greenComponent < 0.2)
            let scale = mode == .fit ? min(content.width / sourceRect.width, content.height / sourceRect.height)
                                    : max(content.width / sourceRect.width, content.height / sourceRect.height)
            let cursor = CGPoint(x: content.midX + (0.375 - 0.5) * sourceRect.width * scale, y: content.midY)
            // The circle cursor is a translucent white lens over the green fixture.
            var cursorPixels = 0
            for offsetY in -8...8 {
                for offsetX in -8...8 {
                    let color = pixel(CGPoint(x: cursor.x + CGFloat(offsetX), y: cursor.y + CGFloat(offsetY)))
                    if color.redComponent > 0.15 && color.blueComponent > 0.15 && color.greenComponent > 0.7 { cursorPixels += 1 }
                }
            }
            precondition(cursorPixels > 10, "Cursor missing or misaligned after crop")
            print("PASS: \(layout.displayName) \(mode.rawValue) export excludes borders, preserves duration, and aligns the cursor")
        }

        if CommandLine.arguments.contains("--render-only") { return }
        for layout in DeviceLayout.allCases {
        let host = NSHostingView(rootView: InlineScreenCropEditor(sourceURL: source, initialCrop: selectedCrop, onCancel: {}, onApply: { _ in }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 430), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 700_000_000)
        host.layoutSubtreeIfNeeded()
        let screenshot = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: screenshot)
        try screenshot.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-phone-crop-\(layout.rawValue).png"))
        let captureProcess = Process()
        captureProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        captureProcess.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/Screen-phone-crop-window-\(layout.rawValue).png"]
        try captureProcess.run()
        captureProcess.waitUntilExit()
        window.orderOut(nil)
        print("PASS: \(layout.displayName) inline crop preview rendered at 700x430")
        }
    }
}
