import Foundation
import CoreImage
import CoreGraphics

/// Composites a shaped webcam PiP overlay onto a screen frame.
final class WebcamCompositor {

    /// Padding from screen edge for the PiP circle.
    private static let edgePadding: CGFloat = 24

    // Cached images — generated once in init
    private let maskImage: CIImage
    private let borderRing: CIImage
    private let diameter: CGFloat
    private let borderWidth: CGFloat = 2
    private let pipOrigin: CGPoint
    private let borderOrigin: CGPoint
    private let position: PiPPosition
    private let shape: PiPShape

    init(outputSize: CGSize, position: PiPPosition, pipSize: PiPSize, shape: PiPShape = .circle) {
        self.position = position
        self.shape = shape
        self.diameter = outputSize.height * pipSize.fraction

        // Pre-generate mask and border once
        self.maskImage = Self.createMask(diameter: diameter, shape: shape)
        self.borderRing = Self.createBorderRing(diameter: diameter, borderWidth: borderWidth, shape: shape)

        self.pipOrigin = Self.calculateOrigin(
            position: position,
            outputSize: outputSize,
            diameter: diameter
        )
        self.borderOrigin = CGPoint(
            x: pipOrigin.x - borderWidth,
            y: pipOrigin.y - borderWidth
        )
    }

