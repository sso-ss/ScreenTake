import AppKit
import CoreImage

enum CursorShape: String, CaseIterable, Codable {
    case arrow
    case hand
    case circle

    var displayName: String { rawValue.capitalized }
}

/// Renders a cursor image from SVG path data at any scale.
/// Source: Resources/cursor.svg (viewBox 0 0 28 28)
enum CursorImageProvider {
    private static let handBitmap: (image: CGImage, hotspot: CGPoint)? = {
        let cursor = NSCursor.pointingHand
        guard let original = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: original.width, height: original.height,
                                      bitsPerComponent: 8, bytesPerRow: original.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        var minX = original.width
        var minY = original.height
        var maxX = 0
        var maxY = 0
        for row in 0..<original.height {
            for column in 0..<original.width where bytes[(row * original.width + column) * 4 + 3] > 8 {
                minX = min(minX, column)
                minY = min(minY, row)
                maxX = max(maxX, column)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let image = context.makeImage()?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return nil }
        return (image, CGPoint(x: cursor.hotSpot.x * CGFloat(original.width) / cursor.image.size.width - CGFloat(minX),
                               y: cursor.hotSpot.y * CGFloat(original.height) / cursor.image.size.height - CGFloat(minY)))
    }()

    // Bounding box of the cursor within the 28×28 SVG viewBox
    private static let originX: CGFloat = 8.2
    private static let originY: CGFloat = 4.9
    private static let cursorWidth: CGFloat = 11.6  // 19.8 - 8.2
    private static let cursorHeight: CGFloat = 18.2  // 23.1 - 4.9

    /// Aspect ratio (height / width) of the cursor shape.
    static let aspectRatio: CGFloat = cursorHeight / cursorWidth  // ≈ 1.569

    /// Render the cursor as a CGImage with the tip at pixel (0, 0).
    /// - Parameters:
    ///   - width: Logical width of the output image.
    ///   - screenScale: Retina multiplier (default 2×).
    static func cgImage(width: CGFloat, screenScale: CGFloat = 2.0, shape: CursorShape = .arrow) -> CGImage? {
        guard width.isFinite, screenScale.isFinite, width > 0, screenScale > 0,
              width * screenScale <= 4096 else { return nil }
        if shape == .hand {
            guard let source = handBitmap else { return nil }
            let pixelsWide = Int(ceil(width * screenScale))
            let pixelsHigh = Int(ceil(width * screenScale * CGFloat(source.image.height) / CGFloat(source.image.width)))
            guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                          bytesPerRow: pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(source.image, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
            return context.makeImage()
        }
        if shape == .circle {
            let pixels = Int(ceil(width * screenScale))
            guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                          bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let border = max(0.75, CGFloat(pixels) / 32)
            let inset = max(1, CGFloat(pixels) / 20)
            let bounds = CGRect(x: inset, y: inset, width: CGFloat(pixels) - inset * 2, height: CGFloat(pixels) - inset * 2)

            context.saveGState()
            context.addEllipse(in: bounds)
            context.clip()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    CGColor(gray: 1, alpha: 0.58),
                    CGColor(gray: 1, alpha: 0.38),
                    CGColor(gray: 0.96, alpha: 0.24)
                ] as CFArray,
                locations: [0, 0.45, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: bounds.midX, y: bounds.maxY),
                    end: CGPoint(x: bounds.midX, y: bounds.minY),
                    options: []
                )
            }
            context.restoreGState()

            context.setStrokeColor(CGColor(gray: 0, alpha: 0.38))
            context.setLineWidth(border * 1.5)
            context.strokeEllipse(in: bounds)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            context.setLineWidth(max(0.5, border * 0.65))
            context.strokeEllipse(in: bounds)
            return context.makeImage()
        }
        let height = width * aspectRatio
        let pixelW = Int(ceil(width * screenScale))
        let pixelH = Int(ceil(height * screenScale))
        guard pixelW > 0, pixelH > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: pixelW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Flip to top-left origin (SVG coordinate system)
        ctx.translateBy(x: 0, y: CGFloat(pixelH))
        ctx.scaleBy(x: 1, y: -1)

