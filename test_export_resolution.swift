import AppKit
import AVFoundation
import CoreImage

@main
struct ExportResolutionChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let ultrawide = CGSize(width: 3440, height: 1440)
        let native = ExportResolution.preserveSource.size(source: ultrawide, ratio: .landscape, usesCanvas: true)
        precondition(native == CGSize(width: 3782, height: 2128))
        let screen = CanvasGeometry(size: native, layout: .desktop, sourceSize: ultrawide).desktop!
        precondition(screen.width >= ultrawide.width && screen.height >= ultrawide.height,
                     "Ultrawide export must keep the original screen pixels inside the background")
        precondition(ExportResolution.uhd4k.size(source: ultrawide, ratio: .landscape, usesCanvas: true) == CGSize(width: 3840, height: 2160))
        precondition(ExportResolution.fhd1080.size(source: ultrawide, ratio: .landscape, usesCanvas: true) == CGSize(width: 1920, height: 1080))
        precondition(ExportResolution.preserveSource.size(source: ultrawide) == ultrawide)
        precondition(ExportResolution.uhd4k.size(source: CGSize(width: 1080, height: 1920)) == CGSize(width: 2160, height: 3840))
        precondition(ExportResolution.fhd1080.size(source: CGSize(width: 1080, height: 1920)) == CGSize(width: 1080, height: 1920))
        let crop = PhoneCrop(rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        for source in [ultrawide, CGSize(width: 3840, height: 2160), CGSize(width: 1170, height: 2532)] {
            for ratio in CanvasRatio.allCases {
                for layout in DeviceLayout.allCases {
                    for mode in PhoneContentMode.allCases {
                        let size = ExportResolution.preserveSource.size(source: source, crop: crop, ratio: ratio,
                                                                         layout: layout, usesCanvas: true, phoneMode: mode)
                        let scale = ExportResolution.contentScale(source: crop.pixelRect(in: source).size, output: size,
                                                                  layout: layout, usesCanvas: true, phoneMode: mode)
                        precondition(scale >= 1 - 0.000001, "Native content was reduced in \(ratio) / \(layout) / \(mode)")
                        precondition(Int(size.width).isMultiple(of: 2) && Int(size.height).isMultiple(of: 2))
                    }
                }
            }
        }
        let quality1080 = VideoEncodingQuality.bitRate(size: CGSize(width: 1920, height: 1080), frameRate: 60)
        let quality4k = VideoEncodingQuality.bitRate(size: CGSize(width: 3840, height: 2160), frameRate: 60)
        precondition(quality4k > quality1080 * 2)
        precondition(VideoEncodingQuality.bitRate(size: ultrawide, frameRate: 120) > VideoEncodingQuality.bitRate(size: ultrawide, frameRate: 60))
        precondition(VideoEncodingQuality.bitRate(size: ultrawide, frameRate: 60, recordingMaster: true) > VideoEncodingQuality.bitRate(size: ultrawide, frameRate: 60))
        print("PASS: native content survives every canvas ratio, crop, phone Fit/Fill; presets and quality budgets scale correctly")

        let directory = URL(fileURLWithPath: "/tmp/Screen-export-resolution-check")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceSize = CGSize(width: 640, height: 400)
        let bitmap = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(origin: .zero, size: sourceSize))
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
        // Fine bars reveal an unintended reduction of detail in an actual codec round trip.
        for x in stride(from: 100, to: 540, by: 4) {
            bitmap.fill(CGRect(x: x, y: 80, width: 2, height: 240))
        }
        let source = directory.appendingPathComponent("pattern-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 640, AVVideoHeightKey: 400,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<15 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 400, kCVPixelFormatType_32BGRA, nil, &buffer)
            context.render(CIImage(cgImage: bitmap.makeImage()!), to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 0.5, preferredTimescale: 600))
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let settings = VideoEditSettings(ratio: .landscape, showCursor: false)
        let expected = settings.outputSize(source: sourceSize)
        let result = try await ExportEngine().export(sourceURL: source, keyframes: [], configuration: .init(
            outputURL: directory.appendingPathComponent("pattern-native.mov"), showCursor: false,
            canvasRatio: .landscape, forceCanvas: true))
        let resultAsset = AVURLAsset(url: result)
        let size = try await resultAsset.loadTracks(withMediaType: .video).first!.load(.naturalSize)
        precondition(size == expected)
        let duration = try await resultAsset.load(.duration)
        precondition(abs(duration.seconds - 0.5) < 0.02)
        let image = try await AVAssetImageGenerator(asset: resultAsset).image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let decoded = NSBitmapImageRep(cgImage: image)
        let rect = CanvasGeometry(size: size, layout: .desktop, sourceSize: sourceSize).desktop!
        var contrast: Double = 0
        for x in 110..<520 {
            let horizontal = Int((rect.minX + CGFloat(x) * rect.width / sourceSize.width).rounded())
            let color = decoded.colorAt(x: horizontal, y: decoded.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
            contrast += abs(Double(color.redComponent) - 0.5)
        }
        contrast /= 410
        precondition(contrast > 0.3, "Fine screen detail was lost during native export: \(contrast)")
        let zoomResult = try await ExportEngine().export(sourceURL: source,
            keyframes: [.init(time: 0, transform: .init(zoom: 2, centerX: 0.5, centerY: 0.5))],
            configuration: .init(outputURL: directory.appendingPathComponent("pattern-zoom.mov"), showCursor: false,
                                 canvasRatio: .landscape, forceCanvas: true))
        let zoomSize = try await AVURLAsset(url: zoomResult).loadTracks(withMediaType: .video).first!.load(.naturalSize)
        precondition(zoomSize == expected)
        print("PASS: encoded native canvas is \(size), fine-bar contrast=\(contrast), duration and zoom preserved")

        if CommandLine.arguments.count > 1 {
            let recording = URL(fileURLWithPath: CommandLine.arguments[1])
            let base = recording.deletingPathExtension().path
            let mouse = URL(fileURLWithPath: base + ".mouse.json")
            let webcam = URL(fileURLWithPath: base + "_webcam.mov")
            let microphone = URL(fileURLWithPath: base + "_mic.caf")
            let originalBytes = try Data(contentsOf: recording)
            let keyframes = try await ClickZoomGenerator.generate(from: mouse, sourceVideoURL: recording)
            let output = try await ExportEngine().export(sourceURL: recording, keyframes: keyframes, configuration: .init(
                outputURL: directory.appendingPathComponent("latest-preserve-source.mov"),
                webcamVideoURL: FileManager.default.fileExists(atPath: webcam.path) ? webcam : nil,
                pipPosition: .middleLeft, pipSize: .large, pipShape: .roundedSquare,
                mouseDataURL: mouse, cursorScale: 1.38, cursorShape: .hand,
                canvasRatio: .landscape, wallpaper: .dusk, forceCanvas: true))
            if FileManager.default.fileExists(atPath: microphone.path) {
                _ = try await MediaMuxer.mux(videoURL: output, systemAudioURL: nil, micAudioURL: microphone, removeSourceAudio: false)
            }
            let outputAsset = AVURLAsset(url: output)
            let outputSize = try await outputAsset.loadTracks(withMediaType: .video).first!.load(.naturalSize)
            precondition(outputSize == native)
            let sourceDuration = try await AVURLAsset(url: recording).load(.duration)
            let outputDuration = try await outputAsset.load(.duration)
            precondition(abs(sourceDuration.seconds - outputDuration.seconds) < 0.04)
            let retainedBytes = try Data(contentsOf: recording)
            precondition(retainedBytes == originalBytes)
            if FileManager.default.fileExists(atPath: microphone.path) {
                let tracks = try await outputAsset.loadTracks(withMediaType: .audio)
                precondition(!tracks.isEmpty, "Latest take lost its microphone audio")
            }
            let generator = AVAssetImageGenerator(asset: outputAsset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let webcamGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: webcam))
            webcamGenerator.requestedTimeToleranceBefore = .zero
            webcamGenerator.requestedTimeToleranceAfter = .zero
            for seconds in [0.5, 3.2] {
                let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
                let bitmap = NSBitmapImageRep(cgImage: frame)
                if FileManager.default.fileExists(atPath: webcam.path) {
                    let cameraFrame = try await webcamGenerator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
                    let cameraBitmap = NSBitmapImageRep(cgImage: cameraFrame)
                    let expected = cameraBitmap.colorAt(x: cameraBitmap.pixelsWide / 2, y: cameraBitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                    let actual = bitmap.colorAt(x: Int(24 + outputSize.height * PiPSize.large.fraction / 2),
                                                y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                    precondition(abs(expected.redComponent - actual.redComponent) < 0.12 &&
                                 abs(expected.greenComponent - actual.greenComponent) < 0.12 &&
                                 abs(expected.blueComponent - actual.blueComponent) < 0.12,
                                 "Webcam frame or placement changed at \(seconds)s")
                }
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: directory.appendingPathComponent("latest-preserve-source-\(seconds).png"))
            }
            print("PASS: latest recording re-exported at \(outputSize), audio/zoom/webcam/duration retained; original bytes unchanged")
            print("LATEST EXPORT: \(output.path)")
        }
    }
}
