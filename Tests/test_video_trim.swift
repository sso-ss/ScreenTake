import AVFoundation
import CoreImage

@main
struct VideoTrimTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 128, 128, kCVPixelFormatType_32BGRA, nil, &buffer)
            let color: CIColor = frame < 30 ? .red : (frame < 60 ? .green : .blue)
            context.render(CIImage(color: color), to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 600))
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let audio = directory.appendingPathComponent("audio.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)!
        samples.frameLength = 144000
        for index in 0..<144000 {
            samples.floatChannelData![0][index] = Float(index) / 144000 * 0.5
        }
        do { try AVAudioFile(forWriting: audio, settings: format.settings).write(from: samples) }
        _ = try await MediaMuxer.mux(videoURL: source, systemAudioURL: nil, micAudioURL: audio)
        let original = try Data(contentsOf: source)
        let untrimmed = try await VideoTrim().export(source: source)
        precondition(untrimmed == source)
        let sourceDuration = CMTime(seconds: 3, preferredTimescale: 60000)
        var splitTrim = VideoTrim()
        precondition(splitTrim.split(at: 1, duration: sourceDuration))
        precondition(splitTrim.split(at: 2, duration: sourceDuration))
        for invalid in [0.0, 3.0, 1.0, 1.01, Double.nan, Double.infinity] {
            precondition(!splitTrim.split(at: invalid, duration: sourceDuration))
        }
        let splitSegments = try splitTrim.segments(duration: sourceDuration)
        precondition(splitSegments.count == 3)
        precondition(splitSegments.allSatisfy { abs($0.duration.seconds - 1) < 0.0001 })
        let splitOnlyExport = try await splitTrim.export(source: source)
        precondition(splitOnlyExport == source, "Split alone must not re-encode or remove footage")
        let undoSnapshot = splitTrim
        splitTrim.cuts.append(.init(start: splitSegments[1].start.seconds, end: splitSegments[1].end.seconds))
        let joined = try splitTrim.timeline(duration: sourceDuration)
        precondition(joined.duration.seconds == 2)
        for seconds in [0.0, 0.5, 2.0, 2.5, 3.0] {
            let sourceTime = CMTime(seconds: seconds, preferredTimescale: 60000)
            precondition(joined.sourceTime(at: joined.outputTime(at: sourceTime)) == sourceTime)
        }
        precondition(joined.outputTime(at: CMTime(seconds: 1.5, preferredTimescale: 60000)).seconds == 1)
        precondition(!splitTrim.split(at: 1.5, duration: sourceDuration), "Cannot split removed footage")
        splitTrim = undoSnapshot
        let restoredSplitTimeline = try splitTrim.timeline(duration: sourceDuration)
        precondition(restoredSplitTimeline.duration == sourceDuration)
        print("PASS: non-destructive splits, boundary rejection, section removal, undo snapshot and source/edited seeking")
        var reordered = undoSnapshot
        precondition(reordered.moveSegment(from: 2, to: 0, duration: sourceDuration))
        let reorderedTimeline = try reordered.timeline(duration: sourceDuration)
        precondition(reorderedTimeline.ranges.map { $0.start.seconds } == [2, 0, 1])
        for (outputSeconds, sourceSeconds) in [(0.5, 2.5), (1.5, 0.5), (2.5, 1.5)] {
            let outputTime = CMTime(seconds: outputSeconds, preferredTimescale: 60000)
            let sourceTime = CMTime(seconds: sourceSeconds, preferredTimescale: 60000)
            precondition(reorderedTimeline.sourceTime(at: outputTime) == sourceTime)
            precondition(reorderedTimeline.outputTime(at: sourceTime) == outputTime)
        }
        let reorderedURL = try await reordered.export(source: source)
        let reorderedAsset = AVURLAsset(url: reorderedURL)
        let reorderedAudioTrack = try await reorderedAsset.loadTracks(withMediaType: .audio)[0]
        let reorderedReader = try AVAssetReader(asset: reorderedAsset)
        let reorderedAudio = AVAssetReaderTrackOutput(track: reorderedAudioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        reorderedReader.add(reorderedAudio)
        precondition(reorderedReader.startReading())
        var reorderedSamples: [Float] = []
        while let sample = reorderedAudio.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            reorderedSamples.append(contentsOf: values)
        }
        precondition(reorderedReader.status == .completed && abs(reorderedSamples.count - 144000) <= 1)
        for (outputSeconds, sourceSeconds) in [(0.5, 2.5), (1.5, 0.5), (2.5, 1.5)] {
            precondition(abs(reorderedSamples[Int(outputSeconds * 48000)] - Float(sourceSeconds / 6)) < 0.001)
        }
        print("PASS: reordered audio samples remain aligned with video and preserve duration")
        let reorderedGenerator = AVAssetImageGenerator(asset: reorderedAsset)
        reorderedGenerator.requestedTimeToleranceBefore = .zero
        reorderedGenerator.requestedTimeToleranceAfter = .zero
        for (seconds, channel) in [(0.5, 2), (1.5, 0), (2.5, 1)] {
            let frame = try await reorderedGenerator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            var color = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: frame), toBitmap: &color, rowBytes: 4,
                           bounds: CGRect(x: 64, y: 64, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            precondition(color[channel] > 180, "Reordered export has wrong clip")
        }
        precondition(reordered.split(at: 2.5, duration: sourceDuration))
        precondition(reordered.moveSegment(from: 1, to: 3, duration: sourceDuration))
        reordered.cuts.append(.init(start: 0, end: 1))
        let ripple = try reordered.timeline(duration: sourceDuration)
        precondition(ripple.duration.seconds == 2)
        precondition(!reordered.moveSegment(from: -1, to: 0, duration: sourceDuration))
        var cutThenMove = VideoTrim(start: 0.2, end: 2.8, cuts: [.init(start: 0.8, end: 2.2)])
        precondition(cutThenMove.moveSegment(from: 1, to: 0, duration: sourceDuration))
        let cutMoved = try cutThenMove.timeline(duration: sourceDuration)
        precondition(cutMoved.ranges.map { $0.start.seconds } == [2.2, 0.2])
        cutThenMove.start = 0
        cutThenMove.end = nil
        cutThenMove.cuts = []
        let extended = try cutThenMove.timeline(duration: sourceDuration)
        precondition(extended.duration == sourceDuration, "Reordering must retain trimmed and removed source for restoration")
        print("PASS: reordered export pixels, bidirectional seeking, split after reorder and ripple deletion")
        let output = try await VideoTrim(start: 1.2, end: 1.8).export(source: source)
        precondition(output != source)
        let unchanged = try Data(contentsOf: source)
        precondition(unchanged == original)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        precondition(abs(duration.seconds - 0.6) < 0.002, "Duration: \(duration.seconds)")
        let image = try AVAssetImageGenerator(asset: asset).copyCGImage(at: .zero, actualTime: nil)
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 64, y: 64, width: 1, height: 1), format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        precondition(pixel[1] > 180 && pixel[0] < 80 && pixel[2] < 80, "Wrong trimmed frame: \(pixel)")
        let audioTrack = try await asset.loadTracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(audioOutput)
        precondition(reader.startReading())
        var count = 0
        var firstValue: Float?
        while let sample = audioOutput.copyNextSampleBuffer() {
            if firstValue == nil, let block = CMSampleBufferGetDataBuffer(sample) {
                var value: Float = 0
                precondition(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &value) == noErr)
                firstValue = value
            }
            count += CMSampleBufferGetNumSamples(sample)
        }
        precondition(reader.status == .completed)
        precondition(abs(count - 28800) <= 1, "Audio length: \(count)")
        precondition(abs((firstValue ?? 0) - 0.2) < 0.001, "Audio did not start at source 1.2s")
        for trim in [VideoTrim(start: -1), VideoTrim(start: 2, end: 1), VideoTrim(start: .nan), VideoTrim(end: .infinity)] {
            do {
                _ = try trim.timeRange(duration: CMTime(seconds: 3, preferredTimescale: 600))
                preconditionFailure("Invalid range accepted")
            } catch VideoTrimError.invalidRange { }
        }
        let restored = try await VideoTrim().export(source: source)
        precondition(restored == source)
        let fractionalDuration = CMTime(value: 123457, timescale: 44100)
        let fullRange = try VideoTrim().timeRange(duration: fractionalDuration)
        precondition(fullRange.end == fractionalDuration)
        let edits = VideoTrim(start: 0.2, end: 2.8, cuts: [.init(start: 0.8, end: 1.5), .init(start: 1.3, end: 2.2)])
        let timeline = try edits.timeline(duration: CMTime(seconds: 3, preferredTimescale: 600))
        precondition(timeline.ranges.count == 2 && abs(timeline.duration.seconds - 1.2) < 0.0001)
        precondition(abs(timeline.sourceTime(at: CMTime(seconds: 0.7, preferredTimescale: 600)).seconds - 2.3) < 0.0001)
        let cutURL = try await edits.export(source: source)
        let cutAsset = AVURLAsset(url: cutURL)
        let cutDuration = try await cutAsset.load(.duration)
        precondition(abs(cutDuration.seconds - 1.2) < 0.002)
        let generator = AVAssetImageGenerator(asset: cutAsset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (seconds, channel) in [(0.3, 0), (0.9, 2)] {
            let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            context.render(CIImage(cgImage: frame), toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 64, y: 64, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            precondition(pixel[channel] > 180, "Wrong frame after middle cut")
        }
        let cutReader = try AVAssetReader(asset: cutAsset)
        let cutTrack = try await cutAsset.loadTracks(withMediaType: .audio)[0]
        let cutAudio = AVAssetReaderTrackOutput(track: cutTrack, outputSettings: audioOutput.outputSettings)
        cutReader.add(cutAudio)
        precondition(cutReader.startReading())
        var decoded: [Float] = []
        while let sample = cutAudio.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            decoded.append(contentsOf: values)
        }
        precondition(cutReader.status == .completed && abs(decoded.count - 57600) <= 1)
        precondition(abs(decoded[14400] - Float(0.5 / 3 * 0.5)) < 0.001)
        precondition(abs(decoded[43200] - Float(2.5 / 3 * 0.5)) < 0.001)
        let preservedSource = try Data(contentsOf: source)
        precondition(preservedSource == original)
        do {
            _ = try VideoTrim(cuts: [.init(start: 0, end: 3)]).timeline(duration: CMTime(seconds: 3, preferredTimescale: 600))
            preconditionFailure("Deleting the whole recording was accepted")
        } catch VideoTrimError.emptySelection { }
        print("PASS: overlapping middle cuts, exact joined video/audio timestamps, duration and original preservation")
        print("PASS: non-keyframe trim, exact duration, matching video/audio start, unchanged original, reset and invalid ranges")
    }
}