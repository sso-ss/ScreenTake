import AppKit
import Foundation
import SwiftUI

enum AppBrand {
    /// Outline of the three-panel mark, kept as a template for menu bar contrast.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let transform = AffineTransform(translationByX: -0.52, byY: 20.52)
            var scaled = transform
            scaled.scale(x: 0.18, y: -0.18)
            let border = NSBezierPath(roundedRect: NSRect(x: 8, y: 25, width: 112, height: 78), xRadius: 18, yRadius: 18)
            let panels = NSBezierPath()
            panels.move(to: NSPoint(x: 22.11, y: 25))
            panels.line(to: NSPoint(x: 55, y: 46.2))
            panels.move(to: NSPoint(x: 50, y: 81))
            panels.line(to: NSPoint(x: 50, y: 103))
            panels.move(to: NSPoint(x: 120, y: 41.9))
            panels.line(to: NSPoint(x: 79.2, y: 68.2))
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 50, y: 49))
            play.curve(to: NSPoint(x: 55, y: 46.2), controlPoint1: NSPoint(x: 50, y: 46.2), controlPoint2: NSPoint(x: 52.6, y: 44.7))
            play.line(to: NSPoint(x: 79.2, y: 61.8))
            play.curve(to: NSPoint(x: 79.2, y: 68.2), controlPoint1: NSPoint(x: 81.6, y: 63.3), controlPoint2: NSPoint(x: 81.6, y: 66.7))
            play.line(to: NSPoint(x: 55, y: 83.8))
            play.curve(to: NSPoint(x: 50, y: 81), controlPoint1: NSPoint(x: 52.6, y: 85.3), controlPoint2: NSPoint(x: 50, y: 83.8))
            play.close()
            for path in [border, panels, play] {
                path.transform(using: scaled)
                path.lineWidth = 1.2
                path.lineJoinStyle = .round
                path.lineCapStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Bypass Launch Services' cached icon, which can belong to an older installation.
    static var icon: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// An app preference, independent of recording and export settings.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "appAppearance"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil // Inherit macOS, including changes while the app is open.
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() {
        NSApplication.shared.appearance = nativeAppearance
    }
}

/// Adaptive interface colors. Media and exported canvas colors remain independent.
enum DesignColors {
    static func adaptive(light: String, dark: String) -> Color {
        let lightColor = NSColor(Color(hex: light))
        let darkColor = NSColor(Color(hex: dark))
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    static let previewBackground = adaptive(light: "#e9e9ed", dark: "#141415")

    // MARK: - Background Colors

    static let windowBackground = adaptive(light: "#f5f5f7", dark: "#1c1c1e")
    static let controlBackground = adaptive(light: "#ffffff", dark: "#2c2c2e")
    static let inputBackground = adaptive(light: "#eaeaef", dark: "#3a3a3c")

    // MARK: - Border Colors

    static let separator = adaptive(light: "#dcdce2", dark: "#1a1a1c")
    static let inputBorder = adaptive(light: "#c5c5ce", dark: "#48484a")

    // MARK: - Text Colors

    static let primaryLabel = adaptive(light: "#242428", dark: "#e5e5ea")
    static let secondaryLabel = adaptive(light: "#61616a", dark: "#98989d")
    static let tertiaryLabel = adaptive(light: "#70707a", dark: "#8e8e93")

    // MARK: - Track Colors

    static let cameraTrack = adaptive(light: "#2563c9", dark: "#60a5fa")    // Blue
    static let cursorTrack = adaptive(light: "#16803c", dark: "#4ade80")     // Green
    static let keystrokeTrack = adaptive(light: "#b45309", dark: "#fb923c")  // Orange
    static let audioTrack = adaptive(light: "#946200", dark: "#fbbf24")      // Yellow

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
    static let titleBarTop = DesignColors.inputBackground
    static let titleBarBottom = DesignColors.controlBackground

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
