import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import os

/// Offline export engine that reads a recorded video, applies per-frame camera transforms,
/// and writes a new video file with zoom/pan effects.
///
/// Pipeline: AVAssetReader → CIImage → TransformApplicator → CIContext → CVPixelBuffer → AVAssetWriter
@MainActor
final class ExportEngine: ObservableObject {

    // MARK: - Progress

    @Published var progress: Double = 0
    @Published var isExporting: Bool = false

    // MARK: - Configuration

    struct Configuration {
        var outputURL: URL
        var codec: AVVideoCodecType = .hevc
        var fileType: AVFileType = .mov
        var bitRate: Int = 20_000_000
        var keyFrameInterval: Int = 60

        /// Output resolution. Nil = same as source.
        var outputSize: CGSize?

        /// Webcam PiP overlay settings
        var webcamVideoURL: URL?
        var videoOverlayTiming: VideoOverlayTiming?
        var videoOverlayTrim: VideoTrim?
        var pipPosition: PiPPosition = .bottomRight
        var pipSize: PiPSize = .medium
        var pipShape: PiPShape = .circle

        /// Mouse data for cursor overlay on fill frames
        var mouseDataURL: URL?
        /// Cursor scale factor (matches recording setting)
        var cursorScale: Double = 1.0
        var cursorShape: CursorShape = .arrow
        var showCursor: Bool = true
        var canvasRatio: CanvasRatio = .original
        var deviceLayout: DeviceLayout = .desktop
        var wallpaper: BackgroundStyle.WallpaperPreset = .sonoma
        var desktopCornerRadius: Double = 0.025
        var phoneVideoURL: URL?
        var preserveSourceAudio: Bool = false
        var phoneCrop: PhoneCrop = PhoneCrop()
        var phoneContentMode: PhoneContentMode = .fit
        var forceCanvas: Bool = false

        var usesCanvas: Bool { forceCanvas || canvasRatio != .original || deviceLayout != .desktop }
    }

    // MARK: - Export