    /// Composite a webcam frame onto a screen frame.
    func composite(webcamImage: CIImage, onto screenImage: CIImage,
                   settings: CameraLayoutSettings = CameraLayoutSettings(),
                   transition: CameraLayoutTransition? = nil) -> CIImage {
        if let transition {
            if transition.progress <= 0 {
                return composite(webcamImage: webcamImage, onto: screenImage, settings: transition.from)
            }
            if transition.progress >= 1 {
                return composite(webcamImage: webcamImage, onto: screenImage, settings: transition.to)
            }
            return transitioning(webcamImage: webcamImage, onto: screenImage, transition: transition)
        }
        if settings.layout == .fullScreen {
            let bounds = screenImage.extent
            let crop = settings.crop(in: webcamImage.extent, output: bounds.size)
            return webcamImage.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: bounds.width / crop.width, y: bounds.height / crop.height))
                .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
                .cropped(to: bounds)
        }
        // Center-crop the webcam to a square, then scale to target diameter
        let webcamExtent = webcamImage.extent
        let minSide = min(webcamExtent.width, webcamExtent.height)
        let cropOriginX = webcamExtent.origin.x + (webcamExtent.width - minSide) / 2
        let cropOriginY = webcamExtent.origin.y + (webcamExtent.height - minSide) / 2
        let squareCrop = CGRect(x: cropOriginX, y: cropOriginY, width: minSide, height: minSide)

        let scale = diameter / squareCrop.width
        let scaled = webcamImage
            .cropped(to: squareCrop)
            .transformed(by: CGAffineTransform(
                translationX: -squareCrop.origin.x,
                y: -squareCrop.origin.y
            ))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Apply cached shape mask
        let masked = scaled.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: maskImage,
        ])

        // Translate to position and composite
        let translatedPiP = masked.transformed(by: CGAffineTransform(
            translationX: pipOrigin.x, y: pipOrigin.y
        ))
        let translatedBorder = borderRing.transformed(by: CGAffineTransform(
            translationX: borderOrigin.x, y: borderOrigin.y
        ))

        return translatedBorder.composited(over: translatedPiP.composited(over: screenImage))
    }

    private func transitioning(webcamImage: CIImage, onto screenImage: CIImage,
                               transition: CameraLayoutTransition) -> CIImage {
        let bounds = screenImage.extent
        let source = webcamImage.extent
        let overlay = CGRect(origin: pipOrigin, size: CGSize(width: diameter, height: diameter))
        let square = CGRect(x: source.midX - min(source.width, source.height) / 2,
                            y: source.midY - min(source.width, source.height) / 2,
                            width: min(source.width, source.height), height: min(source.width, source.height))
        func crop(_ settings: CameraLayoutSettings) -> CGRect {
            settings.layout == .fullScreen ? settings.crop(in: source, output: bounds.size) : square
        }
        let amount = CGFloat(transition.progress)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * amount }
        func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY),
                   width: mix(a.width, b.width), height: mix(a.height, b.height))
        }
        let fromFull = transition.from.layout == .fullScreen
        let toFull = transition.to.layout == .fullScreen
        let rect = mix(fromFull ? bounds : overlay, toFull ? bounds : overlay)
        // Interpolate crop centers and heights, then use the current aspect
        // ratio so the camera does not stretch while its destination expands.
        let fromCrop = crop(transition.from), toCrop = crop(transition.to)
        var height = mix(fromCrop.height, toCrop.height)
        var width = height * rect.width / rect.height
        if width > source.width { height *= source.width / width; width = source.width }
        height = min(height, source.height)
        let cropRect = CGRect(x: min(source.maxX - width, max(source.minX, mix(fromCrop.midX, toCrop.midX) - width / 2)),
                              y: min(source.maxY - height, max(source.minY, mix(fromCrop.midY, toCrop.midY) - height / 2)),
                              width: width, height: height)
        let image = webcamImage.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .transformed(by: CGAffineTransform(scaleX: rect.width / cropRect.width, y: rect.height / cropRect.height))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        let overlayRadius = diameter * (shape == .circle ? 0.5 : 0.18)
        let radius = mix(fromFull ? 0 : overlayRadius, toFull ? 0 : overlayRadius)
        func mask(_ extent: CGRect, radius: CGFloat, alpha: CGFloat = 1) -> CIImage {
            CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: extent), "inputRadius": radius,
                "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: alpha)
            ])!.outputImage!.cropped(to: extent)
        }
        let shapeMask = mask(rect, radius: radius)
        let masked = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: shapeMask
        ])
        let borderOpacity = mix(fromFull ? 0 : 0.6, toFull ? 0 : 0.6)
        let outer = mask(rect.insetBy(dx: -borderWidth, dy: -borderWidth), radius: radius + borderWidth, alpha: borderOpacity)
        let ring = CIImage.empty().applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: outer, kCIInputMaskImageKey: shapeMask
        ])
        return ring.composited(over: masked.composited(over: screenImage)).cropped(to: bounds)
    }

    // MARK: - One-time generation

    private static func createMask(diameter: CGFloat, shape: PiPShape) -> CIImage {
        let d = Int(ceil(diameter))
        let renderer = CGContext(
            data: nil, width: d, height: d,
            bitsPerComponent: 8, bytesPerRow: d * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        renderer.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        renderer.addPath(path(in: CGRect(x: 0, y: 0, width: d, height: d), shape: shape))
        renderer.fillPath()
        return CIImage(cgImage: renderer.makeImage()!)
    }

    private static func createBorderRing(diameter: CGFloat, borderWidth: CGFloat, shape: PiPShape) -> CIImage {
        let full = Int(ceil(diameter + borderWidth * 2))
        let renderer = CGContext(
            data: nil, width: full, height: full,
            bitsPerComponent: 8, bytesPerRow: full * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        renderer.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.6))
        renderer.addPath(path(in: CGRect(x: 0, y: 0, width: full, height: full), shape: shape))
        renderer.fillPath()
        renderer.setBlendMode(.clear)
        renderer.addPath(path(
            in: CGRect(x: borderWidth, y: borderWidth, width: diameter, height: diameter),
            shape: shape
        ))
        renderer.fillPath()
        return CIImage(cgImage: renderer.makeImage()!)
    }

    private static func path(in rect: CGRect, shape: PiPShape) -> CGPath {
        switch shape {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .roundedSquare:
            return CGPath(roundedRect: rect, cornerWidth: rect.width * 0.18,
                          cornerHeight: rect.height * 0.18, transform: nil)
        }
    }

    private static func calculateOrigin(
        position: PiPPosition, outputSize: CGSize, diameter: CGFloat
    ) -> CGPoint {
        let padding = edgePadding
        return CGPoint(
            x: padding + (outputSize.width - diameter - 2 * padding) * position.horizontalFraction,
            y: padding + (outputSize.height - diameter - 2 * padding) * (1 - position.verticalFraction)
        )
    }
}
