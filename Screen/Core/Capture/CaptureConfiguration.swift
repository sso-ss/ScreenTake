import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

struct CaptureConfiguration {
    var width: Int
    var height: Int
    var frameRate: Int
    var pixelFormat: OSType
    var showsCursor: Bool
    var capturesAudio: Bool
    var scaleFactor: CGFloat
    var capturesShadow: Bool
    var sourceRect: CGRect?

    init(
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Int = 60,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        showsCursor: Bool = false,
        capturesAudio: Bool = true,
        scaleFactor: CGFloat = 2.0,
        capturesShadow: Bool = true,
        sourceRect: CGRect? = nil
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.pixelFormat = pixelFormat
        self.showsCursor = showsCursor
        self.capturesAudio = capturesAudio
        self.scaleFactor = scaleFactor
        self.capturesShadow = capturesShadow
        self.sourceRect = sourceRect
    }

    static let `default` = Self()

    func createStreamConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 16
        config.pixelFormat = pixelFormat
        config.showsCursor = showsCursor
        config.capturesAudio = capturesAudio
        config.scalesToFit = sourceRect == nil
        if #available(macOS 14.0, *) {
            config.ignoreShadowsSingleWindow = !capturesShadow
        }
        if let sourceRect {
            config.sourceRect = sourceRect
        }
        return config
    }

    static func forTarget(_ target: CaptureTarget, scaleFactor: CGFloat? = nil, frameRate: Int = 60, showsCursor: Bool = true) -> Self {
        let nativeScale: CGFloat
        switch target {
        case .display(let display):
            nativeScale = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }?.backingScaleFactor ?? 1
        case .window:
            let screen = NSScreen.screens.max { first, second in
                let firstArea = CGDisplayBounds((first.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
                    .intersection(target.frame)
                let secondArea = CGDisplayBounds((second.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
                    .intersection(target.frame)
                return (firstArea.isNull ? 0 : firstArea.width * firstArea.height)
                    < (secondArea.isNull ? 0 : secondArea.width * secondArea.height)
            }
            nativeScale = screen?.backingScaleFactor ?? 1
        }
        let scaleFactor = scaleFactor ?? nativeScale
        let width = max(2, (Int(target.frame.width * scaleFactor) / 2) * 2)
        let height = max(2, (Int(target.frame.height * scaleFactor) / 2) * 2)
        let crop = target.isWindow ? Self.pixelAlignedCrop(size: target.frame.size, scaleFactor: scaleFactor) : nil

        return Self(
            width: width,
            height: height,
            frameRate: frameRate,
            showsCursor: showsCursor,
            scaleFactor: scaleFactor,
            capturesShadow: !target.isWindow,
            sourceRect: crop
        )
    }

    /// HEVC needs even dimensions. Sample the same native pixels instead of
    /// shrinking an odd-sized window across the encoder surface.
    static func pixelAlignedCrop(size: CGSize, scaleFactor: CGFloat) -> CGRect? {
        guard scaleFactor > 0, size.width >= 2 / scaleFactor, size.height >= 2 / scaleFactor else { return nil }
        let width = CGFloat(Int(size.width * scaleFactor) / 2 * 2)
        let height = CGFloat(Int(size.height * scaleFactor) / 2 * 2)
        guard width != size.width * scaleFactor || height != size.height * scaleFactor else { return nil }
        return CGRect(x: 0, y: 0, width: width / scaleFactor, height: height / scaleFactor)
    }

    /// Cursor bounds use Cocoa's bottom-left origin; sourceRect uses top-left.
    func mouseBounds(in bounds: CGRect) -> CGRect {
        guard let sourceRect else { return bounds }
        return CGRect(x: bounds.minX + sourceRect.minX, y: bounds.maxY - sourceRect.maxY,
                      width: sourceRect.width, height: sourceRect.height)
    }

    func croppedBrowserRect(_ rect: CGRect, windowSize: CGSize) -> CGRect? {
        guard let sourceRect else { return rect }
        let points = CGRect(x: rect.minX * windowSize.width, y: rect.minY * windowSize.height,
                            width: rect.width * windowSize.width, height: rect.height * windowSize.height)
            .intersection(sourceRect)
        guard !points.isNull, !points.isEmpty else { return nil }
        return CGRect(x: (points.minX - sourceRect.minX) / sourceRect.width,
                      y: (points.minY - sourceRect.minY) / sourceRect.height,
                      width: points.width / sourceRect.width, height: points.height / sourceRect.height)
    }
}
