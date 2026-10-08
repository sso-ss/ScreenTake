import Foundation
import AVFoundation
import CoreMedia

struct VideoCut: Equatable, Identifiable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
}

struct EditedTimeline {
    let ranges: [CMTimeRange]

    var duration: CMTime { ranges.reduce(.zero) { CMTimeAdd($0, $1.duration) } }

    func outputTime(at source: CMTime) -> CMTime {
        var elapsed = CMTime.zero
        for range in ranges {
            if source >= range.start && source < range.end { return CMTimeAdd(elapsed, CMTimeSubtract(source, range.start)) }
            elapsed = CMTimeAdd(elapsed, range.duration)
        }
        if let next = ranges.filter({ $0.start > source }).min(by: { $0.start < $1.start }) {
            return outputTime(at: next.start)
        }
        return elapsed
    }

    func sourceTime(at output: CMTime) -> CMTime {
        var remaining = CMTimeMaximum(.zero, output)
        for range in ranges {
            if remaining < range.duration { return CMTimeAdd(range.start, remaining) }
            remaining = CMTimeSubtract(remaining, range.duration)
        }
        return ranges.last?.end ?? .zero
    }

    func apply(to composition: AVMutableComposition, sourceDuration: CMTime) throws {
        guard let original = composition.copy() as? AVComposition else { throw VideoTrimError.exportFailed }
        composition.removeTimeRange(CMTimeRange(start: .zero, duration: sourceDuration))
        var elapsed = CMTime.zero
        for range in ranges {
            try composition.insertTimeRange(range, of: original, at: elapsed)
            elapsed = CMTimeAdd(elapsed, range.duration)
        }
    }
}

struct VideoTrim: Equatable, Codable {
    var start: Double = 0
    var end: Double?
    var cuts: [VideoCut] = []
    var splits: [Double] = []
    private(set) var clipOrder: [CMTimeRange] = []

    private enum CodingKeys: String, CodingKey { case start, end, cuts, splits, clipOrder }
    private struct SavedRange: Codable {
        let startValue: Int64
        let startScale: Int32
        let durationValue: Int64
        let durationScale: Int32
        init(_ range: CMTimeRange) {
            startValue = range.start.value; startScale = range.start.timescale
            durationValue = range.duration.value; durationScale = range.duration.timescale
        }
        func range() throws -> CMTimeRange {
            guard startScale > 0, durationScale > 0, startValue >= 0, durationValue > 0 else {
                throw VideoTrimError.invalidRange
            }
            return CMTimeRange(start: CMTime(value: startValue, timescale: startScale),
                               duration: CMTime(value: durationValue, timescale: durationScale))
        }
    }

    init(start: Double = 0, end: Double? = nil, cuts: [VideoCut] = [], splits: [Double] = []) {
        self.start = start; self.end = end; self.cuts = cuts; self.splits = splits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        start = try values.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try values.decodeIfPresent(Double.self, forKey: .end)
        cuts = try values.decodeIfPresent([VideoCut].self, forKey: .cuts) ?? []
        splits = try values.decodeIfPresent([Double].self, forKey: .splits) ?? []
        clipOrder = try (values.decodeIfPresent([SavedRange].self, forKey: .clipOrder) ?? []).map { try $0.range() }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(start, forKey: .start)
        try values.encodeIfPresent(end, forKey: .end)
        try values.encode(cuts, forKey: .cuts)
        try values.encode(splits, forKey: .splits)
        try values.encode(clipOrder.map(SavedRange.init), forKey: .clipOrder)
    }

