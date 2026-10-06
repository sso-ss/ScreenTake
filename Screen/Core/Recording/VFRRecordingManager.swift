import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import CoreVideo
import AppKit
import ScreenCaptureKit

/// Represents a single click event for highlight rendering.
private struct ClickEvent {
    let screenPosition: CGPoint  // Raw screen coordinates (CGEvent space)
    let timestamp: CFTimeInterval
}

/// Writes video frames at their actual timestamps (variable frame rate).
final class VFRRecordingManager: @unchecked Sendable {

    // MARK: - Properties

    private let targetFrameRate: Int
    private var videoWriter: VideoWriter?
    private var isRecording = false
    private var isPaused = false

    private var firstVideoPTS: CMTime?
    private(set) var startTime: CMTime = .zero
    private var lastIOSurfaceID: UInt32 = 0
    private var videoTotalPausedDuration: CMTime = .zero

    private let lock = NSLock()
    private let writerQueue = DispatchQueue(label: "com.screen.vfr-writer", qos: .userInteractive)

    private var frameCount: Int64 = 0
    private var duplicateCount: Int64 = 0
    private var rejectedFrameCount: Int64 = 0
    private var outputURL: URL?
    private var configuration: CaptureConfiguration?

    // Background compositing for window recordings
    private var backgroundStyle: BackgroundStyle?
    private var isWindowRecording: Bool = false
    private var ciContext: CIContext?
    private var backgroundImage: CIImage?
    private var outputPixelBufferPool: CVPixelBufferPool?
    private var compositeOutputWidth: Int = 0
    private var compositeOutputHeight: Int = 0

    // Custom cursor rendering
    private var showCursor: Bool = true
    private var cursorScale: Double = 1.0
    private var cursorCGImage: CGImage?
    private var cursorImage: CIImage?
    private var captureTarget: CaptureTarget?
    private var needsCompositing: Bool = false
    private var lastRenderedMousePos: CGPoint = .zero
    // Two-stage compositing: heavy (background+window) cached, light (cursor+clicks) per-frame
    private var cachedBaseBuffer: CVPixelBuffer?
    private var cachedBaseSourceID: UInt32 = 0
    private var lastCaptureMousePos: CGPoint = CGPoint(x: -1, y: -1)
    private var writerQueueDepth: Int = 0

    // Cursor refresh timer — injects cursor-only frames when SCStream delivers nothing (static content)
    private var cursorRefreshTimer: DispatchSourceTimer?
    private var lastReceivedPTS: CMTime = .zero
    private var lastRealFrameWallTime: CFTimeInterval = 0
    private var lastCursorPTS: CMTime = .zero

    // Click highlight rendering
    private var highlightClicks: Bool = false
    private var clickHighlightColor: ClickHighlightColor = .white
    private var clickEvents: [ClickEvent] = []
    private let clickLock = NSLock()
    private var clickMonitor: Any?
    private static let clickAnimationDuration: CFTimeInterval = 0.5
    private static let clickRingMaxRadius: CGFloat = 60

    // Recording start wall-clock (used to derive end-of-recording PTS)
    private var recordingStartWallTime: CFTimeInterval = 0
    private var pauseStartWallTime: CFTimeInterval?
    private var totalPausedWallTime: CFTimeInterval = 0

    // MARK: - Init

    init(targetFrameRate: Int = 60) {
        self.targetFrameRate = targetFrameRate
    }

    // MARK: - Start

