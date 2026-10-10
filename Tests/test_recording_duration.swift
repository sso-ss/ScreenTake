import AVFoundation
import Foundation

enum DurationTestError: Error {
    case failed(String)
}

@main
struct RecordingDurationTest {
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duration-test-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoWriter(outputURL: url, configuration: VideoWriterConfiguration(width: 64, height: 64))
        try writer.startWriting()
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw DurationTestError.failed("Cannot allocate test frame")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 128, CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        for seconds in [0.0, 0.1, 0.2, 5.0] {
            writer.appendPixelBuffer(pixelBuffer, at: CMTime(seconds: seconds, preferredTimescale: 600))
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { continuation.resume() }
            }
        }
        await writer.finishWriting(at: CMTime(seconds: 5, preferredTimescale: 600))
        let duration = try await AVURLAsset(url: url).load(.duration)
        print("Sparse recording: expected 5.0s, actual \(duration.seconds)s")
        guard abs(duration.seconds - 5.0) < 0.002 else {
            throw DurationTestError.failed("Final frame extended recording beyond stop time")
        }
        for paused in [false, true] {
            let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent("capture-duration-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: captureURL) }
            let manager = VFRRecordingManager()
            try manager.startRecording(to: captureURL, configuration: CaptureConfiguration(width: 64, height: 64), showCursor: false)
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
            guard let format else { throw DurationTestError.failed("Cannot describe frame") }
            var pauseDuration = 0.0
            for seconds in [0.1, 0.2, 1.0] {
                if paused && seconds == 1.0 {
                    let pauseStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    manager.pause()
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
                    }
                    manager.resume()
                    pauseDuration = CMClockGetTime(CMClockGetHostTimeClock()).seconds - pauseStart
                }
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTimeAdd(manager.startTime, CMTime(seconds: seconds + pauseDuration, preferredTimescale: 60_000)), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
                guard let sample else { throw DurationTestError.failed("Cannot create frame") }
                manager.receiveFrame(sample)
            }
            _ = await manager.stopRecording(at: CMTimeAdd(manager.startTime, CMTime(seconds: 5 + pauseDuration, preferredTimescale: 60_000)))
            let capturedDuration = try await AVURLAsset(url: captureURL).load(.duration)
            guard abs(capturedDuration.seconds - 5) < 0.002 else {
                throw DurationTestError.failed("Capture paused=\(paused): expected 5s, got \(capturedDuration.seconds)s")
            }
            let asset = AVURLAsset(url: captureURL)
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            guard reader.startReading(), let firstSample = output.copyNextSampleBuffer(),
                  CMSampleBufferGetPresentationTimeStamp(firstSample) == .zero,
                  let firstImage = CMSampleBufferGetImageBuffer(firstSample) else {
                throw DurationTestError.failed("Recording does not begin with an image at zero")
            }
            CVPixelBufferLockBaseAddress(firstImage, .readOnly)
            let firstPixel = CVPixelBufferGetBaseAddress(firstImage)!.assumingMemoryBound(to: UInt8.self)
            let brightness = Int(firstPixel[0]) + Int(firstPixel[1]) + Int(firstPixel[2])
            CVPixelBufferUnlockBaseAddress(firstImage, .readOnly)
            guard brightness > 100 else { throw DurationTestError.failed("Recording begins with a black placeholder") }
            reader.cancelReading()
            print("PASS: production capture paused=\(paused), duration=\(capturedDuration.seconds)s")
        }
        print("PASS: sparse video ends at the recording stop time")
    }
}