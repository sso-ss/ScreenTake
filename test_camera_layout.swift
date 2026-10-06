import AppKit
import AVFoundation
import CoreImage

@main
struct CameraLayoutChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("camera-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if !CommandLine.arguments.contains("--keep-fixtures") { try? FileManager.default.removeItem(at: directory) } }
        let context = CIContext()
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        let screen = CIImage(color: .green).cropped(to: bounds)
        let camera = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 360))
            .composited(over: CIImage(color: .blue).cropped(to: bounds))
        func movie(_ name: String, image: CIImage, seconds: Int) async throws -> URL {
            let width = Int(image.extent.width), height = Int(image.extent.height)
            let url = directory.appendingPathComponent(name + ".mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                           AVVideoWidthKey: width, AVVideoHeightKey: height])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            precondition(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            for index in 0..<(seconds * 30) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
                context.render(image, to: buffer!)
                precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: Double(seconds), preferredTimescale: 600))
            await writer.finishWriting()
            precondition(writer.status == .completed)
            return url
        }
        let sourceURL = try await movie("screen", image: screen, seconds: 4)
        let cameraURL = try await movie("camera", image: camera, seconds: 2)
        let full = CameraLayoutSettings(layout: .fullScreen)
        let left = CameraLayoutSettings(layout: .fullScreen, zoom: 2, centerX: 0)
        let right = CameraLayoutSettings(layout: .fullScreen, zoom: 2, centerX: 1)
        let timing = VideoOverlayTiming(start: 1, duration: 2)
        let changes = [CameraLayoutChange(start: 1, settings: CameraLayoutSettings())]
        precondition(CameraLayoutChange.settings(at: 0.9, initial: full, changes: changes) == full)
        precondition(CameraLayoutChange.settings(at: 1, initial: full, changes: changes).layout == .overlay)
        let attachedRange = VideoOverlayTimelineRange(outputStart: 2, sourceStart: 0.5, duration: 1.5)
        let attachedSplit = CameraLayoutChange.split(at: 2.75, in: attachedRange, initial: full, changes: changes)
        precondition(attachedSplit?.start == 1.25 && attachedSplit?.settings.layout == .overlay)
        precondition(CameraLayoutChange.split(at: 1, in: attachedRange, initial: full, changes: changes) == nil)
        precondition(CameraLayoutChange.split(at: 2, in: attachedRange, initial: full, changes: changes) == nil)
        precondition(CameraLayoutChange.split(at: 3.5, in: attachedRange, initial: full, changes: changes) == nil)
        precondition(CameraLayoutChange.split(at: 2.5, in: attachedRange, initial: full, changes: changes) == nil)
        precondition(CameraLayoutChange.split(at: 2.51, in: attachedRange, initial: full, changes: changes) == nil)
        let reordered = EditedTimeline(ranges: [CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600)),
                                               CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))])
        let cameraRanges = VideoOverlayTimelineRange.visible(timing: nil, timeline: reordered, sourceDuration: 4)
        let reorderedSplit = CameraLayoutChange.split(at: 0.5, in: cameraRanges[0], initial: full, changes: [])
        precondition(reorderedSplit?.start == 2.5 && reorderedSplit?.settings == full)
        print("PASS: camera split boundaries, inherited layout, trimmed take and reordered screen timing")
        let crop = CameraLayoutSettings(layout: .fullScreen, zoom: 3, centerX: 1, centerY: 0).crop(in: bounds, output: CGSize(width: 240, height: 400))
        precondition(bounds.contains(crop) && crop.maxX == bounds.maxX && crop.maxY == bounds.maxY)
        let invalid = CameraLayoutSettings(layout: .fullScreen, zoom: .nan, centerX: .infinity, centerY: -.infinity)
        precondition(invalid.crop(in: bounds, output: bounds.size) == bounds)
        print("PASS: camera crop boundaries and layout switch timing")

        let smoothFull = CameraLayoutSettings(layout: .fullScreen, smoothTransition: true)
        let smoothChanges = [CameraLayoutChange(start: 1, settings: smoothFull)]
        let halfway = CameraLayoutChange.transition(at: 1.2, initial: CameraLayoutSettings(), changes: smoothChanges)!
        precondition(abs(halfway.progress - 0.5) < 0.0001)
        precondition(CameraLayoutChange.transition(at: 0.9, initial: CameraLayoutSettings(), changes: smoothChanges) == nil)
        precondition(CameraLayoutChange.transition(at: 1.4, initial: CameraLayoutSettings(), changes: smoothChanges) == nil)
        precondition(CameraLayoutChange.transition(at: .nan, initial: full, changes: smoothChanges) == nil)
        precondition(CameraLayoutChange.transition(at: 1.1, initial: full, changes: changes) == nil)
        let shortChanges = smoothChanges + [CameraLayoutChange(start: 1.1, settings: CameraLayoutSettings(smoothTransition: true))]
        precondition(abs(CameraLayoutChange.transition(at: 1.05, initial: CameraLayoutSettings(), changes: shortChanges)!.progress - 0.5) < 0.0001)
        let legacy = try JSONDecoder().decode(CameraLayoutSettings.self, from: Data("{\"layout\":\"fullScreen\"}".utf8))
        precondition(!legacy.smoothTransition)
        let decodedSmooth = try JSONDecoder().decode(CameraLayoutSettings.self, from: JSONEncoder().encode(smoothFull))
        precondition(decodedSmooth == smoothFull)
        print("PASS: eased timing, direct cuts, short sections and legacy transition settings")

        // Green is screen; red/blue are camera. Check corners to detect hidden
        // screen content, wrong crops, letterboxing and held camera end frames.
        for (name, initial, changes, timing, ratio, samples) in [
            ("full", full, [], Optional(timing), CanvasRatio.original, [(0.5, 1), (1.5, 0), (3.5, 1)]),
            ("left", left, [], Optional(timing), .original, [(1.5, 0)]),
            ("right", right, [], Optional(timing), .original, [(1.5, 2)]),
            ("portrait-right", right, [], Optional(timing), .vertical, [(1.5, 2)]),
            ("split", full, changes, Optional(timing), .original, [(1.5, 0), (2.5, 1)]),
            ("trimmed-take", full, changes, Optional(VideoOverlayTiming(start: 0.5, duration: 1.5, sourceStart: 0.5)), .original, [(0.75, 0), (1.25, 1), (2.5, 1)]),
            ("sidecar-end", full, [], nil, .original, [(0.5, 0), (2.5, 1)])
        ] {
            let settings = VideoEditSettings(ratio: ratio, backgroundEnabled: ratio != .original, showCursor: false,
                                             webcamEnabled: true, cameraLayout: initial, cameraLayoutChanges: changes,
                                             videoOverlayURL: cameraURL, videoOverlayTiming: timing)
            let item = try await LiveVideoPreview.makeItem(.init(source: sourceURL, audio: nil, mouse: nil, webcam: cameraURL, settings: settings))
            let preview = AVAssetImageGenerator(asset: item.asset)
            preview.videoComposition = item.videoComposition
            preview.requestedTimeToleranceBefore = .zero
            preview.requestedTimeToleranceAfter = .zero
            let exportedURL = try await ExportEngine().export(sourceURL: sourceURL, keyframes: [], configuration: .init(
                outputURL: directory.appendingPathComponent(name + ".mov"), webcamVideoURL: cameraURL,
                videoOverlayTiming: timing, pipShape: .roundedSquare, cameraLayout: initial,
                cameraLayoutChanges: changes, showCursor: false, canvasRatio: ratio, forceCanvas: ratio != .original))
            let export = AVAssetImageGenerator(asset: AVURLAsset(url: exportedURL))
            export.requestedTimeToleranceBefore = .zero
            export.requestedTimeToleranceAfter = .zero
            for (seconds, channel) in samples {
                for (kind, generator) in [("preview", preview), ("export", export)] {
                    let frame = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
                    let points = initial.zoom > 1 && channel != 1
                        ? [CGPoint(x: 8, y: 8), CGPoint(x: frame.width - 8, y: frame.height - 8)]
                        : [CGPoint(x: 8, y: 8)]
                    for point in points {
                        var pixel = [UInt8](repeating: 0, count: 4)
                        context.render(CIImage(cgImage: frame), toBitmap: &pixel, rowBytes: 4,
                                       bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                        precondition(pixel[channel] > 180 && pixel[(channel + 1) % 3] < 80,
                                     "\(name) \(kind) at \(seconds): expected channel \(channel), got \(pixel)")
                    }
                }
            }
            print("PASS: \(name) preview and export agree")
        }

        // Fine detail in a landscape camera must survive portrait framing and
        // zoom. Resizing to the output bounds before cropping loses that detail.
        let detailBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var detail = CIImage(color: .black).cropped(to: detailBounds)
        for x in stride(from: 0, to: 1920, by: 16) {
            detail = CIImage(color: .white).cropped(to: CGRect(x: x, y: 0, width: 8, height: 1080))
                .composited(over: detail)
        }
        let detailURL = try await movie("detail-camera", image: detail, seconds: 1)
        let detailLayout = CameraLayoutSettings(layout: .fullScreen, zoom: 2)
        let detailSettings = VideoEditSettings(ratio: .vertical, backgroundEnabled: true, showCursor: false,
                                              webcamEnabled: true, cameraLayout: detailLayout,
                                              videoOverlayURL: detailURL)
        let detailRenderer = LiveEditFrameRenderer(sourceSize: bounds.size, settings: detailSettings, keyframes: [], mouse: nil)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let nativeFrame = OverlayVideoFrames(url: detailURL).image(at: time)!
        let reference = detailRenderer.render(screen, at: time.seconds, webcamImage: nativeFrame, webcamTime: time.seconds)
        let detailItem = try await LiveVideoPreview.makeItem(.init(source: sourceURL, audio: nil, mouse: nil,
                                                                 webcam: detailURL, settings: detailSettings))
        let detailPreview = AVAssetImageGenerator(asset: detailItem.asset)
        detailPreview.videoComposition = detailItem.videoComposition
        let actual = CIImage(cgImage: try detailPreview.copyCGImage(at: time, actualTime: nil))
        func difference(_ image: CIImage) -> Double {
            let width = Int(detailRenderer.outputSize.width)
            let row = CGRect(x: 0, y: floor(detailRenderer.outputSize.height / 2), width: CGFloat(width), height: 1)
            var expected = [UInt8](repeating: 0, count: width * 4)
            var pixels = expected
            context.render(reference, toBitmap: &expected, rowBytes: width * 4, bounds: row,
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: row,
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return stride(from: 0, to: width * 4, by: 4).reduce(0.0) { $0 + abs(Double(expected[$1]) - Double(pixels[$1])) } / Double(width)
        }
        let error = difference(actual)
        let reducedFrame = OverlayVideoFrames(url: detailURL, maximumSize: detailRenderer.outputSize).image(at: time)!
        let reduced = detailRenderer.render(screen, at: time.seconds, webcamImage: reducedFrame, webcamTime: time.seconds)
        let reducedError = difference(reduced)
        precondition(error < 10 && reducedError > error + 10,
                     "Camera detail lost: preview error \(error), premature resizing error \(reducedError)")
        print("PASS: full-screen portrait zoom preserves native camera detail (error \(error); old resize \(reducedError))")

        for (name, initial, target) in [
            ("expand", CameraLayoutSettings(), smoothFull),
            ("shrink", full, CameraLayoutSettings(smoothTransition: true)),
            ("reframe", left, CameraLayoutSettings(layout: .fullScreen, zoom: 2, centerX: 1, smoothTransition: true))
        ] {
            let transitions = [CameraLayoutChange(start: 1, settings: target)]
            let take = VideoOverlayTiming(start: 1, duration: 1.5, sourceStart: 0.5)
            let settings = VideoEditSettings(backgroundEnabled: false, showCursor: false, webcamEnabled: true,
                                             cameraLayout: initial, cameraLayoutChanges: transitions,
                                             videoOverlayURL: cameraURL, videoOverlayTiming: take)
            let item = try await LiveVideoPreview.makeItem(.init(source: sourceURL, audio: nil, mouse: nil,
                                                               webcam: cameraURL, settings: settings))
            let preview = AVAssetImageGenerator(asset: item.asset)
            preview.videoComposition = item.videoComposition
            preview.requestedTimeToleranceBefore = .zero
            preview.requestedTimeToleranceAfter = .zero
            let url = try await ExportEngine().export(sourceURL: sourceURL, keyframes: [], configuration: .init(
                outputURL: directory.appendingPathComponent("smooth-\(name).mov"), webcamVideoURL: cameraURL,
                videoOverlayTiming: take, cameraLayout: initial, cameraLayoutChanges: transitions, showCursor: false))
            let export = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            export.requestedTimeToleranceBefore = .zero
            export.requestedTimeToleranceAfter = .zero
            var areas: [Double: Int] = [:]
            for seconds in [1.5, 1.6, 1.7, 1.8, 1.9, 1.6] {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                var previewTime = CMTime.zero, exportTime = CMTime.zero
                let a = CIImage(cgImage: try preview.copyCGImage(at: time, actualTime: &previewTime))
                let b = CIImage(cgImage: try export.copyCGImage(at: time, actualTime: &exportTime))
                var pixelsA = [UInt8](repeating: 0, count: 640 * 360 * 4), pixelsB = pixelsA
                context.render(a, toBitmap: &pixelsA, rowBytes: 640 * 4, bounds: bounds,
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                context.render(b, toBitmap: &pixelsB, rowBytes: 640 * 4, bounds: bounds,
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                // These fixtures use green for screen and red/blue for camera.
                // Compare their geometry, allowing the existing encoder color
                // conversion to change brightness without moving those regions.
                func region(_ pixels: [UInt8], at index: Int) -> Int {
                    let channels = (0..<3).map { Int(pixels[index + $0]) }
                    if channels.max()! - channels.min()! < 80 { return 3 }
                    return channels.firstIndex(of: channels.max()!)!
                }
                let mismatches = stride(from: 0, to: pixelsA.count, by: 4).filter {
                    region(pixelsA, at: $0) != region(pixelsB, at: $0)
                }.count
                let error = Double(mismatches) / Double(640 * 360)
                if error >= 0.01 {
                    FileHandle.standardError.write(Data("\(name) request \(seconds), preview \(previewTime.seconds), export \(exportTime.seconds), error \(error), fixtures \(directory.path)\n".utf8))
                    for (label, image) in [("preview", a), ("export", b)] {
                        try NSBitmapImageRep(cgImage: context.createCGImage(image, from: bounds)!).representation(using: .png, properties: [:])!
                            .write(to: directory.appendingPathComponent("\(name)-\(seconds)-\(label).png"))
                    }
                }
                precondition(error < 0.01, "\(name) transition geometry mismatch at \(seconds): \(error)")
                areas[seconds] = stride(from: 0, to: pixelsA.count, by: 4).filter {
                    pixelsA[$0 + 1] < 80 && (pixelsA[$0] > 180 || pixelsA[$0 + 2] > 180)
                }.count
                if CommandLine.arguments.contains("--keep-fixtures") && seconds == 1.7 {
                    let frame = context.createCGImage(a, from: bounds)!
                    try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!
                        .write(to: directory.appendingPathComponent("smooth-\(name)-middle.png"))
                }
            }
            if name == "expand" { precondition(areas[1.5]! < areas[1.7]! && areas[1.7]! < areas[1.9]!) }
            if name == "shrink" { precondition(areas[1.5]! > areas[1.7]! && areas[1.7]! > areas[1.9]!) }
            print("PASS: \(name) moves smoothly, preview/export agree, trimmed timing and backward seeks")
        }
        if CommandLine.arguments.contains("--keep-fixtures") { print("Preview fixtures: \(directory.path)") }
    }
}
