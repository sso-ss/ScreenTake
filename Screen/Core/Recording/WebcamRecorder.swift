import Foundation
import AVFoundation
import CoreMedia

/// Records webcam video to a sidecar .mov file using AVCaptureSession.
///
/// Two-phase lifecycle:
/// 1. `prepare(device:)` — starts the capture session (camera warm-up, live preview ready)
/// 2. `startWriting(to:)` — begins writing frames to disk
///
/// Expose `session` for AVCaptureVideoPreviewLayer in the live PiP overlay.
final class WebcamRecorder: NSObject, @unchecked Sendable {

    /// The underlying capture session. Available after `prepare(device:)`.
    /// Use this to create an `AVCaptureVideoPreviewLayer` for live preview.
    private(set) var session: AVCaptureSession?

    private var videoOutput: AVCaptureVideoDataOutput?
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?

    private let recordingQueue = DispatchQueue(label: "com.screen.webcam-recorder", qos: .userInteractive)
    private var isRecording = false
    private var isPaused = false
    private var sessionStarted = false
    private let lock = NSLock()
    private var outputURL: URL?
    private var firstPTS: CMTime?
    private var pauseStartPTS: CMTime?
    private var totalPausedDuration: CMTime = .zero
    private var lastPreviewPTS: CMTime?
    private var lastPreviewArrival: CMTime?
    private var consecutivePreviewFrames = 0

    /// Latest pixel buffer for live preview. Updated on every captured frame.
    /// Read from the main thread (PiP overlay); written from the capture queue.
    private(set) var latestPixelBuffer: CVPixelBuffer?

    /// Actual camera frame dimensions (set after session starts).
    private var captureWidth: Int = 640
    private var captureHeight: Int = 480
    private(set) var rotationAngle: CGFloat = 0

    /// Whether the capture session is running and ready for preview / writing.
    var isSessionRunning: Bool { session?.isRunning ?? false }

    // MARK: - Phase 1: Prepare (start camera session)

    /// Starts the AVCaptureSession so the camera warms up and frames begin flowing.
    /// Call this *before* recording to ensure the camera is ready.
    func prepare(device: AVCaptureDevice? = nil) throws {
        let camera = device ?? AVCaptureDevice.default(for: .video)
        guard let camera else {
            throw WebcamRecorderError.noDeviceAvailable
        }

        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .medium // 480p — sufficient for PiP

        let input = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(input) else {
            throw WebcamRecorderError.inputConfigFailed
        }
        captureSession.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: recordingQueue)
        guard captureSession.canAddOutput(output) else {
            throw WebcamRecorderError.outputConfigFailed
        }
        captureSession.addOutput(output)

