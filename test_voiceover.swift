import AppKit
import SwiftUI
import AVFoundation
import CoreImage

@main
struct VoiceOverChecks {
    static func tone(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let seconds = Double(frame) / 48000
            buffer.floatChannelData![0][frame] = Float((seconds < 2 ? 0.2 : 0.4) * sin(2 * .pi * 440 * seconds))
        }
        try file.write(from: buffer)
    }

    static func video(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for index in 0..<120 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixel)
            context.render(CIImage(color: CIColor(red: 0.18, green: 0.12, blue: 0.35)), to: pixel!)
            precondition(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: EditorAudio.time(4))
        await writer.finishWriting()
        precondition(writer.status == .completed)
    }

    static func samples(_ asset: AVAsset, mix: AVAudioMix? = nil) async throws -> [Float] {
        let duration = try await asset.load(.duration).seconds
        var values = [Float](repeating: 0, count: Int(ceil(duration * 48000)))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if tracks.isEmpty { return values }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        reader.add(output)
        precondition(reader.startReading())
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            let start = Int((CMSampleBufferGetPresentationTimeStamp(buffer).seconds * 48000).rounded())
            for index in chunk.indices where values.indices.contains(start + index) { values[start + index] = chunk[index] }
        }
        precondition(reader.status == .completed)
        return values
    }

    static func rms(_ samples: [Float], _ start: Double, _ end: Double) -> Double {
        let section = samples[Int(start * 48000)..<Int(end * 48000)]
        return sqrt(section.reduce(0) { $0 + Double($1 * $1) } / Double(section.count))
    }

    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: "/tmp/ScreenTake-voiceover-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let silent = directory.appendingPathComponent("silent.mov")
        let audio = directory.appendingPathComponent("tone.caf")
        try tone(audio)
        try await video(silent)
        let original = try await MediaMuxer.mux(videoURL: silent, systemAudioURL: audio, micAudioURL: nil, removeSourceAudio: false)
        var settings = VideoEditSettings(backgroundEnabled: false, showCursor: false)
        settings.trim.start = 1
        settings.trim.end = 3
        settings.audioEnabled = false
        settings.voiceOverVolume = 0.5
        settings.voiceOvers = [
            VoiceOverClip(url: audio, start: 0.5, sourceStart: 2, duration: 0.75, sourceDuration: 4),
            VoiceOverClip(url: audio, start: 1.5, duration: 1, sourceDuration: 4)
        ]
        func preview(_ draft: VideoEditSettings) async throws -> AVPlayerItem {
            try await LiveVideoPreview.makeItem(.init(source: original, audio: original, mouse: nil, webcam: nil, settings: draft))
        }
        let item = try await preview(settings)
        let previewSamples = try await samples(item.asset, mix: item.audioMix)
        let trimmed = try await settings.trim.export(source: original)
        let exported = try await EditorAudio.export(video: trimmed, originalEnabled: false, originalVolume: 1,
                                                    clips: settings.voiceOvers, voiceOverVolume: 0.5)
        let exportedSamples = try await samples(AVURLAsset(url: exported))
        precondition(abs(Double(exportedSamples.count) / 48000 - 2) < 0.05)
        for values in [previewSamples, exportedSamples] {
            precondition(rms(values, 0.1, 0.4) < 0.002, "Narration must not begin before its timeline position")
            precondition(abs(rms(values, 0.6, 1.1) - 0.4 * 0.5 / sqrt(2)) < 0.008, "Source trim and volume must both apply")
            precondition(rms(values, 1.32, 1.42) < 0.002, "The trimmed take must end on time")
            precondition(abs(rms(values, 1.65, 1.9) - 0.2 * 0.5 / sqrt(2)) < 0.008)
        }
        print("PASS: preview/export agree on multiple take offsets, trims, volume, original mute and end clipping")
        let silentNarration = try await EditorAudio.export(video: silent, originalEnabled: false, originalVolume: 1,
                                                           clips: settings.voiceOvers, voiceOverVolume: 0.5)
        let silentTracks = try await AVURLAsset(url: silentNarration).loadTracks(withMediaType: .audio)
        precondition(silentTracks.count == 1)
        print("PASS: narration exports on a video without original audio")
        settings.voiceOverEnabled = false
        settings.audioEnabled = true
        settings.originalAudioVolume = 0.25
        let quiet = try await preview(settings)
        let quietSamples = try await samples(quiet.asset, mix: quiet.audioMix)
        precondition(abs(rms(quietSamples, 0.6, 0.8) - 0.2 * 0.25 / sqrt(2)) < 0.002)
        let quietExport = try await EditorAudio.export(video: trimmed, originalEnabled: true, originalVolume: 0.25, clips: [], voiceOverVolume: 1)
        let quietExportSamples = try await samples(AVURLAsset(url: quietExport))
        precondition(abs(rms(quietExportSamples, 0.6, 0.8) - rms(quietSamples, 0.6, 0.8)) < 0.003)
        print("PASS: original volume and independent narration mute agree in preview and export")
        settings.audioEnabled = false
        let muted = try await preview(settings)
        let mutedTracks = try await muted.asset.loadTracks(withMediaType: .audio)
        precondition(mutedTracks.isEmpty)
        let waveform = try await AudioWaveform.load(audio)
        precondition(abs(waveform.level(at: 0.5) - 0.2) < 0.01)
        precondition(abs(waveform.level(at: 2.5) - 0.4) < 0.01)
        precondition(waveform.level(at: 5) == 0)
        print("PASS: real decoded waveforms preserve source amplitude and bounds")
        let recorder = VoiceOverRecorder()
        recorder.start(player: AVPlayer(), duration: 4) { _ in preconditionFailure("An unready player must not record") }
        precondition(!recorder.isBusy && recorder.error != nil)
        recorder.cancel()
        print("PASS: an unready preview does not start microphone recording")
        // Exercise recorded-source exports and ensure narration is never baked into the source audio reference.
        let state = RecordingState()
        state.lastMicAudioURL = nil
        state.lastSystemAudioURL = nil
        settings.voiceOverEnabled = true
        settings.trim = VideoTrim()
        await state.applyAutoZoom(videoURL: silent, mouseDataURL: nil, generateZoom: false, edits: settings)
        precondition(state.processingError == nil, state.processingError ?? "")
        let recordedTracks = try await AVURLAsset(url: state.lastRecordingURL!).loadTracks(withMediaType: .audio)
        precondition(recordedTracks.count == 1)
        let retainedTracks = try await AVURLAsset(url: state.lastUntrimmedRecordingURL!).loadTracks(withMediaType: .audio)
        precondition(retainedTracks.isEmpty)
        print("PASS: recorded-source pipeline exports voiceover without captured audio and keeps the original reference clean")
        if CommandLine.arguments.contains("--ui") {
            settings.audioEnabled = true
            settings.originalAudioVolume = 1
            settings.voiceOverVolume = 1
            settings.trim = VideoTrim()
            let fixture = AudioUIFixture(settings: settings)
            let player = AVPlayer(playerItem: try await preview(settings))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: AudioUIPreview(fixture: fixture, player: player, source: original))
            window.contentView = host
            window.center()
            window.orderFrontRegardless()
            for size in [CGSize(width: 1000, height: 680), CGSize(width: 800, height: 500)] {
                window.setContentSize(size)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/ScreenTake-audio-\(Int(size.width)).png"))
            }
            window.orderOut(nil)
            print("PASS: rendered editor audio controls and waveforms at normal and minimum window sizes")
        }
        print("Fixtures: \(directory.path)")
    }
}