        // Scale SVG viewBox units → pixels, then shift so the tip is at (0,0)
        let sx = CGFloat(pixelW) / cursorWidth
        let sy = CGFloat(pixelH) / cursorHeight
        ctx.scaleBy(x: sx, y: sy)
        ctx.translateBy(x: -originX, y: -originY)

        // ── White shapes (outline / border) ──
        ctx.setFillColor(CGColor.white)

        let outerArrow = CGMutablePath()
        outerArrow.move(to:    CGPoint(x: 8.2,  y: 20.9))
        outerArrow.addLine(to: CGPoint(x: 8.2,  y: 4.9))
        outerArrow.addLine(to: CGPoint(x: 19.8, y: 16.5))
        outerArrow.addLine(to: CGPoint(x: 13.0, y: 16.5))
        outerArrow.addLine(to: CGPoint(x: 12.6, y: 16.6))
        outerArrow.closeSubpath()
        ctx.addPath(outerArrow)
        ctx.fillPath()

        let outerStick = CGMutablePath()
        outerStick.move(to:    CGPoint(x: 17.3, y: 21.6))
        outerStick.addLine(to: CGPoint(x: 13.7, y: 23.1))
        outerStick.addLine(to: CGPoint(x: 9.0,  y: 12.0))
        outerStick.addLine(to: CGPoint(x: 12.7, y: 10.5))
        outerStick.closeSubpath()
        ctx.addPath(outerStick)
        ctx.fillPath()

        // ── Black shapes (fill) ──
        ctx.setFillColor(CGColor.black)

        // Rotated rect (pre-computed transform from SVG matrix)
        let innerStick = CGMutablePath()
        innerStick.move(to:    CGPoint(x: 11.03, y: 14.29))
        innerStick.addLine(to: CGPoint(x: 12.87, y: 13.52))
        innerStick.addLine(to: CGPoint(x: 15.97, y: 20.90))
        innerStick.addLine(to: CGPoint(x: 14.13, y: 21.67))
        innerStick.closeSubpath()
        ctx.addPath(innerStick)
        ctx.fillPath()

        let innerArrow = CGMutablePath()
        innerArrow.move(to:    CGPoint(x: 9.2,  y: 7.3))
        innerArrow.addLine(to: CGPoint(x: 9.2,  y: 18.5))
        innerArrow.addLine(to: CGPoint(x: 12.2, y: 15.6))
        innerArrow.addLine(to: CGPoint(x: 12.6, y: 15.5))
        innerArrow.addLine(to: CGPoint(x: 17.4, y: 15.5))
        innerArrow.closeSubpath()
        ctx.addPath(innerArrow)
        ctx.fillPath()

        return ctx.makeImage()
    }

    /// CIImage variant for video compositing.
    static func ciImage(width: CGFloat, screenScale: CGFloat = 2.0) -> CIImage? {
        guard let cg = cgImage(width: width, screenScale: screenScale) else { return nil }
        return CIImage(cgImage: cg)
    }

    /// NSImage variant for SwiftUI previews.
    static func nsImage(width: CGFloat, shape: CursorShape = .arrow) -> NSImage? {
        guard let cg = cgImage(width: width, shape: shape) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: width * CGFloat(cg.height) / CGFloat(cg.width)))
    }

    static func hotspot(shape: CursorShape, imageSize: CGSize) -> CGPoint {
        switch shape {
        case .arrow: return .zero
        case .circle: return CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        case .hand:
            guard let source = handBitmap else { return .zero }
            return CGPoint(x: source.hotspot.x / CGFloat(source.image.width) * imageSize.width,
                           y: source.hotspot.y / CGFloat(source.image.height) * imageSize.height)
        }
    }
}
