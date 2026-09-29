import Foundation
import CoreGraphics

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