@MainActor
final class AudioUIFixture: ObservableObject {
    @Published var settings: VideoEditSettings
    @Published var selected: UUID?
    init(settings: VideoEditSettings) { self.settings = settings; selected = settings.voiceOvers.first?.id }
}

struct AudioUIPreview: View {
    @ObservedObject var fixture: AudioUIFixture
    let player: AVPlayer
    let source: URL
    @StateObject private var recorder = VoiceOverRecorder()
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                NativeVideoPlayerView(player: player, showsControls: false).frame(maxWidth: .infinity, maxHeight: .infinity)
                VideoTrimControls(trim: $fixture.settings.trim, duration: 4, player: player, source: source, audio: source,
                                  voiceOvers: $fixture.settings.voiceOvers, selectedVoiceOverID: $fixture.selected)
            }
            Divider()
            ScrollView {
                EditorAudioPanel(settings: $fixture.settings, selectedClip: $fixture.selected, recorder: recorder,
                                 duration: 4, hasOriginalAudio: true, startRecording: {}, importAudio: {}).padding(16)
            }.frame(width: 300)
            Divider()
            VStack {
                Label("Audio", systemImage: "waveform").labelStyle(.iconOnly).padding(.top, 16)
                Text("Audio").font(.caption)
                Spacer()
            }.frame(width: 68)
        }
        .background(DesignColors.windowBackground).preferredColorScheme(.dark)
    }
}