    /// Export a video with camera transforms applied.
    ///
    /// - Parameters:
    ///   - sourceURL: URL of the recorded .mov file.
    ///   - keyframes: Camera keyframes defining zoom/pan animation.
    ///   - configuration: Export settings (codec, bitrate, output path).
    /// - Returns: URL of the exported file.
    nonisolated func export(
        sourceURL: URL,
        keyframes: [CameraKeyframe],
        configuration: Configuration
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw ExportError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let orientedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let originalSize = CGSize(
            width: abs(orientedBounds.width),
            height: abs(orientedBounds.height)
        )
        let cropRect = configuration.phoneCrop.pixelRect(in: originalSize)
        let sourceSize = cropRect.size
        let normalizedCrop = CGRect(x: cropRect.minX / originalSize.width, y: 1 - cropRect.maxY / originalSize.height,
                                    width: cropRect.width / originalSize.width, height: cropRect.height / originalSize.height)
        let automaticSize = configuration.canvasRatio.size(source: configuration.usesCanvas ? originalSize : sourceSize)
        let outputSize = configuration.outputSize ?? CGSize(width: max(2, floor((automaticSize.width + 0.000001) / 2) * 2),
                                                           height: max(2, floor((automaticSize.height + 0.000001) / 2) * 2))
        let canvas = configuration.usesCanvas
            ? CanvasCompositor(size: outputSize, sourceSize: sourceSize, layout: configuration.deviceLayout, wallpaper: configuration.wallpaper, phoneContentMode: configuration.phoneContentMode, desktopCornerRadius: CGFloat(configuration.desktopCornerRadius)) : nil
        var phoneReader: TimedVideoReader?
        if configuration.deviceLayout == .duo {
            guard let phoneURL = configuration.phoneVideoURL else { throw ExportError.missingPhoneVideo }
            phoneReader = try await TimedVideoReader(url: phoneURL)
        }
        Log.export.info("Export started: \(Int(sourceSize.width))x\(Int(sourceSize.height)) → \(Int(outputSize.width))x\(Int(outputSize.height))")

        // Load mouse position data for cursor overlay on fill frames
        var mousePositions: [MouseDataRecorder.MousePosition] = []
        var mousePaddingRatio: CGFloat = 0
        var mouseContentScale: CGFloat = 1.0
        if let mouseURL = configuration.mouseDataURL,
           let data = try? Data(contentsOf: mouseURL),
           let recording = try? JSONDecoder().decode(MouseDataRecorder.MouseRecording.self, from: data) {
            mousePositions = recording.positions

            let captureWidth = recording.screenBounds.width * recording.scaleFactor
            let captureHeight = recording.screenBounds.height * recording.scaleFactor
            let videoWidth = Double(originalSize.width)
            let videoHeight = Double(originalSize.height)
            if videoWidth > captureWidth + 1 {
                mousePaddingRatio = CGFloat((videoWidth - captureWidth) / (2.0 * videoWidth))
            }
            mouseContentScale = 1.0 - 2.0 * mousePaddingRatio

            let timeRange = mousePositions.isEmpty ? "empty" : "\(String(format: "%.2f", mousePositions.first!.timestamp))s-\(String(format: "%.2f", mousePositions.last!.timestamp))s"
            Log.export.info("Cursor data: \(mousePositions.count) positions [\(timeRange)], padding=\(String(format: "%.4f", mousePaddingRatio)), capture=\(captureWidth)x\(captureHeight), video=\(videoWidth)x\(videoHeight)")
        }

        // Generate cursor image for fill frame overlay — match recording size × zoom
        let cursorBaseSize: CGFloat = 24 * CGFloat(configuration.cursorScale)
        let cursorCGImage = configuration.showCursor
            ? CursorImageProvider.cgImage(width: cursorBaseSize, screenScale: 2.0, shape: configuration.cursorShape) : nil
        let cursorHotspot = cursorCGImage.map {
            CursorImageProvider.hotspot(shape: configuration.cursorShape, imageSize: CGSize(width: $0.width, height: $0.height))
        } ?? .zero

        // Set up reader
        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(readerOutput) else {
            throw ExportError.readerSetupFailed
        }
        reader.add(readerOutput)

        var audioReaderWriterPairs: [(reader: AVAssetReaderTrackOutput, writer: AVAssetWriterInput)] = []
        if configuration.preserveSourceAudio {
            for track in try await asset.loadTracks(withMediaType: .audio) {
                let audioOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                let descriptions = try await track.load(.formatDescriptions)
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: descriptions.first)
                audioInput.expectsMediaDataInRealTime = false
                guard reader.canAdd(audioOutput) else { throw ExportError.readerSetupFailed }
                reader.add(audioOutput)
                audioReaderWriterPairs.append((audioOutput, audioInput))
            }
        }

        // Remove existing output file
        let fm = FileManager.default
        if fm.fileExists(atPath: configuration.outputURL.path) {
            try fm.removeItem(at: configuration.outputURL)
        }

