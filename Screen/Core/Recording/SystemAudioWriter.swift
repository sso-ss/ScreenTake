import Foundation
import AVFoundation
import CoreMedia

/// Records system audio from SCStream to a sidecar .caf file.
///
/// Self-contained: manages its own PTS rebasing and pause tracking.
/// Writes raw LPCM (no AAC encoding) to avoid format mismatch distortion.
/// The AVAssetWriter is created lazily on the first sample so the
/// output settings match the actual format SCStream delivers.
final class SystemAudioRecorder: @unchecked Sendable {

    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var isRecording = false
    private var isPaused = false
    private var writerReady = false
    private let lock = NSLock()
    private var outputURL: URL?

    // PTS tracking
    private var firstPTS: CMTime?
    private var pauseStartPTS: CMTime?
    private var totalPausedDuration: CMTime = .zero
    private var samplesWritten: Int64 = 0
    private var recordingStartTime: CMTime?
    private(set) var startOffset: CMTime = .zero

    /// Prepare for recording. The writer is created lazily on first sample.
    func startRecording(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        self.outputURL = url
        self.assetWriter = nil
        self.audioInput = nil
        self.writerReady = false
        self.isRecording = true
        self.isPaused = false
        self.firstPTS = nil
      self.pauseStartPTS = nil
        self.totalPausedDuration = .zero
        self.samplesWritten = 0
        self.recordingStartTime = nil
        self.startOffset = .zero

        Log.recording.info("System audio recording prepared: \(url.lastPathComponent)")
    }

    func setRecordingStartTime(_ time: CMTime) {
        lock.lock()
        recordingStartTime = time
        if let firstPTS {
            startOffset = CMTimeMaximum(.zero, CMTimeSubtract(firstPTS, time))
        }
        lock.unlock()
    }

    /// Receive an audio sample buffer from SCStream.
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }

        // Handle pause
        if isPaused {
            lock.unlock()
            return
        }

        if firstPTS == nil {
            firstPTS = CMTimeSubtract(rawPTS, totalPausedDuration)
            if let recordingStartTime {
                startOffset = CMTimeMaximum(.zero, CMTimeSubtract(firstPTS!, recordingStartTime))
            }
        }
        let basePTS = firstPTS!
        let pauseOffset = totalPausedDuration
        lock.unlock()

        // Lazy writer setup on first sample
        if !writerReady {
            guard setupWriter(firstSample: sampleBuffer) else { return }
        }

        // Rebase PTS to zero-based
        let rebasedPTS = CMTimeSubtract(CMTimeSubtract(rawPTS, basePTS), pauseOffset)

        var timingInfo = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo) == noErr else {
            return
        }
        timingInfo.presentationTimeStamp = rebasedPTS
        timingInfo.decodeTimeStamp = .invalid

        var rebasedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &rebasedBuffer
        )

        guard status == noErr, let buffer = rebasedBuffer else { return }

        lock.lock()
        guard let audioInput, audioInput.isReadyForMoreMediaData else {
            lock.unlock()
            return
        }
        audioInput.append(buffer)
        samplesWritten += 1
        lock.unlock()
    }

    func stopRecording() async -> URL? {
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return nil
        }
        isRecording = false
        let samples = samplesWritten
        lock.unlock()

        audioInput?.markAsFinished()

        if let writer = assetWriter {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting {
                    continuation.resume()
                }
            }

            if writer.status == .failed {
                Log.recording.error("System audio writer failed: \(writer.error?.localizedDescription ?? "unknown")")
                return nil
            }
        }

        if samples == 0 {
            Log.recording.warning("System audio recording stopped with 0 samples")
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }

        Log.recording.info("System audio recording stopped: \(samples) samples written")
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

    private func setupWriter(firstSample: CMSampleBuffer) -> Bool {
        guard let url = outputURL else {
            Log.recording.error("System audio setupWriter: missing outputURL")
            return false
        }

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .caf)

            // Read source format for logging
            var sampleRate: Double = 48000
            var channels: UInt32 = 2
            if let formatDesc = CMSampleBufferGetFormatDescription(firstSample),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                sampleRate = asbd.pointee.mSampleRate
                channels = asbd.pointee.mChannelsPerFrame
                let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
                let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                Log.recording.info("System audio source: \(sampleRate)Hz \(channels)ch float=\(isFloat) nonInterleaved=\(isNonInterleaved)")
            }

            // Always write as standard interleaved Float32 PCM.
            // AVAssetWriterInput will convert non-interleaved → interleaved
            // automatically when outputSettings differ from source format.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]

            Log.recording.info("System audio writer settings: interleaved Float32 \(sampleRate)Hz \(channels)ch")

            let sourceFormat = CMSampleBufferGetFormatDescription(firstSample)
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: settings,
                sourceFormatHint: sourceFormat
            )
            input.expectsMediaDataInRealTime = true

            guard writer.canAdd(input) else {
                Log.recording.error("System audio writer cannot add input")
                return false
            }
            writer.add(input)

            guard writer.startWriting() else {
                Log.recording.error("System audio writer startWriting failed: \(writer.error?.localizedDescription ?? "nil")")
                return false
            }
            writer.startSession(atSourceTime: .zero)

            self.assetWriter = writer
            self.audioInput = input
            self.writerReady = true

            Log.recording.info("System audio writer initialized (LPCM passthrough)")
            return true
        } catch {
            Log.recording.error("System audio setupWriter error: \(error)")
            return false
        }
    }

    // MARK: - Helpers

    static func generateOutputURL(for videoURL: URL) -> URL {
        let dir = videoURL.deletingLastPathComponent()
        let name = videoURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(name)_system.caf")
    }
}
