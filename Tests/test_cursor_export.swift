import AppKit
import AVFoundation
import CoreImage

@main
struct CursorExportTest {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let mouseURL = directory.appendingPathComponent("source.mouse.json")
        let recording = MouseDataRecorder.MouseRecording(
            positions: [.init(timestamp: 0, x: 0.25, y: 0.75, velocity: 0), .init(timestamp: 1, x: 0.25, y: 0.75, velocity: 0)],
            clicks: [], keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(x: 0, y: 0, width: 256, height: 256)), scaleFactor: 1, sampleInterval: 1.0 / 60)
        try JSONEncoder().encode(recording).write(to: mouseURL)
        let writer = try VideoWriter(outputURL: source, configuration: VideoWriterConfiguration(width: 256, height: 256))
        try writer.startWriting()
        let context = CIContext()
        for time in [0.0, 0.5, 1.0] {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 256, 256, kCVPixelFormatType_32BGRA, nil, &buffer)
            context.render(CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)), to: buffer!)
            writer.appendPixelBuffer(buffer!, at: CMTime(seconds: time, preferredTimescale: 600))
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.04) { continuation.resume() }
            }
        }
        await writer.finishWriting(at: CMTime(seconds: 1, preferredTimescale: 600))
        let audioURL = directory.appendingPathComponent("microphone.wav")
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 44100)!
        audioBuffer.frameLength = 44100
        for sampleIndex in 0..<44100 {
            audioBuffer.floatChannelData![0][sampleIndex] = Float(sin(Double(sampleIndex) * 2 * .pi * 440 / 44100) * 0.25)
        }
        do {
            let audioFile = try AVAudioFile(forWriting: audioURL, settings: audioFormat.settings)
            try audioFile.write(from: audioBuffer)
        }
        var circleCounts: [Int] = []
        for (index, choice) in [(CursorShape.arrow, 1.0, true), (.hand, 1.0, true), (.circle, 1.0, true), (.circle, 2.0, true), (.arrow, 1.0, false)].enumerated() {
            let output = directory.appendingPathComponent("output-\(index).mov")
            _ = try await ExportEngine().export(sourceURL: source, keyframes: [], configuration: .init(
                outputURL: output, mouseDataURL: mouseURL, cursorScale: choice.1, cursorShape: choice.0, showCursor: choice.2))
            _ = try await MediaMuxer.mux(videoURL: output, systemAudioURL: nil, micAudioURL: audioURL, removeSourceAudio: false)
            precondition(FileManager.default.fileExists(atPath: audioURL.path))
            let asset = AVURLAsset(url: output)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            precondition(audioTracks.count == 1, "Repeated export lost or duplicated audio")
            let audioRange = try await audioTracks[0].load(.timeRange)
            precondition(abs(audioRange.duration.seconds - 1) < 0.05)
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let reader = try AVAssetReader(asset: asset)
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(readerOutput)
            precondition(reader.startReading())
            let sample = readerOutput.copyNextSampleBuffer()!
            let buffer = CMSampleBufferGetImageBuffer(sample)!
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            var darkPixels: [CGPoint] = []
            var glassRimPixels: [CGPoint] = []
            var contrastingPixels = 0
            for row in 0..<256 {
                for column in 0..<256 {
                    let offset = row * stride + column * 4
                    if bytes[offset] < 60 || bytes[offset] > 220 {
                        contrastingPixels += 1
                    }
                    if bytes[offset] < 100 || bytes[offset] > 155 {
                        glassRimPixels.append(CGPoint(x: column, y: row))
                    }
                    if max(bytes[offset], bytes[offset + 1], bytes[offset + 2]) < 60 {
                        darkPixels.append(CGPoint(x: column, y: row))
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            if choice.2 {
                let minimumContrast = choice.0 == .circle ? 30 : 100
                precondition(contrastingPixels > minimumContrast, "Missing cursor: \(choice.0), contrasting pixels=\(contrastingPixels)")
                if choice.0 == .circle {
                    precondition(!glassRimPixels.isEmpty, "Missing glass circle rim")
                    let centerX = (glassRimPixels.map(\.x).min()! + glassRimPixels.map(\.x).max()!) / 2
                    let centerY = (glassRimPixels.map(\.y).min()! + glassRimPixels.map(\.y).max()!) / 2
                    precondition(abs(centerX - 64) < 2 && abs(centerY - 64) < 2, "Misaligned circle: \(centerX), \(centerY)")
                    let centerOffset = 64 * stride + 64 * 4
                    precondition(bytes[centerOffset] > 100, "Exported circle center is still black: \(bytes[centerOffset])")
                    circleCounts.append(glassRimPixels.count)
                }
            } else {
                precondition(contrastingPixels == 0, "Hidden cursor still visible")
            }
            print("PASS: exported \(choice.0) \(choice.1)x visible=\(choice.2), dark pixels=\(darkPixels.count)")
        }
        precondition(circleCounts[1] > circleCounts[0] * 3)
        print("PASS: exported cursor size, off-center hotspot alignment, hidden state, and cursor without zoom")
        print("PASS: all five exports retain one full-length audio track and preserve the audio source")
    }
}