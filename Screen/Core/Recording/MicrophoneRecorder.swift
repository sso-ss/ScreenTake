import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

/// Records microphone audio to an uncompressed sidecar .caf file using AVCaptureSession.
///
/// The AVAssetWriter is created lazily on receipt of the first audio sample so
/// that the writer settings are derived from the actual device output format.
/// Handles pause/resume with PTS rebasing.
final class MicrophoneRecorder: NSObject, @unchecked Sendable {

    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var assetWriter: AVAssetWriter?
    private var audioWriterInput: AVAssetWriterInput?

    private let recordingQueue = DispatchQueue(label: "com.screen.mic-recorder", qos: .userInteractive)
    private var isRecording = false
    private var isPaused = false
    private var isMuted = false
    private var writerReady = false
    private let lock = NSLock()
    private var outputURL: URL?

    // PTS tracking
    private var firstPTS: CMTime?
    private var pauseStartPTS: CMTime?
    private var totalPausedDuration: CMTime = .zero
    private var samplesWritten: Int64 = 0
    private var writerFailed = false
    private var recordingStartTime: CMTime?
    private(set) var startOffset: CMTime = .zero
    private(set) var receivedBuffers = 0
    private(set) var backpressuredBuffers = 0
    private var inputWarmupStart: CMTime?
    private var lastInputPTS: CMTime?
    private var lastInputArrival: CMTime?

    /// Start recording microphone audio.
    func startRecording(to url: URL, device: AVCaptureDevice? = nil, startTime: CMTime? = nil) throws {
        try prepare(device: device)
        try startWriting(to: url, startTime: startTime)
    }

    func prepare(device: AVCaptureDevice? = nil, outputURL: URL? = nil) throws {
        let mic = device ?? AVCaptureDevice.default(for: .audio)
        guard let mic else {
            throw MicrophoneRecorderError.noDeviceAvailable
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: mic)
        guard session.canAddInput(input) else {
            throw MicrophoneRecorderError.inputConfigFailed
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: recordingQueue)
        guard session.canAddOutput(output) else {
            throw MicrophoneRecorderError.outputConfigFailed
        }
        session.addOutput(output)

        self.captureSession = session
        self.audioOutput = output

        if let outputURL {
            try prepareRecording(to: outputURL)
        }
        lock.withLock {
            isRecording = false
            inputWarmupStart = nil
            lastInputPTS = nil
            lastInputArrival = nil
        }

        // startRunning() is synchronous but should not block the main thread.
        // Dispatch to the recording queue so the capture session configures
        // its audio hardware on the correct thread.
        recordingQueue.sync {
            session.startRunning()
        }

        if !session.isRunning {
            Log.recording.warning("Microphone session not yet running — may start asynchronously")
        }

        Log.recording.info("Microphone warming up: \(mic.localizedName)")
    }

