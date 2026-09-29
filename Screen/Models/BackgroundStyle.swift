import Foundation
import SwiftUI

/// Background style for window-mode recordings
enum BackgroundStyle: Codable, Equatable {
    case solid(CodableColor)
    case gradient(GradientDef)
    case wallpaper(WallpaperPreset)
    case image(Data)

    // MARK: - Wallpaper Presets (from mockup-tool)

    enum WallpaperPreset: String, Codable, CaseIterable {
        case sonoma
        case aurora
        case sunset
        case ocean
        case blossom
        case nebula
        case moss
        case dusk
        case prism
        case lagoon
        case ember
        case midnight

        var displayName: String {
            rawValue.capitalized
        }

        var imageName: String? {
            switch self {
            case .prism, .lagoon, .ember, .midnight:
                return "Wallpaper\(displayName)"
            default:
                return nil
            }
        }

        /// Returns gradient stops for CoreImage rendering
        var gradientColors: [GradientStop] {
            switch self {
            case .sonoma:
                return [
                    GradientStop(color: CodableColor(hex: "#1e1b4b"), location: 0),
                    GradientStop(color: CodableColor(hex: "#6a3de8"), location: 0.3),
                    GradientStop(color: CodableColor(hex: "#f472b6"), location: 0.6),
                    GradientStop(color: CodableColor(hex: "#38bdf8"), location: 1.0),
                ]
            case .aurora:
                return [
                    GradientStop(color: CodableColor(hex: "#0c0a1a"), location: 0),
                    GradientStop(color: CodableColor(hex: "#22d3ee"), location: 0.3),
                    GradientStop(color: CodableColor(hex: "#a78bfa"), location: 0.6),
                    GradientStop(color: CodableColor(hex: "#042f2e"), location: 1.0),
                ]
            case .sunset:
                return [
                    GradientStop(color: CodableColor(hex: "#1c1917"), location: 0),
                    GradientStop(color: CodableColor(hex: "#ec4899"), location: 0.3),
                    GradientStop(color: CodableColor(hex: "#f97316"), location: 0.7),
                    GradientStop(color: CodableColor(hex: "#1e1b4b"), location: 1.0),
                ]
            case .ocean:
                return [
                    GradientStop(color: CodableColor(hex: "#020617"), location: 0),
                    GradientStop(color: CodableColor(hex: "#0891b2"), location: 0.3),
                    GradientStop(color: CodableColor(hex: "#6366f1"), location: 0.6),
                    GradientStop(color: CodableColor(hex: "#064e3b"), location: 1.0),
                ]
            case .blossom:
                return [
                    GradientStop(color: CodableColor(hex: "#fdf2f8"), location: 0),
                    GradientStop(color: CodableColor(hex: "#f9a8d4"), location: 0.4),
                    GradientStop(color: CodableColor(hex: "#c4b5fd"), location: 0.7),
                    GradientStop(color: CodableColor(hex: "#ede9fe"), location: 1.0),
                ]
            case .nebula:
                return [
                    GradientStop(color: CodableColor(hex: "#0a0a0f"), location: 0),
                    GradientStop(color: CodableColor(hex: "#7c3aed"), location: 0.3),
                    GradientStop(color: CodableColor(hex: "#ec4899"), location: 0.6),
                    GradientStop(color: CodableColor(hex: "#0f0518"), location: 1.0),
                ]
            case .moss:
                return [
                    GradientStop(color: CodableColor(hex: "#022c22"), location: 0),
                    GradientStop(color: CodableColor(hex: "#4ade80"), location: 0.4),
                    GradientStop(color: CodableColor(hex: "#22d3ee"), location: 0.7),
                    GradientStop(color: CodableColor(hex: "#0c1a0f"), location: 1.0),
                ]
            case .dusk:
                return [
                    GradientStop(color: CodableColor(hex: "#1e1338"), location: 0),
                    GradientStop(color: CodableColor(hex: "#f472b6"), location: 0.2),
                    GradientStop(color: CodableColor(hex: "#818cf8"), location: 0.5),
                    GradientStop(color: CodableColor(hex: "#0f172a"), location: 1.0),
                ]
            case .prism:
                return [
                    GradientStop(color: CodableColor(hex: "#151316"), location: 0),
                    GradientStop(color: CodableColor(hex: "#DE7880"), location: 0.3),
                    GradientStop(color: CodableColor(hex: "#F7D29C"), location: 0.52),
                    GradientStop(color: CodableColor(hex: "#28D3CE"), location: 0.78),
                    GradientStop(color: CodableColor(hex: "#175B8B"), location: 1.0),
                ]
            case .lagoon:
                return [
                    GradientStop(color: CodableColor(hex: "#101820"), location: 0),
                    GradientStop(color: CodableColor(hex: "#287A92"), location: 0.28),
                    GradientStop(color: CodableColor(hex: "#31D5C8"), location: 0.58),
                    GradientStop(color: CodableColor(hex: "#B6F0CE"), location: 0.78),
                    GradientStop(color: CodableColor(hex: "#19657A"), location: 1.0),
                ]
            case .ember:
                return [
                    GradientStop(color: CodableColor(hex: "#171216"), location: 0),
                    GradientStop(color: CodableColor(hex: "#8C394E"), location: 0.25),
                    GradientStop(color: CodableColor(hex: "#F17C70"), location: 0.52),
                    GradientStop(color: CodableColor(hex: "#FFD29A"), location: 0.76),
                    GradientStop(color: CodableColor(hex: "#67344E"), location: 1.0),
                ]
            case .midnight:
                return [
                    GradientStop(color: CodableColor(hex: "#111216"), location: 0),
                    GradientStop(color: CodableColor(hex: "#273050"), location: 0.28),
                    GradientStop(color: CodableColor(hex: "#436E9E"), location: 0.55),
                    GradientStop(color: CodableColor(hex: "#26BFC1"), location: 0.78),
                    GradientStop(color: CodableColor(hex: "#12384D"), location: 1.0),
                ]
            }
        }
    }

    struct GradientDef: Codable, Equatable {
        var startColor: CodableColor
        var endColor: CodableColor
        var angle: Double = 135
    }

    struct GradientStop: Codable, Equatable {
        var color: CodableColor
        var location: Double
    }
}

// MARK: - Codable Color

struct CodableColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)

        if hex.count == 8 {
            self.red = Double((rgb >> 24) & 0xFF) / 255.0
            self.green = Double((rgb >> 16) & 0xFF) / 255.0
            self.blue = Double((rgb >> 8) & 0xFF) / 255.0
            self.alpha = Double(rgb & 0xFF) / 255.0
        } else {
            self.red = Double((rgb >> 16) & 0xFF) / 255.0
            self.green = Double((rgb >> 8) & 0xFF) / 255.0
            self.blue = Double(rgb & 0xFF) / 255.0
            self.alpha = 1.0
        }
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    // Common colors
    static let black = CodableColor(red: 0, green: 0, blue: 0)
    static let white = CodableColor(red: 1, green: 1, blue: 1)
    static let gray = CodableColor(hex: "#1c1c1e")
    static let clear = CodableColor(red: 0, green: 0, blue: 0, alpha: 0)
}
