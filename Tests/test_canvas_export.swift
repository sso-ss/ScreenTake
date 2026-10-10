import AppKit
import AVFoundation
import CoreImage

@main
struct CanvasExportTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = CIContext()

        func makeVideo(_ name: String, size: CGSize, rotated: Bool = false, phone: Bool = false) async throws -> URL {
            let url = directory.appendingPathComponent(name + ".mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
            ])
            if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0) }
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            precondition(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            for time in phone ? [0.0, 0.5] : [0.0, 0.95] {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buffer)
                let color = phone ? (time == 0 ? CIColor(red: 0, green: 1, blue: 0) : CIColor(red: 0, green: 0, blue: 1)) : CIColor(red: 1, green: 0, blue: 0)
                context.render(CIImage(color: color), to: buffer!)
                precondition(adaptor.append(buffer!, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: phone ? 0.6 : 1, preferredTimescale: 600))
            await writer.finishWriting()
            precondition(writer.status == .completed)
            return url
        }

        let sourceSize = CGSize(width: 320, height: 200)
        let source = try await makeVideo("desktop", size: sourceSize)
        let phone = try await makeVideo("phone", size: CGSize(width: 240, height: 120), rotated: true, phone: true)
        let audioURL = directory.appendingPathComponent("tone.wav")
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 44100)!
        audioBuffer.frameLength = 44100
        for index in 0..<44100 {
            audioBuffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44100) * 0.2)
        }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: audioFormat.settings)
            try file.write(from: audioBuffer)
        }
        _ = try await MediaMuxer.mux(videoURL: source, systemAudioURL: nil, micAudioURL: audioURL, removeSourceAudio: false)

        func color(_ asset: AVAsset, at time: Double, point: CGPoint) async throws -> NSColor {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let bitmap = NSBitmapImageRep(cgImage: frame)
            return bitmap.colorAt(x: Int(point.x), y: bitmap.pixelsHigh - 1 - Int(point.y))!.usingColorSpace(.sRGB)!
        }

        for ratio in CanvasRatio.allCases {
            for layout in DeviceLayout.allCases {
                let output = directory.appendingPathComponent("\(ratio.rawValue)-\(layout.rawValue).mov")
                _ = try await ExportEngine().export(sourceURL: source, keyframes: [], configuration: .init(
                    outputURL: output, outputSize: ratio.size(source: sourceSize), showCursor: false, canvasRatio: ratio, deviceLayout: layout,
                    wallpaper: .blossom, phoneVideoURL: layout == .duo ? phone : nil, preserveSourceAudio: true))
                let asset = AVURLAsset(url: output)
                let track = try await asset.loadTracks(withMediaType: .video)[0]
                let size = try await track.load(.naturalSize)
                precondition(size == ratio.size(source: sourceSize), "Wrong output dimensions")
                let duration = try await asset.load(.duration)
                precondition(abs(duration.seconds - 1) < 0.05)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                precondition(audio.count == 1, "Layout export lost source audio")
                let audioRange = try await audio[0].load(.timeRange)
                precondition(abs(audioRange.duration.seconds - 1) < 0.05)
                let geometry = CanvasGeometry(size: size, layout: layout, sourceSize: sourceSize)
                let primaryRect = geometry.desktop ?? CanvasGeometry.phoneContent(geometry.phone!)
                let primaryColor = try await color(asset, at: 0, point: CGPoint(x: primaryRect.midX, y: primaryRect.midY))
                precondition(primaryColor.redComponent > 0.75 && primaryColor.redComponent > primaryColor.greenComponent + 0.4, "Primary video missing: \(primaryColor)")
                if layout == .duo {
                    let rect = CanvasGeometry.phoneContent(geometry.phone!)
                    let point = CGPoint(x: rect.midX, y: rect.midY)
                    let early = try await color(asset, at: 0.1, point: point)
                    let late = try await color(asset, at: 0.8, point: point)
                    precondition(early.greenComponent > 0.8, "Phone first frame missing")
                    precondition(late.blueComponent > 0.8, "Phone animation froze during sparse primary frames or failed to hold final frame")
                }
                print("PASS: \(ratio.rawValue) / \(layout.rawValue), \(Int(size.width))x\(Int(size.height)), audio and duration preserved")
            }
        }

        let mouseURL = directory.appendingPathComponent("cursor.mouse.json")
        let recording = MouseDataRecorder.MouseRecording(
            positions: [.init(timestamp: 0, x: 0.4, y: 0.6, velocity: 0)],
            clicks: [], keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(origin: .zero, size: sourceSize)), scaleFactor: 1, sampleInterval: 1.0 / 60)
        try JSONEncoder().encode(recording).write(to: mouseURL)
        let cursorOutput = directory.appendingPathComponent("cursor.mov")
        _ = try await ExportEngine().export(sourceURL: source, keyframes: [.init(time: 0, transform: .init(zoom: 2, centerX: 0.5, centerY: 0.5))], configuration: .init(
            outputURL: cursorOutput, mouseDataURL: mouseURL, cursorShape: .circle, canvasRatio: .portrait, wallpaper: .blossom,
            exportResolution: .fhd1080))
        let cursorAsset = AVURLAsset(url: cursorOutput)
        let generator = AVAssetImageGenerator(asset: cursorAsset)
        let cursorFrame = try await generator.image(at: .zero).image
        let bitmap = NSBitmapImageRep(cgImage: cursorFrame)
        let rect = CanvasGeometry(size: CanvasRatio.portrait.size(source: sourceSize), layout: .desktop, sourceSize: sourceSize).desktop!
        var cursorPoints: [CGPoint] = []
        for row in Int(rect.minY + 10)..<Int(rect.maxY - 10) {
            for column in Int(rect.minX + 10)..<Int(rect.maxX - 10) {
                let color = bitmap.colorAt(x: column, y: bitmap.pixelsHigh - 1 - row)!.usingColorSpace(.sRGB)!
                // The translucent circle adds white over the red fixture.
                if color.greenComponent > 0.15 && color.blueComponent > 0.15 {
                    cursorPoints.append(CGPoint(x: column, y: row))
                }
            }
        }
        precondition(cursorPoints.count > 100, "Cursor missing from resized canvas")
        let cursorX = cursorPoints.map(\.x).reduce(0, +) / CGFloat(cursorPoints.count)
        let cursorY = cursorPoints.map(\.y).reduce(0, +) / CGFloat(cursorPoints.count)
        precondition(abs(cursorX - (rect.minX + rect.width * 0.3)) < 4, "Canvas cursor X is misaligned")
        precondition(abs(cursorY - (rect.minY + rect.height * 0.7)) < 4, "Canvas cursor Y is misaligned")
        print("PASS: cursor hotspot remains aligned through 2x zoom and 4:5 canvas resize")

        let rotatedOutput = directory.appendingPathComponent("rotated.mov")
        _ = try await ExportEngine().export(sourceURL: phone, keyframes: [], configuration: .init(outputURL: rotatedOutput, showCursor: false))
        let rotatedTrack = try await AVURLAsset(url: rotatedOutput).loadTracks(withMediaType: .video)[0]
        let rotatedSize = try await rotatedTrack.load(.naturalSize)
        precondition(rotatedSize == CGSize(width: 120, height: 240), "Portrait orientation metadata ignored")
        do {
            _ = try await ExportEngine().export(sourceURL: source, keyframes: [], configuration: .init(outputURL: directory.appendingPathComponent("missing.mov"), deviceLayout: .duo))
            preconditionFailure("Duo silently accepted a missing phone clip")
        } catch ExportError.missingPhoneVideo {}
        print("PASS: rotated phone footage and missing duo source validation")
    }
}
