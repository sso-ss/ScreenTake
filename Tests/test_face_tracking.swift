import AppKit
import AVFoundation
import CoreImage
#if IMPORT_BUILT_APP
@testable import ScreenTake
#endif

@main
struct FaceTrackingChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let context = CIContext()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent(".build/face-tracking-checks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = Data(#"{"layout":"fullScreen","zoom":2,"centerX":0.7,"centerY":0.2}"#.utf8)
        let decoded = try JSONDecoder().decode(CameraLayoutSettings.self, from: legacy)
        precondition(!decoded.followFace && decoded.zoom == 2)
        let enabled = CameraLayoutSettings(layout: .fullScreen, followFace: true)
        let roundTrip = try JSONDecoder().decode(CameraLayoutSettings.self, from: JSONEncoder().encode(enabled))
        precondition(roundTrip == enabled)

        let left = CGRect(x: 0.1, y: 0.4, width: 0.15, height: 0.25)
        let right = CGRect(x: 0.7, y: 0.4, width: 0.22, height: 0.3)
        var smoother = FaceTrackingSmoother()
        let initial = smoother.sample(at: 0, faces: [left]).focus
        let held = smoother.sample(at: 0.5, faces: []).focus
        precondition(held.center == initial.center && held.strength == initial.strength)
        let distracted = smoother.sample(at: 0.75, faces: [left, right]).focus
        precondition(distracted.center.x < 0.3, "Must keep the original subject when a larger face enters")
        let lost = smoother.sample(at: 2, faces: []).focus
        precondition(lost.strength < 0.2 && lost.strength > 0)
        let recovered = smoother.sample(at: 2.125, faces: [right]).focus
        precondition(recovered.strength > lost.strength && recovered.center.x < right.midX)
        let bounds = CGRect(x: 15, y: 20, width: 640, height: 360)
        for center in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 0.5)] {
            let crop = FaceTrackingTrack.Focus(center: center, strength: 1).crop(in: bounds, fallback: bounds)
            precondition(bounds.contains(crop) && crop.width < bounds.width)
        }
        precondition(FaceTrackingTrack.Focus(center: .zero, strength: 0).crop(in: bounds, fallback: bounds) == bounds)
        let path = FaceTrackingTrack(samples: [
            .init(time: 0, focus: .init(center: .zero, strength: 0)),
            .init(time: 2, focus: .init(center: CGPoint(x: 1, y: 1), strength: 1))
        ])
        precondition(path.focus(at: 1)?.center == CGPoint(x: 0.5, y: 0.5))
        precondition(path.focus(at: .nan) == nil)
        print("PASS: legacy settings, tracking selection, held gaps, recovery, crop bounds and interpolation")

        let frameBounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        guard let portrait = CIImage(contentsOf: root.appendingPathComponent("website/assets/camera-presenter.png")) else {
            fatalError("Missing presenter test fixture")
        }
        let smallPortrait = portrait.transformed(by: CGAffineTransform(scaleX: 260 / portrait.extent.width,
                                                                      y: 260 / portrait.extent.height))
        func movie(_ name: String, duration: Double, transform: CGAffineTransform = .identity,
                   frame: (Double) -> CIImage) async throws -> URL {
            let url = directory.appendingPathComponent(name + ".mov")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360
            ])
            input.transform = transform
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            precondition(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            for index in 0..<Int(duration * 30) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                autoreleasepool {
                    var buffer: CVPixelBuffer?
                    CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
                    context.render(frame(Double(index) / 30), to: buffer!)
                    precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
                }
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
            await writer.finishWriting()
            precondition(writer.status == .completed)
            return url
        }
        let screenURL = try await movie("screen", duration: 6) { _ in CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: frameBounds) }
        let cameraURL = try await movie("moving-face", duration: 5) { seconds in
            let background = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12)).cropped(to: frameBounds)
            if seconds >= 2.5 && seconds < 4 { return background }
            let x = 20 + min(1, seconds / 2.5) * 340
            return smallPortrait.transformed(by: CGAffineTransform(translationX: x, y: 50)).composited(over: background)
        }
        let rotatedURL = try await movie("rotated-camera", duration: 1, transform: CGAffineTransform(rotationAngle: .pi)) { _ in
            let raw = smallPortrait.transformed(by: CGAffineTransform(translationX: 20, y: 50))
                .composited(over: CIImage(color: .black).cropped(to: frameBounds))
                .transformed(by: CGAffineTransform(rotationAngle: .pi))
            return raw.transformed(by: CGAffineTransform(translationX: 640, y: 360))
        }
        let track = try await FaceTrackingAnalyzer.shared.track(for: cameraURL)
        precondition(track.samples.count >= 30)
        let first = track.focus(at: 0.2)!, moved = track.focus(at: 2.2)!
        precondition(first.strength > 0.8 && moved.strength > 0.8, "Vision must detect the face")
        precondition(moved.center.x - first.center.x > 0.25, "Framing must follow horizontal movement")
        precondition(track.focus(at: 3.9)!.strength < 0.8, "Long detection gaps must ease toward manual framing")
        let cached = try await FaceTrackingAnalyzer.shared.track(for: cameraURL)
        precondition(cached.samples.count == track.samples.count)
        let blank = try await FaceTrackingAnalyzer.shared.track(for: screenURL)
        precondition(blank.samples.allSatisfy { $0.focus.strength == 0 })
        let rotatedTrack = try await FaceTrackingAnalyzer.shared.track(for: rotatedURL)
        precondition(rotatedTrack.focus(at: 0)!.strength > 0.8)
        precondition(abs(rotatedTrack.focus(at: 0)!.center.x - track.focus(at: 0)!.center.x) < 0.03)
        let cancelled = Task { try await FaceTrackingAnalyzer.shared.track(for: cameraURL) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Analysis must honor cancellation") }
        catch is CancellationError {}
        print("PASS: orientation metadata and cancellation")
        print("PASS: real Vision detection follows movement, loses/reacquires face, and handles no-face video")

        // Compare the independently rendered player composition and export after
        // moving/trimming a take, including a per-section toggle and reverse seeks.
        for (name, layout, timing, changes, camera) in [
            ("bubble", CameraLayoutSettings(followFace: true), Optional<VideoOverlayTiming>.none, [CameraLayoutChange](), cameraURL),
            ("full", enabled, Optional(VideoOverlayTiming(start: 0.5, duration: 4.5, sourceStart: 0.25)), [], cameraURL),
            ("section", enabled, Optional<VideoOverlayTiming>.none,
             [CameraLayoutChange(start: 2, settings: CameraLayoutSettings(layout: .fullScreen))], cameraURL),
            ("rotated", enabled, Optional<VideoOverlayTiming>.none, [], rotatedURL),
            ("transition", CameraLayoutSettings(followFace: true), Optional<VideoOverlayTiming>.none,
             [CameraLayoutChange(start: 2, settings: CameraLayoutSettings(layout: .fullScreen, followFace: true,
                                                                         smoothTransition: true))], cameraURL)
        ] {
            let settings = VideoEditSettings(backgroundEnabled: false, showCursor: false, webcamEnabled: true,
                                             webcamShape: .roundedSquare, cameraLayout: layout, cameraLayoutChanges: changes,
                                             videoOverlayURL: camera, videoOverlayTiming: timing)
            let item = try await LiveVideoPreview.makeItem(.init(source: screenURL, audio: nil, mouse: nil, webcam: camera, settings: settings))
            let preview = AVAssetImageGenerator(asset: item.asset)
            preview.videoComposition = item.videoComposition
            preview.requestedTimeToleranceBefore = .zero
            preview.requestedTimeToleranceAfter = .zero
            let outputURL = directory.appendingPathComponent(name + ".mov")
            if FileManager.default.fileExists(atPath: outputURL.path) { try FileManager.default.removeItem(at: outputURL) }
            let url = try await ExportEngine().export(sourceURL: screenURL, keyframes: [], configuration: .init(
                outputURL: outputURL, webcamVideoURL: camera, videoOverlayTiming: timing, pipShape: .roundedSquare,
                cameraLayout: layout, cameraLayoutChanges: changes, showCursor: false))
            let exported = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            exported.requestedTimeToleranceBefore = .zero
            exported.requestedTimeToleranceAfter = .zero
            for seconds in [0.5, 1.0, 2.0, 2.1, 2.3, 4.5, 3.0, 1.0, 5.5] {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                let a = try preview.copyCGImage(at: time, actualTime: nil)
                let b = try exported.copyCGImage(at: time, actualTime: nil)
                // Compare edges in the camera region so the existing video
                // color conversion does not mask framing or timing differences.
                let region = layout.layout == .overlay && name != "transition"
                    ? CGRect(x: 534, y: 22, width: 85, height: 85) : frameBounds.insetBy(dx: 3, dy: 3)
                let width = Int(region.width), height = Int(region.height)
                var pixelsA = [UInt8](repeating: 0, count: width * height * 4)
                var pixelsB = pixelsA
                context.render(CIImage(cgImage: a), toBitmap: &pixelsA, rowBytes: width * 4, bounds: region,
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                context.render(CIImage(cgImage: b), toBitmap: &pixelsB, rowBytes: width * 4, bounds: region,
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                if seconds >= (name == "rotated" ? 1 : 5) {
                    for pixels in [pixelsA, pixelsB] {
                        let red = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
                        precondition(Int(red.max()!) - Int(red.min()!) < 3, "Camera must disappear at its end")
                    }
                }
                var edgeError = 0.0
                var count = 0
                for y in 1..<height {
                    for x in 1..<width {
                        let index = (y * width + x) * 4
                        for offset in [4, width * 4] {
                            for channel in 0..<3 {
                                let a = Int(pixelsA[index + channel]) - Int(pixelsA[index + channel - offset])
                                let b = Int(pixelsB[index + channel]) - Int(pixelsB[index + channel - offset])
                                edgeError += Double(abs(a - b))
                                count += 1
                            }
                        }
                    }
                }
                edgeError /= Double(count)
                print("Edge error \(name) at \(seconds): \(edgeError)")
                precondition(edgeError < 3, "\(name) framing differs at \(seconds): \(edgeError)")
            }
            print("PASS: \(name) preview/export agreement, trimmed source time, backward seeks and camera end")
        }
        print("Face tracking checks passed. Fixtures: \(directory.path)")
    }
}
