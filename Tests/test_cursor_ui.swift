import AppKit
import SwiftUI

@main
struct CursorUIPreview {
    @MainActor
    static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let appState = AppState.shared
        let originalShape = appState.capture.cursorShape
        let originalVisibility = appState.capture.showCursor
        let originalScale = appState.capture.cursorScale
        let originalHighlightClicks = appState.capture.highlightClicks
        let originalHighlightColor = appState.capture.clickHighlightColor
        defer {
            appState.capture.cursorShape = originalShape
            appState.capture.showCursor = originalVisibility
            appState.capture.cursorScale = originalScale
            appState.capture.highlightClicks = originalHighlightClicks
            appState.capture.clickHighlightColor = originalHighlightColor
        }
        appState.capture.showCursor = true
        appState.capture.highlightClicks = true
        appState.capture.clickHighlightColor = .coral
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SettingsView().environmentObject(appState))
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        for shape in CursorShape.allCases {
            appState.capture.cursorShape = shape
            appState.capture.cursorScale = shape == .circle ? 3 : 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-cursor-\(shape.rawValue).png"))
            print("PASS: rendered \(shape.displayName) sidebar and preview")
        }
        window.setContentSize(NSSize(width: 800, height: 500))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func scrollControls(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.bounds.width <= 310,
               let document = scroll.documentView {
                document.scroll(CGPoint(x: 0, y: 300))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            for child in view.subviews { scrollControls(child) }
        }
        scrollControls(host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-cursor-minimum.png"))
        window.orderOut(nil)
        print("PASS: rendered minimum 800x500 window")
    }
}