    func startRecording(to outputURL: URL, configuration: CaptureConfiguration, backgroundStyle: BackgroundStyle? = nil, isWindowRecording: Bool = false, showCursor: Bool = true, cursorScale: Double = 1.0, highlightClicks: Bool = false, clickHighlightColor: ClickHighlightColor = .white, captureTarget: CaptureTarget? = nil) throws {
        guard !isRecording else { return }

        self.outputURL = outputURL
        self.configuration = configuration
        self.backgroundStyle = backgroundStyle
        self.isWindowRecording = isWindowRecording
        self.showCursor = showCursor
        self.cursorScale = cursorScale
        self.highlightClicks = highlightClicks
        self.clickHighlightColor = clickHighlightColor
        self.captureTarget = captureTarget

        // Determine if compositing is needed
        self.needsCompositing = (isWindowRecording && backgroundStyle != nil) || showCursor || highlightClicks

        if needsCompositing {
            ciContext = ciContext ?? CIContext(options: [.useSoftwareRenderer: false])
        }

        // Start click tracking for highlight effect
        if highlightClicks {
            startClickTracking()
        }

        // For window recordings with background, output video is padded
        let outputWidth: Int
        let outputHeight: Int
        if isWindowRecording, backgroundStyle != nil {
            outputWidth = (Int(Double(configuration.width) * 1.3) / 2) * 2
            outputHeight = (Int(Double(configuration.height) * 1.3) / 2) * 2
            compositeOutputWidth = outputWidth
            compositeOutputHeight = outputHeight
            setupBackgroundImage(width: outputWidth, height: outputHeight)
            setupPixelBufferPool(width: outputWidth, height: outputHeight)
        } else {
            outputWidth = configuration.width
            outputHeight = configuration.height
            if showCursor || highlightClicks {
                compositeOutputWidth = outputWidth
                compositeOutputHeight = outputHeight
                setupPixelBufferPool(width: outputWidth, height: outputHeight)
            }
        }

        // Generate cursor image
        if showCursor {
            generateCursorImage()
        }

        let scaledBitRate = VideoEncodingQuality.bitRate(
            size: CGSize(width: outputWidth, height: outputHeight),
            frameRate: Double(configuration.frameRate), recordingMaster: true)

        let writerConfig = VideoWriterConfiguration(
            width: outputWidth,
            height: outputHeight,
            frameRate: configuration.frameRate,
            videoBitRate: scaledBitRate,
            keyFrameInterval: configuration.frameRate,
            videoCodec: .hevc,
            fileType: .mov,
            includeAudio: false
        )

        videoWriter = try VideoWriter(outputURL: outputURL, configuration: writerConfig)
        try videoWriter?.startWriting()

        isRecording = true
        isPaused = false
        frameCount = 0
        duplicateCount = 0
        rejectedFrameCount = 0
        firstVideoPTS = nil
        lastIOSurfaceID = 0
        lastCaptureMousePos = CGPoint(x: -1, y: -1)
        writerQueueDepth = 0
        lock.lock()
        lastReceivedPTS = .zero
        lastRealFrameWallTime = CACurrentMediaTime()
        lastCursorPTS = .zero
        lock.unlock()
        videoTotalPausedDuration = .zero

        // Start cursor refresh timer for smooth cursor on static content
        if needsCompositing && (showCursor || highlightClicks) {
            startCursorRefreshTimer()
        }

        startTime = CMClockGetTime(CMClockGetHostTimeClock())
        firstVideoPTS = startTime
        recordingStartWallTime = startTime.seconds
        pauseStartWallTime = nil
        totalPausedWallTime = 0

        Log.recording.info("VFR recording started: \(configuration.width)x\(configuration.height) @ \(configuration.frameRate)fps")
    }

    // MARK: - Stop

