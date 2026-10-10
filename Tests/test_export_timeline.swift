import AppKit
import AVFoundation
import CoreImage
import Combine

enum ExportTimelineError: Error {
    case failed(String)
}

@main
struct ExportTimelineTest {
    static func makeVideo(at url: URL, frames: [(Double, CIColor)], splitColors: Bool = false) async throws {
        let writer = try VideoWriter(outputURL: url, configuration: VideoWriterConfiguration(width: 256, height: 256))
        try writer.startWriting()
        let context = CIContext()
        for (seconds, color) in frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 256, 256, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw ExportTimelineError.failed("Cannot allocate frame") }
            let image: CIImage
            if splitColors {
                let left = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 256))
                image = left.composited(over: CIImage(color: .blue))
            } else {
                image = CIImage(color: color)
            }
            context.render(image, to: buffer)
            writer.appendPixelBuffer(buffer, at: CMTime(seconds: seconds, preferredTimescale: 600))
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.04) { continuation.resume() }
            }
        }
        await writer.finishWriting(at: CMTime(seconds: 5, preferredTimescale: 600))
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--recording" {
            try await verifyRecording(URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = directory.appendingPathComponent("screen.mov")
        let camera = directory.appendingPathComponent("camera.mov")
        let output = directory.appendingPathComponent("output.mov")
        let gray = CIColor(red: 0.4, green: 0.4, blue: 0.4)
        let cameraFrame = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 80))
        let screenFrame = CIImage(color: gray).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        let positionContext = CIContext()
        let positions: [[PiPPosition]] = [
            [.topLeft, .topCenter, .topRight],
            [.middleLeft, .center, .middleRight],
            [.bottomLeft, .bottomCenter, .bottomRight]
        ]
        for (row, rowPositions) in positions.enumerated() {
            for (column, position) in rowPositions.enumerated() {
                let frame = WebcamCompositor(outputSize: CGSize(width: 256, height: 256),
                                             position: position, pipSize: .small)
                    .composite(webcamImage: cameraFrame, onto: screenFrame)
                var pixel = [UInt8](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes { bytes in
                    positionContext.render(frame, toBitmap: bytes.baseAddress!, rowBytes: 4,
                                           bounds: CGRect(x: [43, 128, 213][column], y: [213, 128, 43][row], width: 1, height: 1),
                                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                }
                precondition(Int(pixel[1]) > Int(pixel[0]) + 80, "Camera placement mismatch at \(position.displayName)")
            }
        }
        print("PASS: webcam renders at all nine positions")
        try await makeVideo(at: screen, frames: [(0, gray), (2.5, gray), (5, gray)])
        try await makeVideo(at: camera, frames: [(1, .red), (2, .green), (3, .blue), (5, .blue)])
        _ = try await ExportEngine().export(sourceURL: screen, keyframes: [], configuration: .init(
            outputURL: output, webcamVideoURL: camera, pipShape: .roundedSquare
        ))
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        guard abs(duration.seconds - 5) < 0.002 else { throw ExportTimelineError.failed("Export duration \(duration.seconds)") }
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(readerOutput)
        guard reader.startReading() else { throw reader.error! }
        let diameter = 256 * PiPSize.medium.fraction
        let center = CGPoint(x: 256 - 24 - diameter / 2, y: 24 + diameter / 2)
        let context = CIContext()
        let targets = [0.5, 1.5, 2.5, 3.5, 4.5]
        var targetIndex = 0
        while let sample = readerOutput.copyNextSampleBuffer(), targetIndex < targets.count {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time >= targets[targetIndex] else { continue }
            guard time - targets[targetIndex] < 0.06, let buffer = CMSampleBufferGetImageBuffer(sample) else {
                throw ExportTimelineError.failed("Webcam frozen near \(targets[targetIndex])s; next frame \(time)s")
            }
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                context.render(CIImage(cvPixelBuffer: buffer), toBitmap: bytes.baseAddress!, rowBytes: 4, bounds: CGRect(x: center.x, y: center.y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            let correct: Bool
            switch targetIndex {
            case 0: correct = abs(Int(pixel[0]) - Int(pixel[1])) < 10 && abs(Int(pixel[1]) - Int(pixel[2])) < 10
            case 1: correct = Int(pixel[0]) > max(Int(pixel[1]), Int(pixel[2])) + 80
            case 2: correct = Int(pixel[1]) > max(Int(pixel[0]), Int(pixel[2])) + 80
            default: correct = Int(pixel[2]) > max(Int(pixel[0]), Int(pixel[1])) + 80
            }
            guard correct else { throw ExportTimelineError.failed("Wrong webcam frame at \(time)s: \(pixel)") }
            if targetIndex == 2 {
                let left = 256 - 24 - diameter
                let top = 24 + diameter
                func sample(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
                    var result = [UInt8](repeating: 0, count: 4)
                    result.withUnsafeMutableBytes { bytes in
                        context.render(CIImage(cvPixelBuffer: buffer), toBitmap: bytes.baseAddress!,
                                       rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                    }
                    return result
                }
                let outside = sample(left + 1, top - 1)
                let inside = sample(left + 12, top - 12)
                guard abs(Int(outside[0]) - Int(outside[1])) < 15,
                      abs(Int(outside[1]) - Int(outside[2])) < 15,
                      Int(inside[1]) > max(Int(inside[0]), Int(inside[2])) + 80 else {
                    throw ExportTimelineError.failed("Rounded-square export corner mismatch: \(outside), \(inside)")
                }
                print("PASS: rounded-square webcam mask in exported video")
            }
            print("PASS: webcam marker at \(time)s = \(pixel)")
            targetIndex += 1
        }
        guard targetIndex == targets.count else { throw ExportTimelineError.failed("Webcam stopped before final marker") }
        print("PASS: delayed webcam, static-screen playback and exact 5s export")

        if CommandLine.arguments.contains("--webcam-only") { return }

        let staticScreen = directory.appendingPathComponent("static-screen.mov")
        try await makeVideo(at: staticScreen, frames: [(0, gray), (2.5, gray)])
        let cursorData = directory.appendingPathComponent("cursor.mouse.json")
        let cursorRecording = MouseDataRecorder.MouseRecording(
            positions: (0...300).map { index in
                .init(timestamp: Double(index) / 60, x: 0.2 + Double(index) / 500, y: 0.5, velocity: 30)
            }, clicks: [], keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(x: 0, y: 0, width: 256, height: 256)),
            scaleFactor: 1, sampleInterval: 1.0 / 60
        )
        try JSONEncoder().encode(cursorRecording).write(to: cursorData)
        for visible in [true, false] {
            let cursorOutput = directory.appendingPathComponent("cursor-\(visible).mov")
            let engine = ExportEngine()
            var progressValues: [Double] = []
            let observation = engine.$progress.sink { progressValues.append($0) }
            _ = try await engine.export(sourceURL: staticScreen, keyframes: [], configuration: .init(
                outputURL: cursorOutput, mouseDataURL: cursorData, cursorShape: .circle, showCursor: visible
            ))
            if visible {
                precondition(progressValues.contains { $0 > 0.1 && $0 < 0.5 }, "Missing intermediate cursor export progress")
                precondition(progressValues.contains { $0 > 0.6 && $0 < 1 }, "Missing progress during static tail frames")
                precondition(progressValues.last == 1, "Export did not finish progress")
                precondition(zip(progressValues, progressValues.dropFirst()).allSatisfy { $0 <= $1 }, "Progress moved backwards")
                print("PASS: cursor export publishes intermediate progress including static tail frames")
            }
            observation.cancel()
            let cursorAsset = AVURLAsset(url: cursorOutput)
            let cursorTrack = try await cursorAsset.loadTracks(withMediaType: .video)[0]
            let cursorReader = try AVAssetReader(asset: cursorAsset)
            let cursorFrames = AVAssetReaderTrackOutput(track: cursorTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            cursorReader.add(cursorFrames)
            precondition(cursorReader.startReading())
            var previousTime = 0.0
            var frameCount = 0
            while let sample = cursorFrames.copyNextSampleBuffer() {
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if visible {
                    precondition(time - previousTime < 0.027, "Cursor froze on a static screen: \(previousTime) to \(time)")
                    let buffer = CMSampleBufferGetImageBuffer(sample)!
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRow(buffer)
                    var totalX = 0.0
                    var cursorPixelCount = 0.0
                    for vertical in 0..<256 {
                        for horizontal in 0..<256 {
                            let offset = vertical * stride + horizontal * 4
                            if min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) > 140 {
                                totalX += Double(horizontal)
                                cursorPixelCount += 1
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    precondition(cursorPixelCount > 50, "Cursor missing from generated frame")
                    precondition(abs(totalX / cursorPixelCount - (0.2 + time * 0.12) * 256) < 2, "Cursor timestamp is stale")
                    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--screenshots",
                       frameCount == 30 || frameCount == 270 {
                        let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: 256, height: 256))!
                        let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                            .appendingPathComponent("cursor-static-\(frameCount == 30 ? "early" : "late").png")
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: destination)
                    }
                }
                previousTime = time
                frameCount += 1
            }
            let cursorDuration = try await cursorAsset.load(.duration)
            precondition(abs(cursorDuration.seconds - 5) < 0.002)
            if visible {
                precondition(previousTime > 4.97, "Cursor animation stopped before the recording ended")
            } else {
                precondition(frameCount <= 3, "Hidden cursor must not generate unnecessary frames")
            }
            print("PASS: static-screen cursor visible=\(visible), frames=\(frameCount), exact duration and pointer positions")
        }

        let splitScreen = directory.appendingPathComponent("split-screen.mov")
        let zoomOutput = directory.appendingPathComponent("click-zoom.mov")
        try await makeVideo(at: splitScreen, frames: [(0, gray), (2.5, gray), (5, gray)], splitColors: true)
        let mouseRecording = MouseDataRecorder.MouseRecording(
            positions: [],
            clicks: [
                .init(timestamp: 1, x: 0.25, y: 0.5, button: 0, isDown: true),
                .init(timestamp: 2, x: 0.75, y: 0.5, button: 0, isDown: true)
            ],
            keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(x: 0, y: 0, width: 256, height: 256)),
            scaleFactor: 1, sampleInterval: 1.0 / 60
        )
        let keyframes = ClickZoomGenerator.generate(from: mouseRecording)
        _ = try await ExportEngine().export(sourceURL: splitScreen, keyframes: keyframes, configuration: .init(outputURL: zoomOutput))
        let zoomAsset = AVURLAsset(url: zoomOutput)
        let zoomDuration = try await zoomAsset.load(.duration)
        guard abs(zoomDuration.seconds - 5) < 0.002 else { throw ExportTimelineError.failed("Click zoom changed duration") }
        let zoomTrack = try await zoomAsset.loadTracks(withMediaType: .video)[0]
        let zoomReader = try AVAssetReader(asset: zoomAsset)
        let zoomReaderOutput = AVAssetReaderTrackOutput(track: zoomTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        zoomReader.add(zoomReaderOutput)
        guard zoomReader.startReading() else { throw zoomReader.error! }
        let zoomTargets = [1.5, 2.5, 3.0, 3.8, 4.0]
        var zoomTargetIndex = 0
        while let sample = zoomReaderOutput.copyNextSampleBuffer(), zoomTargetIndex < zoomTargets.count {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time >= zoomTargets[zoomTargetIndex] else { continue }
            guard time - zoomTargets[zoomTargetIndex] < 0.06, let buffer = CMSampleBufferGetImageBuffer(sample) else {
                throw ExportTimelineError.failed("Missing click zoom frame near \(zoomTargets[zoomTargetIndex])s")
            }
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                context.render(CIImage(cvPixelBuffer: buffer), toBitmap: bytes.baseAddress!, rowBytes: 4,
                               bounds: CGRect(x: 64, y: 128, width: 1, height: 1), format: .RGBA8,
                               colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            let expectedChannel = zoomTargetIndex == 0 ? 0 : 2
            let otherChannel = zoomTargetIndex == 0 ? 2 : 0
            guard Int(pixel[expectedChannel]) > Int(pixel[otherChannel]) + 80 else {
                throw ExportTimelineError.failed("Click zoom returned to the wrong target at \(time)s: \(pixel)")
            }
            print("PASS: exported click target at \(time)s = \(pixel)")
            zoomTargetIndex += 1
        }
        guard zoomTargetIndex == zoomTargets.count else { throw ExportTimelineError.failed("Missing exported click targets") }
        print("PASS: rendered click zoom stays on the new target without stale movements")
    }

    @MainActor
    static func verifyRecording(_ source: URL) async throws {
        let mouse = source.deletingPathExtension().appendingPathExtension("mouse.json")
        let keyframes = try await ClickZoomGenerator.generate(from: mouse, sourceVideoURL: source)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Screen-cursor-motion-\(UUID().uuidString).mov")
        _ = try await ExportEngine().export(sourceURL: source, keyframes: keyframes, configuration: .init(
            outputURL: output, mouseDataURL: mouse, canvasRatio: .landscape, wallpaper: .lagoon,
            preserveSourceAudio: true, forceCanvas: true
        ))
        let asset = AVURLAsset(url: output)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(frames)
        precondition(reader.startReading())
        var previous = 0.0
        var maximumGap = 0.0
        var minimumGap = Double.greatestFiniteMagnitude
        var count = 0
        while let sample = frames.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if count > 0 {
                maximumGap = max(maximumGap, time - previous)
                minimumGap = min(minimumGap, time - previous)
            }
            previous = time
            count += 1
        }
        precondition(reader.status == .completed)
        let duration = try await asset.load(.duration)
        let sourceDuration = try await AVURLAsset(url: source).load(.duration)
        precondition(abs(duration.seconds - sourceDuration.seconds) < 0.002)
        precondition(maximumGap < 0.018, "Real recording cursor cadence is uneven: \(maximumGap)")
        precondition(minimumGap > 0.015, "Real recording has bursty cursor frames: \(minimumGap)")
        precondition(duration.seconds - previous < 0.027)
        print("PASS: real recording \(count) frames, gap range \(minimumGap)s...\(maximumGap)s, duration \(duration.seconds)s")
        print("PREVIEW: \(output.path)")
    }
}