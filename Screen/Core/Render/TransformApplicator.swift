import Foundation
import CoreImage
import CoreGraphics
import AppKit

/// Applies a CameraTransform to a CIImage, producing a cropped and scaled output.
///
/// The transform defines a viewport (zoom + center) in normalized 0-1 coordinates.
/// This applicator computes the crop rect in pixel space and returns a scaled CIImage
/// at the desired output resolution.
enum TransformApplicator {

    /// Apply a camera transform to a source image.
    ///
    /// - Parameters:
    ///   - transform: The camera state (zoom, center) to apply.
    ///   - image: Source CIImage (full frame from video).
    ///   - sourceSize: Pixel dimensions of the source frame.
    ///   - outputSize: Desired pixel dimensions of the output. Defaults to sourceSize.
    /// - Returns: A CIImage cropped and scaled according to the transform.
    static func apply(
        _ transform: CameraTransform,
        to image: CIImage,
        sourceSize: CGSize,
        outputSize: CGSize? = nil
    ) -> CIImage {
        let output = outputSize ?? sourceSize
        let clamped = transform.clamped()

        // No zoom — just scale to output if needed
        guard clamped.zoom > 1.001 else {
            if sourceSize == output {
                return image
            }
            let scaleX = output.width / sourceSize.width
            let scaleY = output.height / sourceSize.height
            return image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        // Compute crop rect in source pixel coordinates.
        // CIImage origin is bottom-left, but our normalized coords have (0,0) at top-left.
        // Flip Y: ciY = 1.0 - normalizedY
        let viewportWidth = sourceSize.width / clamped.zoom
        let viewportHeight = sourceSize.height / clamped.zoom

        let ciCenterX = clamped.centerX * sourceSize.width
        let ciCenterY = (1.0 - clamped.centerY) * sourceSize.height

        let cropX = ciCenterX - viewportWidth / 2.0
        let cropY = ciCenterY - viewportHeight / 2.0
        let cropRect = CGRect(x: cropX, y: cropY, width: viewportWidth, height: viewportHeight)

        // Crop, then scale up to output size
        let cropped = image.cropped(to: cropRect)

        let scaleX = output.width / viewportWidth
        let scaleY = output.height / viewportHeight

        // Translate to origin first (cropped image retains its original origin)
        let translated = cropped.transformed(by: CGAffineTransform(
            translationX: -cropRect.origin.x,
            y: -cropRect.origin.y
        ))

        return translated.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }
}

final class LiveEditFrameRenderer {
    let outputSize: CGSize
    private let settings: VideoEditSettings
    private let cropRect: CGRect
    private let normalizedCrop: CGRect
    private let evaluator: FrameEvaluator
    private let canvas: CanvasCompositor?
    private let webcam: WebcamCompositor?
    private let positions: [MouseDataRecorder.MousePosition]
    private let padding: CGFloat
    private let cursor: CGImage?

    init(sourceSize: CGSize, settings: VideoEditSettings, keyframes: [CameraKeyframe],
         mouse: MouseDataRecorder.MouseRecording? = nil) {
        self.settings = settings
        cropRect = settings.crop.pixelRect(in: sourceSize)
        normalizedCrop = CGRect(x: cropRect.minX / sourceSize.width,
                                y: 1 - cropRect.maxY / sourceSize.height,
                                width: cropRect.width / sourceSize.width, height: cropRect.height / sourceSize.height)
        let dimensions = settings.outputSize(source: sourceSize)
        let scale = min(1, 2560 / max(dimensions.width, dimensions.height))
        outputSize = CGSize(width: max(2, floor((dimensions.width * scale + 0.000001) / 2) * 2),
                            height: max(2, floor((dimensions.height * scale + 0.000001) / 2) * 2))
        evaluator = FrameEvaluator(keyframes: settings.zoomEnabled ? keyframes : [])
        positions = mouse?.positions ?? []
        let captureWidth = (mouse?.screenBounds.width ?? Double(sourceSize.width)) * (mouse?.scaleFactor ?? 1)
        padding = sourceSize.width > captureWidth + 1 ? (sourceSize.width - captureWidth) / (2 * sourceSize.width) : 0
        cursor = settings.showCursor ? CursorImageProvider.cgImage(width: 24 * settings.cursorScale, screenScale: 2, shape: settings.cursorShape) : nil
        canvas = settings.backgroundEnabled || settings.ratio != .original || settings.layout != .desktop
            ? CanvasCompositor(size: outputSize, sourceSize: cropRect.size, layout: settings.layout,
                               wallpaper: settings.wallpaper, phoneContentMode: settings.phoneMode,
                               desktopCornerRadius: CGFloat(settings.desktopCornerRadius)) : nil
        webcam = settings.webcamEnabled ? WebcamCompositor(outputSize: outputSize, position: settings.webcamPosition,
                                   pipSize: settings.webcamSize, shape: settings.webcamShape) : nil
    }

