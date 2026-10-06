import Foundation
import AVFoundation
import CoreMedia
import Combine

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
        return writer.status == .completed ? outputURL : nil
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


/// Records a camera take against the edited playback clock, like narration.
@MainActor
final class VideoOverlayRecorder: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var session: AVCaptureSession?
    @Published private(set) var rotationAngle: CGFloat = 0
    @Published var error: String?
    private var camera: WebcamRecorder?
    private var player: AVPlayer?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var output: URL?
    private var start: Double = 0
    private var limit: Double = 0
    private var hostStart: CMTime = .zero
    private var wasWaiting = true
    private var keepTake = false
    @Published private(set) var isFinishing = false
    private var completion: ((URL, VideoOverlayTiming) -> Void)?

    func start(player: AVPlayer, device: AVCaptureDevice?, duration: Double,
               completion: @escaping (URL, VideoOverlayTiming) -> Void) {
        guard !isBusy, player.currentItem?.status == .readyToPlay else {
            error = "Wait for the video preview to finish loading, then try again."
            return
        }
        let position = player.currentTime().seconds
        guard position.isFinite, position >= 0, duration.isFinite, duration - position > 0.1 else {
            error = "Move the playhead before the end of the video to record a camera take."
            return
        }
        player.pause()
        player.currentItem?.forwardPlaybackEndTime = .invalid
        self.player = player
        wasWaiting = player.automaticallyWaitsToMinimizeStalling
        start = position
        limit = duration - position
        self.completion = completion
        isBusy = true
        elapsed = 0
        error = nil
        keepTake = false
        isFinishing = false
        let camera = WebcamRecorder()
        self.camera = camera
        task = Task {
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                try Task.checkCancellation()
                guard allowed else { throw VideoOverlayRecordingError.message("Allow Camera access for ScreenTake in System Settings > Privacy & Security, then try again.") }
                try await Task.detached(priority: .userInitiated) { try camera.prepare(device: device) }.value
                try Task.checkCancellation()
                try await camera.waitUntilReady()
                session = camera.session
                rotationAngle = camera.rotationAngle
                player.automaticallyWaitsToMinimizeStalling = false
                let ready = await withCheckedContinuation { continuation in
                    player.preroll(atRate: 1) { continuation.resume(returning: $0) }
                }
                try Task.checkCancellation()
                guard ready else { throw VideoOverlayRecordingError.message("The video preview could not start. Try again once it is ready.") }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenTake-CameraTakes", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("Camera-\(UUID().uuidString).mov")
                output = url
                hostStart = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), EditorAudio.time(0.15))
                try camera.startWriting(to: url, startTime: hostStart)
                player.setRate(1, time: EditorAudio.time(start), atHostTime: hostStart)
                isRecording = true
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
                await Task.detached { camera.tearDown() }.value
                if let output { try? FileManager.default.removeItem(at: output) }
                reset()
            }
        }
    }

    private func tick() {
        guard isRecording, let player else { return }
        elapsed = max(0, min(limit, CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), hostStart).seconds))
        if elapsed >= limit || (elapsed > 0.3 && player.timeControlStatus != .playing) {
            if elapsed < limit - 0.2 { error = "Camera recording stopped because playback paused. Your take was kept." }
            stop()
        }
    }

    func stop() { finish(keep: true) }

    func cancel() {
        guard isBusy else { return }
        keepTake = false
        if isFinishing { return }
        if isRecording { finish(keep: false) }
        else {
            task?.cancel()
            player?.cancelPendingPrerolls()
            player?.pause()
        }
    }

    private func finish(keep: Bool) {
        guard isRecording, let camera else { return }
        keepTake = keep
        isFinishing = true
        isRecording = false
        timer?.invalidate()
        timer = nil
        player?.pause()
        session = nil
        let cutoff = CMTimeMinimum(CMClockGetTime(CMClockGetHostTimeClock()), CMTimeAdd(hostStart, EditorAudio.time(limit)))
        task = Task {
            let url = await Task.detached { await camera.stopRecording(at: cutoff) }.value
            var timing: VideoOverlayTiming?
            if keepTake, url == nil { error = "The camera take could not be saved. Please try again." }
            if keepTake, let url {
                do {
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration).seconds
                    guard duration.isFinite, duration > 0.05,
                          !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                        throw VideoOverlayRecordingError.message("The take was too short. Record a little longer and try again.")
                    }
                    timing = VideoOverlayTiming(start: start, duration: min(limit, duration))
                } catch { self.error = error.localizedDescription }
            }
            let saved = keepTake ? timing : nil
            let complete = completion
            if saved == nil, let output { try? FileManager.default.removeItem(at: output) }
            reset()
            if let url, let saved { complete?(url, saved) }
        }
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        player?.pause()
        player?.automaticallyWaitsToMinimizeStalling = wasWaiting
        player = nil
        camera = nil
        session = nil
        output = nil
        completion = nil
        task = nil
        isFinishing = false
        isRecording = false
        isBusy = false
    }
}

private enum VideoOverlayRecordingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