    mutating func moveSegment(from sourceIndex: Int, to destinationIndex: Int, duration: CMTime) -> Bool {
        guard let visible = try? segments(duration: duration),
              visible.indices.contains(sourceIndex), visible.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return false }
        var complete = self
        complete.start = 0
        complete.end = nil
        complete.cuts = []
        complete.splits += cuts.flatMap { [$0.start, $0.end] } + [start, end ?? duration.seconds]
        guard var ordered = try? complete.segments(duration: duration),
              let from = ordered.firstIndex(of: visible[sourceIndex]),
              let to = ordered.firstIndex(of: visible[destinationIndex]) else { return false }
        let moved = ordered.remove(at: from)
        ordered.insert(moved, at: to)
        clipOrder = ordered
        return true
    }

    func segments(duration: CMTime) throws -> [CMTimeRange] {
        try timeline(duration: duration).ranges.flatMap { range in
            let boundaries = [range.start] + splits.filter {
                $0.isFinite && $0 > range.start.seconds && $0 < range.end.seconds
            }.sorted().map { CMTime(seconds: $0, preferredTimescale: 60000) } + [range.end]
            return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
                end > start ? CMTimeRange(start: start, end: end) : nil
            }
        }
    }

    mutating func split(at seconds: Double, duration: CMTime) -> Bool {
        guard seconds.isFinite,
              let segments = try? segments(duration: duration),
              segments.contains(where: { seconds - $0.start.seconds >= 1.0 / 30 && $0.end.seconds - seconds >= 1.0 / 30 }) else { return false }
        splits.append(seconds)
        splits.sort()
        return true
    }

    func timeline(duration: CMTime) throws -> EditedTimeline {
        let selection = try timeRange(duration: duration)
        var boundary = selection.start
        var ranges: [CMTimeRange] = []
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            guard cut.start.isFinite, cut.end.isFinite, cut.start >= 0, cut.end > cut.start else {
                throw VideoTrimError.invalidRange
            }
            let cutStart = CMTimeMaximum(selection.start, CMTime(seconds: cut.start, preferredTimescale: 60000))
            let cutEnd = CMTimeMinimum(selection.end, CMTime(seconds: cut.end, preferredTimescale: 60000))
            guard cutEnd > boundary, cutStart < selection.end else { continue }
            if cutStart > boundary { ranges.append(CMTimeRange(start: boundary, end: cutStart)) }
            boundary = CMTimeMaximum(boundary, cutEnd)
        }
        if boundary < selection.end { ranges.append(CMTimeRange(start: boundary, end: selection.end)) }
        guard !ranges.isEmpty else { throw VideoTrimError.emptySelection }
        if !clipOrder.isEmpty {
            ranges = clipOrder.flatMap { clip in
                ranges.compactMap { range in
                    let intersection = CMTimeRangeGetIntersection(clip, otherRange: range)
                    return intersection.duration > .zero ? intersection : nil
                }
            }
        }
        return EditedTimeline(ranges: ranges)
    }

    func timeRange(duration: CMTime) throws -> CMTimeRange {
        let seconds = duration.seconds
        let stop = end ?? seconds
        guard seconds.isFinite, seconds > 0, start.isFinite, stop.isFinite,
              start >= 0, start < seconds, stop > start else {
            throw VideoTrimError.invalidRange
        }
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                           end: stop >= seconds ? duration : CMTime(seconds: stop, preferredTimescale: 60000))
    }

    func export(source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let timeline = try timeline(duration: duration)
        guard timeline.ranges.count != 1 || timeline.ranges[0] != CMTimeRange(start: .zero, duration: duration) else { return source }
        let composition = AVMutableComposition()
        for sourceTrack in try await asset.load(.tracks) where sourceTrack.mediaType == .video || sourceTrack.mediaType == .audio {
            guard let track = composition.addMutableTrack(withMediaType: sourceTrack.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VideoTrimError.exportFailed
            }
            let sourceRange = try await sourceTrack.load(.timeRange)
            let range = CMTimeRangeGetIntersection(sourceRange, otherRange: CMTimeRange(start: .zero, duration: duration))
            if range.duration > .zero { try track.insertTimeRange(range, of: sourceTrack, at: range.start) }
            if sourceTrack.mediaType == .video { track.preferredTransform = try await sourceTrack.load(.preferredTransform) }
        }
        try timeline.apply(to: composition, sourceDuration: duration)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoTrimError.exportFailed
        }
        let output = source.deletingLastPathComponent()
            .appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)_trimmed_\(UUID().uuidString).mov")
        exporter.outputURL = output
        exporter.outputFileType = .mov
        exporter.timeRange = CMTimeRange(start: .zero, duration: timeline.duration)
        await exporter.export()
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw exporter.error ?? VideoTrimError.exportFailed
        }
        return output
    }
}

enum SilenceDetector {
    struct Settings: Equatable, Codable {
        var thresholdDB: Double = -42
        var minimumPause: Double = 0.8
        var padding: Double = 0.15
    }

