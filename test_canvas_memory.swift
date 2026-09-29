import AppKit
import AVFoundation
import CoreImage
import Darwin

@main
struct CanvasMemoryTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let output = directory.appendingPathComponent("iphone.mov")
        let size = CGSize(width: 3840, height: 2160)
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for seconds in [0.0, 7.95] {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            autoreleasepool {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buffer)
                context.render(CIImage(color: CIColor(red: 0.2, green: 0.7, blue: 0.5)), to: buffer!)
                precondition(adaptor.append(buffer!, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)))
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 8, preferredTimescale: 600))
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let start = Date()
        _ = try await ExportEngine().export(sourceURL: source,
            keyframes: [.init(time: 0, transform: .init(zoom: 2, centerX: 0.5, centerY: 0.5))],
            configuration: .init(outputURL: output, showCursor: false, canvasRatio: .vertical, deviceLayout: .iPhone))
        let asset = AVURLAsset(url: output)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let outputSize = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        precondition(outputSize == CGSize(width: 1080, height: 1920))
        precondition(abs(duration.seconds - 8) < 0.05)
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(frames)
        precondition(reader.startReading())
        var frameCount = 0
        while autoreleasepool(invoking: { frames.copyNextSampleBuffer() != nil }) { frameCount += 1 }
        precondition(frameCount >= 239, "Missing synthesized frames: \(frameCount)")
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        precondition(usage.ru_maxrss < 1_500_000_000, "Export retained excessive frame memory: \(usage.ru_maxrss)")
        print("PASS: 4K to iPhone, \(frameCount) frames, 8 seconds preserved; peak RSS \(usage.ru_maxrss / 1_000_000) MB, elapsed \(Date().timeIntervalSince(start))s")
    }
}