    func waitUntilReady(timeout: TimeInterval = 3) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if lock.withLock({ frameCount > 0 }) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CaptureError.noCompleteFrames
    }

    func stopRecording(at stopTime: CMTime? = nil) async -> URL? {
        guard isRecording else { return nil }
        let stopWallTime = (stopTime ?? CMClockGetTime(CMClockGetHostTimeClock())).seconds
        lock.lock()
        let currentPause = pauseStartWallTime.map { stopWallTime - $0 } ?? 0
        let elapsed = max(0, stopWallTime - recordingStartWallTime - totalPausedWallTime - currentPause)
        lock.unlock()
        let endTime = CMTime(seconds: elapsed, preferredTimescale: 60_000)
        isRecording = false

        cursorRefreshTimer?.cancel()
        cursorRefreshTimer = nil
        stopClickTracking()

        // Write an end-cap frame so the video duration matches the actual recording
        // session length. Without this, VFR dedup can make the video much shorter
        // than the mouse data timeline, causing zoom keyframes to fall outside the
        // video and producing no visible zoom effect.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async { [weak self] in
                guard let self else { continuation.resume(); return }

                self.lock.lock()
                let lastPTS = self.lastReceivedPTS
                let hasFrames = self.frameCount > 0
                self.lock.unlock()

                if hasFrames {
                    let endPTS = endTime

                    // Only write if it advances beyond the last written PTS
                    if CMTimeCompare(endPTS, lastPTS) > 0 {
                        if self.needsCompositing, let baseBuffer = self.cachedBaseBuffer {
                            // Compositing mode: re-use the cached composite
                            let finalBuffer = self.drawOverlays(onto: baseBuffer, mousePosition: nil)
                            self.videoWriter?.appendPixelBuffer(finalBuffer, at: endPTS)
                            Log.recording.info("End-cap frame written at \(String(format: "%.2f", elapsed))s (last real frame was at \(String(format: "%.2f", CMTimeGetSeconds(lastPTS)))s)")
                        } else if !self.needsCompositing {
                            // Non-compositing mode: create a minimal black frame as duration marker
                            // The actual content doesn't matter much — this just ensures the video
                            // duration matches the recording session.
                            if let pool = self.outputPixelBufferPool ?? self.createEndCapPool() {
                                var endBuffer: CVPixelBuffer?
                                let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &endBuffer)
                                if status == kCVReturnSuccess, let buf = endBuffer {
                                    // Zero-fill (black) — this frame exists solely to set duration
                                    CVPixelBufferLockBaseAddress(buf, [])
                                    let baseAddr = CVPixelBufferGetBaseAddress(buf)
                                    let dataSize = CVPixelBufferGetDataSize(buf)
                                    if let baseAddr { memset(baseAddr, 0, dataSize) }
                                    CVPixelBufferUnlockBaseAddress(buf, [])
                                    self.videoWriter?.appendPixelBuffer(buf, at: endPTS)
                                    Log.recording.info("End-cap frame (non-composite) written at \(String(format: "%.2f", elapsed))s")
                                }
                            }
                        }
                    }
                }

                continuation.resume()
            }
        }

        await videoWriter?.finishWriting(at: endTime)

        Log.recording.info("VFR recording stopped: \(self.frameCount) frames, \(self.duplicateCount) duplicates skipped, \(self.rejectedFrameCount) incomplete frames rejected")
        return outputURL
    }

    // MARK: - Frame Handling

    func receiveFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }

        if isPaused {
            return
        }

        guard sampleBuffer.isValid else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let rawStatus = attachments.first?[.status] as? Int,
           rawStatus != SCFrameStatus.complete.rawValue {
            rejectedFrameCount += 1
            if rejectedFrameCount == 1 {
                Log.capture.warning("Ignoring incomplete screen frame: status=\(rawStatus, privacy: .public)")
            }
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        let surfaceID = surface.map { IOSurfaceGetID($0) } ?? 0

        // For non-compositing: classic dedup
        if !needsCompositing {
            if surfaceID == lastIOSurfaceID, surfaceID != 0 {
                lock.lock()
                duplicateCount += 1
                lock.unlock()
                return
            }
            lastIOSurfaceID = surfaceID
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lock.lock()
        if firstVideoPTS == nil { firstVideoPTS = pts }
        let basePTS = firstVideoPTS!
        let pauseOffset = videoTotalPausedDuration
        lock.unlock()
        let rebasedPTS = CMTimeSubtract(CMTimeSubtract(pts, basePTS), pauseOffset)

        // For compositing: two-stage approach
        if needsCompositing {
            let contentChanged = surfaceID != lastIOSurfaceID || surfaceID == 0

            // Sample mouse position NOW on capture thread, not later on writer thread
            let mousePos = (showCursor || highlightClicks) ? getCurrentMousePosition() : nil
            let snappedMouse = mousePos.map { CGPoint(x: round($0.x), y: round($0.y)) }

            // Capture-thread dedup: skip frame if nothing visually changed
            if !contentChanged {
                let cursorMoved = snappedMouse != nil && snappedMouse != lastCaptureMousePos
                var hasActiveClicks = false
                if highlightClicks {
                    clickLock.lock()
                    hasActiveClicks = !clickEvents.isEmpty
                    clickLock.unlock()
                }
                if !cursorMoved && !hasActiveClicks {
                    lock.lock()
                    duplicateCount += 1
                    lock.unlock()
                    return
                }
            }

            // Backpressure: skip if writer queue is backed up
            lock.lock()
            if writerQueueDepth >= 4 {
                duplicateCount += 1
                lock.unlock()
                return
            }
            writerQueueDepth += 1
            lock.unlock()

            // Commit tracking state — this frame will be processed
            lastIOSurfaceID = surfaceID
            if let pos = snappedMouse { lastCaptureMousePos = pos }

            writerQueue.async { [weak self] in
                guard let self else { return }
                defer {
                    self.lock.lock()
                    self.writerQueueDepth -= 1
                    self.lock.unlock()
                }

                // Stage 1: Heavy composite (background + window) — only when window content changes
                if contentChanged || self.cachedBaseBuffer == nil {
                    self.cachedBaseBuffer = self.compositeBase(pixelBuffer)
                    self.cachedBaseSourceID = surfaceID
                }

                // Stage 2: Light overlay (cursor + clicks) — drawn via CGContext onto a copy
                guard let baseBuffer = self.cachedBaseBuffer else { return }
                let finalBuffer = self.drawOverlays(onto: baseBuffer, mousePosition: mousePos)

                if self.frameCount == 0, rebasedPTS > .zero {
                    self.videoWriter?.appendPixelBuffer(finalBuffer, at: .zero)
                }
                self.videoWriter?.appendPixelBuffer(finalBuffer, at: rebasedPTS)
                self.lock.lock()
                self.lastReceivedPTS = rebasedPTS
                self.lastRealFrameWallTime = CACurrentMediaTime()
                self.frameCount += 1
                self.lock.unlock()
            }
        } else {
            writerQueue.async { [weak self] in
                guard let self else { return }
                if self.frameCount == 0, rebasedPTS > .zero {
                    self.videoWriter?.appendPixelBuffer(pixelBuffer, at: .zero)
                }
                self.videoWriter?.appendPixelBuffer(pixelBuffer, at: rebasedPTS)
                self.lock.lock()
                self.lastReceivedPTS = rebasedPTS
                self.lastRealFrameWallTime = CACurrentMediaTime()
                self.frameCount += 1
                self.lock.unlock()
            }
        }
    }

    // MARK: - Pause/Resume

    func pause(at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.lock()
        if !isPaused {
            pauseStartWallTime = time.seconds
            isPaused = true
        }
        lock.unlock()
    }

    func resume(at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.lock()
        if let pauseStartWallTime {
            totalPausedWallTime += time.seconds - pauseStartWallTime
        }
        videoTotalPausedDuration = CMTime(seconds: totalPausedWallTime, preferredTimescale: 60_000)
        pauseStartWallTime = nil
        isPaused = false
        lock.unlock()
    }

    // MARK: - Background Compositing

    private func setupBackgroundImage(width: Int, height: Int) {
        guard let backgroundStyle else { return }

        let stops: [(CodableColor, CGFloat)]
        switch backgroundStyle {
        case .wallpaper(let preset):
            if let imageName = preset.imageName,
               let image = NSImage(named: imageName),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let scale = max(CGFloat(width) / CGFloat(cgImage.width),
                                CGFloat(height) / CGFloat(cgImage.height))
                let offsetX = (CGFloat(width) - CGFloat(cgImage.width) * scale) / 2
                let offsetY = (CGFloat(height) - CGFloat(cgImage.height) * scale) / 2
                backgroundImage = CIImage(cgImage: cgImage)
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
                    .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
                return
            }
            stops = preset.gradientColors.map { ($0.color, CGFloat($0.location)) }
        case .gradient(let def):
            stops = [(def.startColor, 0), (def.endColor, 1)]
        case .solid(let color):
            stops = [(color, 0), (color, 1)]
        case .image:
            stops = [(.gray, 0), (.gray, 1)]
        }

        guard stops.count >= 2 else { return }

        // Render multi-stop gradient via CGGradient (matches SwiftUI LinearGradient preview)
        let cgColors = stops.map { $0.0.cgColor } as CFArray
        let locations = stops.map { $0.1 }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: cgColors,
                                        locations: locations) else { return }

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // Draw diagonal: top-left → bottom-right (CGContext origin is bottom-left)
        let startPoint = CGPoint(x: 0, y: CGFloat(height))  // top-left
        let endPoint = CGPoint(x: CGFloat(width), y: 0)      // bottom-right
        ctx.drawLinearGradient(gradient, start: startPoint, end: endPoint,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        guard let cgImage = ctx.makeImage() else { return }
        backgroundImage = CIImage(cgImage: cgImage)
    }

    private func setupPixelBufferPool(width: Int, height: Int) {
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 8
        ]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &outputPixelBufferPool)
    }

    /// Create a one-off pixel buffer pool for the end-cap frame (non-compositing mode).
    private func createEndCapPool() -> CVPixelBufferPool? {
        guard let config = configuration else { return nil }
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 1
        ]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.width,
            kCVPixelBufferHeightKey as String: config.height,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &pool)
        return pool
    }

    /// Stage 1: Heavy composite — background gradient + centered window. Cached until IOSurface changes.
    private func compositeBase(_ windowBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = outputPixelBufferPool else { return nil }

        var outputBuffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let outputBuffer else {
            Log.recording.warning("VFR compositeBase: pixel buffer pool exhausted (status \(poolStatus))")
            return nil
        }

        if isWindowRecording, let backgroundImage, let ciContext {
            // Window recording: composite window on gradient background via GPU
            let result = CIImage(cvPixelBuffer: windowBuffer)
            let windowWidth = CGFloat(CVPixelBufferGetWidth(windowBuffer))
            let windowHeight = CGFloat(CVPixelBufferGetHeight(windowBuffer))
            let canvasWidth = CGFloat(compositeOutputWidth)
            let canvasHeight = CGFloat(compositeOutputHeight)
            let offsetX = (canvasWidth - windowWidth) / 2
            let offsetY = (canvasHeight - windowHeight) / 2
            let centeredWindow = result.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            let composited = centeredWindow.composited(over: backgroundImage)
            ciContext.render(composited, to: outputBuffer)
        } else {
            if !Self.copyPixels(from: windowBuffer, to: outputBuffer), let ciContext {
                let image = CIImage(cvPixelBuffer: windowBuffer)
                let scaleX = CGFloat(CVPixelBufferGetWidth(outputBuffer)) / image.extent.width
                let scaleY = CGFloat(CVPixelBufferGetHeight(outputBuffer)) / image.extent.height
                ciContext.render(image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)), to: outputBuffer)
            }
        }

        return outputBuffer
    }

    static func copyPixels(from source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        let rowBytes = width * 4
        guard width == CVPixelBufferGetWidth(destination), height == CVPixelBufferGetHeight(destination),
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_32BGRA,
              sourceStride >= rowBytes, destinationStride >= rowBytes else { return false }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        guard let sourceAddress = CVPixelBufferGetBaseAddress(source),
              let destinationAddress = CVPixelBufferGetBaseAddress(destination) else { return false }
        for row in 0..<height {
            memcpy(destinationAddress.advanced(by: row * destinationStride),
                   sourceAddress.advanced(by: row * sourceStride), rowBytes)
        }
        return true
    }

    /// Stage 2: Light overlay — copy base buffer and draw cursor + click effects via CGContext (fast).
    private func drawOverlays(onto baseBuffer: CVPixelBuffer, mousePosition: CGPoint? = nil) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(baseBuffer)
        let height = CVPixelBufferGetHeight(baseBuffer)
        let canvasHeight = CGFloat(height)

        // Use pre-sampled position (from capture thread) or fall back to polling.
        // Snap to integer pixels to avoid sub-pixel jitter that becomes visible under zoom.
        let mousePos: CGPoint? = {
            let raw = mousePosition ?? ((showCursor || highlightClicks) ? getCurrentMousePosition() : nil)
            guard let p = raw else { return nil }
            return CGPoint(x: round(p.x), y: round(p.y))
        }()

        var hasActiveClicks = false
        var activeClicks: [ClickEvent] = []
        if highlightClicks {
            let now = CACurrentMediaTime()
            clickLock.lock()
            clickEvents.removeAll { now - $0.timestamp > Self.clickAnimationDuration }
            activeClicks = clickEvents
            hasActiveClicks = !activeClicks.isEmpty
            clickLock.unlock()
        }

        let needsCursor = showCursor && cursorCGImage != nil && mousePos != nil
        let cursorMoved = needsCursor && mousePos != lastRenderedMousePos
        let needsOverlay = cursorMoved || hasActiveClicks

        // If nothing to draw (or cursor hasn't moved), return base buffer directly (zero copy)
        if !needsOverlay {
            if let pos = mousePos { lastRenderedMousePos = pos }
            return baseBuffer
        }

        // Copy base buffer so we don't mutate the cache
        guard let pool = outputPixelBufferPool else { return baseBuffer }
        var outputBuffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let outputBuffer else {
            Log.recording.warning("VFR drawOverlays: pixel buffer pool exhausted (status \(poolStatus))")
            return baseBuffer
        }

        guard Self.copyPixels(from: baseBuffer, to: outputBuffer) else { return baseBuffer }
        CVPixelBufferLockBaseAddress(outputBuffer, [])

        // Draw overlays via CGContext (top-left origin)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let baseAddr = CVPixelBufferGetBaseAddress(outputBuffer)

        guard let ctx = CGContext(
            data: baseAddr,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
            return baseBuffer
        }

        // CGContext origin is bottom-left, flip to top-left for easier drawing
        ctx.translateBy(x: 0, y: canvasHeight)
        ctx.scaleBy(x: 1, y: -1)

        // Draw click highlights
        if hasActiveClicks {
            let now = CACurrentMediaTime()
            let color = clickHighlightColor.components
            for click in activeClicks {
                guard let capturePos = screenToCapture(click.screenPosition) else { continue }
                let elapsed = now - click.timestamp
                let progress = CGFloat(elapsed / Self.clickAnimationDuration)

                let maxRadius = Self.clickRingMaxRadius * CGFloat(cursorScale)
                let currentRadius = maxRadius * progress

                // Filled circle that fades out
                let fillAlpha = CGFloat(1.0 - progress) * 0.3
                ctx.setFillColor(CGColor(red: color.red, green: color.green, blue: color.blue, alpha: fillAlpha))
                let fillRect = CGRect(
                    x: capturePos.x - currentRadius,
                    y: capturePos.y - currentRadius,
                    width: currentRadius * 2,
                    height: currentRadius * 2
                )
                ctx.fillEllipse(in: fillRect)

                // Ring stroke
                let ringAlpha = CGFloat(1.0 - progress) * 0.8
                let ringWidth: CGFloat = max(2, 4 * (1 - progress))
                ctx.setStrokeColor(CGColor(red: color.red, green: color.green, blue: color.blue, alpha: ringAlpha))
                ctx.setLineWidth(ringWidth)
                let ringRect = fillRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2)
                ctx.strokeEllipse(in: ringRect)
            }
        }

        // Draw cursor (un-flip locally since ctx.draw renders bottom-up)
        if needsCursor, let cursor = cursorCGImage, let pos = mousePos {
            lastRenderedMousePos = pos
            let cursorW = CGFloat(cursor.width)
            let cursorH = CGFloat(cursor.height)
            ctx.saveGState()
            ctx.translateBy(x: pos.x, y: pos.y + cursorH)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cursor, in: CGRect(x: 0, y: 0, width: cursorW, height: cursorH))
            ctx.restoreGState()
        }

        CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        return outputBuffer
    }

    // MARK: - Cursor Image Generation

    private func generateCursorImage() {
        let baseSize: CGFloat = 24 * CGFloat(cursorScale)
        cursorCGImage = CursorImageProvider.cgImage(width: baseSize, screenScale: 2.0)
        if let cg = cursorCGImage {
            cursorImage = CIImage(cgImage: cg)
        }
    }

    private func getCurrentMousePosition() -> CGPoint? {
        guard let config = configuration else { return nil }

        let mouseLocation = CGEvent(source: nil)?.location ?? .zero
        let scaleFactor = config.scaleFactor

        if isWindowRecording {
            // For window recording, convert screen coords to window-relative coords
            if case .window(let window) = captureTarget {
                let relX = (mouseLocation.x - window.frame.origin.x) * scaleFactor
                let relY = (mouseLocation.y - window.frame.origin.y) * scaleFactor

                // Add offset for background padding
                let padX = (CGFloat(compositeOutputWidth) - CGFloat(config.width)) / 2
                let padY = (CGFloat(compositeOutputHeight) - CGFloat(config.height)) / 2

                return CGPoint(x: relX + padX, y: relY + padY)
            }
            return nil
        } else {
            // For screen recording, convert to capture coordinates
            if case .display(let display) = captureTarget {
                let displayBounds = CGDisplayBounds(display.displayID)
                let relX = (mouseLocation.x - displayBounds.origin.x) * scaleFactor
                let relY = (mouseLocation.y - displayBounds.origin.y) * scaleFactor
                return CGPoint(x: relX, y: relY)
            }
            return nil
        }
    }

    // MARK: - Helpers

    // MARK: - Click Highlight Tracking

    private func startClickTracking() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isRecording, !self.isPaused else { return }
            // Store raw screen position — will be transformed to capture coords at render time
            let screenPos = CGEvent(source: nil)?.location ?? .zero
            let click = ClickEvent(screenPosition: screenPos, timestamp: CACurrentMediaTime())
            self.clickLock.lock()
            self.clickEvents.append(click)
            self.clickLock.unlock()
        }
    }

    // MARK: - Cursor Refresh Timer

    /// Injects cursor-only frames when SCStream delivers nothing (e.g. static window content).
    /// Without this, cursor freezes when showsCursor=false in SCStream config.
    private func startCursorRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        let interval = 1.0 / Double(targetFrameRate)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRecording, !self.isPaused, self.needsCompositing else { return }
            guard let baseBuffer = self.cachedBaseBuffer else { return }

            self.lock.lock()
            let lastPTS = self.lastReceivedPTS
            let lastRealWallTime = self.lastRealFrameWallTime
            self.lock.unlock()

            guard lastPTS != .zero else { return }

            // Only inject when real frames have actually stalled.
            let now = CACurrentMediaTime()
            if now - lastRealWallTime < interval * 1.25 {
                return
            }

            // Only inject if mouse moved enough to matter (>= 1px in capture coords)
            let mousePos = self.getCurrentMousePosition().map {
                CGPoint(x: round($0.x), y: round($0.y))
            }
            var hasActiveClicks = false
            if self.highlightClicks {
                self.clickLock.lock()
                hasActiveClicks = !self.clickEvents.isEmpty
                self.clickLock.unlock()
            }

            let cursorMoved: Bool
            if let pos = mousePos {
                let dx = pos.x - self.lastRenderedMousePos.x
                let dy = pos.y - self.lastRenderedMousePos.y
                cursorMoved = (dx * dx + dy * dy) >= 1.0
            } else {
                cursorMoved = false
            }
            guard cursorMoved || hasActiveClicks else { return }

            // Use a PTS that advances beyond the last cursor frame.
            // We track cursor-injected PTS separately so each cursor frame
            // gets a unique, increasing timestamp without interfering with
            // real frame PTS tracking.
            let cursorPTS: CMTime
            let halfInterval = CMTime(value: 1, timescale: CMTimeScale(self.targetFrameRate * 2))
            if self.lastCursorPTS != .zero && CMTimeCompare(self.lastCursorPTS, lastPTS) >= 0 {
                cursorPTS = CMTimeAdd(self.lastCursorPTS, halfInterval)
            } else {
                cursorPTS = CMTimeAdd(lastPTS, halfInterval)
            }

            let finalBuffer = self.drawOverlays(onto: baseBuffer, mousePosition: mousePos)
            self.videoWriter?.appendPixelBuffer(finalBuffer, at: cursorPTS)
            self.lastCursorPTS = cursorPTS

            self.lock.lock()
            self.frameCount += 1
            self.lock.unlock()
        }
        timer.resume()
        cursorRefreshTimer = timer
    }

    private func stopClickTracking() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        clickLock.lock()
        clickEvents.removeAll()
        clickLock.unlock()
    }

    // MARK: - Click Highlight Rendering

    /// Convert raw screen coordinates to capture pixel coordinates (same logic as getCurrentMousePosition).
    private func screenToCapture(_ screenPos: CGPoint) -> CGPoint? {
        guard let config = configuration else { return nil }
        let scaleFactor = config.scaleFactor

        if isWindowRecording {
            if case .window(let window) = captureTarget {
                let relX = (screenPos.x - window.frame.origin.x) * scaleFactor
                let relY = (screenPos.y - window.frame.origin.y) * scaleFactor
                let padX = (CGFloat(compositeOutputWidth) - CGFloat(config.width)) / 2
                let padY = (CGFloat(compositeOutputHeight) - CGFloat(config.height)) / 2
                return CGPoint(x: relX + padX, y: relY + padY)
            }
            return nil
        } else {
            if case .display(let display) = captureTarget {
                let displayBounds = CGDisplayBounds(display.displayID)
                let relX = (screenPos.x - displayBounds.origin.x) * scaleFactor
                let relY = (screenPos.y - displayBounds.origin.y) * scaleFactor
                return CGPoint(x: relX, y: relY)
            }
            return nil
        }
    }
}
