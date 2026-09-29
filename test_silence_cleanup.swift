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
        print("PASS: silence suggestions, speech padding, quiet sound, stereo phase safety, minimum pause, cancellation and unchanged source")
    }
}