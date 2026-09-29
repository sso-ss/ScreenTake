import AVFoundation
import CoreImage
import XCTest
@testable import ScreenMobile

@MainActor
final class VideoWorkflowTests: XCTestCase {
    func testTrimmedExportPreservesAudioAndMatchesPreview() async throws {
        let source = try await makeFixture()
        let model = EditorModel()
        await model.importFile(source)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.sourceSize, CGSize(width: 320, height: 640))
        model.settings.format = .square
        model.settings.background = .white
        model.settings.trimStart = 1
        model.settings.trimEnd = 3
        model.settings.zoomEnabled = true
        model.settings.zoomStart = 1
        model.settings.zoomEnd = 3
        model.settings.zoomAmount = 2
        model.settings.focusX = 0.3
        model.settings.focusY = 0.7
        model.applyEdits()
        let output = try await export(model)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let outputSize = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(outputSize, CGSize(width: 1080, height: 1080))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let audiblePeak = try await audioPeak(asset)
        XCTAssertGreaterThan(audiblePeak, 0.1)
        let originalFrame = try await image(from: AVURLAsset(url: source), at: 2)
        let rendered = VideoRenderer.render(CIImage(cgImage: originalFrame), at: 2, settings: model.settings,
                                            canvas: model.canvasSize,
                                            background: VideoRenderer.backgroundImage(.white, bounds: CGRect(origin: .zero, size: model.canvasSize)))
        let actual = CIImage(cgImage: try await image(from: asset, at: 1))
        var maximumDifference = 0.0
        for horizontal in [0.05, 0.3, 0.45, 0.55, 0.7, 0.95] {
            for vertical in [0.05, 0.25, 0.45, 0.75, 0.95] {
                let point = CGPoint(x: horizontal * 1080, y: vertical * 1080)
                let expectedPixel = pixel(rendered, at: point)
                let actualPixel = pixel(actual, at: point)
                for channel in 0..<3 {
                    maximumDifference = max(maximumDifference, abs(Double(expectedPixel[channel]) - Double(actualPixel[channel])) / 255)
                }
            }
        }
        XCTAssertLessThan(maximumDifference, 0.13, "Export must match the shared preview renderer")
        let corner = pixel(actual, at: CGPoint(x: 20, y: 20))
        XCTAssertTrue(corner[0] > 240 && corner[1] > 240 && corner[2] > 240)
        model.saveDraft()
        let restored = EditorModel()
        await restored.restoreDraft()
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.settings, model.settings)
        XCTAssertEqual(restored.sourceURL, model.sourceURL)
    }

    func testMutedExportAndRotatedSource() async throws {
        let source = try await makeFixture(rotated: true)
        let model = EditorModel()
        await model.importFile(source)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.sourceSize, CGSize(width: 640, height: 320))
        model.settings.format = .landscape
        model.settings.background = .black
        model.settings.muted = true
        model.settings.trimEnd = 0.5
        model.applyEdits()
        let output = try await export(model)
        let asset = AVURLAsset(url: output)
        let mutedPeak = try await audioPeak(asset)
        XCTAssertLessThan(mutedPeak, 0.001)
        let frame = try await image(from: asset, at: 0.2)
        XCTAssertEqual(frame.width, 1920)
        XCTAssertEqual(frame.height, 1080)
        let center = pixel(CIImage(cgImage: frame), at: CGPoint(x: 800, y: 600))
        XCTAssertGreaterThan(Int(center[0]) + Int(center[1]) + Int(center[2]), 100)
    }

    func testInvalidImportKeepsCurrentVideo() async throws {
        let model = EditorModel()
        await model.importFile(try await makeFixture())
        let previous = model.sourceURL
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent("invalid.mov")
        try Data("not a movie".utf8).write(to: invalid)
        await model.importFile(invalid)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.sourceURL, previous)
        XCTAssertFalse(model.isImporting)
    }

    func testExportCancellationDoesNotProduceOutput() async throws {
        let model = EditorModel()
        await model.importFile(try await makeFixture())
        model.beginExport()
        model.cancelExport()
        let deadline = Date().addingTimeInterval(30)
        while model.isExporting && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(model.isExporting)
        XCTAssertNil(model.exportedURL)
        XCTAssertNil(model.errorMessage)
    }

    func testBundledBackgroundsRender() {
        for background in MobileBackground.allCases {
            if let name = background.assetName { XCTAssertNotNil(UIImage(named: name), name) }
            let image = VideoRenderer.backgroundImage(background, bounds: CGRect(x: 0, y: 0, width: 1080, height: 1920))
            XCTAssertEqual(image.extent.size, CGSize(width: 1080, height: 1920))
            XCTAssertNotNil(VideoRenderer.context.createCGImage(image, from: image.extent))
        }
    }

    private func export(_ model: EditorModel) async throws -> URL {
        model.beginExport()
        let deadline = Date().addingTimeInterval(90)
        while model.isExporting && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(model.isExporting, "Export timed out")
        XCTAssertNil(model.errorMessage)
        return try XCTUnwrap(model.exportedURL)
    }

    private func image(from asset: AVAsset, at time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    private func pixel(_ image: CIImage, at point: CGPoint) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        VideoRenderer.context.render(image, toBitmap: &bytes, rowBytes: 4,
                                     bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    private func audioPeak(_ asset: AVAsset) async throws -> Float {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer(), let data = CMSampleBufferGetDataBuffer(sample) {
            var pointer: UnsafeMutablePointer<Int8>?
            var length = 0
            CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            if let pointer {
                let values = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
                for index in 0..<(length / 4) { peak = max(peak, abs(values[index])) }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        return peak
    }

    private func makeFixture(rotated: Bool = false) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let videoURL = folder.appendingPathComponent("video.mov")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 640
        ])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 640, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 640,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 640), format: format).image { drawing in
            let colors: [UIColor] = [.systemRed, .systemGreen, .systemBlue, .systemYellow]
            for index in 0..<4 {
                colors[index].setFill()
                drawing.fill(CGRect(x: (index % 2) * 160, y: (index / 2) * 320, width: 160, height: 320))
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: UIColor.white]
            ("Sample recording" as NSString).draw(at: CGPoint(x: 20, y: 40), withAttributes: attributes)
        }
        let base = CIImage(cgImage: try XCTUnwrap(image.cgImage))
        for index in 0..<120 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            let marker = CIImage(color: .white).cropped(to: CGRect(x: 20 + index, y: 40, width: 20, height: 20))
            VideoRenderer.context.render(marker.composited(over: base), to: pixelBuffer)
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let audioURL = folder.appendingPathComponent("tone.caf")
        let audioFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let audioFile = try AVAudioFile(forWriting: audioURL, settings: audioFormat.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 192000))
        buffer.frameLength = 192000
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<192000 { samples[index] = 0.25 * sin(Float(index) * 2 * .pi * 440 / 48000) }
        try audioFile.write(from: buffer)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let compositionVideo = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try compositionVideo.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600)), of: videoTrack, at: .zero)
        compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        let audioAsset = AVURLAsset(url: audioURL)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let compositionAudio = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try compositionAudio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600)), of: audioTrack, at: .zero)
        let output = folder.appendingPathComponent("Sample Recording.mov")
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: output, as: .mov)
        return output
    }
}