import Foundation
import CoreGraphics

/// A fixed-aspect viewport in the cropped screen, with a top-left origin.
struct ZoomRegion: Codable, Equatable {
    var rect: CGRect

    init(zoom: CGFloat = 2, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        let side = 1 / min(8, max(1, zoom.isFinite ? zoom : 2))
        let x = center.x.isFinite ? center.x : 0.5
        let y = center.y.isFinite ? center.y : 0.5
        rect = CGRect(x: min(1 - side, max(0, x - side / 2)),
                      y: min(1 - side, max(0, y - side / 2)), width: side, height: side)
    }

    var normalized: ZoomRegion {
        ZoomRegion(zoom: rect.width > 0 ? 1 / rect.width : 2,
                   center: CGPoint(x: rect.midX, y: rect.midY))
    }

    var magnification: CGFloat { 1 / normalized.rect.width }

    /// Fraction of the source crop visible through the device screen at 1×.
    /// Fit keeps the whole source; Fill clips it to the phone screen's aspect.
    static func viewport(sourceSize: CGSize, layout: DeviceLayout, mode: PhoneContentMode) -> CGSize {
        guard layout.isPhone, mode == .fill, sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let screen = CanvasGeometry.phoneContent(CGRect(origin: .zero, size: layout.phoneFrameSize), layout: layout)
        let scale = max(screen.width / sourceSize.width, screen.height / sourceSize.height)
        return CGSize(width: min(1, screen.width / (sourceSize.width * scale)),
                      height: min(1, screen.height / (sourceSize.height * scale)))
    }

    func visibleRect(in viewport: CGSize = CGSize(width: 1, height: 1)) -> CGRect {
        let area = normalized.rect
        let size = CGSize(width: area.width * viewport.width, height: area.height * viewport.height)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func moved(by delta: CGSize) -> ZoomRegion {
        let area = normalized.rect
        return ZoomRegion(zoom: magnification,
                          center: CGPoint(x: area.midX + delta.width, y: area.midY + delta.height))
    }

    func resized(by delta: CGSize, corner: PhoneCrop.Corner,
                 viewport: CGSize = CGSize(width: 1, height: 1)) -> ZoomRegion {
        let area = normalized.rect
        let visible = visibleRect(in: viewport)
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let anchor = CGPoint(x: left ? visible.maxX : visible.minX, y: top ? visible.maxY : visible.minY)
        let change = ((left ? -delta.width : delta.width) / viewport.width
                      + (top ? -delta.height : delta.height) / viewport.height) / 2
        // The renderer clamps the underlying source crop. Respect those bounds
        // while keeping the opposite visible (phone) corner fixed.
        func limit(anchor: CGFloat, fraction: CGFloat, negative: Bool) -> CGFloat {
            let direction: CGFloat = negative ? -1 : 1
            let before = (1 - direction * fraction) / 2
            let after = (1 + direction * fraction) / 2
            return min(before > 0 ? anchor / before : 1,
                       after > 0 ? (1 - anchor) / after : 1)
        }
        let maximumSide = min(limit(anchor: anchor.x, fraction: viewport.width, negative: left),
                              limit(anchor: anchor.y, fraction: viewport.height, negative: top))
        let side = min(maximumSide, max(1.0 / 8, area.width + change))
        return ZoomRegion(zoom: 1 / side,
                          center: CGPoint(x: anchor.x + (left ? -side : side) * viewport.width / 2,
                                          y: anchor.y + (top ? -side : side) * viewport.height / 2))
    }

    func camera(in crop: PhoneCrop) -> CameraTransform {
        let area = normalized.rect
        let source = crop.normalized
        // Bounds are clamped after the source crop is applied by the renderer.
        return CameraTransform(zoom: magnification,
                               centerX: source.minX + area.midX * source.width,
                               centerY: source.minY + area.midY * source.height)
    }
}

/// A camera state at a specific point in time, defined by zoom level and center position.
///
/// All coordinates are normalized to 0-1 range where (0,0) is top-left and (1,1) is bottom-right.
/// Zoom of 1.0 means no zoom (full frame visible), 2.0 means 2× magnification.
struct CameraTransform: Codable, Equatable {
    /// Zoom level. 1.0 = no zoom, 2.0 = 2× magnification.
    var zoom: CGFloat = 1.0
    /// Center X in normalized coordinates (0-1). 0.5 = center of frame.
    var centerX: CGFloat = 0.5
    /// Center Y in normalized coordinates (0-1). 0.5 = center of frame.
    var centerY: CGFloat = 0.5

    static let identity = CameraTransform()

    /// Clamp center so the viewport stays within [0, 1] at the given zoom.
    func clamped() -> CameraTransform {
        guard zoom > 1.0 else {
            return CameraTransform(zoom: 1.0, centerX: 0.5, centerY: 0.5)
        }
        let halfCrop = 0.5 / zoom
        let x = max(halfCrop, min(1.0 - halfCrop, centerX))
        let y = max(halfCrop, min(1.0 - halfCrop, centerY))
        return CameraTransform(zoom: zoom, centerX: x, centerY: y)
    }

    /// Linearly interpolate between two transforms.
    func lerp(to other: CameraTransform, t: CGFloat) -> CameraTransform {
        let t = max(0, min(1, t))
        return CameraTransform(
            zoom: zoom + (other.zoom - zoom) * t,
            centerX: centerX + (other.centerX - centerX) * t,
            centerY: centerY + (other.centerY - centerY) * t
        )
    }
}

/// Easing functions for interpolating between keyframes.
enum EasingCurve: String, Codable, CaseIterable {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    /// Evaluate the easing function for a linear progress value in [0, 1].
    func evaluate(_ t: CGFloat) -> CGFloat {
        let t = max(0, min(1, t))
        switch self {
        case .linear:
            return t
        case .easeIn:
            return t * t * t
        case .easeOut:
            return 1.0 - pow(1.0 - t, 3)
        case .easeInOut:
            // Smooth cubic ease-in-out for gentle camera motion
            return t < 0.5
                ? 4.0 * t * t * t
                : 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0
        }
    }
}

/// A camera state at a specific time, used to define the zoom animation.
struct CameraKeyframe: Codable {
    /// Time in seconds from the start of the recording.
    var time: TimeInterval
    /// The camera state at this time.
    var transform: CameraTransform
    /// Easing curve used when interpolating FROM this keyframe to the next.
    var easing: EasingCurve = .easeInOut
}