    static func suggestions(source: URL, settings: Settings = .init()) async throws -> [VideoCut] {
        guard settings.thresholdDB.isFinite, (-80...0).contains(settings.thresholdDB),
              settings.minimumPause.isFinite, settings.minimumPause > 0,
              settings.padding.isFinite, settings.padding >= 0 else { throw CleanupError.invalidSettings }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CleanupError.noAudio }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw CleanupError.noAudio }
        let window = 0.02
        let binCount = Int(ceil(duration / window))
        var levels = [Double](repeating: 0, count: binCount)
        for track in tracks {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false
            ])
            guard reader.canAdd(output) else { throw CleanupError.readFailed }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CleanupError.readFailed }
            defer { reader.cancelReading() }
            var energy = [Double](repeating: 0, count: binCount)
            var counts = [Int](repeating: 0, count: binCount)
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample),
                      let description = CMSampleBufferGetFormatDescription(sample),
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { throw CleanupError.readFailed }
                let channels = Int(format.pointee.mChannelsPerFrame)
                let rate = format.pointee.mSampleRate
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard channels > 0, rate > 0, timestamp.isFinite else { throw CleanupError.readFailed }
                let length = CMBlockBufferGetDataLength(block)
                var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                let result = values.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                }
                guard result == noErr else { throw CleanupError.readFailed }
                for frame in 0..<(values.count / channels) {
                    let bin = Int(floor((timestamp + Double(frame) / rate) / window))
                    guard bin >= 0, bin < binCount else { continue }
                    var peakEnergy: Double = 0
                    for channel in 0..<channels {
                        let value = Double(values[frame * channels + channel])
                        guard value.isFinite else { throw CleanupError.readFailed }
                        peakEnergy = max(peakEnergy, value * value)
                    }
                    energy[bin] += peakEnergy
                    counts[bin] += 1
                }
            }
            guard reader.status == .completed else { throw reader.error ?? CleanupError.readFailed }
            for bin in levels.indices where counts[bin] > 0 {
                levels[bin] = max(levels[bin], energy[bin] / Double(counts[bin]))
            }
        }
        let threshold = pow(10, settings.thresholdDB / 10)
        guard levels.contains(where: { $0 > threshold }) else { throw CleanupError.noAudibleContent }
        var suggestions: [VideoCut] = []
        var silenceStart: Double?
        for bin in 0...binCount {
            let seconds = min(duration, Double(bin) * window)
            let silent = bin < binCount && levels[bin] <= threshold
            if silent, silenceStart == nil { silenceStart = seconds }
            if !silent, let start = silenceStart {
                let paddedStart = start == 0 ? start : start + settings.padding
                let paddedEnd = bin == binCount ? duration : seconds - settings.padding
                if seconds - start >= settings.minimumPause, paddedEnd > paddedStart {
                    suggestions.append(VideoCut(start: paddedStart, end: paddedEnd))
                }
                silenceStart = nil
            }
        }
        return suggestions
    }
}

enum CleanupError: LocalizedError {
    case noAudio, noAudibleContent, invalidSettings, readFailed

    var errorDescription: String? {
        switch self {
        case .noAudio: return "This recording has no audio to analyze."
        case .noAudibleContent: return "No sound above the threshold was found. No cuts were suggested."
        case .invalidSettings: return "Choose a valid silence threshold and minimum pause."
        case .readFailed: return "Audio could not be analyzed. The recording is unchanged."
        }
    }
}

enum VideoTrimError: LocalizedError {
    case invalidRange, emptySelection, exportFailed

    var errorDescription: String? {
        switch self {
        case .invalidRange: return "Choose an end time after the start, within the recording."
        case .emptySelection: return "Keep at least one section of the recording."
        case .exportFailed: return "The trimmed copy could not be exported. The original is unchanged."
        }
    }
}

/// Muxes video + audio tracks into a single .mov file.
/// Uses AVMutableComposition + AVAssetExportSession passthrough
/// so audio bytes are never decoded/re-encoded (no distortion).
enum MediaMuxer {