        // Set up writer
        let writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: configuration.fileType)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: configuration.codec,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.bitRate,
                AVVideoMaxKeyFrameIntervalKey: configuration.keyFrameInterval,
                AVVideoProfileLevelKey: configuration.codec == .hevc
                    ? "HEVC_Main_AutoLevel"
                    : AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )

        guard writer.canAdd(videoInput) else {
            throw ExportError.writerSetupFailed
        }
        writer.add(videoInput)

        // Audio passthrough writers (one per audio track)
        for pair in audioReaderWriterPairs {
            guard writer.canAdd(pair.writer) else { throw ExportError.writerSetupFailed }
            writer.add(pair.writer)
        }

        // Start reading/writing
        guard reader.startReading() else {
            throw ExportError.readerStartFailed(reader.error)
        }
        guard writer.startWriting() else {
            throw ExportError.writerStartFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let evaluator = FrameEvaluator(keyframes: keyframes)
        func camera(at time: TimeInterval) -> CameraTransform {
            var transform = evaluator.evaluate(at: time)
            transform.centerX = (transform.centerX - normalizedCrop.minX) / normalizedCrop.width
            transform.centerY = (transform.centerY - normalizedCrop.minY) / normalizedCrop.height
            return transform.clamped()
        }
        Log.export.info("Export keyframes: \(keyframes.count) keyframes")
        for (i, kf) in keyframes.prefix(20).enumerated() {
            Log.export.info("  kf[\(i)] t=\(String(format: "%.2f", kf.time))s zoom=\(String(format: "%.2f", kf.transform.zoom))")
        }
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        let totalSeconds = CMTimeGetSeconds(duration)
        var lastProgressUpdate: TimeInterval = 0
        var framesRead = 0
        var framesWritten = 0
        var droppedFrameCount = 0

        // Set up webcam reader if PiP is enabled
        var webcamReader: AVAssetReader?
        var webcamReaderOutput: AVAssetReaderTrackOutput?
        var compositor: WebcamCompositor?
        var overlayFrames: OverlayVideoFrames?
        let overlayTimeline = try configuration.videoOverlayTrim?.timeline(duration: duration)

        if let webcamURL = configuration.webcamVideoURL,
           FileManager.default.fileExists(atPath: webcamURL.path) {
            let webcamAsset = AVURLAsset(url: webcamURL)
            if configuration.videoOverlayTiming != nil {
                overlayFrames = OverlayVideoFrames(url: webcamURL)
                compositor = WebcamCompositor(outputSize: outputSize, position: configuration.pipPosition,
                                               pipSize: configuration.pipSize, shape: configuration.pipShape)
            } else if let webcamTrack = try? await webcamAsset.loadTracks(withMediaType: .video).first {
                let wReader = try AVAssetReader(asset: webcamAsset)
                let wOutput = AVAssetReaderTrackOutput(track: webcamTrack, outputSettings: readerSettings)
                wOutput.alwaysCopiesSampleData = true
                if wReader.canAdd(wOutput) {
                    wReader.add(wOutput)
                    wReader.startReading()
                    webcamReader = wReader
                    webcamReaderOutput = wOutput
                    compositor = WebcamCompositor(
                        outputSize: outputSize,
                        position: configuration.pipPosition,
                        pipSize: configuration.pipSize,
                        shape: configuration.pipShape
                    )
                    Log.export.info("Webcam PiP reader initialized")
                }
            }
        }

        // Process frames
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()

            // Video processing
            group.enter()
            let videoQueue = DispatchQueue(label: "com.screen.export.video", qos: .userInitiated)

            // Track the current webcam frame so we can hold it across multiple video frames
            // (webcam is ~30fps, screen is 60fps — we must sync by timestamp, not 1:1)
            var currentWebcamImage: CIImage?
            var pendingWebcamSample: CMSampleBuffer?
            var webcamExhausted = false

            // VFR gap filling: when zoom is active and source frames are sparse,
            // synthesize intermediate frames to keep the zoom animation smooth.
            var lastAppendedPTS: CMTime = CMTime(value: -1, timescale: 600)
            var lastSourceImage: CIImage?
            let hasCursorAnimation = cursorCGImage != nil && !mousePositions.isEmpty
            let fillFrameInterval: TimeInterval = hasCursorAnimation ? 1.0 / 60.0 : 1.0 / 30.0
            var nextCursorFrameIndex: Int64 = 0

            /// Safely append a pixel buffer, ensuring strictly increasing PTS.
            /// Catches ObjC exceptions from AVAssetWriter to prevent crashes.
            func safeAppend(_ buffer: CVPixelBuffer, at pts: CMTime) -> Bool {
                guard CMTimeCompare(pts, lastAppendedPTS) > 0 else { return false }
                guard writer.status == .writing else { return false }
                do {
                    try ObjCExceptionCatcher.`try` {
                        adaptor.append(buffer, withPresentationTime: pts)
                    }
                    lastAppendedPTS = pts
                    return true
                } catch {
                    Log.export.warning("safeAppend: ObjC exception caught at PTS \(CMTimeGetSeconds(pts)): \(error.localizedDescription)")
                    return false
                }
            }

            /// Interpolate mouse position at a given time from the positions array.
            func cursorPosition(at time: TimeInterval) -> (x: Double, y: Double)? {
                guard !mousePositions.isEmpty else { return nil }
                var lo = 0, hi = mousePositions.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if mousePositions[mid].timestamp < time { lo = mid + 1 } else { hi = mid }
                }
                if lo == 0 { return (mousePositions[0].x, mousePositions[0].y) }
                if lo >= mousePositions.count { return (mousePositions.last!.x, mousePositions.last!.y) }
                let a = mousePositions[lo - 1], b = mousePositions[lo]
                let dt = b.timestamp - a.timestamp
                guard dt > 0.0001 else { return (a.x, a.y) }
                let t = (time - a.timestamp) / dt
                return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            }

            /// Draw cursor on a pixel buffer at the correct position for the given zoom transform.
            var cursorLogCount = 0

            func drawCursor(on buffer: CVPixelBuffer, transform: CameraTransform, atTime time: TimeInterval) {
                guard let cursorCG = cursorCGImage else { return }
                guard let pos = cursorPosition(at: time) else { return }

                let width = CVPixelBufferGetWidth(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                let clamped = transform.clamped()

                // Mouse pos is normalized 0-1 within the capture area.
                // Remap to video-frame normalized coords accounting for window padding.
                // X: left=0, right=1 (same everywhere)
                // Y: mouse pos.y uses NSEvent: 0=bottom, 1=top
                //    CameraTransform centerY: 0=top, 1=bottom (top-left origin)
                //    ClickZoomGenerator maps clicks with: 1.0 - click.y (flips to top-left)
                //    So we must also flip here to match the CameraTransform space.
                let sourceX = mousePaddingRatio + CGFloat(pos.x) * mouseContentScale
                let sourceY = mousePaddingRatio + (1.0 - CGFloat(pos.y)) * mouseContentScale
                guard normalizedCrop.contains(CGPoint(x: sourceX, y: sourceY)) else { return }
                let mouseNormX = (sourceX - normalizedCrop.minX) / normalizedCrop.width
                let mouseNormY = (sourceY - normalizedCrop.minY) / normalizedCrop.height

                // Viewport in CameraTransform space (top-left origin)
                let halfViewW = 0.5 / clamped.zoom
                let halfViewH = 0.5 / clamped.zoom
                let vpLeft = clamped.centerX - halfViewW
                let vpTop = clamped.centerY - halfViewH

                // Map to output pixel coords (top-left: row 0 = top)
                let outX = (mouseNormX - vpLeft) / (2.0 * halfViewW) * CGFloat(width)
                let outY = (mouseNormY - vpTop) / (2.0 * halfViewH) * CGFloat(height)

                if cursorLogCount < 20 && clamped.zoom > 1.01 {
                    cursorLogCount += 1
                    let msg = "drawCursor t=\(String(format: "%.2f", time)) rawPos=(\(String(format: "%.3f", pos.x)),\(String(format: "%.3f", pos.y))) normPos=(\(String(format: "%.3f", mouseNormX)),\(String(format: "%.3f", mouseNormY))) zoom=\(String(format: "%.1f", clamped.zoom)) center=(\(String(format: "%.3f", clamped.centerX)),\(String(format: "%.3f", clamped.centerY))) out=(\(Int(outX)),\(Int(outY))) buf=\(width)x\(height)\n"
                    if cursorLogCount == 1 {
                        try? msg.write(toFile: "/tmp/cursor_debug.txt", atomically: false, encoding: .utf8)
                    } else if let fh = FileHandle(forWritingAtPath: "/tmp/cursor_debug.txt") {
                        fh.seekToEndOfFile()
                        if let d = msg.data(using: String.Encoding.utf8) { fh.write(d) }
                        fh.closeFile()
                    }
                }

                // Skip if cursor is outside the visible viewport
                guard outX >= -100 && outX < CGFloat(width) + 100 &&
                      outY >= -100 && outY < CGFloat(height) + 100 else { return }

                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

                guard let ctx = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer),
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ) else { return }

                // Pixel buffer from ciContext.render has row 0 at top.
                // CGContext has origin at bottom-left, but data is top-down.
                // The VFRRecordingManager draws cursor using the same pattern:
                // flip context, then un-flip for cursor draw.
                ctx.translateBy(x: 0, y: CGFloat(height))
                ctx.scaleBy(x: 1, y: -1)
                // Now (0,0) = top-left, outX/outY are in top-left coords

                let cursorW = CGFloat(cursorCG.width)
                let cursorH = CGFloat(cursorCG.height)
                // Draw cursor with its tip at (outX, outY)
                // Need to un-flip for CGImage draw (ctx.draw renders bottom-up)
                ctx.saveGState()
                ctx.translateBy(x: outX - cursorHotspot.x, y: outY - cursorHotspot.y)
                ctx.translateBy(x: 0, y: cursorH)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cursorCG, in: CGRect(x: 0, y: 0, width: cursorW, height: cursorH))
                ctx.restoreGState()
            }

            /// Render a single frame with transform, webcam, and write it.
            func renderAndWrite(
                image: CIImage,
                transform: CameraTransform,
                at pts: CMTime,
                time: TimeInterval = -1
            ) -> Bool {
                return autoreleasepool {
                // Skip if PTS would not be strictly increasing
                guard CMTimeCompare(pts, lastAppendedPTS) > 0 else { return false }
                guard writer.status == .writing else { return false }

                // Wait for the encoder to be ready (backpressure)
                var waitAttempts = 0
                while !videoInput.isReadyForMoreMediaData && waitAttempts < 100 {
                    Thread.sleep(forTimeInterval: 0.01)
                    waitAttempts += 1
                }
                guard videoInput.isReadyForMoreMediaData else { return false }

                if let webcamOutput = webcamReaderOutput {
                    while !webcamExhausted {
                        if pendingWebcamSample == nil {
                            pendingWebcamSample = webcamOutput.copyNextSampleBuffer()
                        }
                        guard let sample = pendingWebcamSample else {
                            webcamExhausted = true
                            break
                        }
                        guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), pts) <= 0 else { break }
                        if let buffer = CMSampleBufferGetImageBuffer(sample) {
                            currentWebcamImage = CIImage(cvPixelBuffer: buffer)
                        }
                        pendingWebcamSample = nil
                    }
                }

                if let timing = configuration.videoOverlayTiming, let overlayFrames {
                    let outputTime = overlayTimeline?.outputTime(at: pts) ?? pts
                    currentWebcamImage = timing.sampleTime(at: outputTime.seconds).flatMap { overlayFrames.image(at: $0) }
                }

                var frameImage = image

                let transformSize = canvas == nil ? outputSize : sourceSize
                if canvas == nil && (transform.zoom > 1.001 || sourceSize != transformSize) {
                    frameImage = TransformApplicator.apply(
                        transform,
                        to: frameImage,
                        sourceSize: sourceSize,
                        outputSize: transformSize
                    )
                }

                if let canvas {
                    var cursorLayer: CIImage?
                    if time >= 0, let cursorCGImage, let position = cursorPosition(at: time) {
                        let sourcePoint = CGPoint(x: mousePaddingRatio + position.x * mouseContentScale,
                                                  y: mousePaddingRatio + (1 - position.y) * mouseContentScale)
                        if normalizedCrop.contains(sourcePoint) {
                            let camera = transform.clamped()
                            let horizontal = ((sourcePoint.x - normalizedCrop.minX) / normalizedCrop.width - camera.centerX) * camera.zoom + 0.5
                            let vertical = ((sourcePoint.y - normalizedCrop.minY) / normalizedCrop.height - camera.centerY) * camera.zoom + 0.5
                            let overlay = CIImage(cgImage: cursorCGImage).transformed(by: CGAffineTransform(
                                translationX: horizontal * sourceSize.width - cursorHotspot.x,
                                y: (1 - vertical) * sourceSize.height - (CGFloat(cursorCGImage.height) - cursorHotspot.y)))
                            let bounds = CGRect(origin: .zero, size: sourceSize)
                            cursorLayer = overlay.composited(over: CIImage(color: .clear).cropped(to: bounds)).cropped(to: bounds)
                        }
                    }
                    frameImage = canvas.composite(primary: frameImage, phone: phoneReader?.image(at: pts),
                                                  camera: transform, primaryOverlay: cursorLayer)
                }

                if let compositor,
                   let webcamImage = currentWebcamImage {
                    frameImage = compositor.composite(
                        webcamImage: webcamImage,
                        onto: frameImage
                    )
                }

                var outputBuffer: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool {
                    var attempts = 0
                    while attempts < 50 {
                        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
                        if status == kCVReturnSuccess, outputBuffer != nil { break }
                        attempts += 1
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
                guard let outBuffer = outputBuffer else { return false }

                ciContext.render(frameImage, to: outBuffer)

                // Draw cursor from mouse position data on every frame
                if time >= 0, canvas == nil {
                    drawCursor(on: outBuffer, transform: transform, atTime: time)
                }

                let appended = safeAppend(outBuffer, at: pts)
                let renderedSeconds = pts.seconds
                if appended, totalSeconds > 0, renderedSeconds - lastProgressUpdate >= 0.25 {
                    lastProgressUpdate = renderedSeconds
                    let progress = min(0.99, renderedSeconds / totalSeconds)
                    Task { @MainActor [weak self] in
                        self?.progress = progress
                    }
                }
                return appended
                }
            }

            videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
                while videoInput.isReadyForMoreMediaData {
                    let shouldContinue = autoreleasepool { () -> Bool in
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        if let image = lastSourceImage, hasCursorAnimation || webcamReaderOutput != nil || phoneReader != nil || !keyframes.isEmpty {
                            var fillTime = hasCursorAnimation
                                ? Double(nextCursorFrameIndex) / 60
                                : CMTimeGetSeconds(lastAppendedPTS) + fillFrameInterval
                            while fillTime < totalSeconds {
                                let fillPTS = hasCursorAnimation
                                    ? CMTime(value: nextCursorFrameIndex, timescale: 60)
                                    : CMTime(seconds: fillTime, preferredTimescale: 600)
                                if renderAndWrite(image: image, transform: camera(at: fillTime), at: fillPTS, time: fillTime) {
                                    framesWritten += 1
                                }
                                if hasCursorAnimation {
                                    nextCursorFrameIndex += 1
                                    fillTime = Double(nextCursorFrameIndex) / 60
                                } else {
                                    fillTime += fillFrameInterval
                                }
                            }
                        }
                        withExtendedLifetime(webcamReader) {}
                        videoInput.markAsFinished()
                        group.leave()
                        return false
                    }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let timeSeconds = CMTimeGetSeconds(pts)

                    // Evaluate camera state at this frame's timestamp
                    let transform = camera(at: timeSeconds)

                    // Get pixel buffer from sample
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        droppedFrameCount += 1
                        return true
                    }
                    framesRead += 1

                    let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
                        .transformed(by: preferredTransform)
                        .transformed(by: CGAffineTransform(translationX: -orientedBounds.minX, y: -orientedBounds.minY))
                        .cropped(to: cropRect)
                        .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

                    if hasCursorAnimation {
                        if let previousImage = lastSourceImage {
                            var frameTime = Double(nextCursorFrameIndex) / 60
                            while frameTime < timeSeconds - 0.000_001 {
                                let framePTS = CMTime(value: nextCursorFrameIndex, timescale: 60)
                                if renderAndWrite(image: previousImage, transform: camera(at: frameTime),
                                                  at: framePTS, time: frameTime) {
                                    framesWritten += 1
                                }
                                nextCursorFrameIndex += 1
                                frameTime = Double(nextCursorFrameIndex) / 60
                            }
                        }
                        lastSourceImage = sourceImage
                        return true
                    }

                    // Fill VFR gaps during active zoom: when frame gap exceeds threshold
                    // and zoom is animating, synthesize frames using the previous source image.
                    if let prevImage = lastSourceImage, CMTimeCompare(lastAppendedPTS, .zero) >= 0 {
                        let lastAppendedSeconds = CMTimeGetSeconds(lastAppendedPTS)
                        let gap = timeSeconds - lastAppendedSeconds
                        if gap > fillFrameInterval * 1.5 {
                            // Check if ANY zoom activity occurs within this gap by sampling
                            // at regular intervals. We can't just compare endpoints because
                            // zoom might start and end within the gap (both ends = identity).
                            var hasZoomActivity = false
                            let checkPoints = max(10, Int(gap / fillFrameInterval))
                            let sampleStep = gap / Double(checkPoints)
                            var sampleT = lastAppendedSeconds
                            for _ in 0...checkPoints {
                                let t = camera(at: sampleT)
                                if t.zoom > 1.01 {
                                    hasZoomActivity = true
                                    break
                                }
                                sampleT += sampleStep
                            }

                            if hasCursorAnimation || hasZoomActivity || webcamReaderOutput != nil || phoneReader != nil {
                                // Generate fill frames at ~30fps through the gap
                                var fillCount = 0
                                var fillTime = lastAppendedSeconds + fillFrameInterval
                                while fillTime < timeSeconds - fillFrameInterval * 0.5 {
                                    let fillTransform = camera(at: fillTime)
                                    let fillPTS = CMTime(seconds: fillTime, preferredTimescale: 600)
                                    if renderAndWrite(image: prevImage, transform: fillTransform, at: fillPTS, time: fillTime) {
                                        framesWritten += 1
                                        fillCount += 1
                                    }
                                    fillTime += fillFrameInterval
                                }
                                Log.export.info("VFR fill: \(fillCount) frames in \(String(format: "%.2f", lastAppendedSeconds))s→\(String(format: "%.2f", timeSeconds))s gap")
                            }
                        }
                    }

                    // All frames go through renderAndWrite to get cursor overlay
                    if renderAndWrite(image: sourceImage, transform: transform, at: pts, time: timeSeconds) {
                        framesWritten += 1
                    } else {
                        droppedFrameCount += 1
                    }
                    lastSourceImage = sourceImage

                    return true
                    }
                    if !shouldContinue { return }
                }
            }

            // Audio passthrough (one pump per audio track)
            for pair in audioReaderWriterPairs {
                group.enter()
                let audioQueue = DispatchQueue(label: "com.screen.export.audio.\(pair.writer.hash)", qos: .userInitiated)
                let readerOut = pair.reader
                let writerIn = pair.writer
                writerIn.requestMediaDataWhenReady(on: audioQueue) {
                    while writerIn.isReadyForMoreMediaData {
                        guard let sampleBuffer = readerOut.copyNextSampleBuffer() else {
                            writerIn.markAsFinished()
                            group.leave()
                            return
                        }
                        writerIn.append(sampleBuffer)
                    }
                }
            }

            group.notify(queue: .main) {
                writer.endSession(atSourceTime: duration)
                writer.finishWriting {
                    if let error = writer.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        if reader.status == .failed { throw reader.error ?? ExportError.readerSetupFailed }
        if let error = phoneReader?.error { throw error }
        guard framesWritten > 0, droppedFrameCount == 0 else { throw ExportError.incompleteFrames }

        await MainActor.run {
            self.progress = 1.0
            self.isExporting = false
        }

        Log.export.info("Export completed: \(configuration.outputURL.lastPathComponent), read=\(framesRead), written=\(framesWritten), dropped=\(droppedFrameCount)")
        return configuration.outputURL
    }
}