    func render(_ source: CIImage, at time: Double, webcamImage: CIImage? = nil,
                webcamTime: Double? = nil) -> CIImage {
        var transform = evaluator.evaluate(at: time)
        transform.centerX = (transform.centerX - normalizedCrop.minX) / normalizedCrop.width
        transform.centerY = (transform.centerY - normalizedCrop.minY) / normalizedCrop.height
        transform = transform.clamped()
        let contentSize = canvas == nil ? outputSize : cropRect.size
        var image = source.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        if canvas == nil {
            image = TransformApplicator.apply(transform, to: image, sourceSize: cropRect.size, outputSize: contentSize)
        }
        var cursorLayer: CIImage?
        if let cursor, let position = position(at: time) {
            let sourcePoint = CGPoint(x: padding + position.x * (1 - 2 * padding),
                                      y: padding + (1 - position.y) * (1 - 2 * padding))
            if normalizedCrop.contains(sourcePoint) {
                let normalizedX = (sourcePoint.x - normalizedCrop.minX) / normalizedCrop.width
                let normalizedY = (sourcePoint.y - normalizedCrop.minY) / normalizedCrop.height
                let horizontal = (normalizedX - transform.centerX) * transform.zoom + 0.5
                let vertical = (normalizedY - transform.centerY) * transform.zoom + 0.5
                let hotspot = CursorImageProvider.hotspot(shape: settings.cursorShape, imageSize: CGSize(width: cursor.width, height: cursor.height))
                let cursorScale = canvas == nil ? outputSize.width / cropRect.width : 1
                let overlay = CIImage(cgImage: cursor)
                    .transformed(by: CGAffineTransform(scaleX: cursorScale, y: cursorScale))
                    .transformed(by: CGAffineTransform(translationX: horizontal * contentSize.width - hotspot.x * cursorScale,
                                                       y: (1 - vertical) * contentSize.height - (CGFloat(cursor.height) - hotspot.y) * cursorScale))
                if canvas != nil {
                    cursorLayer = overlay.composited(over: CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: contentSize)))
                        .cropped(to: CGRect(origin: .zero, size: contentSize))
                } else {
                    image = overlay.composited(over: image).cropped(to: CGRect(origin: .zero, size: contentSize))
                }
            }
        }
        if let canvas { image = canvas.composite(primary: image, camera: transform, primaryOverlay: cursorLayer) }
        if let webcam, let webcamImage {
            let layout = CameraLayoutChange.settings(at: webcamTime ?? time, initial: settings.cameraLayout,
                                                     changes: settings.cameraLayoutChanges)
            image = webcam.composite(webcamImage: webcamImage, onto: image, settings: layout)
        }
        return image.cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    private func position(at time: Double) -> CGPoint? {
        guard let first = positions.first, let last = positions.last else { return nil }
        if time <= first.timestamp { return CGPoint(x: first.x, y: first.y) }
        if time >= last.timestamp { return CGPoint(x: last.x, y: last.y) }
        var lower = 0
        var upper = positions.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if positions[middle].timestamp <= time { lower = middle } else { upper = middle }
        }
        let before = positions[lower]
        let after = positions[upper]
        let fraction = (time - before.timestamp) / max(0.0001, after.timestamp - before.timestamp)
        return CGPoint(x: before.x + (after.x - before.x) * fraction, y: before.y + (after.y - before.y) * fraction)
    }
}

struct CanvasGeometry {
    let desktop: CGRect?
    let phone: CGRect?