    func waitUntilReady(timeout: TimeInterval = 8) async throws {
        let deadline = CMClockGetTime(CMClockGetHostTimeClock()).seconds + timeout
        while CMClockGetTime(CMClockGetHostTimeClock()).seconds < deadline {
            try Task.checkCancellation()
            let ready = lock.withLock {
                guard let inputWarmupStart, let lastInputPTS, let lastInputArrival else { return false }
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                return CMTimeSubtract(lastInputPTS, inputWarmupStart).seconds >= 2.5
                    && CMTimeSubtract(now, lastInputArrival).seconds < 0.2
                    && (outputURL == nil || writerReady)
            }
            if ready { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw MicrophoneRecorderError.inputNotReady
    }

    func startWriting(to url: URL, startTime: CMTime? = nil) throws {
        guard captureSession?.isRunning == true else { throw MicrophoneRecorderError.sessionStartFailed }
        try recordingQueue.sync {
            if outputURL == url && writerReady {
                lock.withLock {
                    recordingStartTime = startTime
                    isRecording = true
                }
            } else {
                try prepareRecording(to: url, startTime: startTime)
            }
        }
        Log.recording.info("Microphone writing started: \(url.lastPathComponent)")
    }

    func tearDown() {
        lock.withLock { isRecording = false }
        captureSession?.stopRunning()
        recordingQueue.sync {}
        if assetWriter?.status == .writing {
            assetWriter?.cancelWriting()
        }
        captureSession = nil
        audioOutput = nil
    }

    func prepareRecording(to url: URL, startTime: CMTime? = nil) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        outputURL = url
        assetWriter = nil
        audioWriterInput = nil
        writerReady = false
        isRecording = true
        isPaused = false
        isMuted = false
        firstPTS = nil
        recordingStartTime = startTime
        startOffset = .zero
        pauseStartPTS = nil
        totalPausedDuration = .zero
        samplesWritten = 0
        receivedBuffers = 0
        backpressuredBuffers = 0
        writerFailed = false
    }

    func stopRecording() async -> URL? {
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return nil
        }
        isRecording = false
        let samples = samplesWritten
        let failed = writerFailed
        lock.unlock()

        captureSession?.stopRunning()
        recordingQueue.sync {}

        audioWriterInput?.markAsFinished()

        if let writer = assetWriter {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting {
                    continuation.resume()
                }
            }

            if writer.status == .failed || failed {
                Log.recording.error("Microphone writer failed: \(String(describing: writer.error as NSError?), privacy: .public)")
                captureSession = nil
                audioOutput = nil
                return nil
            }
        }

        captureSession = nil
        audioOutput = nil

        if samples == 0 {
            Log.recording.warning("Microphone recording stopped with 0 samples — no audio captured")
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }

