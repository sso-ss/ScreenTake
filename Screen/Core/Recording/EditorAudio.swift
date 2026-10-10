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

    static func insertRecordedAudio(into composition: AVMutableComposition, source: URL,
                                    clips: [MediaTimelineClip], duration: CMTime) async throws {
        let asset = AVURLAsset(url: source)
        for sourceTrack in try await asset.loadTracks(withMediaType: .audio) {
            guard let track = composition.addMutableTrack(withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VideoTrimError.exportFailed }
            let available = try await sourceTrack.load(.timeRange)
            for clip in clips.sorted(by: { $0.start < $1.start }) where clip.start < duration.seconds {
                let requested = CMTimeRange(start: time(clip.sourceStart),
                    duration: time(min(clip.duration, duration.seconds - clip.start)))
                let range = CMTimeRangeGetIntersection(requested, otherRange: available)
                if range.duration > .zero {
                    let position = CMTimeAdd(time(clip.start), CMTimeSubtract(range.start, requested.start))
                    try track.insertTimeRange(range, of: sourceTrack, at: position)
                }
            }
        }
    }

    static func export(video: URL, originalEnabled: Bool, originalVolume: Double,
                       clips: [VoiceOverClip], voiceOverVolume: Double,
                       recordedSource: URL? = nil, recordedClips: [MediaTimelineClip]? = nil) async throws -> URL {
        if recordedClips == nil && clips.isEmpty && originalEnabled && originalVolume == 1 { return video }
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for source in try await asset.load(.tracks) where source.mediaType == .video || (originalEnabled && recordedClips == nil && source.mediaType == .audio) {
            guard let track = composition.addMutableTrack(withMediaType: source.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VideoTrimError.exportFailed
            }
            let range = CMTimeRangeGetIntersection(try await source.load(.timeRange), otherRange: CMTimeRange(start: .zero, duration: duration))
            if range.duration > .zero { try track.insertTimeRange(range, of: source, at: range.start) }
            if source.mediaType == .video { track.preferredTransform = try await source.load(.preferredTransform) }
        }
        if originalEnabled, let recordedClips, let recordedSource {
            try await insertRecordedAudio(into: composition, source: recordedSource, clips: recordedClips, duration: duration)
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

/// Splitting the waveform lane reuses one decode of its immutable source media.
actor RecordedWaveformCache {
    static let shared = RecordedWaveformCache()
    private var tasks: [URL: Task<AudioWaveform, Error>] = [:]
    private var order: [URL] = []
    func load(_ url: URL) async throws -> AudioWaveform {
        if let task = tasks[url] { return try await task.value }
        let task = Task.detached(priority: .utility) { try await AudioWaveform.load(url) }
        tasks[url] = task; order.append(url)
        if order.count > 8 { tasks.removeValue(forKey: order.removeFirst()) }
        do { return try await task.value }
        catch { tasks.removeValue(forKey: url); order.removeAll { $0 == url }; throw error }
    }
}

/// Editable source audio and screen clips share link IDs, while each track owns its positions.
struct LinkedMediaTimeline: Equatable {
    enum Track { case screen, audio }
    var video: [MediaTimelineClip]
    var audio: [MediaTimelineClip]
    var duration: Double

    init(trim: VideoTrim, audioClips: [MediaTimelineClip]?, sourceDuration: Double, hasAudio: Bool) {
        let time = EditorAudio.time(sourceDuration)
        let timeline = try? trim.timeline(duration: time)
        if let clips = trim.clips {
            video = clips.sorted { $0.start < $1.start }
        } else {
            let ranges = (try? trim.segments(duration: time)) ?? []
            video = ranges.enumerated().map { index, range in
                let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index + 1))!
                return MediaTimelineClip(id: id, start: timeline?.outputTime(at: range.start).seconds ?? 0,
                    sourceStart: range.start.seconds, duration: range.duration.seconds, linkID: hasAudio ? id : nil)
            }
        }
        audio = audioClips ?? (hasAudio ? video.enumerated().map { index, clip in
            var copy = clip
            copy.id = UUID(uuidString: String(format: "00000000-0000-4000-9000-%012x", index + 1))!
            return copy
        } : [])
        duration = max(timeline?.duration.seconds ?? 0, audio.map(\.end).max() ?? 0)
    }

    func clips(on track: Track) -> [MediaTimelineClip] { track == .screen ? video : audio }
    func clip(_ id: UUID, on track: Track) -> MediaTimelineClip? { clips(on: track).first { $0.id == id } }
    func partner(of clip: MediaTimelineClip, on track: Track) -> MediaTimelineClip? {
        guard let link = clip.linkID else { return nil }
        return clips(on: track == .screen ? .audio : .screen).first { $0.linkID == link }
    }
    func linkCandidate(for clip: MediaTimelineClip, on track: Track) -> MediaTimelineClip? {
        clips(on: track == .screen ? .audio : .screen).first {
            $0.linkID == nil && abs($0.start - clip.start) < 0.001
                && abs($0.sourceStart - clip.sourceStart) < 0.001 && abs($0.duration - clip.duration) < 0.001
        }
    }
    mutating func toggleLink(_ id: UUID, on track: Track) -> Bool {
        guard let selected = clip(id, on: track) else { return false }
        if let linked = partner(of: selected, on: track) {
            change(id, on: track) { $0.linkID = nil }
            change(linked.id, on: track == .screen ? .audio : .screen) { $0.linkID = nil }
        } else {
            guard let other = linkCandidate(for: selected, on: track) else { return false }
            let link = UUID()
            change(id, on: track) { $0.linkID = link }
            change(other.id, on: track == .screen ? .audio : .screen) { $0.linkID = link }
        }
        return true
    }
    mutating func split(_ id: UUID, on track: Track, at seconds: Double) -> Bool {
        guard let selected = clip(id, on: track), seconds.isFinite,
              seconds - selected.start >= 1.0 / 30, selected.end - seconds >= 1.0 / 30 else { return false }
        let other = partner(of: selected, on: track)
        let link = other == nil ? nil : UUID()
        func splitClip(_ clip: MediaTimelineClip) -> (MediaTimelineClip, MediaTimelineClip) {
            var left = clip, right = clip
            left.duration = seconds - clip.start
            right.id = UUID(); right.linkID = link
            right.start = seconds; right.sourceStart += left.duration; right.duration -= left.duration
            return (left, right)
        }
        let (left, right) = splitClip(selected)
        change(id, on: track) { $0 = left }; append(right, on: track)
        if let other {
            let (left, right) = splitClip(other)
            let otherTrack: Track = track == .screen ? .audio : .screen
            change(other.id, on: otherTrack) { $0 = left }; append(right, on: otherTrack)
        }
        sort()
        return true
    }
    mutating func delete(_ id: UUID, on track: Track, closeGaps: Bool) -> Bool {
        guard let selected = clip(id, on: track) else { return false }
        let other = partner(of: selected, on: track)
        guard (track != .screen && other == nil) || video.count > 1 else { return false }
        let old = self
        func removing(_ clips: [MediaTimelineClip], id: UUID) -> [MediaTimelineClip] {
            clips.filter { $0.id != id }.map { clip in
                var result = clip
                if closeGaps && clip.start >= selected.end - 0.000001 { result.start -= selected.duration }
                return result
            }
        }
        if track == .screen {
            video = removing(video, id: id)
            if let other { audio = removing(audio, id: other.id) }
        } else {
            audio = removing(audio, id: id)
            if let other { video = removing(video, id: other.id) }
        }
        // Rippling a single lane must never silently leave a stale link to a displaced partner.
        clearMismatchedLinks()
        if !validPositions { self = old; return false }
        if closeGaps { duration = max(video.map(\.end).max() ?? 0, audio.map(\.end).max() ?? 0) }
        sort()
        return true
    }
    mutating func move(_ id: UUID, on track: Track, by delta: Double) -> Bool {
        guard let selected = clip(id, on: track), delta.isFinite else { return false }
        let other = partner(of: selected, on: track)
        var lower = -selected.start, upper = Double.infinity
        func constrain(_ clips: [MediaTimelineClip], selected: MediaTimelineClip) {
            for clip in clips where clip.id != selected.id {
                if clip.end <= selected.start + 0.000001 { lower = max(lower, clip.end - selected.start) }
                if clip.start >= selected.end - 0.000001 { upper = min(upper, clip.start - selected.end) }
            }
        }
        constrain(clips(on: track), selected: selected)
        if let other { constrain(clips(on: track == .screen ? .audio : .screen), selected: other) }
        let shift = min(upper, max(lower, delta))
        guard abs(shift) > 0.000001 else { return false }
        change(id, on: track) { $0.start += shift }
        if let other { change(other.id, on: track == .screen ? .audio : .screen) { $0.start += shift } }
        duration = max(duration, selected.end + shift)
        sort(); return true
    }
    mutating func trim(_ id: UUID, on track: Track, beginning: Bool, by delta: Double, sourceDuration: Double,
                       closeGaps: Bool = false) -> Bool {
        guard let selected = clip(id, on: track), delta.isFinite else { return false }
        let other = partner(of: selected, on: track)
        let previous = clips(on: track).filter { $0.id != id && $0.end <= selected.start + 0.000001 }.map(\.end).max() ?? 0
        let next = clips(on: track).filter { $0.id != id && $0.start >= selected.end - 0.000001 }.map(\.start).min() ?? .infinity
        var lower: Double, upper: Double
        if beginning {
            lower = closeGaps ? -selected.sourceStart : max(previous - selected.start, -selected.sourceStart)
            upper = selected.duration - 1.0 / 30
        } else {
            lower = 1.0 / 30 - selected.duration
            upper = closeGaps ? sourceDuration - selected.sourceStart - selected.duration
                : min(next - selected.end, sourceDuration - selected.sourceStart - selected.duration)
        }
        if let other {
            let otherClips = clips(on: track == .screen ? .audio : .screen)
            if beginning {
                let boundary = otherClips.filter { $0.id != other.id && $0.end <= other.start + 0.000001 }.map(\.end).max() ?? 0
                lower = closeGaps ? max(lower, -other.sourceStart) : max(lower, boundary - other.start, -other.sourceStart)
            } else {
                let boundary = otherClips.filter { $0.id != other.id && $0.start >= other.end - 0.000001 }.map(\.start).min() ?? .infinity
                if !closeGaps { upper = min(upper, boundary - other.end) }
            }
        }
        let shift = min(upper, max(lower, delta))
        guard abs(shift) > 0.000001 else { return false }
        func adjust(_ clip: inout MediaTimelineClip) {
            if beginning { if !closeGaps { clip.start += shift }; clip.sourceStart += shift; clip.duration -= shift }
            else { clip.duration += shift }
        }
        let old = self
        change(id, on: track, adjust)
        if let other { change(other.id, on: track == .screen ? .audio : .screen, adjust) }
        if closeGaps {
            let offset = beginning ? -shift : shift
            func shifting(_ clips: [MediaTimelineClip], selectedID: UUID) -> [MediaTimelineClip] {
                clips.map { clip in
                    var result = clip
                    if clip.id != selectedID && clip.start >= selected.end - 0.000001 { result.start += offset }
                    return result
                }
            }
            if track == .screen {
                video = shifting(video, selectedID: id)
                if let other { audio = shifting(audio, selectedID: other.id) }
            } else {
                audio = shifting(audio, selectedID: id)
                if let other { video = shifting(video, selectedID: other.id) }
            }
            clearMismatchedLinks()
            if !validPositions { self = old; return false }
            duration = max(video.map(\.end).max() ?? 0, audio.map(\.end).max() ?? 0)
        } else { duration = max(duration, video.map(\.end).max() ?? 0, audio.map(\.end).max() ?? 0) }
        sort(); return true
    }
    /// Reorder contiguous clips while retaining gaps and updating linked audio partners.
    mutating func reorderVideo(from: Int, to: Int) -> Bool {
        guard video.indices.contains(from), video.indices.contains(to), from != to else { return false }
        let old = self
        var order = video
        let moved = order.remove(at: from); order.insert(moved, at: to)
        let lower = min(from, to), upper = max(from, to)
        var position = video[lower].start
        for index in lower...upper {
            let original = order[index]
            order[index].start = position
            if let partner = partner(of: original, on: .screen) {
                change(partner.id, on: .audio) { $0.start = position }
            }
            position += original.duration
            if index < upper { position += max(0, video[index + 1].start - video[index].end) }
        }
        video = order; clearMismatchedLinks(); sort()
        guard validPositions else { self = old; return false }
        return true
    }
    /// Source-based silence cuts use the same link and ripple rules as manual deletion.
    mutating func cutSources(_ cuts: [VideoCut], closeGaps: Bool) -> Bool {
        let old = self
        for cut in cuts {
            guard cut.start.isFinite, cut.end.isFinite, cut.start >= 0, cut.end > cut.start else { self = old; return false }
            for clip in video.reversed() {
                let lower = max(clip.sourceStart, cut.start), upper = min(clip.sourceStart + clip.duration, cut.end)
                guard upper > lower else { continue }
                let outputStart = clip.start + lower - clip.sourceStart
                let outputEnd = clip.start + upper - clip.sourceStart
                let partner = partner(of: clip, on: .screen)
                var pieces: [MediaTimelineClip] = []
                if lower > clip.sourceStart {
                    var left = clip; left.duration = lower - clip.sourceStart; pieces.append(left)
                }
                if upper < clip.sourceStart + clip.duration {
                    var right = clip
                    if !pieces.isEmpty { right.id = UUID(); right.linkID = partner == nil ? nil : UUID() }
                    right.start = outputEnd; right.sourceStart = upper
                    right.duration = clip.sourceStart + clip.duration - upper
                    pieces.append(right)
                }
                video.removeAll { $0.id == clip.id }; video += pieces
                if let partner {
                    audio.removeAll { $0.id == partner.id }
                    audio += pieces.enumerated().map { index, piece in
                        var audioPiece = piece
                        audioPiece.id = index == 0 ? partner.id : UUID()
                        return audioPiece
                    }
                }
                if closeGaps {
                    let length = outputEnd - outputStart
                    video = video.map { var c = $0; if c.start >= outputEnd - 0.000001 { c.start -= length }; return c }
                    if partner != nil {
                        audio = audio.map { var c = $0; if c.start >= outputEnd - 0.000001 { c.start -= length }; return c }
                    }
                }
                sort()
            }
        }
        clearMismatchedLinks()
        guard !video.isEmpty, validPositions else { self = old; return false }
        if closeGaps { duration = max(video.map(\.end).max() ?? 0, audio.map(\.end).max() ?? 0) }
        return self != old
    }
    private var validPositions: Bool {
        [video, audio].allSatisfy { clips in
            let ordered = clips.sorted { $0.start < $1.start }
            return ordered.allSatisfy { $0.start >= 0 && $0.duration > 0 }
                && zip(ordered, ordered.dropFirst()).allSatisfy { $0.end <= $1.start + 0.000001 }
        }
    }
    private mutating func clearMismatchedLinks() {
        let valid = Set(video.compactMap { clip -> UUID? in
            guard let partner = partner(of: clip, on: .screen),
                  abs(partner.start - clip.start) < 0.001, abs(partner.sourceStart - clip.sourceStart) < 0.001,
                  abs(partner.duration - clip.duration) < 0.001 else { return nil }
            return clip.linkID
        })
        video = video.map { var c = $0; if let link = c.linkID, !valid.contains(link) { c.linkID = nil }; return c }
        audio = audio.map { var c = $0; if let link = c.linkID, !valid.contains(link) { c.linkID = nil }; return c }
    }
    private mutating func change(_ id: UUID, on track: Track, _ update: (inout MediaTimelineClip) -> Void) {
        if track == .screen, let index = video.firstIndex(where: { $0.id == id }) { update(&video[index]) }
        if track == .audio, let index = audio.firstIndex(where: { $0.id == id }) { update(&audio[index]) }
    }
    private mutating func append(_ clip: MediaTimelineClip, on track: Track) {
        if track == .screen { video.append(clip) } else { audio.append(clip) }
    }
    private mutating func sort() { video.sort { $0.start < $1.start }; audio.sort { $0.start < $1.start } }
}
