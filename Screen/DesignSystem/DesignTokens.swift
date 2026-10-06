import Foundation
import SwiftUI

/// Design system color tokens — macOS dark mode grays from mockup-tool
enum DesignColors {
    // MARK: - Background Colors

    static let windowBackground = Color(hex: "#1c1c1e")
    static let controlBackground = Color(hex: "#2c2c2e")
    static let inputBackground = Color(hex: "#3a3a3c")

    // MARK: - Border Colors

    static let separator = Color(hex: "#1a1a1c")
    static let inputBorder = Color(hex: "#48484a")

    // MARK: - Text Colors

    static let primaryLabel = Color(hex: "#e5e5ea")
    static let secondaryLabel = Color(hex: "#98989d")
    static let tertiaryLabel = Color(hex: "#636366")

    // MARK: - Track Colors

    static let cameraTrack = Color(hex: "#60a5fa")    // Blue
    static let cursorTrack = Color(hex: "#4ade80")     // Green
    static let keystrokeTrack = Color(hex: "#fb923c")  // Orange
    static let audioTrack = Color(hex: "#fbbf24")      // Yellow

    static func trackColor(for type: String) -> Color {
        switch type {
        case "transform": return cameraTrack
        case "cursor": return cursorTrack
        case "keystroke": return keystrokeTrack
        case "audio": return audioTrack
        default: return secondaryLabel
        }
    }

    // MARK: - Accent Colors

    static let accent = Color(hex: "#6C5CE7")
    static let success = Color(hex: "#22c55e")
    static let warning = Color(hex: "#f59e0b")
    static let error = Color(hex: "#ef4444")
    static let recording = Color(hex: "#ef4444")
}

// MARK: - Typography

enum Typography {
    static let displayLarge = Font.system(size: 32, weight: .bold, design: .default)
    static let display = Font.system(size: 24, weight: .bold, design: .default)
    static let heading = Font.system(size: 16, weight: .semibold, design: .default)
    static let body = Font.system(size: 14, weight: .regular, design: .default)
    static let caption = Font.system(size: 12, weight: .regular, design: .default)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let timelineLabel = Font.system(size: 11, weight: .medium, design: .default)
}

// MARK: - Spacing

enum Spacing {
    // Official settings layout: label to control, then feature to feature.
    static let labelToControl: CGFloat = 12
    static let featureGap: CGFloat = 20

    static let xs: CGFloat = 2
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let xxxl: CGFloat = 32
}

// MARK: - Corner Radius

enum CornerRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 6
    static let lg: CGFloat = 8
    static let xl: CGFloat = 10
    static let xxl: CGFloat = 12
}

// MARK: - Compact Actions

enum ControlMetrics {
    static let actionHeight: CGFloat = 24
    static let mediumActionHeight: CGFloat = 32
}

enum ActionButtonSize {
    case compact, medium

    var height: CGFloat { self == .medium ? ControlMetrics.mediumActionHeight : ControlMetrics.actionHeight }
    var fontSize: CGFloat { self == .medium ? 13 : 12 }
    var horizontalPadding: CGFloat { self == .medium ? 12 : 10 }
}

struct CompactActionButtonStyle: ButtonStyle {
    var prominent = false
    var size: ActionButtonSize = .compact
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size.fontSize, weight: .medium))
            .foregroundStyle(prominent ? Color.white : (configuration.role == .destructive ? DesignColors.error : DesignColors.primaryLabel))
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(prominent ? DesignColors.accent : DesignColors.inputBackground,
                        in: RoundedRectangle(cornerRadius: CornerRadius.md))
            .contentShape(RoundedRectangle(cornerRadius: CornerRadius.md))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

// MARK: - Window Chrome (from mockup-tool)

enum WindowChrome {
    static let titleBarHeight: CGFloat = 52
    static let tabBarHeight: CGFloat = 36
    static let trafficLightSize: CGFloat = 12
    static let trafficLightGap: CGFloat = 8
    static let cornerRadius: CGFloat = 12

    // Traffic light colors
    static let closeColor = Color(hex: "#ff5f57")
    static let minimizeColor = Color(hex: "#febc2e")
    static let maximizeColor = Color(hex: "#28c840")

    // Title bar gradient
    static let titleBarTop = Color(hex: "#3a3a3c")
    static let titleBarBottom = Color(hex: "#2c2c2e")

    // Shadow
    static let shadowRadius: CGFloat = 60
    static let shadowOpacity: Double = 0.35
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)

        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