    init(size: CGSize, layout: DeviceLayout, sourceSize: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        let margin = min(size.width, size.height) * 0.08
        let area = bounds.insetBy(dx: margin, dy: margin)
        switch layout {
        case .desktop:
            desktop = Self.fit(sourceSize, in: area)
            phone = nil
        case .iPhone, .iPhoneDuoClosed, .iPhoneDuoUnfolded:
            desktop = nil
            phone = Self.fit(layout.phoneFrameSize, in: area)
        case .duo:
            let gap = margin * 0.65
            if size.width / size.height >= 1.3 {
                let phoneWidth = min(area.width * 0.27, area.height * 414 / 868)
                phone = Self.fit(CGSize(width: 414, height: 868), in: CGRect(x: area.maxX - phoneWidth, y: area.minY, width: phoneWidth, height: area.height))
                desktop = Self.fit(sourceSize, in: CGRect(x: area.minX, y: area.minY, width: area.width - phoneWidth - gap, height: area.height))
            } else {
                let desktopHeight = min(area.height * 0.36, area.width * sourceSize.height / sourceSize.width)
                desktop = Self.fit(sourceSize, in: CGRect(x: area.minX, y: area.maxY - desktopHeight, width: area.width, height: desktopHeight))
                phone = Self.fit(CGSize(width: 414, height: 868), in: CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - desktopHeight - gap))
            }
        }
    }

    static func fit(_ source: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / max(1, source.width), rect.height / max(1, source.height))
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func phoneUnit(_ frame: CGRect, layout: DeviceLayout = .iPhone) -> CGFloat {
        (layout.isFoldablePhone ? min(frame.width, frame.height) : frame.width) / 414
    }

    static func phoneScreen(_ frame: CGRect, layout: DeviceLayout = .iPhone) -> CGRect {
        let unit = phoneUnit(frame, layout: layout)
        return frame.insetBy(dx: 12 * unit, dy: 12 * unit)
    }

    static func phoneContent(_ frame: CGRect, layout: DeviceLayout = .iPhone) -> CGRect {
        let screen = phoneScreen(frame, layout: layout)
        if layout.isFoldablePhone { return screen }
        let unit = phoneUnit(frame, layout: layout)
        return CGRect(x: screen.minX, y: screen.minY + 24 * unit, width: screen.width, height: screen.height - 66 * unit)
    }
}

final class CanvasCompositor {
    let geometry: CanvasGeometry
    let bounds: CGRect
    private let background: CIImage
    private let chrome: CIImage
    private let layout: DeviceLayout
    private let phoneContentMode: PhoneContentMode
    private let desktopCornerRadius: CGFloat

    init(size: CGSize, sourceSize: CGSize, layout: DeviceLayout, wallpaper: BackgroundStyle.WallpaperPreset, phoneContentMode: PhoneContentMode = .fit, desktopCornerRadius: CGFloat = 0.025) {
        self.layout = layout
        self.phoneContentMode = phoneContentMode
        self.desktopCornerRadius = min(0.5, max(0, desktopCornerRadius))
        bounds = CGRect(origin: .zero, size: size)
        geometry = CanvasGeometry(size: size, layout: layout, sourceSize: sourceSize)
        background = Self.makeBackground(size: size, wallpaper: wallpaper)
        chrome = Self.makeChrome(size: size, geometry: geometry, layout: layout, desktopCornerRadius: self.desktopCornerRadius)
    }

