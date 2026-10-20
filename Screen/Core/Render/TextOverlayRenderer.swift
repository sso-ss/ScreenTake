import AppKit
import CoreImage
import CoreText

/// Immutable raster layers are prepared once and shared by preview/export frame callbacks.
final class TextOverlayRenderer {
    private struct Layer {
        let settings: TextOverlay
        let image: CIImage
    }
    private let layers: [Layer]
    private let bounds: CGRect

    init(overlays: [TextOverlay], size: CGSize) {
        bounds = CGRect(origin: .zero, size: size)
        layers = overlays.compactMap { overlay in
            guard (try? overlay.validate()) != nil, !overlay.text.isEmpty,
                  let image = Self.raster(overlay, size: size) else { return nil }
            return Layer(settings: overlay, image: image)
        }
    }

    func composite(over image: CIImage, at time: Double) -> CIImage {
        layers.reduce(image) { result, layer in
            guard layer.settings.isVisible(at: time) else { return result }
            return layer.image.composited(over: result).cropped(to: bounds)
        }
    }

    private static func nsColor(_ hex: String) -> NSColor {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private struct Layout {
        let unit: Double
        let rasterSize: CGSize
        let frame: CTFrame
        let lineRects: [CGRect]
        let textBounds: CGRect
        let crop: CGRect
    }

    /// Uses the same cropped layout as rendering, before rotation, in output pixels.
    static func selectionSize(for text: TextOverlay, canvas: CGSize) -> CGSize? {
        guard (try? text.validate()) != nil, let layout = layout(text, size: canvas) else { return nil }
        let outputScale = canvas.height / 1080 / layout.unit
        return CGSize(width: layout.crop.width * outputScale * text.scale,
                      height: layout.crop.height * outputScale * (text.uniformScale ? text.scale : text.scaleY))
    }

    private static func layout(_ text: TextOverlay, size: CGSize) -> Layout? {
        guard size.width > 0, size.height > 0 else { return nil }
        // Lay out in stable design units so resolution changes preserve line wrapping.
        let unit = min(2, size.height / 1080)
        let width = max(1, size.width / size.height * 1080 * text.boxWidth)
        let font = text.fontName == "System" ? NSFont.systemFont(ofSize: text.fontSize)
            : NSFont(name: text.fontName, size: text.fontSize) ?? NSFont.systemFont(ofSize: text.fontSize)
        var traits: NSFontTraitMask = []
        if text.bold { traits.insert(.boldFontMask) }
        if text.italic { traits.insert(.italicFontMask) }
        let styledFont = NSFontManager.shared.convert(font, toHaveTrait: traits)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = text.alignment == .left ? .left : text.alignment == .right ? .right : .center
        paragraph.lineSpacing = text.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: styledFont, .foregroundColor: nsColor(text.color).cgColor,
            .kern: text.characterSpacing, .paragraphStyle: paragraph
        ]
        if text.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if text.strokeEnabled && text.strokeWidth > 0 {
            attributes[.strokeColor] = nsColor(text.strokeColor).cgColor
            attributes[.strokeWidth] = -text.strokeWidth / text.fontSize * 100
        }
        let string = NSAttributedString(string: text.displayText, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(string)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                   CGSize(width: width, height: 2160), nil)
        let height = max(text.fontSize * 1.5, min(2160, ceil(measured.height) + text.fontSize))
        let margin = 240.0
        let rasterSize = CGSize(width: ceil((width + margin * 2) * unit), height: ceil((height + margin * 2) * unit))
        let rect = CGRect(x: margin, y: margin, width: width, height: height)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var lineRects: [CGRect] = []
        for (index, line) in lines.enumerated() {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let length = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            guard length > 0 else { continue }
            lineRects.append(CGRect(x: margin + origins[index].x, y: margin + origins[index].y - descent,
                                    width: length, height: ascent + descent))
        }
        guard let first = lineRects.first else { return nil }
        let textBounds = lineRects.dropFirst().reduce(first) { $0.union($1) }
        var visibleBounds = textBounds.insetBy(dx: -text.strokeWidth - 4, dy: -text.strokeWidth - 4)
        if text.backgroundEnabled {
            for line in text.backgroundStyle == .lines ? lineRects : [textBounds] {
                let background = line.insetBy(dx: -text.paddingX, dy: -text.paddingY)
                    .offsetBy(dx: text.backgroundOffsetX, dy: -text.backgroundOffsetY)
                visibleBounds = visibleBounds.union(background)
            }
        }
        let crop = visibleBounds.applying(CGAffineTransform(scaleX: unit, y: unit)).integral
            .intersection(CGRect(origin: .zero, size: rasterSize))
        return Layout(unit: unit, rasterSize: rasterSize, frame: frame, lineRects: lineRects,
                      textBounds: textBounds, crop: crop)
    }

    private static func raster(_ text: TextOverlay, size: CGSize) -> CIImage? {
        guard let layout = layout(text, size: size) else { return nil }
        let unit = layout.unit, rasterSize = layout.rasterSize, crop = layout.crop
        guard let context = CGContext(data: nil, width: Int(rasterSize.width), height: Int(rasterSize.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: unit, y: unit)
        context.setAlpha(text.opacity)
        if text.backgroundEnabled {
            context.setFillColor(nsColor(text.backgroundColor).withAlphaComponent(text.backgroundOpacity).cgColor)
            for line in text.backgroundStyle == .lines ? layout.lineRects : [layout.textBounds] {
                let background = line.insetBy(dx: -text.paddingX, dy: -text.paddingY)
                    .offsetBy(dx: text.backgroundOffsetX, dy: -text.backgroundOffsetY)
                let radius = min(text.backgroundRadius, background.width / 2, background.height / 2)
                context.addPath(CGPath(roundedRect: background, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
        }
        context.textMatrix = .identity
        CTFrameDraw(layout.frame, context)
        guard let bitmap = context.makeImage() else { return nil }
        // Release the large layout surface; retain only the actual text pixels.
        let bitmapCrop = CGRect(x: crop.minX, y: rasterSize.height - crop.maxY, width: crop.width, height: crop.height)
        guard let cropped = bitmap.cropping(to: bitmapCrop) else { return nil }
        let raster = CIImage(cgImage: cropped)
        let outputScale = size.height / 1080 / unit
        return raster
            .transformed(by: CGAffineTransform(translationX: -crop.width / 2, y: -crop.height / 2))
            .transformed(by: CGAffineTransform(scaleX: outputScale * text.scale,
                                              y: outputScale * (text.uniformScale ? text.scale : text.scaleY)))
            .transformed(by: CGAffineTransform(rotationAngle: -text.rotation * .pi / 180))
            .transformed(by: CGAffineTransform(translationX: size.width * text.x, y: size.height * (1 - text.y)))
    }
}