        let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        let requestedAngle: CGFloat = dimensions.height > dimensions.width ? 90 : 0
        let outputConnection = output.connection(with: .video)
        if #available(macOS 14.0, *) {
            rotationAngle = outputConnection?.isVideoRotationAngleSupported(requestedAngle) == true ? requestedAngle : 0
            outputConnection?.videoRotationAngle = rotationAngle
        } else if requestedAngle == 90, outputConnection?.isVideoOrientationSupported == true {
            outputConnection?.videoOrientation = .landscapeRight
            rotationAngle = requestedAngle
        }

        self.session = captureSession
        self.videoOutput = output

        lock.withLock {
            lastPreviewPTS = nil
            lastPreviewArrival = nil
            consecutivePreviewFrames = 0
        }
        captureSession.startRunning()

        // Read actual camera dimensions so the writer matches the capture format
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        captureWidth = rotationAngle == 90 ? Int(dims.height) : Int(dims.width)
        captureHeight = rotationAngle == 90 ? Int(dims.width) : Int(dims.height)
        Log.recording.info("Webcam session prepared (camera running) — \(self.captureWidth)x\(self.captureHeight)")
    }

    // MARK: - Phase 2: Start writing to file

    func waitUntilReady(timeout: TimeInterval = 8) async throws {
        let deadline = CMClockGetTime(CMClockGetHostTimeClock()).seconds + timeout
        while CMClockGetTime(CMClockGetHostTimeClock()).seconds < deadline {
            try Task.checkCancellation()
            let ready = lock.withLock {
                guard let lastPreviewArrival, let lastPreviewPTS, lastPreviewPTS.isNumeric else { return false }
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                return consecutivePreviewFrames >= 3
                    && CMTimeSubtract(now, lastPreviewArrival).seconds < 0.2
            }
            if ready { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw WebcamRecorderError.framesNotReady
    }

    /// Begins writing captured frames to the given URL.
    /// The capture session must already be running (`prepare` must be called first).
    func startWriting(to url: URL, startTime: CMTime? = nil) throws {
        guard session?.isRunning == true else {
            throw WebcamRecorderError.sessionNotRunning
        }

        self.outputURL = url

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: captureWidth,
            AVVideoHeightKey: captureHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ] as [String: Any],
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = true

        if writer.canAdd(writerInput) {
            writer.add(writerInput)
        }

        guard writer.startWriting() else {
            throw writer.error ?? WebcamRecorderError.writerStartFailed
        }

        self.assetWriter = writer
        self.videoWriterInput = writerInput
        self.sessionStarted = false
        self.firstPTS = startTime
        self.pauseStartPTS = nil
        self.totalPausedDuration = .zero
        self.isRecording = true
        self.isPaused = false

        Log.recording.info("Webcam writing started: \(url.lastPathComponent)")
    }

    // MARK: - Legacy convenience (prepare + write in one call)

    /// Start recording webcam video (prepares session and starts writing in one step).
    func startRecording(to url: URL, device: AVCaptureDevice? = nil) throws {
        try prepare(device: device)
        try startWriting(to: url)
    }

    func stopRecording(at stopTime: CMTime? = nil) async -> URL? {
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return nil
        }
        isRecording = false
        let cutoff = stopTime ?? CMClockGetTime(CMClockGetHostTimeClock())
        let currentPause = pauseStartPTS.map { CMTimeSubtract(cutoff, $0) } ?? .zero
        let pausedDuration = CMTimeAdd(totalPausedDuration, currentPause)
        let origin = firstPTS
        lock.unlock()

        session?.stopRunning()
        recordingQueue.sync {}
        if let origin, sessionStarted, assetWriter?.status == .writing {
            let endTime = CMTimeSubtract(CMTimeSubtract(cutoff, origin), pausedDuration)
            assetWriter?.endSession(atSourceTime: CMTimeMaximum(.zero, endTime))
        }
        videoWriterInput?.markAsFinished()

        guard let writer = assetWriter else { return nil }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        session = nil
        videoOutput = nil
        Log.recording.info("Webcam recording stopped")
        return outputURL
    }

    /// Tears down the capture session without writing. Use when cancelling before recording.
    func tearDown() {
        session?.stopRunning()
        session = nil
        videoOutput = nil
    }

    func pause(at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.lock()
        if !isPaused {
            isPaused = true
            pauseStartPTS = time
        }
        lock.unlock()
    }

    func resume(at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.lock()
        if let pauseStartPTS {
            totalPausedDuration = CMTimeAdd(totalPausedDuration, CMTimeSubtract(time, pauseStartPTS))
        }
        pauseStartPTS = nil
        isPaused = false
        lock.unlock()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension WebcamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Always publish the latest frame for live preview, regardless of recording state
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            latestPixelBuffer = pixelBuffer
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            lock.withLock {
                if let previous = lastPreviewPTS, timestamp > previous,
                   CMTimeSubtract(timestamp, previous).seconds < 0.2 {
                    consecutivePreviewFrames += 1
                } else {
                    consecutivePreviewFrames = 1
                }
                lastPreviewPTS = timestamp
                lastPreviewArrival = CMClockGetTime(CMClockGetHostTimeClock())
            }
        }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }

        if isPaused {
            lock.unlock()
            return
        }

        if firstPTS == nil {
            firstPTS = CMTimeSubtract(rawPTS, totalPausedDuration)
        }
        let basePTS = firstPTS!
        let pauseOffset = totalPausedDuration
        lock.unlock()

        let rebasedPTS = CMTimeSubtract(CMTimeSubtract(rawPTS, basePTS), pauseOffset)
        guard rebasedPTS >= .zero else { return }

        guard let writerInput = videoWriterInput,
              writerInput.isReadyForMoreMediaData else { return }

        if !sessionStarted {
            assetWriter?.startSession(atSourceTime: .zero)
            sessionStarted = true
        }

        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: rebasedPTS,
            decodeTimeStamp: .invalid
        )
        var rebasedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &rebasedBuffer
        )
        guard status == noErr, let buffer = rebasedBuffer else { return }
        writerInput.append(buffer)
    }
}

// MARK: - Errors

enum WebcamRecorderError: LocalizedError {
    case noDeviceAvailable
    case inputConfigFailed
    case outputConfigFailed
    case writerStartFailed
    case sessionNotRunning
    case framesNotReady

    var errorDescription: String? {
        switch self {
        case .noDeviceAvailable: return "No webcam device available"
        case .inputConfigFailed: return "Failed to configure webcam input"
        case .outputConfigFailed: return "Failed to configure webcam output"
        case .writerStartFailed: return "Failed to start webcam writer"
        case .sessionNotRunning: return "Webcam session not running — call prepare() first"
        case .framesNotReady: return "Camera did not become ready. Please try recording again."
        }
    }
}
