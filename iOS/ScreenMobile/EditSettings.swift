import Foundation
import CoreGraphics

enum CanvasFormat: String, CaseIterable, Codable, Identifiable {
    case original = "Original"
    case portrait = "9:16"
    case square = "1:1"
    case landscape = "16:9"

    var id: String { rawValue }

    func size(for source: CGSize) -> CGSize {
        switch self {
        case .original:
            let scale = min(1, 1920 / max(source.width, source.height, 1))
            return CGSize(width: max(2, floor(source.width * scale / 2) * 2),
                          height: max(2, floor(source.height * scale / 2) * 2))
        case .portrait: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        case .landscape: return CGSize(width: 1920, height: 1080)
        }
    }
}

enum MobileBackground: String, CaseIterable, Codable, Identifiable {
    case prism = "Prism"
    case lagoon = "Lagoon"
    case ember = "Ember"
    case midnight = "Midnight"
    case white = "White"
    case black = "Black"

    var id: String { rawValue }
    var assetName: String? {
        switch self {
        case .white, .black: return nil
        default: return "Wallpaper\(rawValue)"
        }
    }
}

struct EditSettings: Codable, Equatable {
    var format: CanvasFormat = .original
    var background: MobileBackground = .prism
    var padding: Double = 0.08
    var cornerRadius: Double = 0.04
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var muted = false
    var zoomEnabled = false
    var zoomStart: Double = 0
    var zoomEnd: Double = 0
    var zoomAmount: Double = 1.6
    var focusX: Double = 0.5
    var focusY: Double = 0.5

    var trimmedDuration: Double { max(0, trimEnd - trimStart) }

    mutating func constrain(to duration: Double) {
        let duration = duration.isFinite ? max(0, duration) : 0
        let minimum = min(0.1, duration)
        trimStart = min(max(0, trimStart), max(0, duration - minimum))
        trimEnd = min(duration, max(trimStart + minimum, trimEnd))
        zoomStart = min(trimEnd, max(trimStart, zoomStart))
        zoomEnd = min(trimEnd, max(zoomStart, zoomEnd))
        padding = min(0.2, max(0, padding))
        cornerRadius = min(0.12, max(0, cornerRadius))
        zoomAmount = min(3, max(1, zoomAmount))
        focusX = min(1, max(0, focusX))
        focusY = min(1, max(0, focusY))
    }

    func zoom(at sourceTime: Double) -> Double {
        guard zoomEnabled, zoomEnd > zoomStart,
              sourceTime > zoomStart, sourceTime < zoomEnd else { return 1 }
        let ramp = min(0.35, (zoomEnd - zoomStart) / 2)
        let progress = min(1, (sourceTime - zoomStart) / ramp, (zoomEnd - sourceTime) / ramp)
        let eased = progress * progress * (3 - 2 * progress)
        return 1 + (zoomAmount - 1) * eased
    }

    func videoRect(source: CGSize, canvas: CGSize) -> CGRect {
        let inset = min(canvas.width, canvas.height) * padding
        let available = CGRect(origin: .zero, size: canvas).insetBy(dx: inset, dy: inset)
        let scale = min(available.width / max(1, source.width), available.height / max(1, source.height))
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}