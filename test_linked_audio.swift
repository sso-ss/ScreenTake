import AppKit
import AVFoundation
import CoreImage

@main
struct LinkedAudioChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func model() -> LinkedMediaTimeline {
        LinkedMediaTimeline(trim: VideoTrim(splits: [1, 2]), audioClips: nil, sourceDuration: 3, hasAudio: true)
    }
    static func trim(_ model: LinkedMediaTimeline) -> VideoTrim {
        var result = VideoTrim(); result.clips = model.video; result.timelineLength = model.duration; return result
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        var linked = model()
        check(linked.video.count == 3 && linked.audio.count == 3, "Legacy splits must migrate to paired tracks")
        check(linked.video.allSatisfy { linked.partner(of: $0, on: .screen) != nil }, "Default must be linked")
        let middle = linked.video[1]
        check(linked.delete(middle.id, on: .screen, closeGaps: true), "Linked ripple delete")
        check(linked.video.map(\.start) == [0, 1] && linked.audio.map(\.start) == [0, 1] && linked.duration == 2,
              "Ripple must close both tracks together")
        check(linked.video.map(\.sourceStart) == [0, 2], "Ripple must retain original source times")
        var gaps = model()
        check(gaps.delete(gaps.video[1].id, on: .screen, closeGaps: false), "Linked fixed-position delete")
        check(gaps.video.map(\.start) == [0, 2] && gaps.audio.map(\.start) == [0, 2] && gaps.duration == 3,
              "Deleting without gap closing must preserve later positions")
        let timeline = try trim(gaps).timeline(duration: EditorAudio.time(3))
        check(timeline.hasGaps && !timeline.sourceTime(at: EditorAudio.time(1.5)).isNumeric, "Gap must not sample a stale source frame")
        check(timeline.outputTime(at: EditorAudio.time(2.5)).seconds == 2.5, "Seeking must account for gaps")
        var unlinked = model()
        check(unlinked.toggleLink(unlinked.audio[1].id, on: .audio), "Unlink selected pair")
        let audioID = unlinked.audio[1].id
        check(unlinked.delete(audioID, on: .audio, closeGaps: false), "Independent audio delete")
        check(unlinked.video.count == 3 && unlinked.audio.map(\.start) == [0, 2], "Deleting unlinked audio must leave all video in place")
        var independentRipple = model()
        let videoID = independentRipple.video[1].id
        check(independentRipple.toggleLink(videoID, on: .screen), "Unlink screen pair")
        check(independentRipple.delete(videoID, on: .screen, closeGaps: true), "Independent screen ripple")
        check(independentRipple.video.map(\.start) == [0, 1] && independentRipple.audio.map(\.start) == [0, 1, 2],
              "Unlinked ripple must move only video")
        check(independentRipple.duration == 3, "Independent audio must retain its duration")
        var split = model()
        check(split.split(split.audio[1].id, on: .audio, at: 1.5), "Linked split from audio selection")
        check(split.video.count == 4 && split.audio.count == 4, "Linked split must split both tracks")
        check(split.video.allSatisfy { split.partner(of: $0, on: .screen) != nil }, "Split must preserve links on both resulting halves")
        let leftAudio = split.audio[1].id
        check(split.toggleLink(leftAudio, on: .audio), "Unlink split audio")
        check(split.split(leftAudio, on: .audio, at: 1.25), "Independent audio split")
        check(split.video.count == 4 && split.audio.count == 5, "Independent split must leave video intact")
        var trimmedPair = model()
        let trimID = trimmedPair.video[0].id
        check(trimmedPair.trim(trimID, on: .screen, beginning: true, by: 0.2, sourceDuration: 3, closeGaps: true), "Ripple trim beginning")
        check(abs(trimmedPair.duration - 2.8) < 0.001 && trimmedPair.video[0].start == 0
              && abs(trimmedPair.audio[0].sourceStart - 0.2) < 0.001, "Linked ripple trim must shorten both lanes without a leading gap")
        check(trimmedPair.trim(trimID, on: .screen, beginning: true, by: -0.2, sourceDuration: 3, closeGaps: true), "Restore trimmed beginning")
        check(abs(trimmedPair.duration - 3) < 0.001 && trimmedPair.video[0].sourceStart == 0, "Ripple trim must restore source footage")
        var moved = gaps
        let first = moved.audio[0].id
        check(moved.move(first, on: .audio, by: 0.25), "Linked audio move")
        check(moved.video[0].start == 0.25 && moved.audio[0].start == 0.25, "Moving linked audio must move video")
        check(moved.trim(first, on: .audio, beginning: true, by: 0.2, sourceDuration: 3), "Linked audio edge trim")
        check(abs(moved.video[0].sourceStart - 0.2) < 0.001 && abs(moved.audio[0].sourceStart - 0.2) < 0.001,
              "Linked trim must update both source ranges")
        check(moved.toggleLink(first, on: .audio), "Unlink for isolated trim")
        let untouched = moved.video
        check(moved.trim(first, on: .audio, beginning: false, by: -0.2, sourceDuration: 3), "Unlinked audio edge trim")
        check(moved.video == untouched, "Independent trim must leave video untouched")
        check(!moved.toggleLink(first, on: .audio), "Misaligned clips must not relink")
        var reordered = model()
        check(reordered.reorderVideo(from: 2, to: 0), "Linked video reorder")
        check(reordered.video.map(\.sourceStart) == [2, 0, 1] && reordered.audio.map(\.sourceStart) == [2, 0, 1],
              "Reorder must carry matching audio")
        var cuts = model()
        check(cuts.cutSources([VideoCut(start: 0.5, end: 1.5)], closeGaps: true), "Silence cleanup on materialized tracks")
        check(cuts.duration == 2 && cuts.video.allSatisfy { cuts.partner(of: $0, on: .screen) != nil }, "Silence cleanup must preserve links")
        var one = LinkedMediaTimeline(trim: VideoTrim(), audioClips: nil, sourceDuration: 3, hasAudio: true)
        check(!one.delete(one.video[0].id, on: .screen, closeGaps: true), "Last video section cannot be deleted")
        check(one.toggleLink(one.audio[0].id, on: .audio), "Unlink sole audio")
        check(one.delete(one.audio[0].id, on: .audio, closeGaps: false) && one.audio.isEmpty,
              "All audio may be removed independently")
        print("PASS: linked/unlinked split, delete, ripple, fixed positions, move, trim, relink, reorder, and silence cuts")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linked-audio-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeVideo(source)
        let audio = directory.appendingPathComponent("audio.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<144000 {
            buffer.floatChannelData![0][index] = Float((index < 48000 ? 0.2 : index < 96000 ? 0.4 : 0.6) * sin(Double(index) * 2 * .pi * 440 / 48000))
        }
        try AVAudioFile(forWriting: audio, settings: format.settings).write(from: buffer)
        var settings = VideoEditSettings(backgroundEnabled: false, showCursor: false)
        settings.trim = trim(gaps); settings.recordedAudioClips = gaps.audio; settings.closeTimelineGaps = false
        try settings.validate(duration: 3)
        let saved = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(VideoEditSettings.self, from: saved)
        check(restored == settings, "Project settings must persist tracks, links, gaps and gap closing")
        let legacy = try JSONDecoder().decode(VideoEditSettings.self, from: JSONEncoder().encode(VideoEditSettings()))
        check(legacy.recordedAudioClips == nil && legacy.closesTimelineGaps, "Older projects must default to linked / close gaps")
        var legacyJSON = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        legacyJSON.removeValue(forKey: "recordedAudioClips"); legacyJSON.removeValue(forKey: "closeTimelineGaps")
        legacyJSON["trim"] = ["start": 0, "cuts": [], "splits": []]
        let migrated = try JSONDecoder().decode(VideoEditSettings.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        check(migrated.trim.clips == nil && migrated.recordedAudioClips == nil && migrated.closesTimelineGaps,
              "Projects saved before this feature must remain readable")
        let preview = try await LiveVideoPreview.makeItem(.init(source: source, audio: audio, mouse: nil, webcam: nil, settings: settings))
        try await verify(preview.asset, composition: preview.videoComposition, mix: preview.audioMix, expectSilence: true)
        print("PASS: middle-gap preview pixels and sound")
        let trimmed = try await settings.trim.export(source: source)
        let exported = try await EditorAudio.export(video: trimmed, originalEnabled: true, originalVolume: 1,
            clips: [], voiceOverVolume: 1, recordedSource: audio, recordedClips: settings.recordedAudioClips)
        try await verify(AVURLAsset(url: exported), expectSilence: true)
        print("PASS: middle-gap exported pixels and sound")
        settings.trim = trim(independentRipple); settings.recordedAudioClips = independentRipple.audio
        let independentPreview = try await LiveVideoPreview.makeItem(.init(source: source, audio: audio, mouse: nil, webcam: nil, settings: settings))
        try await verify(independentPreview.asset, composition: independentPreview.videoComposition,
                         mix: independentPreview.audioMix, expectSilence: false, videoChannels: [0, 2, -1])
        print("PASS: trailing-gap preview pixels and independent sound")
        let independentVideo = try await settings.trim.export(source: source)
        let independentExport = try await EditorAudio.export(video: independentVideo, originalEnabled: true, originalVolume: 1,
            clips: [], voiceOverVolume: 1, recordedSource: audio, recordedClips: settings.recordedAudioClips)
        try await verify(AVURLAsset(url: independentExport), expectSilence: false, videoChannels: [0, 2, -1])
        print("PASS: preview/export black gaps, silence, independent audio timing, and settings persistence")

        let session = EditorSession()
        let muxed = try await MediaMuxer.mux(videoURL: source, systemAudioURL: audio, micAudioURL: nil, removeSourceAudio: false)
        try await session.openVideo(muxed)
        let initial = session.draft
        let id = session.mediaTimeline.video[0].id
        check(session.editMediaTimeline { $0.split(id, on: .screen, at: 1) }, "Session split")
        let edited = session.draft
        check(session.undoEdits.count == 1, "Paired edit must create one Undo step")
        session.selectedRecordedAudioID = session.mediaTimeline.audio[0].id
        session.undo()
        check(session.draft == initial && session.selectedRecordedAudioID == nil, "Undo must restore both tracks and clear stale selection")
        session.redo(); check(session.draft == edited, "Redo must restore links and positions")
        try session.updateEdits { $0.trim.cuts.append(VideoCut(start: 1.5, end: 2)) }
        check(abs(session.editedDuration - 2.5) < 0.001, "Existing source-based commands must honor the materialized timeline")
        await session.waitForPreview()
        check(session.previewReady && session.previewError == nil, "Session preview must rebuild")
        let package = directory.appendingPathComponent("edited.screentake")
        try await session.saveProject(to: package)
        let reopened = EditorSession(); try await reopened.openProject(package)
        check(reopened.draft.trim == session.draft.trim && reopened.draft.recordedAudioClips == session.draft.recordedAudioClips,
              "Project reopen must preserve independent tracks")
        try reopened.updateEdits {
            $0.trim = trim(independentRipple)
            $0.recordedAudioClips = independentRipple.audio
        }
        let rendered = try await reopened.applyChanges()
        try await verify(AVURLAsset(url: rendered), expectSilence: false, videoChannels: [0, 2, -1])
        print("PASS: session Undo/Redo, existing commands, preview rebuild, project save/reopen, and actual editor export")
    }
    static func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input); check(writer.startWriting(), "Video writer")
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for index in 0..<90 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &pixel)
            context.render(CIImage(color: index < 30 ? .red : index < 60 ? .green : .blue), to: pixel!)
            check(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)), "Append video frame")
        }
        input.markAsFinished(); writer.endSession(atSourceTime: EditorAudio.time(3)); await writer.finishWriting()
        check(writer.status == .completed, "Finish video")
    }
    static func verify(_ asset: AVAsset, composition: AVVideoComposition? = nil, mix: AVAudioMix? = nil, expectSilence: Bool, videoChannels: [Int] = [0, -1, 2]) async throws {
        let duration = try await asset.load(.duration).seconds
        check(abs(duration - 3) < 0.05, "Gap must retain output length")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition; generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for (seconds, channel) in zip([0.5, 1.5, 2.5], videoChannels) {
            let image = try await generator.image(at: EditorAudio.time(seconds)).image
            let context = CIContext()
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 80, y: 45, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            if channel < 0 { check(pixel[0] < 25 && pixel[1] < 25 && pixel[2] < 25, "Deleted video must show black, not a frozen frame") }
            else { check(pixel[channel] > 150, "Video after gap must retain source frame") }
        }
        try await verifyAudio(asset, mix: mix, expectSilence: expectSilence)
    }
    static func verifyAudio(_ asset: AVAsset, mix: AVAudioMix? = nil, expectSilence: Bool) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        check(!tracks.isEmpty, "Recorded audio tracks must exist")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false])
        output.audioMix = mix; reader.add(output); check(reader.startReading(), "Audio reader")
        var values = [Float](repeating: 0, count: 144000)
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            let offset = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 48000).rounded())
            for index in chunk.indices where values.indices.contains(offset + index) { values[offset + index] = chunk[index] }
        }
        check(reader.status == .completed, "Read complete audio")
        func rms(_ start: Double) -> Double {
            let samples = values[Int(start * 48000)..<Int((start + 0.2) * 48000)]
            return sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count))
        }
        check(abs(rms(0.4) - 0.1414) < 0.025 && abs(rms(2.4) - 0.4243) < 0.025, "Source audio placement must match")
        check(expectSilence ? rms(1.4) < 0.01 : abs(rms(1.4) - 0.2828) < 0.025,
              "Gap audio must be silent only when linked audio was removed")
    }
}
