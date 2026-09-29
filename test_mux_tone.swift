import AVFoundation
import Foundation

enum MuxToneError: Error {
    case failed(String)
}

@main
struct MuxToneTest {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw MuxToneError.failed("Pass a video-only MOV path")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("video.mov")
        let audioURL = directory.appendingPathComponent("tone.caf")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: videoURL)
        let sampleRate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames: AVAudioFrameCount = 192_000
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        pcm.frameLength = frames
        for frame in 0..<Int(frames) {
            pcm.floatChannelData![0][frame] = Float(0.2 * sin(Double(frame) * 0.031 + Double(frame * frame) * 0.0000001))
        }
        let microphone = MicrophoneRecorder()
        try microphone.prepareRecording(to: audioURL)
        let chunkFrames: AVAudioFrameCount = 512
        for start in stride(from: 0, to: Int(frames), by: Int(chunkFrames)) {
            let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)!
            chunk.frameLength = chunkFrames
            chunk.floatChannelData![0].update(from: pcm.floatChannelData![0].advanced(by: start), count: Int(chunkFrames))
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: Int64(start), timescale: 48_000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            let sampleStatus = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: Int(chunkFrames), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
            guard sampleStatus == noErr, let sample else { throw MuxToneError.failed("Cannot create PCM sample") }
            guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: chunk.audioBufferList) == noErr else {
                throw MuxToneError.failed("Cannot populate PCM sample")
            }
            microphone.appendSampleBuffer(sample)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(chunkFrames) / sampleRate) { continuation.resume() }
            }
        }
        guard await microphone.stopRecording() != nil else { throw MuxToneError.failed("Microphone writer failed") }
        let rawFile = try AVAudioFile(forReading: audioURL)
        let rawPCM = AVAudioPCMBuffer(pcmFormat: rawFile.processingFormat, frameCapacity: frames)!
        try rawFile.read(into: rawPCM)
        print("RAW read frames=\(rawPCM.frameLength) file frames=\(rawFile.length)")
        guard rawFile.length == Int64(frames) else { throw MuxToneError.failed("Raw microphone lost samples") }
        for frame in 0..<Int(rawPCM.frameLength) {
            guard rawPCM.floatChannelData![0][frame] == pcm.floatChannelData![0][frame] else {
                throw MuxToneError.failed("Raw microphone corrupted frame \(frame): actual=\(rawPCM.floatChannelData![0][frame]) expected=\(pcm.floatChannelData![0][frame])")
            }
        }
        print("Raw microphone CAF: \(rawPCM.frameLength) returned samples match")
        let offset = CMTime(value: 4400, timescale: 48_000)
        let result = try await MediaMuxer.mux(videoURL: videoURL, systemAudioURL: nil, micAudioURL: audioURL, micAudioStartOffset: offset)
        let asset = AVURLAsset(url: result)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1 else { throw MuxToneError.failed("Expected one audio track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var decodedFrames = 0
        let offsetFrames = Int(offset.seconds * sampleRate)
        var maximumError: Float = 0
        while let sample = output.copyNextSampleBuffer() {
            if decodedFrames == 0 {
                let firstTime = CMSampleBufferGetPresentationTimeStamp(sample)
                guard firstTime == .zero else {
                    throw MuxToneError.failed("Unexpected decoded timeline start: \(firstTime.seconds)")
                }
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw MuxToneError.failed("Missing PCM") }
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
            let copyStatus = values.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            guard copyStatus == noErr else { throw MuxToneError.failed("Cannot decode PCM") }
            for value in values {
                let toneFrame = decodedFrames - offsetFrames
                let expected: Float = toneFrame < 0 ? 0 : pcm.floatChannelData![0][toneFrame]
                maximumError = max(maximumError, abs(value - expected))
                decodedFrames += 1
            }
        }
        guard reader.status == .completed, decodedFrames == Int(frames) + offsetFrames, maximumError < 0.000001 else {
            throw MuxToneError.failed("Mux changed waveform: frames=\(decodedFrames), maximumError=\(maximumError)")
        }
        print("PASS: production mux preserved \(decodedFrames) samples at a \(offset.seconds)s offset; maximum waveform error=\(maximumError)")
    }
}