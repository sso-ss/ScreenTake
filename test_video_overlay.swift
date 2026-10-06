import Foundation
import AppKit
import SwiftUI
import AVFoundation
import CoreImage
@testable import ScreenTake

@main
struct VideoOverlayTests {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: VideoReplacementDialog(action: .record, onResolve: { _ in }))
        let fit = host.fittingSize
        precondition(fit.width == 440 && fit.height < 210 && fit.height > 100)
        print("PASS: warning dialog uses content-derived size: \(fit)")
        let timing = VideoOverlayTiming(start: 1, duration: 2)
        precondition(timing.sampleTime(at: 0.9) == nil)
        precondition(timing.sampleTime(at: 1) == .zero)
        precondition(timing.sampleTime(at: 2)?.seconds == 1)
        precondition(timing.sampleTime(at: 3) == nil)
        precondition(timing.sampleTime(at: .nan) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = CIContext()
        func movie(_ name: String, seconds: Int, color: (Double) -> CIColor) async throws -> URL {
            let url = directory.appendingPathComponent(name + ".mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 400, AVVideoHeightKey: 240])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            precondition(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            for index in 0..<(seconds * 30) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 400, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
                context.render(CIImage(color: color(Double(index)/30)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 240)), to: buffer!)
                precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: Double(seconds), preferredTimescale: 600))
            await writer.finishWriting()
            precondition(writer.status == .completed)
            return url
        }
        let source = try await movie("source", seconds: 4) { _ in .green }
        let overlay = try await movie("overlay", seconds: 2) { $0 < 1 ? .blue : .red }
        let recorder = VideoOverlayRecorder()
        recorder.start(player: AVPlayer(), device: nil, duration: 4) { _, _ in preconditionFailure("An unready player must not record") }
        precondition(!recorder.isBusy && recorder.error != nil)
        let player = AVPlayer(url: source)
        for _ in 0..<100 {
            if player.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(player.currentItem?.status == .readyToPlay)
        await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: 4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in continuation.resume() }
        }
        recorder.start(player: player, device: nil, duration: 4) { _, _ in preconditionFailure("A playhead at the end must not record") }
        precondition(!recorder.isBusy && recorder.error?.contains("playhead") == true)
        print("PASS: camera recording rejects an unready preview and a playhead at the end without opening the camera")
        var reordered = VideoTrim()
        precondition(reordered.split(at: 2, duration: CMTime(seconds: 4, preferredTimescale: 600)))
        precondition(reordered.moveSegment(from: 1, to: 0, duration: CMTime(seconds: 4, preferredTimescale: 600)))
        let trimmed = VideoTrim(start: 1, end: 4)
        for (name, trim, timing, samples) in [
            ("normal", VideoTrim(), timing, [(0.5, 1), (1.5, 2), (2.5, 0), (3.5, 1)]),
            ("reordered", reordered, timing, [(0.5, 1), (1.5, 2), (2.5, 0), (3.5, 1)]),
            ("trimmed", trimmed, VideoOverlayTiming(start: 0.5, duration: 2), [(0.25, 1), (0.75, 2), (1.75, 0), (2.75, 1)])
        ] {
            let settings = VideoEditSettings(backgroundEnabled: false, showCursor: false, webcamEnabled: true,
                                             videoOverlayURL: overlay, videoOverlayTiming: timing, trim: trim)
            let item = try await LiveVideoPreview.makeItem(.init(source: source, audio: nil, mouse: nil, webcam: overlay, settings: settings))
            let preview = AVAssetImageGenerator(asset: item.asset)
            preview.videoComposition = item.videoComposition
            preview.requestedTimeToleranceBefore = .zero
            preview.requestedTimeToleranceAfter = .zero
            let raw = try await ExportEngine().export(sourceURL: source, keyframes: [], configuration: .init(
                outputURL: directory.appendingPathComponent(name + ".mov"), webcamVideoURL: overlay,
                videoOverlayTiming: timing, videoOverlayTrim: trim, showCursor: false))
            let exported = try await trim.export(source: raw)
            let export = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
            export.requestedTimeToleranceBefore = .zero
            export.requestedTimeToleranceAfter = .zero
            let diameter = 240 * PiPSize.medium.fraction
            let point = CGPoint(x: 400 - 24 - diameter / 2, y: 24 + diameter / 2)
            for (seconds, channel) in samples {
                for (kind, generator) in [("preview", preview), ("export", export)] {
                    let cg = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
                    var pixel = [UInt8](repeating: 0, count: 4)
                    context.render(CIImage(cgImage: cg), toBitmap: &pixel, rowBytes: 4,
                                   bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                    precondition(pixel[channel] > 180 && pixel[(channel + 1) % 3] < 80,
                                 "\(name) \(kind) at \(seconds): expected channel \(channel), got \(pixel)")
                }
            }
            print("PASS: \(name) camera preview/export hides before and after take and samples the correct frames")
        }
    }
}
