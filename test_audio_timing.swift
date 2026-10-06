import AVFoundation
import Foundation

enum AudioTestError: Error {
    case failed(String)
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw AudioTestError.failed(message) }
}

func makeTone(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) throws -> CMSampleBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    pcm.frameLength = frames
    for channel in 0..<Int(channels) {
        for frame in 0..<Int(frames) {
            pcm.floatChannelData![channel][frame] = Float(0.25 * sin(2 * .pi * Double(440 + channel * 220) * Double(frame) / sampleRate))
        }
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: Int32(sampleRate)),
        presentationTimeStamp: CMTime(seconds: 12, preferredTimescale: Int32(sampleRate)),
        decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    let createStatus = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
        sampleCount: Int(frames), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
    )
    try require(createStatus == noErr && sample != nil, "Cannot create tone sample buffer")
    let copyStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
        sample!, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
        bufferList: pcm.audioBufferList
    )
    try require(copyStatus == noErr, "Cannot copy tone PCM")
    return sample!
}

@main
struct AudioTimingTests {
    static func main() async throws {
        let reusedSample = try makeTone(sampleRate: 48_000, channels: 1, frames: 1024)
        let ownershipRecorder = MicrophoneRecorder()
        guard let ownedSample = ownershipRecorder.rebaseTiming(reusedSample, pts: .zero),
              let originalBlock = CMSampleBufferGetDataBuffer(reusedSample),
              let ownedBlock = CMSampleBufferGetDataBuffer(ownedSample) else {
            throw AudioTestError.failed("Cannot prepare buffer ownership test")
        }
        let byteCount = CMBlockBufferGetDataLength(originalBlock)
        var expectedBytes = Data(count: byteCount)
        let expectedStatus = expectedBytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(originalBlock, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
        }
        try require(expectedStatus == noErr, "Cannot read original PCM")
        let overwriteStatus = CMBlockBufferFillDataBytes(with: 0, blockBuffer: originalBlock, offsetIntoDestination: 0, dataLength: byteCount)
        try require(overwriteStatus == noErr, "Cannot simulate capture-buffer reuse")
        var actualBytes = Data(count: byteCount)
        let actualStatus = actualBytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(ownedBlock, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
        }
        try require(actualStatus == noErr && actualBytes == expectedBytes, "Reusing the capture buffer changed audio already handed to the writer")
        print("PASS: microphone PCM survives capture-buffer reuse")
        for sampleRate in [44_100.0, 48_000.0] {
            for channels: AVAudioChannelCount in [1, 2] {
                let frames: AVAudioFrameCount = 1024
                let sample = try makeTone(sampleRate: sampleRate, channels: channels, frames: frames)
                let expectedDuration = Double(frames) / sampleRate
                let recorder = MicrophoneRecorder()
                guard let rebased = recorder.rebaseTiming(sample, pts: .zero) else {
                    throw AudioTestError.failed("Microphone rebasing failed")
                }
                let actualDuration = CMSampleBufferGetDuration(rebased).seconds
                print("Mic \(Int(sampleRate))Hz \(channels)ch: expected \(expectedDuration)s, got \(actualDuration)s")
                try require(abs(actualDuration - expectedDuration) < 0.000001, "Microphone rebasing changed audio duration")
                try require(CMSampleBufferGetPresentationTimeStamp(rebased) == .zero, "Microphone PTS not rebased")
                try require(CMSampleBufferGetPresentationTimeStamp(sample).seconds == 12, "Source PTS mutated")
                let resumedPTS = CMTime(seconds: 0.5, preferredTimescale: Int32(sampleRate))
                guard let resumed = recorder.rebaseTiming(sample, pts: resumedPTS) else {
                    throw AudioTestError.failed("Microphone nonzero rebasing failed")
                }
                try require(CMSampleBufferGetPresentationTimeStamp(resumed) == resumedPTS, "Microphone nonzero PTS changed")
                try require(CMSampleBufferGetDuration(resumed) == CMSampleBufferGetDuration(sample), "Microphone nonzero rebasing changed duration")

                let micURL = FileManager.default.temporaryDirectory.appendingPathComponent("mic-regression-\(UUID().uuidString).caf")
                defer { try? FileManager.default.removeItem(at: micURL) }
                try recorder.prepareRecording(to: micURL)
                for bufferIndex in 0..<4 {
                    let pts = CMTime(value: Int64(bufferIndex * Int(frames)), timescale: Int32(sampleRate))
                    guard let input = recorder.rebaseTiming(sample, pts: pts) else {
                        throw AudioTestError.failed("Cannot create sequential microphone buffer")
                    }
                    recorder.appendSampleBuffer(input)
                    guard let submittedData = CMSampleBufferGetDataBuffer(input) else {
                        throw AudioTestError.failed("Submitted microphone sample has no PCM")
                    }
                    let reuseStatus = CMBlockBufferFillDataBytes(
                        with: 0,
                        blockBuffer: submittedData,
                        offsetIntoDestination: 0,
                        dataLength: CMBlockBufferGetDataLength(submittedData)
                    )
                    try require(reuseStatus == noErr, "Cannot reuse submitted microphone buffer")
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global().asyncAfter(deadline: .now() + expectedDuration) {
                            continuation.resume()
                        }
                    }
                }
                guard await recorder.stopRecording() != nil else {
                    throw AudioTestError.failed("Microphone writer failed on consecutive buffers")
                }
                let micFile = try AVAudioFile(forReading: micURL)
                try require(micFile.length == AVAudioFramePosition(frames) * 4, "Microphone lost consecutive buffers: \(micFile.length)")
                let micPCM = AVAudioPCMBuffer(pcmFormat: micFile.processingFormat, frameCapacity: frames * 4)!
                try micFile.read(into: micPCM)
                var micMaximumError: Float = 0
                for channel in 0..<Int(channels) {
                    for frame in 0..<Int(frames * 4) {
                        let expected = Float(0.25 * sin(2 * .pi * Double(440 + channel * 220) * Double(frame % Int(frames)) / sampleRate))
                        micMaximumError = max(micMaximumError, abs(micPCM.floatChannelData![channel][frame] - expected))
                    }
                }
                try require(micMaximumError < 0.000001, "Microphone writer corrupted PCM: \(micMaximumError)")
                print("Mic writer: \(micFile.length) consecutive frames, maximum waveform error \(micMaximumError)")

                let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-regression-\(UUID().uuidString).caf")
                defer { try? FileManager.default.removeItem(at: url) }
                let system = SystemAudioRecorder()
                try system.startRecording(to: url)
                system.appendSampleBuffer(sample)
                guard await system.stopRecording() != nil else {
                    throw AudioTestError.failed("System audio writer failed")
                }
                let savedDuration = try await AVURLAsset(url: url).load(.duration)
                try require(abs(savedDuration.seconds - expectedDuration) < 0.000001, "Saved system audio duration changed: \(savedDuration.seconds)")
                let file = try AVAudioFile(forReading: url)
                try require(file.length == AVAudioFramePosition(frames), "System audio frame count changed: \(file.length)")
                let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
                try file.read(into: decoded)
                var maximumError: Float = 0
                for channel in 0..<Int(channels) {
                    for frame in 0..<Int(frames) {
                        let expected = Float(0.25 * sin(2 * .pi * Double(440 + channel * 220) * Double(frame) / sampleRate))
                        maximumError = max(maximumError, abs(decoded.floatChannelData![channel][frame] - expected))
                    }
                }
                try require(maximumError < 0.000001, "System audio waveform corrupted: \(maximumError)")
                print("System PCM: \(file.length) frames, maximum waveform error \(maximumError)")
            }
        }
        let delayedURL = FileManager.default.temporaryDirectory.appendingPathComponent("delayed-mic-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: delayedURL) }
        let delayedRecorder = MicrophoneRecorder()
        try delayedRecorder.prepareRecording(to: delayedURL, startTime: CMTime(seconds: 11.5, preferredTimescale: 48_000))
        let delayedSample = try makeTone(sampleRate: 48_000, channels: 1, frames: 1024)
        delayedRecorder.appendSampleBuffer(delayedSample)
        guard await delayedRecorder.stopRecording() != nil else {
            throw AudioTestError.failed("Delayed microphone recording failed")
        }
        let delayedFile = try AVAudioFile(forReading: delayedURL)
        print("Delayed microphone: \(delayedFile.length) frames, start offset \(delayedRecorder.startOffset.seconds)s")
        try require(delayedFile.length == 1024, "Microphone PCM was changed to represent the start offset")
        try require(abs(delayedRecorder.startOffset.seconds - 0.5) < 0.000001, "Microphone start offset was discarded")
        for microphone in [true, false] {
            let pauseURL = FileManager.default.temporaryDirectory.appendingPathComponent("paused-audio-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: pauseURL) }
            let mic = MicrophoneRecorder()
            let system = SystemAudioRecorder()
            if microphone {
                try mic.prepareRecording(to: pauseURL)
            } else {
                try system.startRecording(to: pauseURL)
                system.setRecordingStartTime(CMTime(seconds: 11.5, preferredTimescale: 48_000))
            }
            let sample = try makeTone(sampleRate: 48_000, channels: 1, frames: 1024)
            if microphone { mic.appendSampleBuffer(sample) } else { system.appendSampleBuffer(sample) }
            let pauseTime = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample))
            let resumeTime = CMTimeAdd(pauseTime, CMTime(seconds: 2, preferredTimescale: 48_000))
            mic.pause(at: pauseTime)
            system.pause(at: pauseTime)
            mic.resume(at: resumeTime)
            system.resume(at: resumeTime)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { continuation.resume() }
            }
            let resumed = mic.rebaseTiming(sample, pts: resumeTime)!
            if microphone { mic.appendSampleBuffer(resumed) } else { system.appendSampleBuffer(resumed) }
            let result = microphone ? await mic.stopRecording() : await system.stopRecording()
            try require(result != nil, "Paused audio writer failed")
            let file = try AVAudioFile(forReading: pauseURL)
            try require(file.length == 2048, "Pause with no samples added a gap: \(file.length)")
            if !microphone {
                try require(abs(system.startOffset.seconds - 0.5) < 0.000001, "System start offset lost")
            }
            print("PASS: \(microphone ? "microphone" : "system audio") pause without samples, \(file.length) frames")
        }
        let muteURL = FileManager.default.temporaryDirectory.appendingPathComponent("muted-mic-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: muteURL) }
        let muteRecorder = MicrophoneRecorder()
        try muteRecorder.prepareRecording(to: muteURL)
        let tone = try makeTone(sampleRate: 48_000, channels: 2, frames: 1024)
        for index in 0..<3 {
            muteRecorder.setMuted(index == 1)
            let pts = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(tone), CMTime(value: Int64(index * 1024), timescale: 48_000))
            let sample = muteRecorder.rebaseTiming(tone, pts: pts)!
            muteRecorder.appendSampleBuffer(sample)
        }
        try require(await muteRecorder.stopRecording() != nil, "Muted microphone writer failed")
        let muteFile = try AVAudioFile(forReading: muteURL)
        try require(muteFile.length == 3072, "Muting changed microphone duration")
        let mutePCM = AVAudioPCMBuffer(pcmFormat: muteFile.processingFormat, frameCapacity: 3072)!
        try muteFile.read(into: mutePCM)
        for channel in 0..<2 {
            for frame in 0..<3072 {
                let expected: Float = frame >= 1024 && frame < 2048
                    ? 0 : Float(0.25 * sin(2 * .pi * Double(440 + channel * 220) * Double(frame % 1024) / 48_000))
                try require(abs(mutePCM.floatChannelData![channel][frame] - expected) < 0.000001,
                            "Mic mute/unmute lost silence, changed narration, or shifted timing")
            }
        }
        print("PASS: microphone mute preserves silent intervals, stereo narration and timing after unmute")
        print("PASS: audio duration, timestamps, channel layout and PCM waveform")
    }
}
