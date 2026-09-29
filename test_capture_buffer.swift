import Foundation
import CoreVideo
import AppKit
import AVFoundation
import ScreenCaptureKit

@main
struct CaptureBufferTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        var statusBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &statusBuffer)
        var statusFormat: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: statusBuffer!, formatDescriptionOut: &statusFormat)
        let statusURL = FileManager.default.temporaryDirectory.appendingPathComponent("capture-status-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: statusURL) }
        let statusManager = VFRRecordingManager()
        try statusManager.startRecording(to: statusURL, configuration: CaptureConfiguration(width: 64, height: 64), showCursor: false)
        do {
            try await statusManager.waitUntilReady(timeout: 0.04)
            preconditionFailure("Empty capture must time out")
        } catch CaptureError.noCompleteFrames {
            print("PASS: empty capture reports a startup error")
        }
        for (index, frameStatus) in [SCFrameStatus.blank, .suspended, .idle, .started, .stopped, .complete].enumerated() {
            CVPixelBufferLockBaseAddress(statusBuffer!, [])
            memset(CVPixelBufferGetBaseAddress(statusBuffer!)!, frameStatus == .complete ? 255 : 0, CVPixelBufferGetDataSize(statusBuffer!))
            CVPixelBufferUnlockBaseAddress(statusBuffer!, [])
            var timing = CMSampleTimingInfo(duration: .invalid,
                presentationTimeStamp: CMTimeAdd(statusManager.startTime, CMTime(seconds: Double(index) / 10, preferredTimescale: 600)),
                decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: statusBuffer!, formatDescription: statusFormat!, sampleTiming: &timing, sampleBufferOut: &sample)
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true)! as NSArray
            let attachment = attachments[0] as! NSMutableDictionary
            attachment[SCStreamFrameInfo.status.rawValue] = frameStatus.rawValue
            statusManager.receiveFrame(sample!)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        try await statusManager.waitUntilReady(timeout: 0.1)
        _ = await statusManager.stopRecording(at: CMTimeAdd(statusManager.startTime, CMTime(seconds: 0.7, preferredTimescale: 600)))
        let statusImage = try await AVAssetImageGenerator(asset: AVURLAsset(url: statusURL)).image(at: .zero).image
        let statusColor = NSBitmapImageRep(cgImage: statusImage).colorAt(x: 32, y: 32)!.usingColorSpace(.sRGB)!
        precondition(statusColor.redComponent > 0.8, "Incomplete capture frames must not seed a black recording")
        print("PASS: blank, suspended, idle, started and stopped frames are rejected; first complete frame seeds recording")
        func buffer(width: Int, height: Int, stride: Int) -> CVPixelBuffer {
            let memory = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 64)
            memory.initializeMemory(as: UInt8.self, repeating: 0xEE, count: stride * height)
            var result: CVPixelBuffer?
            let code = CVPixelBufferCreateWithBytes(nil, width, height, kCVPixelFormatType_32BGRA,
                memory, stride, { _, address in UnsafeMutableRawPointer(mutating: address)?.deallocate() },
                nil, nil, &result)
            precondition(code == kCVReturnSuccess)
            return result!
        }
        for strides in [(320, 256), (256, 320)] {
            let source = buffer(width: 64, height: 32, stride: strides.0)
            let destination = buffer(width: 64, height: 32, stride: strides.1)
            CVPixelBufferLockBaseAddress(source, [])
            let pixels = CVPixelBufferGetBaseAddress(source)!
            for row in 0..<32 {
                memset(pixels.advanced(by: row * strides.0), Int32(row), 256)
            }
            CVPixelBufferUnlockBaseAddress(source, [])
            precondition(VFRRecordingManager.copyPixels(from: source, to: destination))
            CVPixelBufferLockBaseAddress(destination, .readOnly)
            let copied = CVPixelBufferGetBaseAddress(destination)!.assumingMemoryBound(to: UInt8.self)
            for row in 0..<32 {
                for column in 0..<256 { precondition(copied[row * strides.1 + column] == UInt8(row)) }
                for column in 256..<strides.1 { precondition(copied[row * strides.1 + column] == 0xEE) }
            }
            CVPixelBufferUnlockBaseAddress(destination, .readOnly)
        }
        let source = buffer(width: 64, height: 64, stride: 256)
        let smaller = buffer(width: 32, height: 32, stride: 128)
        precondition(!VFRRecordingManager.copyPixels(from: source, to: smaller))
        print("PASS: unequal row strides copy correctly, padding remains untouched, and mismatched dimensions are rejected")

        for sourceSize in [64, 96] {
            let frame = buffer(width: sourceSize, height: sourceSize, stride: sourceSize * 4 + 64)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("window-buffer-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: url) }
            let manager = VFRRecordingManager()
            try manager.startRecording(to: url, configuration: CaptureConfiguration(width: 64, height: 64),
                                       isWindowRecording: true, showCursor: true)
            var format: CMVideoFormatDescription?
            precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame, formatDescriptionOut: &format) == noErr)
            for seconds in [0.0, 0.1] {
                var timing = CMSampleTimingInfo(duration: .invalid,
                    presentationTimeStamp: CMTimeAdd(manager.startTime, CMTime(seconds: seconds, preferredTimescale: 600)),
                    decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame,
                    formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
                manager.receiveFrame(sample!)
            }
            let result = await manager.stopRecording(at: CMTimeAdd(manager.startTime, CMTime(seconds: 0.2, preferredTimescale: 600)))
            precondition(result == url)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            precondition(abs(duration.seconds - 0.2) < 0.002)
            let generator = AVAssetImageGenerator(asset: asset)
            let image = try await generator.image(at: .zero).image
            precondition(image.width == 64 && image.height == 64)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let color = bitmap.colorAt(x: 32, y: 32)!.usingColorSpace(.sRGB)!
            precondition(color.redComponent > 0.5, "Captured frame was blank")
            print("PASS: window recorder starts and stops with \(sourceSize)x\(sourceSize) padded input; output is 64x64 and nonblank")
        }
        if CommandLine.arguments.contains("--live") {
            let content = try await ScreenCaptureManager.availableContent()
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                preconditionFailure("Main display unavailable")
            }
            let target = try await ScreenCaptureManager.refreshedTarget(.display(display))
            precondition(target.id == "display-\(display.displayID)")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Screen-live-capture-check-\(UUID().uuidString).mov")
            let manager = ScreenCaptureManager()
            var configuration = CaptureConfiguration.forTarget(target, showsCursor: false)
            configuration.capturesAudio = false
            try await manager.startRecording(target: target, configuration: configuration, outputURL: url, showCursor: false)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let result = await manager.stopRecording()
            precondition(result == url)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            let bitmap = NSBitmapImageRep(cgImage: image)
            var maximumBrightness: CGFloat = 0
            for vertical in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
                for horizontal in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
                    let color = bitmap.colorAt(x: horizontal, y: vertical)!.usingColorSpace(.sRGB)!
                    maximumBrightness = max(maximumBrightness, color.redComponent, color.greenComponent, color.blueComponent)
                }
            }
            precondition(maximumBrightness > 0.2, "Live screen capture is black")
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-live-capture-fixed.png"))
            print("PASS: live screen capture is nonblank, refreshed target matches selected display")
            print("LIVE VIDEO: \(url.path)")
        }
    }
}