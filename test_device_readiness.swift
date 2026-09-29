import AVFoundation
import Foundation

enum ReadinessTestError: Error {
    case failed(String)
}

@main
struct DeviceReadinessTest {
    static func main() async throws {
        let microphone = MicrophoneRecorder()
        let webcam = WebcamRecorder()
        do {
            try await microphone.waitUntilReady(timeout: 0.05)
            throw ReadinessTestError.failed("Microphone became ready without samples")
        } catch MicrophoneRecorderError.inputNotReady {}
        do {
            try await webcam.waitUntilReady(timeout: 0.05)
            throw ReadinessTestError.failed("Webcam became ready without frames")
        } catch WebcamRecorderError.framesNotReady {}
        let waiting = Task { try await webcam.waitUntilReady() }
        waiting.cancel()
        do {
            try await waiting.value
            throw ReadinessTestError.failed("Cancelled readiness wait succeeded")
        } catch is CancellationError {}
        print("PASS: unavailable devices time out and readiness wait can be cancelled")

        guard CommandLine.arguments.contains("--live") else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            print("SKIP: live test requires existing camera and microphone authorization")
            return
        }
        let defaults = UserDefaults(suiteName: "com.screen.Screen")
        let micID = defaults?.string(forKey: "selectedMicrophoneDeviceID") ?? ""
        let cameraID = defaults?.string(forKey: "selectedWebcamDeviceID") ?? ""
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screen-readiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            microphone.tearDown()
            webcam.tearDown()
        }
        let warmupStart = CMClockGetTime(CMClockGetHostTimeClock())
        try webcam.prepare(device: AVCaptureDevice(uniqueID: cameraID))
        try microphone.prepare(device: AVCaptureDevice(uniqueID: micID), outputURL: directory.appendingPathComponent("microphone.caf"))
        try await microphone.waitUntilReady()
        try await webcam.waitUntilReady()
        let origin = CMClockGetTime(CMClockGetHostTimeClock())
        print("Devices ready after \(CMTimeSubtract(origin, warmupStart).seconds)s")
        let micURL = directory.appendingPathComponent("microphone.caf")
        let cameraURL = directory.appendingPathComponent("camera.mov")
        try microphone.startWriting(to: micURL, startTime: origin)
        try webcam.startWriting(to: cameraURL, startTime: origin)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let cutoff = CMClockGetTime(CMClockGetHostTimeClock())
        guard await microphone.stopRecording() != nil,
              await webcam.stopRecording(at: cutoff) != nil else {
            throw ReadinessTestError.failed("Device writer did not produce output")
        }
        let asset = AVURLAsset(url: cameraURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw ReadinessTestError.failed("No webcam track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ReadinessTestError.failed("Cannot decode webcam") }
        var timestamps: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil {
                timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
        }
        guard reader.status == .completed, timestamps.count > 10 else {
            throw ReadinessTestError.failed("Webcam frames missing")
        }
        let maximumGap = zip(timestamps, timestamps.dropFirst()).map { $1 - $0 }.max() ?? 0
        print("Camera first frames=\(Array(timestamps.prefix(5))); maximum gap=\(maximumGap)s")
        guard timestamps[0] < 0.2, maximumGap < 0.2, microphone.startOffset.seconds < 0.2 else {
            throw ReadinessTestError.failed("Device started late after readiness")
        }
        print("PASS: live camera and microphone start within 0.2s; audio offset=\(microphone.startOffset.seconds)s")
        print("Diagnostic files: \(directory.path)")
    }
}