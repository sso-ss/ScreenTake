import AppKit
import CoreImage
import AVFoundation

@main
struct PrivacyMaskChecks {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let size = CGSize(width: 200, height: 100)
        let bounds = CGRect(origin: .zero, size: size)
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        var mask = PrivacyMask(start: 1, duration: 2, rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2))
        mask.setRect(CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.2), at: 2)
        precondition(abs(mask.rect(at: 1.5)!.midX - 0.4) < 0.001)
        precondition(mask.rect(at: 3) == nil)
        let rippled = mask.removingTimelineInterval(1.75..<2.25)
        precondition(rippled.count == 2 && rippled[0].end == 1.75
                     && abs(rippled[1].start - 1.75) < 0.0001
                     && abs(rippled[1].end - 2.5) < 0.0001)
        for piece in rippled { try piece.validate(maxDuration: 2.5) }
        precondition(mask.removingTimelineInterval(1..<3).isEmpty)
        var settings = VideoEditSettings(backgroundEnabled: false, showCursor: false)
        settings.privacyMasks = [mask]
        try settings.validate(duration: 4)
        let restored = try JSONDecoder().decode(VideoEditSettings.self, from: JSONEncoder().encode(settings))
        precondition(restored == settings)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        old.removeValue(forKey: "privacyMasks")
        let legacy = try JSONDecoder().decode(VideoEditSettings.self,
                     from: JSONSerialization.data(withJSONObject: old))
        precondition(legacy.privacyMasks == nil)

        func pixel(_ image: CIImage, x: Int, y: Int) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 200 * 100 * 4)
            data.withUnsafeMutableBytes { bytes in
                context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 200 * 4,
                               bounds: bounds, format: .RGBA8,
                               colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            let offset = ((99 - y) * 200 + x) * 4
            return Array(data[offset..<(offset + 4)])
        }
        let renderer = PrivacyMaskRenderer(masks: [mask], size: size)
        precondition(pixel(renderer.composite(over: source, at: 0.5), x: 30, y: 70)[0] > 200)
        precondition(pixel(renderer.composite(over: source, at: 1.5), x: 80, y: 70)[0] < 10)
        precondition(pixel(renderer.composite(over: source, at: 1.5), x: 30, y: 70)[0] > 200)
        precondition(pixel(renderer.composite(over: source, at: 2.5), x: 110, y: 70)[0] < 10)
        precondition(pixel(renderer.composite(over: source, at: 3), x: 110, y: 70)[0] > 200)
        var invalid = mask
        invalid.keyframes[0].rect.origin.x = 0.95
        do { try invalid.validate(maxDuration: 4); preconditionFailure("Out-of-bounds mask accepted") }
        catch is EditValidationError {}
        print("PASS: privacy mask timing, motion, rendered coverage, validation and project compatibility")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-track-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movieURL = folder.appendingPathComponent("moving.mov")
        let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frameBounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        for index in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let x = 64 + Double(index) * 0.7
            let y = 50 + Double(index) * 0.35
            var frame = CIImage(color: CIColor(red: 0.35, green: 0.35, blue: 0.35)).cropped(to: frameBounds)
            frame = CIImage(color: .white).cropped(to: CGRect(x: x, y: y, width: 102, height: 44)).composited(over: frame)
            for stripe in 0..<7 {
                frame = CIImage(color: .black).cropped(to: CGRect(x: x + Double(stripe) * 15, y: y, width: 5, height: 44))
                    .composited(over: frame)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
            context.render(frame, to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let movingMask = PrivacyMask(start: 0, duration: 1.5,
                                     rect: CGRect(x: 0.1, y: 0.74, width: 0.16, height: 0.12))
        let tracked = try await PrivacyMaskTracker.track(videoURL: movieURL, mask: movingMask)
        precondition(tracked.keyframes.count > 5 && tracked.keyframes.last!.rect.minX > movingMask.keyframes[0].rect.minX + 0.03
                     && tracked.keyframes.last!.rect.minY < movingMask.keyframes[0].rect.minY - 0.02
                     && !tracked.endedWhenTargetLeftFrame,
                     "Motion tracking did not follow the moving private area")
        print("PASS: tracking follows a moving marked area in an encoded video")

        let textURL = folder.appendingPathComponent("moving-text.mov")
        let textWriter = try AVAssetWriter(outputURL: textURL, fileType: .mov)
        let textInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let textAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: textInput, sourcePixelBufferAttributes: nil)
        textWriter.add(textInput)
        precondition(textWriter.startWriting())
        textWriter.startSession(atSourceTime: .zero)
        for index in 0..<24 {
            while !textInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let frame = NSImage(size: NSSize(width: 640, height: 360))
            frame.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 360)).fill()
            let textY = index < 12 ? 230 + Double(index) * 0.5
                      : index < 19 ? 35 + Double(index - 12) * 0.5 : -120
            ("Secret42" as NSString).draw(at: NSPoint(x: 70 + Double(index) * 1.8,
                                                    y: textY),
                                          withAttributes: [.font: NSFont.boldSystemFont(ofSize: 48),
                                                           .foregroundColor: NSColor.black])
            frame.unlockFocus()
            guard let cgImage = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                preconditionFailure("Text test image unavailable")
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
            let image = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(
                scaleX: 640 / CGFloat(cgImage.width), y: 360 / CGFloat(cgImage.height)))
            context.render(image, to: buffer!)
            precondition(textAdaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        textInput.markAsFinished()
        textWriter.endSession(atSourceTime: CMTime(seconds: 0.8, preferredTimescale: 600))
        await textWriter.finishWriting()
        precondition(textWriter.status == .completed)
        let textMask = PrivacyMask(start: 0, duration: 0.7,
                                   rect: CGRect(x: 0.10, y: 0.20, width: 0.34, height: 0.16))
        let textTrack = try await PrivacyMaskTracker.track(videoURL: textURL, mask: textMask, target: .text)
        precondition(textTrack.keyframes.count >= 6
                     && textTrack.keyframes.last!.rect.minX > textMask.keyframes[0].rect.minX + 0.02
                     && textTrack.keyframes.last!.rect.minY > textMask.keyframes[0].rect.minY + 0.2
                     && textTrack.endedWhenTargetLeftFrame && textTrack.duration < textMask.duration,
                     "Text tracking did not follow the jump and end when the words left the frame")
        print("PASS: text tracking follows a fast scroll and ends when the words leave the frame")

        let session = EditorSession()
        try await session.openVideo(movieURL)
        session.draft.privacyMasks = [movingMask]
        session.draft.crop = PhoneCrop(rect: CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96))
        precondition(session.privacyTrackingURL == nil)
        let prepared = try await session.applyChanges(excludingPrivacyMasks: true)
        precondition(session.privacyTrackingURL == prepared)
        precondition(session.appliedEdits.privacyMasks == nil)
        precondition(session.draft.privacyMasks == [movingMask])
        print("PASS: tracking prepares edited video while preserving the editable mask")
        await session.waitForPreview()
        let previewItem = session.player?.currentItem
        var movedMask = movingMask
        movedMask.setRect(CGRect(x: 0.14, y: 0.74, width: 0.16, height: 0.12), at: 0)
        session.draft.privacyMasks = [movedMask]
        precondition(session.player?.currentItem === previewItem && session.previewReady,
                     "Moving a mask replaced the player item")
        print("PASS: mask movement updates the live preview without replacing its player item")
    }
}