        Log.recording.info("Microphone recording stopped: \(samples) samples written")
        return outputURL
    }

    func pause(at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.lock()
        if !isPaused {
            isPaused = true
            pauseStartPTS = time
        }
        lock.unlock()
    }

    /// Keep muted intervals silent without removing time from the audio track.
    func setMuted(_ muted: Bool) {
        lock.withLock { isMuted = muted }
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

    // MARK: - Lazy Writer Setup

    /// Called on `recordingQueue` when the first valid sample arrives.
    /// Uses the capture output's recommended settings to guarantee format compatibility.
    private func setupWriter(firstSample: CMSampleBuffer) -> Bool {
        guard let url = outputURL else {
            Log.recording.error("Mic setupWriter: missing outputURL")
            return false
        }

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .caf)

            var sampleRate: Double = 48_000
            var channels: UInt32 = 1
            if let sourceFormat = CMSampleBufferGetFormatDescription(firstSample),
               let description = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormat) {
                sampleRate = description.pointee.mSampleRate
                channels = description.pointee.mChannelsPerFrame
                Log.recording.info("Mic source: rate=\(sampleRate, privacy: .public) channels=\(channels, privacy: .public) flags=\(description.pointee.mFormatFlags, privacy: .public)")
            }

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
            Log.recording.info("Mic writer settings: \(settings)")

            let sourceFormat = CMSampleBufferGetFormatDescription(firstSample)
            let writerInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: settings,
                sourceFormatHint: sourceFormat
            )
            writerInput.expectsMediaDataInRealTime = true

            guard writer.canAdd(writerInput) else {
                Log.recording.error("Mic writer cannot add audio input")
                return false
            }
            writer.add(writerInput)

            guard writer.startWriting() else {
                Log.recording.error("Mic writer startWriting failed: \(writer.error?.localizedDescription ?? "nil")")
                return false
            }
            writer.startSession(atSourceTime: .zero)

            lock.withLock {
                self.assetWriter = writer
                self.audioWriterInput = writerInput
                self.writerReady = true
            }

            Log.recording.info("Mic writer initialized on first sample")
            return true
        } catch {
            Log.recording.error("Mic setupWriter error: \(error)")
            return false
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension MicrophoneRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        appendSampleBuffer(sampleBuffer)
    }

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        if rawPTS.isNumeric {
            if inputWarmupStart == nil || lastInputPTS.map({ rawPTS <= $0 || CMTimeSubtract(rawPTS, $0).seconds > 0.2 }) == true {
                inputWarmupStart = rawPTS
            }
            lastInputPTS = rawPTS
            lastInputArrival = CMClockGetTime(CMClockGetHostTimeClock())
        }
        guard isRecording else {
            let shouldPrepareWriter = outputURL != nil && !writerReady && !writerFailed
            lock.unlock()
            if shouldPrepareWriter && !setupWriter(firstSample: sampleBuffer) {
                lock.withLock { writerFailed = true }
            }
            return
        }

        if isPaused {
            lock.unlock()
            return
        }

        receivedBuffers += 1
        if firstPTS == nil {
            firstPTS = CMTimeSubtract(rawPTS, totalPausedDuration)
            if let recordingStartTime {
                startOffset = CMTimeMaximum(.zero, CMTimeSubtract(firstPTS!, recordingStartTime))
            }
        }
        let basePTS = firstPTS!
        let pauseOffset = totalPausedDuration
        let ready = writerReady
        let failed = writerFailed
        let muted = isMuted
        lock.unlock()

        guard !failed else { return }

        let rebasedPTS = CMTimeSubtract(CMTimeSubtract(rawPTS, basePTS), pauseOffset)
        guard let buffer = rebaseTiming(sampleBuffer, pts: rebasedPTS) else { return }
        if muted {
            guard let data = CMSampleBufferGetDataBuffer(buffer),
                  CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0,
                                            dataLength: CMBlockBufferGetDataLength(data)) == noErr else { return }
        }

        // Lazy writer init on first sample
        if !ready {
            if !setupWriter(firstSample: buffer) {
                lock.lock()
                writerFailed = true
                lock.unlock()
                return
            }
        }

        guard let writerInput = audioWriterInput,
                            writerInput.isReadyForMoreMediaData else {
                        lock.withLock { backpressuredBuffers += 1 }
                        return
                }

        let ok = writerInput.append(buffer)
        if ok {
            lock.lock()
            samplesWritten += 1
            lock.unlock()
        } else if !writerFailed {
            lock.lock()
            writerFailed = true
            lock.unlock()
            Log.recording.error("Mic writer append failed: \(String(describing: self.assetWriter?.error as NSError?), privacy: .public)")
        }
    }

    func rebaseTiming(_ sampleBuffer: CMSampleBuffer, pts: CMTime) -> CMSampleBuffer? {
        guard let sourceData = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        var ownedData: CMBlockBuffer?
        let copyStatus = CMBlockBufferCreateContiguous(
            allocator: kCFAllocatorDefault,
            sourceBuffer: sourceData,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: CMBlockBufferGetDataLength(sourceData),
            flags: kCMBlockBufferAlwaysCopyDataFlag,
            blockBufferOut: &ownedData
        )
        guard copyStatus == noErr, let ownedData else { return nil }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else {
            return nil
        }
        timing.presentationTimeStamp = pts
        timing.decodeTimeStamp = .invalid
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: ownedData,
            formatDescription: format,
            sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &out
        )
        guard status == noErr else { return nil }
        return out
    }
}

enum MicrophoneRecorderError: LocalizedError {
    case permissionDenied
    case noDeviceAvailable
    case inputConfigFailed
    case outputConfigFailed
    case writerStartFailed
    case sessionStartFailed
    case inputNotReady

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Allow microphone access for ScreenTake in System Settings."
        case .noDeviceAvailable: return "No microphone device available"
        case .inputConfigFailed: return "Failed to configure audio input"
        case .outputConfigFailed: return "Failed to configure audio output"
        case .writerStartFailed: return "Failed to start audio writer"
        case .sessionStartFailed: return "Microphone capture session failed to start"
        case .inputNotReady: return "Microphone did not become ready. Please try recording again."
        }
    }
}
