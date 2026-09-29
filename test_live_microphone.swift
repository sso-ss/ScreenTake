import AVFoundation
import Foundation

final class LiveMicrophoneProbe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let recorder = MicrophoneRecorder()
    var buffers = 0
    var firstInputPTS: Double?
    var lastInputEnd = 0.0
    var inputFrames = 0
    var timestampGaps = 0
    var firstArrival: Double?
    var lastArrival = 0.0
    var rawFile: AVAudioFile?
    let rawURL = FileManager.default.temporaryDirectory.appendingPathComponent("live-mic-incoming-\(UUID().uuidString).caf")

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        buffers += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let arrival = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if buffers > 1 && arrival - lastArrival > 0.1 {
            print("DELIVERY GAP \(arrival - lastArrival)s at input \(pts - (firstInputPTS ?? pts))s latency=\(arrival - pts)s")
        }
        if firstInputPTS == nil { firstInputPTS = pts; firstArrival = arrival }
        if buffers > 1 && abs(pts - lastInputEnd) > 0.002 { timestampGaps += 1 }
        lastInputEnd = pts + CMSampleBufferGetDuration(sampleBuffer).seconds
        lastArrival = arrival
        inputFrames += CMSampleBufferGetNumSamples(sampleBuffer)
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))) else { return }
            pcm.frameLength = pcm.frameCapacity
            let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList)
            if copyStatus == noErr {
                do {
                    if rawFile == nil { rawFile = try AVAudioFile(forWriting: rawURL, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved) }
                    try rawFile?.write(from: pcm)
                } catch { print("RAW COPY ERROR \(error)") }
            }
        }
        if buffers <= 4 {
            if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
               let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                print("SOURCE \(buffers): \(description.pointee)")
            }
            var timingCount = 0
            var sizeCount = 0
            var listSize = 0
            CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount)
            CMSampleBufferGetSampleSizeArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &sizeCount)
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
            print("BUFFER frames=\(CMSampleBufferGetNumSamples(sampleBuffer)) duration=\(CMSampleBufferGetDuration(sampleBuffer).seconds) pts=\(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds) latency=\(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), CMSampleBufferGetPresentationTimeStamp(sampleBuffer)).seconds) timingEntries=\(timingCount) sizeEntries=\(sizeCount) audioListBytes=\(listSize)")
        }
        let writeStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        recorder.appendSampleBuffer(sampleBuffer)
        let writeDuration = CMClockGetTime(CMClockGetHostTimeClock()).seconds - writeStart
        if writeDuration > 0.05 { print("WRITER STALL \(writeDuration)s at input \(pts - (firstInputPTS ?? pts))s") }
        let callbackDuration = CMClockGetTime(CMClockGetHostTimeClock()).seconds - arrival
        if callbackDuration > 0.05 { print("CALLBACK STALL \(callbackDuration)s") }
    }
}

@main
struct LiveMicrophoneTest {
    static func main() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("Microphone access is not authorized for this diagnostic executable.")
            exit(2)
        }
        let selectedID = UserDefaults(suiteName: "com.screen.Screen")?.string(forKey: "selectedMicrophoneDeviceID") ?? ""
        guard let device = AVCaptureDevice(uniqueID: selectedID) ?? AVCaptureDevice.default(for: .audio) else {
            print("No microphone available")
            exit(2)
        }
        print("DEVICE \(device.localizedName)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-mic-probe-\(UUID().uuidString).caf")
        if CommandLine.arguments.contains("--production") {
            let recorder = MicrophoneRecorder()
            defer { recorder.tearDown() }
            try recorder.prepare(device: device, outputURL: url)
            try await recorder.waitUntilReady()
            let origin = CMClockGetTime(CMClockGetHostTimeClock())
            try recorder.startWriting(to: url, startTime: origin)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    continuation.resume()
                }
            }
            let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), origin).seconds
            guard await recorder.stopRecording() != nil else {
                print("FAIL: production capture failed; file=\(url.path)")
                exit(1)
            }
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            print("Microphone received=\(recorder.receivedBuffers) backpressured=\(recorder.backpressuredBuffers)")
            guard abs(duration - elapsed) < 0.15 else {
                print("FAIL: captured duration=\(duration)s elapsed=\(elapsed)s")
                exit(1)
            }
            guard recorder.startOffset.seconds < 0.2 else {
                print("FAIL: warmed microphone started late: \(recorder.startOffset.seconds)s")
                exit(1)
            }
            print("Warmed microphone start offset=\(recorder.startOffset.seconds)s")
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .audio)[0]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
            reader.add(output)
            guard reader.startReading() else { throw reader.error! }
            var samples: [Float] = []
            while let sample = output.copyNextSampleBuffer() {
                if let block = CMSampleBufferGetDataBuffer(sample) {
                    var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
                    values.withUnsafeMutableBytes { bytes in
                        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
                    }
                    samples.append(contentsOf: values)
                }
            }
            guard reader.status == .completed else { throw reader.error! }
            let channels = Int(file.processingFormat.channelCount)
            let lag = 32768 * channels
            var repeated = 0
            var nonzero = 0
            for index in 0..<max(0, samples.count - lag) {
                if samples[index] == samples[index + lag] {
                    repeated += 1
                    if abs(samples[index]) > 0.0001 { nonzero += 1 }
                } else {
                    repeated = 0
                    nonzero = 0
                }
                if repeated > 2400 * channels && nonzero > 100 * channels {
                    print("FAIL: repeated non-silent microphone startup block")
                    exit(1)
                }
            }
            print("PASS: no repeated non-silent block at the observed 32768-frame lag")
            print("PASS: production capture frames=\(file.length) duration=\(Double(file.length) / file.processingFormat.sampleRate) file=\(url.path)")
            return
        }
        let probe = LiveMicrophoneProbe()
        try probe.recorder.prepareRecording(to: url)
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        let queue = DispatchQueue(label: "live-mic-probe")
        output.setSampleBufferDelegate(probe, queue: queue)
        session.addOutput(output)
        session.startRunning()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                continuation.resume()
            }
        }
        queue.sync {
            print("BEFORE STOP frames=\(probe.inputFrames) ptsSpan=\(probe.lastInputEnd - (probe.firstInputPTS ?? 0)) arrivalSpan=\(probe.lastArrival - (probe.firstArrival ?? 0)) lastLatency=\(probe.lastArrival - probe.lastInputEnd)")
        }
        session.stopRunning()
        queue.sync {}
        probe.rawFile = nil
        print("INPUT frames=\(probe.inputFrames) ptsSpan=\(probe.lastInputEnd - (probe.firstInputPTS ?? 0)) arrivalSpan=\(probe.lastArrival - (probe.firstArrival ?? 0)) gaps=\(probe.timestampGaps)")
        print("INCOMING PCM \(probe.rawURL.path)")
        let result = await probe.recorder.stopRecording()
        print("RESULT capturedBuffers=\(probe.buffers) writerSucceeded=\(result != nil) file=\(url.path)")
        guard result != nil else { exit(1) }
        let file = try AVAudioFile(forReading: url)
        print("SAVED frames=\(file.length) duration=\(Double(file.length) / file.processingFormat.sampleRate)")
    }
}