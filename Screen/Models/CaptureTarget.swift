import Foundation
import ScreenCaptureKit
import CoreGraphics

enum CaptureTarget: Identifiable, Hashable {
    case display(SCDisplay)
    case window(SCWindow)

    static func isSelectableWindow(_ window: SCWindow) -> Bool {
        guard window.isOnScreen, window.windowLayer == 0,
              window.frame.width > 50, window.frame.height > 50,
              let owner = window.owningApplication,
              owner.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        return ![
            "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
            "com.apple.notificationcenterui", "com.apple.screencaptureui"
        ].contains(owner.bundleIdentifier)
    }

    var id: String {
        switch self {
        case .display(let display):
            return "display-\(display.displayID)"
        case .window(let window):
            return "window-\(window.windowID)"
        }
    }

    var displayName: String {
        switch self {
        case .display(let display):
            return "Display \(display.displayID)"
        case .window(let window):
            return window.title ?? window.owningApplication?.applicationName ?? "Unknown Window"
        }
    }

    var frame: CGRect {
        switch self {
        case .display(let display):
            return CGRect(x: 0, y: 0, width: display.width, height: display.height)
        case .window(let window):
            return window.frame
        }
    }

    var width: Int { Int(frame.width) }
    var height: Int { Int(frame.height) }

    /// Whether the capture target is a window (adds background in export)
    var isWindow: Bool {
        if case .window = self { return true }
        return false
    }

    /// Whether the capture target is full-screen
    var isFullScreen: Bool {
        if case .display = self { return true }
        return false
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}