    func composite(primary: CIImage, phone: CIImage? = nil, camera: CameraTransform = .identity, primaryOverlay: CIImage? = nil) -> CIImage {
        var result = chrome.composited(over: background)
        func content(in rect: CGRect, mode: PhoneContentMode = .fit) -> CIImage {
            let video = Self.fitted(primary, in: rect, mode: mode, camera: camera)
            guard let primaryOverlay else { return video }
            return Self.fitted(primaryOverlay, in: rect, mode: mode).composited(over: video)
        }
        if let rect = geometry.desktop {
            result = content(in: rect)
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: result,
                    kCIInputMaskImageKey: Self.roundedMask(rect, radius: min(rect.width, rect.height) * desktopCornerRadius)
                ])
        }
        if let frame = geometry.phone, let image = layout.isPhone ? primary : phone {
            let rect = CanvasGeometry.phoneContent(frame, layout: layout)
            let phoneImage = layout.isPhone ? content(in: rect, mode: phoneContentMode) : Self.fitted(image, in: rect, mode: phoneContentMode)
            result = phoneImage.composited(over: result).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: result,
                kCIInputMaskImageKey: Self.roundedMask(CanvasGeometry.phoneScreen(frame, layout: layout), radius: CanvasGeometry.phoneUnit(frame, layout: layout) * (layout.isFoldablePhone ? 32 : 48))
            ])
        }
        return result.cropped(to: bounds)
    }

    static func preview(size: CGSize, layout: DeviceLayout, wallpaper: BackgroundStyle.WallpaperPreset, desktopCornerRadius: CGFloat = 0.025) -> CGImage? {
        func sample(phone: Bool) -> CIImage {
            let size = phone ? (layout.isFoldablePhone ? layout.phoneFrameSize : CGSize(width: 390, height: 778)) : CGSize(width: 1440, height: 900)
            let context = context(size: size)
            context.setFillColor(CGColor(gray: 0.11, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(CGColor(gray: 0.16, alpha: 1))
            context.fill(CGRect(x: 0, y: size.height - 65, width: size.width, height: 65))
            if !phone {
                for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    context.setFillColor(color.cgColor)
                    context.fillEllipse(in: CGRect(x: 26 + index * 30, y: Int(size.height) - 44, width: 18, height: 18))
                }
            }
            let lineHeight = size.width * 0.018
            let lineSpacing = lineHeight * 2
            let centerY = (size.height - 65) / 2
            for (index, fraction) in [0.45, 0.36, 0.405].enumerated() {
                let width = size.width * fraction
                let line = CGRect(x: (size.width - width) / 2,
                                  y: centerY + CGFloat(1 - index) * lineSpacing - lineHeight / 2,
                                  width: width, height: lineHeight)
                context.setFillColor(CGColor(gray: 0.16, alpha: 1))
                context.addPath(CGPath(roundedRect: line, cornerWidth: lineHeight * 0.375, cornerHeight: lineHeight * 0.375, transform: nil))
                context.fillPath()
            }
            return CIImage(cgImage: context.makeImage()!)
        }
        let primary = sample(phone: layout.isPhone)
        let compositor = CanvasCompositor(size: size, sourceSize: primary.extent.size, layout: layout, wallpaper: wallpaper, desktopCornerRadius: desktopCornerRadius)
        let image = compositor.composite(primary: primary, phone: sample(phone: true))
        return CIContext().createCGImage(image, from: image.extent)
    }

    static func fitted(_ image: CIImage, in rect: CGRect, mode: PhoneContentMode = .fit, camera: CameraTransform = .identity) -> CIImage {
        let scale = mode == .fit
            ? min(rect.width / image.extent.width, rect.height / image.extent.height)
            : max(rect.width / image.extent.width, rect.height / image.extent.height)
        let target = CGRect(x: rect.midX - image.extent.width * scale / 2,
                            y: rect.midY - image.extent.height * scale / 2,
                            width: image.extent.width * scale, height: image.extent.height * scale)
        let source = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return TransformApplicator.apply(camera, to: source, sourceSize: image.extent.size, outputSize: target.size)
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
            .cropped(to: rect)
    }

    private static func roundedMask(_ rect: CGRect, radius: CGFloat) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": radius,
            "inputColor": CIColor.white
        ])!.outputImage!
    }

    private static func context(size: CGSize) -> CGContext {
        CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)), bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func makeBackground(size: CGSize, wallpaper: BackgroundStyle.WallpaperPreset) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        if let name = wallpaper.imageName, let image = NSImage(named: name),
           let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let scale = max(size.width / CGFloat(bitmap.width), size.height / CGFloat(bitmap.height))
            return CIImage(cgImage: bitmap)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (size.width - CGFloat(bitmap.width) * scale) / 2,
                                                  y: (size.height - CGFloat(bitmap.height) * scale) / 2))
                .cropped(to: rect)
        }
        let context = context(size: size)
        let stops = wallpaper.gradientColors
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map { $0.color.cgColor } as CFArray,
                                  locations: stops.map { CGFloat($0.location) })!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        return CIImage(cgImage: context.makeImage()!)
    }

    private static func makeChrome(size: CGSize, geometry: CanvasGeometry, layout: DeviceLayout, desktopCornerRadius: CGFloat) -> CIImage {
        let context = context(size: size)
        func rounded(_ rect: CGRect, radius: CGFloat, color: CGColor) {
            context.setFillColor(color)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        if let desktop = geometry.desktop {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -size.height * 0.012), blur: size.height * 0.025, color: CGColor(gray: 0, alpha: 0.4))
            rounded(desktop.insetBy(dx: -1, dy: -1), radius: min(desktop.width, desktop.height) * desktopCornerRadius + 1, color: CGColor(gray: 0.25, alpha: 1))
            context.restoreGState()
        }
        if let phone = geometry.phone {
            let unit = CanvasGeometry.phoneUnit(phone, layout: layout)
            let radius: CGFloat = layout.isFoldablePhone ? 44 : 60
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 28 * unit, color: CGColor(gray: 0, alpha: 0.45))
            rounded(phone, radius: radius * unit, color: CGColor(gray: 0.42, alpha: 1))
            context.restoreGState()
            rounded(phone.insetBy(dx: 2 * unit, dy: 2 * unit), radius: (radius - 2) * unit, color: CGColor(gray: 0.025, alpha: 1))
            let screen = CanvasGeometry.phoneScreen(phone, layout: layout)
            rounded(screen, radius: (radius - 12) * unit, color: CGColor(gray: 0.07, alpha: 1))
            if !layout.isFoldablePhone {
                rounded(CGRect(x: phone.midX - 60 * unit, y: screen.maxY - 34 * unit, width: 120 * unit, height: 25 * unit), radius: 13 * unit, color: CGColor(gray: 0, alpha: 1))
                rounded(CGRect(x: phone.midX - 64 * unit, y: screen.minY + 8 * unit, width: 128 * unit, height: 5 * unit), radius: 2.5 * unit, color: CGColor(gray: 0.8, alpha: 1))
            }
        }
        return CIImage(cgImage: context.makeImage()!)
    }
}
