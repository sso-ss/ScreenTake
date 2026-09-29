import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Configuration for the video writer
struct VideoWriterConfiguration {
    var width: Int
    var height: Int
    var frameRate: Int
    var videoBitRate: Int
    var keyFrameInterval: Int
    var videoCodec: AVVideoCodecType
    var fileType: AVFileType
    var includeAudio: Bool

    init(
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Int = 60,
        videoBitRate: Int = 20_000_000,
        keyFrameInterval: Int = 60,
        videoCodec: AVVideoCodecType = .hevc,
        fileType: AVFileType = .mov,
        includeAudio: Bool = false
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitRate = videoBitRate
        self.keyFrameInterval = keyFrameInterval
        self.videoCodec = videoCodec
        self.fileType = fileType
        self.includeAudio = includeAudio
    }
}

/// AVAssetWriter wrapper for writing video frames
final class VideoWriter: @unchecked Sendable {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private let outputURL: URL
    private let configuration: VideoWriterConfiguration

    private var isWriting = false
    private var sessionStartTime: CMTime?
    private var lastVideoTime: CMTime = .zero

    private let lock = NSLock()

    // Diagnostic counters
    private var appendCount: Int64 = 0
    private var rejectedOutOfOrder: Int64 = 0
    private var encoderBusyCount: Int64 = 0
    private var pendingDropCount: Int64 = 0

    /// Small queue of frames that couldn't be written because the encoder was busy.
    /// Kept intentionally shallow to bound memory while absorbing short stalls.
    private var pendingFrames: [(buffer: CVPixelBuffer, time: CMTime)] = []
    private let maxPendingFrames = 8

    init(outputURL: URL, configuration: VideoWriterConfiguration) throws {
        self.outputURL = outputURL
        self.configuration = configuration

        try setupAssetWriter()
    }

    private func setupAssetWriter() throws {
        // Remove existing file
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: configuration.fileType)

        // Video settings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: configuration.videoCodec,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.videoBitRate,
                AVVideoMaxKeyFrameIntervalKey: configuration.keyFrameInterval,
                AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
                AVVideoProfileLevelKey: configuration.videoCodec == .hevc
                    ? "HEVC_Main_AutoLevel"
                    : AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: configuration.width,
                kCVPixelBufferHeightKey as String: configuration.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )

        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        }

        self.assetWriter = writer
        self.videoInput = videoInput
        self.pixelBufferAdaptor = adaptor
    }

    func startWriting() throws {
        guard let writer = assetWriter else { return }
        guard writer.startWriting() else {
            throw writer.error ?? VideoWriterError.startFailed
        }
        writer.startSession(atSourceTime: .zero)
        isWriting = true
    }

    /// Append a pixel buffer. Must be called from a single serial queue.
    ///
    /// When the encoder is busy (`isReadyForMoreMediaData == false`), the frame
    /// is held as a pending buffer and flushed on the next call. This avoids
    /// multi-second gaps without introducing cross-queue races.
    func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard isWriting,
              let writer = assetWriter, writer.status == .writing,
              let videoInput,
              let adaptor = pixelBufferAdaptor else { return }

        // Early out for out-of-order timestamps
        lock.lock()
        guard time > lastVideoTime || sessionStartTime == nil else {
            rejectedOutOfOrder += 1
            if rejectedOutOfOrder % 100 == 1 {
                Log.recording.warning("VideoWriter: rejected out-of-order #\(self.rejectedOutOfOrder), time=\(time.seconds) <= lastVideoTime=\(self.lastVideoTime.seconds)")
            }
            lock.unlock()
            return
        }
        lock.unlock()

        if videoInput.isReadyForMoreMediaData {
            // Flush pending frames first (older timestamps) while encoder is ready.
            flushPendingFrames(videoInput: videoInput, adaptor: adaptor)

            lock.lock()
            // Re-check after potential flush
            guard time > lastVideoTime || sessionStartTime == nil else {
                lock.unlock()
                return
            }
            lock.unlock()

            if safeAppend(adaptor: adaptor, pixelBuffer: pixelBuffer, time: time) {
                lock.lock()
                lastVideoTime = time
                if sessionStartTime == nil { sessionStartTime = time }
                appendCount += 1
                lock.unlock()
            }
        } else {
            // Encoder busy — queue this frame so we can write it when ready.
            lock.lock()
            if pendingFrames.count >= maxPendingFrames {
                pendingDropCount += 1
                pendingFrames.removeFirst()
            }
            encoderBusyCount += 1
            pendingFrames.append((pixelBuffer, time))
            lock.unlock()
        }
    }

    /// Flush queued pending frames while encoder is ready and timestamps are valid.
    private func flushPendingFrames(videoInput: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        guard assetWriter?.status == .writing else { return }
        while videoInput.isReadyForMoreMediaData {
            var next: (buffer: CVPixelBuffer, time: CMTime)?
            lock.lock()
            if !pendingFrames.isEmpty {
                next = pendingFrames.removeFirst()
            }
            lock.unlock()

            guard let next else { return }

            lock.lock()
            guard next.time > lastVideoTime || sessionStartTime == nil else {
                lock.unlock()
                continue
            }
            lock.unlock()

            guard safeAppend(adaptor: adaptor, pixelBuffer: next.buffer, time: next.time) else {
                return
            }

            lock.lock()
            lastVideoTime = next.time
            if sessionStartTime == nil { sessionStartTime = next.time }
            appendCount += 1
            lock.unlock()
        }
    }

    /// Append a pixel buffer, catching any ObjC exception thrown by AVFoundation
    /// when the writer transitions to `.failed` between our status check and the call.
    private func safeAppend(adaptor: AVAssetWriterInputPixelBufferAdaptor, pixelBuffer: CVPixelBuffer, time: CMTime) -> Bool {
        var appended = false
        do {
            try ObjCExceptionCatcher.`try` {
                appended = adaptor.append(pixelBuffer, withPresentationTime: time)
            }
        } catch {
            Log.recording.error("VideoWriter: append failed (ObjC exception caught): \(error.localizedDescription)")
            return false
        }

        if !appended {
            Log.recording.error("VideoWriter: append rejected: \(self.assetWriter?.error?.localizedDescription ?? "unknown")")
        }
        return appended
    }

    func finishWriting(at endTime: CMTime? = nil) async {
        guard let writer = assetWriter else { return }
        let wasWriting = isWriting
        isWriting = false

        Log.recording.info("VideoWriter stats: appended=\(self.appendCount), rejectedOOO=\(self.rejectedOutOfOrder), encoderBusy=\(self.encoderBusyCount), pendingDrops=\(self.pendingDropCount)")

        // Flush any remaining queued pending frames
        if wasWriting, writer.status == .writing,
           let videoInput, let adaptor = pixelBufferAdaptor,
           videoInput.isReadyForMoreMediaData {
            flushPendingFrames(videoInput: videoInput, adaptor: adaptor)
        }

        if writer.status == .writing, let endTime, endTime.isNumeric {
            writer.endSession(atSourceTime: endTime)
        }
        videoInput?.markAsFinished()

        // Always finalize — even if isWriting was cleared by a failed append,
        // the writer must call finishWriting() to produce a valid moov atom.
        guard writer.status == .writing else {
            Log.recording.warning("VideoWriter: skipping finishWriting, writer status=\(writer.status.rawValue)")
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }
}

enum VideoWriterError: LocalizedError {
    case startFailed

    var errorDescription: String? {
        "Failed to start video writer"
    }
}
