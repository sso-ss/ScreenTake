import AppKit
import SwiftUI

@main
struct ToolbarAppearanceTest {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let coordinator = CaptureToolbarCoordinator(appState: AppState.shared)
        let cases: [(String, ColorScheme, Bool, Bool)] = [
            ("light", .light, false, false),
            ("dark", .dark, false, false),
            ("contrast", .light, true, false),
            ("recording", .dark, false, true),
            ("status", .light, false, false)
        ]
        for (name, scheme, highContrast, recording) in cases {
            coordinator.toolbarPhase = recording ? .recording : .selecting
            coordinator.isWebcamAvailable = recording
            coordinator.statusMessage = name == "status" ? "Screen recording permission is required. Enable it in System Settings, then try again." : ""
            let view = CaptureToolbarView(coordinator: coordinator)
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.appearance = NSAppearance(named: highContrast ? .accessibilityHighContrastAqua : scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.center()
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            precondition(host.bounds.height >= 144, "Missing shadow padding")
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var maximumEdgeAlpha: CGFloat = 0
            for column in 0..<bitmap.pixelsWide {
                for row in [0, bitmap.pixelsHigh - 1] {
                    maximumEdgeAlpha = max(maximumEdgeAlpha, bitmap.colorAt(x: column, y: row)!.alphaComponent)
                }
            }
            for row in 0..<bitmap.pixelsHigh {
                for column in [0, bitmap.pixelsWide - 1] {
                    maximumEdgeAlpha = max(maximumEdgeAlpha, bitmap.colorAt(x: column, y: row)!.alphaComponent)
                }
            }
            precondition(maximumEdgeAlpha < 0.02, "Shadow clipped at window boundary: \(maximumEdgeAlpha)")
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-toolbar-\(name).png"))
            print("PASS: \(name), window=\(host.bounds.size), edge alpha=\(maximumEdgeAlpha)")
            window.orderOut(nil)
        }
        print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }
}