private final class TimedVideoReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let transform: CGAffineTransform
    private var pending: CMSampleBuffer?
    private var current: CIImage?
    private var exhausted = false

    var error: Error? { reader.status == .failed ? reader.error : nil }

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        transform = try await track.load(.preferredTransform)
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { throw ExportError.readerSetupFailed }
        reader.add(output)
        guard reader.startReading() else { throw ExportError.readerStartFailed(reader.error) }
    }

    func image(at time: CMTime) -> CIImage? {
        while !exhausted {
            if pending == nil { pending = output.copyNextSampleBuffer() }
            guard let sample = pending else { exhausted = true; break }
            guard CMSampleBufferGetPresentationTimeStamp(sample) <= time || current == nil else { break }
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                let image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                current = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            }
            pending = nil
        }
        return current
    }
}

// MARK: - Errors

enum ExportError: LocalizedError {
    case noVideoTrack
    case readerSetupFailed
    case writerSetupFailed
    case readerStartFailed(Error?)
    case writerStartFailed(Error?)
    case missingPhoneVideo
    case incompleteFrames

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "Source video has no video track"
        case .readerSetupFailed: return "Failed to configure video reader"
        case .writerSetupFailed: return "Failed to configure video writer"
        case .readerStartFailed(let e): return "Failed to start reading: \(e?.localizedDescription ?? "unknown")"
        case .writerStartFailed(let e): return "Failed to start writing: \(e?.localizedDescription ?? "unknown")"
        case .missingPhoneVideo: return "Choose a phone video for the Duo layout."
        case .incompleteFrames: return "Some video frames could not be rendered. The original video has been kept."
        }
    }
}

final class OverlayVideoFrames {
    private let generator: AVAssetImageGenerator
    private let lock = NSLock()
    private var cachedTime = -Double.infinity
    private var cachedImage: CIImage?

    init(url: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
    }

    func image(at time: CMTime) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        if abs(time.seconds - cachedTime) < 1.0 / 30 { return cachedImage }
        if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
            cachedImage = CIImage(cgImage: image)
            cachedTime = time.seconds
        }
        return cachedTime == time.seconds ? cachedImage : nil
    }
}
