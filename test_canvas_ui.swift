import AppKit
import SwiftUI

@main
struct CanvasUIPreview {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let appState = AppState.shared
        let originalRatio = appState.capture.canvasRatio
        let originalLayout = appState.capture.deviceLayout
        let originalCornerRadius = appState.capture.desktopCornerRadius
        let originalWallpaper = appState.capture.selectedWallpaper
        let originalWebcamEnabled = appState.capture.isWebcamEnabled
        let originalWebcamShape = appState.capture.webcamPiPShape
        let originalWebcamPosition = appState.capture.webcamPiPPosition
        defer {
            appState.capture.canvasRatio = originalRatio
            appState.capture.deviceLayout = originalLayout
            appState.capture.desktopCornerRadius = originalCornerRadius
            appState.capture.selectedWallpaper = originalWallpaper
            appState.capture.isWebcamEnabled = originalWebcamEnabled
            appState.capture.webcamPiPShape = originalWebcamShape
            appState.capture.webcamPiPPosition = originalWebcamPosition
        }
        appState.capture.selectedWallpaper = .lagoon
        appState.capture.webcamPiPShape = .circle
        appState.capture.webcamPiPPosition = .bottomRight
        precondition(DeviceLayout.allCases == [.desktop, .iPhone])
        for layout in DeviceLayout.allCases {
            precondition(NSImage(systemSymbolName: layout.symbol, accessibilityDescription: nil) != nil)
        }
        for hiddenLayout in [DeviceLayout.duo, .iPhoneDuoClosed, .iPhoneDuoUnfolded] {
            appState.capture.deviceLayout = hiddenLayout
            precondition(appState.capture.deviceLayout == .desktop)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SettingsView().environmentObject(appState))
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        let cases: [(String, CanvasRatio, DeviceLayout, CGSize)] = [
            ("desktop", .portrait, .desktop, CGSize(width: 1000, height: 850)),
            ("iphone", .vertical, .iPhone, CGSize(width: 1000, height: 850)),
            ("desktop-wide", .landscape, .desktop, CGSize(width: 1000, height: 850)),
            ("iphone-portrait", .portrait, .iPhone, CGSize(width: 1000, height: 850)),
            ("minimum", .portrait, .desktop, CGSize(width: 800, height: 500)),
            ("iphone-minimum", .vertical, .iPhone, CGSize(width: 800, height: 500)),
            ("hidden-duo-closed-fallback", .portrait, .iPhoneDuoClosed, CGSize(width: 1000, height: 850)),
            ("hidden-duo-unfolded-fallback", .landscape, .iPhoneDuoUnfolded, CGSize(width: 1000, height: 850)),
            ("hidden-duo-minimum-fallback", .landscape, .iPhoneDuoUnfolded, CGSize(width: 800, height: 500))
        ]
        for (name, ratio, layout, size) in cases {
            appState.capture.canvasRatio = ratio
            appState.capture.deviceLayout = layout
            window.setContentSize(size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            precondition(host.bounds.size == size)
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-canvas-\(name).png"))
            print("PASS: rendered \(name) at \(size)")
        }
        appState.capture.canvasRatio = .portrait
        appState.capture.deviceLayout = .desktop
        for (name, radius) in [("square", 0.0), ("rounded", 0.1)] {
            appState.capture.desktopCornerRadius = radius
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-canvas-corners-\(name).png"))
            print("PASS: rendered \(name) canvas corners")
        }
        appState.capture.desktopCornerRadius = originalCornerRadius
        appState.capture.canvasRatio = .landscape
        appState.capture.deviceLayout = .iPhoneDuoUnfolded
        window.setContentSize(NSSize(width: 1000, height: 850))
        appState.capture.isWebcamEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var previousImage: Data?
        var circleCornerBlue: CGFloat = 0
        for (name, top) in [("Canvas", 92.0), ("Cursor", 150.0), ("Camera", 201.0), ("Audio", 259.0), ("Output", 317.0)] {
            let point = NSPoint(x: 965, y: 850 - top)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if name == "Camera" {
                circleCornerBlue = bitmap.colorAt(x: 526, y: 525)!.usingColorSpace(.sRGB)!.blueComponent
            }
            let image = bitmap.representation(using: .png, properties: [:])!
            try image.write(to: URL(fileURLWithPath: "/tmp/Screen-tab-\(name.lowercased()).png"))
            precondition(image != previousImage, "Selecting \(name) did not update the settings panel")
            previousImage = image
            print("PASS: selected \(name) tab")
        }
        for point in [NSPoint(x: 965, y: 850 - 201), NSPoint(x: 849, y: 850 - 204)] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        precondition(appState.capture.webcamPiPShape == .roundedSquare, "Selecting the rounded-square camera button should update the shape")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let roundedBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: roundedBitmap)
        let squareCornerBlue = roundedBitmap.colorAt(x: 526, y: 525)!.usingColorSpace(.sRGB)!.blueComponent
        try roundedBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-tab-camera-rounded-square.png"))
        precondition(squareCornerBlue > circleCornerBlue + 0.15, "Rounded-square camera button should update the mock preview")
        print("PASS: rounded-square camera button updates the preview")
        let centerPoint = NSPoint(x: 782, y: 850 - 312)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: centerPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(appState.capture.webcamPiPPosition == .center, "Center camera position should be selectable")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let centeredBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: centeredBitmap)
        let oldCenterBlue = roundedBitmap.colorAt(x: 300, y: 420)!.usingColorSpace(.sRGB)!.blueComponent
        let newCenterBlue = centeredBitmap.colorAt(x: 300, y: 420)!.usingColorSpace(.sRGB)!.blueComponent
        precondition(newCenterBlue > oldCenterBlue + 0.15, "Center position should move the mock camera")
        try centeredBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/Screen-tab-camera-center.png"))
        print("PASS: center camera position updates the preview")
        window.orderOut(nil)
    }
}