    /// Combines a video .mov with optional system audio and microphone audio
    /// into a single output .mov with all tracks embedded.
    /// - Returns: URL of the muxed file (replaces the original video-only file).
    static func mux(
        videoURL: URL,
        systemAudioURL: URL?,
        micAudioURL: URL?,
        voiceOverURL: URL? = nil,
        systemAudioStartOffset: CMTime = .zero,
        micAudioStartOffset: CMTime = .zero,
        removeSourceAudio: Bool = true
    ) async throws -> URL {
        let hasSystemAudio = systemAudioURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let hasMicAudio = micAudioURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let hasVoiceOver = voiceOverURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        guard hasSystemAudio || hasMicAudio || hasVoiceOver else {
            return videoURL
        }

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let videoDuration = try await videoAsset.load(.duration)

        // Add video track (passthrough)
        if let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first {
            guard let compVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw MuxerError.trackCreationFailed }

            try compVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoDuration),
                of: sourceVideoTrack,
                at: .zero
            )
        }

        // Carry over any existing audio tracks from the video file
        for existingAudioTrack in try await videoAsset.loadTracks(withMediaType: .audio) {
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try compTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoDuration),
                of: existingAudioTrack,
                at: .zero
            )
        }

        // Add sidecar audio tracks, trimmed to video duration
        if hasSystemAudio, let sysURL = systemAudioURL {
            let sysAsset = AVURLAsset(url: sysURL)
            let sysDuration = try await sysAsset.load(.duration)
            let offset = CMTimeMaximum(.zero, systemAudioStartOffset)
            let trimDuration = CMTimeMinimum(CMTimeSubtract(videoDuration, offset), sysDuration)

            if trimDuration > .zero, let sysTrack = try await sysAsset.loadTracks(withMediaType: .audio).first {
                guard let compTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { throw MuxerError.trackCreationFailed }

                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: trimDuration),
                    of: sysTrack,
                    at: offset
                )
            }
        }

        if hasMicAudio, let micURL = micAudioURL {
            let micAsset = AVURLAsset(url: micURL)
            let micDuration = try await micAsset.load(.duration)
            let offset = CMTimeMaximum(.zero, micAudioStartOffset)
            let trimDuration = CMTimeMinimum(CMTimeSubtract(videoDuration, offset), micDuration)

            if trimDuration > .zero, let micTrack = try await micAsset.loadTracks(withMediaType: .audio).first {
                guard let compTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { throw MuxerError.trackCreationFailed }

                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: trimDuration),
                    of: micTrack,
                    at: offset
                )
            }
        }

        if hasVoiceOver, let voiceOverURL {
            let voiceOverAsset = AVURLAsset(url: voiceOverURL)
            let voiceOverDuration = try await voiceOverAsset.load(.duration)
            let trimDuration = CMTimeMinimum(videoDuration, voiceOverDuration)

            if trimDuration > .zero, let voiceOverTrack = try await voiceOverAsset.loadTracks(withMediaType: .audio).first {
                guard let compTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { throw MuxerError.trackCreationFailed }

                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: trimDuration),
                    of: voiceOverTrack,
                    at: .zero
                )
            }
        }

        // Export with passthrough — no re-encoding, no audioMix
        let muxedURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent + "_muxed.mov")

        if FileManager.default.fileExists(atPath: muxedURL.path) {
            try FileManager.default.removeItem(at: muxedURL)
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MuxerError.exportSessionFailed
        }

        exporter.outputURL = muxedURL
        exporter.outputFileType = .mov

        await exporter.export()

        guard exporter.status == .completed else {
            Log.recording.error("Mux failed: \(exporter.error?.localizedDescription ?? "unknown")")
            throw exporter.error ?? MuxerError.exportFailed
        }

        // Replace original video file with the muxed version
        try FileManager.default.removeItem(at: videoURL)
        try FileManager.default.moveItem(at: muxedURL, to: videoURL)

        // Clean up sidecar audio files
        if removeSourceAudio, hasSystemAudio, let sysURL = systemAudioURL {
            try? FileManager.default.removeItem(at: sysURL)
        }
        if removeSourceAudio, hasMicAudio, let micURL = micAudioURL {
            try? FileManager.default.removeItem(at: micURL)
        }

        Log.recording.info("Muxed audio into \(videoURL.lastPathComponent)")
        return videoURL
    }
}

enum MuxerError: LocalizedError {
    case trackCreationFailed
    case exportSessionFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .trackCreationFailed: return "Failed to create composition track"
        case .exportSessionFailed: return "Failed to create export session"
        case .exportFailed: return "Audio muxing export failed"
        }
    }
}
