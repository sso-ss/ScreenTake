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

    init(outputSize: CGSize, position: PiPPosition, pipSize: PiPSize, shape: PiPShape = .circle) {
        self.position = position
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
    func composite(webcamImage: CIImage, onto screenImage: CIImage) -> CIImage {
        // Center-crop the webcam to a square, then scale to target diameter
        let webcamExtent = webcamImage.extent
        let minSide = min(webcamExtent.width, webcamExtent.height)
        let cropOriginX = webcamExtent.origin.x + (webcamExtent.width - minSide) / 2
        let cropOriginY = webcamExtent.origin.y + (webcamExtent.height - minSide) / 2
        let squareCrop = CGRect(x: cropOriginX, y: cropOriginY, width: minSide, height: minSide)

        let scale = diameter / minSide
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
