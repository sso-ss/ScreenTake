import AVFoundation

/// Narration is positioned on the edited video's timeline, independent of source clip order.
struct VoiceOverClip: Equatable, Identifiable, Codable {
    var id = UUID()
    var url: URL
    var start: Double = 0
    var sourceStart: Double = 0
    var duration: Double
    var sourceDuration: Double

    var end: Double { start + duration }
}

enum EditorAudio {
    /// Shared by playback and export so timing, trimming and levels match.
    static func mix(into composition: AVMutableComposition, duration: CMTime,
                    originalVolume: Double, clips: [VoiceOverClip], voiceOverVolume: Double) async throws -> AVAudioMix {
        var parameters = composition.tracks(withMediaType: .audio).map { track in
            let parameter = AVMutableAudioMixInputParameters(track: track)
            parameter.setVolume(Float(max(0, min(1, originalVolume))), at: .zero)
            return parameter
        }
        for clip in clips {
            try Task.checkCancellation()
            guard clip.start.isFinite, clip.sourceStart.isFinite, clip.duration.isFinite,
                  clip.start >= 0, clip.sourceStart >= 0, clip.duration > 0 else { throw VideoTrimError.invalidRange }
            guard clip.start < duration.seconds else { continue }
            let asset = AVURLAsset(url: clip.url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { throw CleanupError.noAudio }
            let requested = CMTimeRange(start: time(clip.sourceStart),
                                        duration: time(min(clip.duration, duration.seconds - clip.start)))
            for source in tracks {
                let range = CMTimeRangeGetIntersection(requested, otherRange: try await source.load(.timeRange))
                guard range.duration > .zero else { continue }
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw VideoTrimError.exportFailed
                }
                let position = CMTimeAdd(time(clip.start), CMTimeSubtract(range.start, requested.start))
                try track.insertTimeRange(range, of: source, at: position)
                let parameter = AVMutableAudioMixInputParameters(track: track)
                parameter.setVolume(Float(max(0, min(1, voiceOverVolume))), at: .zero)
                parameters.append(parameter)
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    static func export(video: URL, originalEnabled: Bool, originalVolume: Double,
                       clips: [VoiceOverClip], voiceOverVolume: Double) async throws -> URL {
        if clips.isEmpty && originalEnabled && originalVolume == 1 { return video }
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for source in try await asset.load(.tracks) where source.mediaType == .video || (originalEnabled && source.mediaType == .audio) {
            guard let track = composition.addMutableTrack(withMediaType: source.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VideoTrimError.exportFailed
            }
            let range = CMTimeRangeGetIntersection(try await source.load(.timeRange), otherRange: CMTimeRange(start: .zero, duration: duration))
            if range.duration > .zero { try track.insertTimeRange(range, of: source, at: range.start) }
            if source.mediaType == .video { track.preferredTransform = try await source.load(.preferredTransform) }
        }
        let mix = try await mix(into: composition, duration: duration, originalVolume: originalVolume,
                                clips: clips, voiceOverVolume: voiceOverVolume)
        // An audio mix requires encoding; passthrough would ignore volume changes.
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoTrimError.exportFailed
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenTake-audio-\(UUID().uuidString).mov")
        exporter.outputURL = output
        exporter.outputFileType = .mov
        exporter.timeRange = CMTimeRange(start: .zero, duration: duration)
        exporter.audioMix = mix
        await withTaskCancellationHandler {
            await exporter.export()
        } onCancel: {
            exporter.cancelExport()
        }
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw exporter.error ?? VideoTrimError.exportFailed
        }
        return output
    }

    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60000) }
}

struct AudioWaveform {
    let duration: Double
    let peaks: [Float]

    func level(at seconds: Double) -> Float {
        guard duration > 0, seconds >= 0, seconds < duration, !peaks.isEmpty else { return 0 }
        return peaks[min(peaks.count - 1, Int(seconds / duration * Double(peaks.count)))]
    }

    /// Fixed-size peak storage keeps even long recordings bounded in memory.
    static func load(_ url: URL) async throws -> AudioWaveform {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CleanupError.noAudio }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw CleanupError.noAudio }
        let count = min(12000, max(256, Int(min(duration, 600) * 20)))
        var peaks = [Float](repeating: 0, count: count)
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000,
                AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false
            ])
            guard reader.canAdd(output) else { throw CleanupError.readFailed }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CleanupError.readFailed }
            defer { reader.cancelReading() }
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample),
                      let format = CMSampleBufferGetFormatDescription(sample),
                      let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { continue }
                let channels = Int(description.pointee.mChannelsPerFrame)
                let rate = description.pointee.mSampleRate
                let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard channels > 0, rate > 0, start.isFinite else { continue }
                let length = CMBlockBufferGetDataLength(block)
                guard length > 0 else { continue }
                var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                let status = values.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                }
                guard status == noErr else { throw CleanupError.readFailed }
                for frame in 0..<(values.count / channels) {
                    let seconds = start + Double(frame) / rate
                    guard seconds >= 0, seconds < duration else { continue }
                    let bin = min(count - 1, Int(seconds / duration * Double(count)))
                    for channel in 0..<channels {
                        let value = abs(values[frame * channels + channel])
                        if value.isFinite { peaks[bin] = max(peaks[bin], min(1, value)) }
                    }
                }
            }
            guard reader.status == .completed else { throw reader.error ?? CleanupError.readFailed }
        }
        return AudioWaveform(duration: duration, peaks: peaks)
    }
}
