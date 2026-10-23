import AVFoundation

@main
struct SilenceCleanupTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("silence-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func audio(name: String, silent: Bool, quiet: Bool = false, fillMiddle: Bool = false) throws -> URL {
            let url = directory.appendingPathComponent(name + ".wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240000)!
            buffer.frameLength = 240000
            for index in 0..<240000 {
                let seconds = Double(index) / 48000
                let active = fillMiddle ? (2..<3).contains(seconds) : ((1..<2).contains(seconds) || (3..<4).contains(seconds))
                let value = !silent && active ? Float(sin(seconds * 440 * 2 * .pi) * (quiet ? 0.02 : 0.2)) : 0
                buffer.floatChannelData![0][index] = value
                buffer.floatChannelData![1][index] = -value
            }
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
            return url
        }
        let source = try audio(name: "pauses", silent: false)
        let original = try Data(contentsOf: source)
        let cuts = try await SilenceDetector.suggestions(source: source)
        precondition(cuts.count == 3, "Expected leading, middle and trailing silence")
        for (cut, expected) in zip(cuts, [(0.0, 0.85), (2.15, 2.85), (4.15, 5.0)]) {
            precondition(abs(cut.start - expected.0) < 0.04 && abs(cut.end - expected.1) < 0.04)
        }
        let timeline = try VideoTrim(cuts: cuts).timeline(duration: CMTime(seconds: 5, preferredTimescale: 600))
        precondition(abs(timeline.duration.seconds - 2.6) < 0.08)
        let cleaned = try await VideoTrim(cuts: cuts).export(source: source)
        let cleanedDuration = try await AVURLAsset(url: cleaned).load(.duration)
        precondition(abs(cleanedDuration.seconds - timeline.duration.seconds) < 0.002)
        let secondAudio = try audio(name: "other-track", silent: false, fillMiddle: true)
        let composition = AVMutableComposition()
        for url in [source, secondAudio] {
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .audio)[0]
            let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600)), of: track, at: .zero)
        }
        let mixedURL = directory.appendingPathComponent("multiple-tracks.mov")
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        exporter.outputURL = mixedURL
        exporter.outputFileType = .mov
        await exporter.export()
        precondition(exporter.status == .completed)
        let mixedCuts = try await SilenceDetector.suggestions(source: mixedURL)
        precondition(mixedCuts.count == 2, "Sound in a second track must protect a pause from removal")
        var rearranged = VideoTrim()
        rearranged.clips = [MediaTimelineClip(start: 0, sourceStart: 3, duration: 2, linkID: UUID()),
                            MediaTimelineClip(start: 2, sourceStart: 0, duration: 3, linkID: UUID())]
        let take = VoiceOverClip(url: source, start: 0.5, sourceStart: 1, duration: 3, sourceDuration: 5)
        let review = SilenceReview()
        review.analyze(audio: source, clip: take, trim: rearranged,
                       recordedAudioClips: nil, duration: 5)
        while review.analyzing { try await Task.sleep(nanoseconds: 10_000_000) }
        let takeSuggestions = review.suggestions
        precondition(takeSuggestions.count == 2, "A pause spanning video clips must be split for review")
        precondition(abs(takeSuggestions[0].start - 1.65) < 0.04 && abs(takeSuggestions[0].end - 2) < 0.04)
        precondition(abs(takeSuggestions[1].start - 2) < 0.04 && abs(takeSuggestions[1].end - 2.35) < 0.04)
        var linked = LinkedMediaTimeline(trim: rearranged, audioClips: nil, sourceDuration: 5, hasAudio: true)
        precondition(linked.cutOutput([VideoCut(start: 1.5, end: 2.5)]))
        precondition(abs(linked.duration - 4) < 0.001 && linked.video.count == 2)
        precondition(abs(linked.video[0].duration - 1.5) < 0.001)
        precondition(abs(linked.video[1].start - 1.5) < 0.001 && abs(linked.video[1].sourceStart - 0.5) < 0.001)
        precondition(linked.audio.count == 2 && linked.audio.allSatisfy { $0.linkID != nil })
        let trimmedTakes = VoiceOverClip.removing([VideoCut(start: 1.5, end: 2.5)], from: [take])
        precondition(trimmedTakes.count == 2)
        precondition(abs(trimmedTakes[0].duration - 1) < 0.001)
        precondition(abs(trimmedTakes[1].start - 1.5) < 0.001 && abs(trimmedTakes[1].sourceStart - 3) < 0.001)
        let quiet = try audio(name: "quiet-speech", silent: false, quiet: true)
        let quietCuts = try await SilenceDetector.suggestions(source: quiet)
        precondition(quietCuts.count == 3)
        let longPauses = try await SilenceDetector.suggestions(source: source, settings: .init(minimumPause: 1.5))
        precondition(longPauses.isEmpty)
        do {
            _ = try await SilenceDetector.suggestions(source: audio(name: "silent", silent: true))
            preconditionFailure("Fully silent recording must not be removed automatically")
        } catch CleanupError.noAudibleContent { }
        let preserved = try Data(contentsOf: source)
        precondition(preserved == original)
        let task = Task { try await SilenceDetector.suggestions(source: source) }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancellation ignored") }
        catch is CancellationError { }
        print("PASS: silence suggestions, added-take mapping and synchronized cuts, speech padding, quiet sound, stereo phase safety, minimum pause, cancellation and unchanged source")
    }
}
