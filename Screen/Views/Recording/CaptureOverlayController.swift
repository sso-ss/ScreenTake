import AppKit
import ScreenCaptureKit

/// Manages overlay windows for visual feedback during capture target selection.
/// - Hover: dim overlay on the hovered screen/window
/// - Click: selects the target and shows a persistent red border
@MainActor
final class CaptureOverlayController {

    // MARK: - Callbacks

    var onScreenHovered: ((SCDisplay?) -> Void)?
    var onWindowHovered: ((SCWindow?) -> Void)?
    var onScreenClicked: ((SCDisplay) -> Void)?
    var onWindowClicked: ((SCWindow) -> Void)?
    var onDeselected: (() -> Void)?
    weak var ignoredWindow: NSWindow?

    // MARK: - Private

    private var hoverOverlayWindow: NSWindow?
    private var selectedBorderWindow: NSWindow?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var currentMode: CaptureMode = .entireScreen
    private var isActive = false
    private var isSelected: Bool = false
    private var selectedDisplayID: CGDirectDisplayID?
    private var selectedWindowID: CGWindowID?

    private var availableDisplays: [SCDisplay] = []
    private var availableWindows: [SCWindow] = []

    private var lastHoveredDisplayID: CGDirectDisplayID?
    private var lastHoveredWindowID: CGWindowID?
    private var hoveredDisplay: SCDisplay?
    private var hoveredWindow: SCWindow?

    // MARK: - Activate

    func activate(mode: CaptureMode, displays: [SCDisplay], windows: [SCWindow]) {
        isActive = true
        self.currentMode = mode
        self.availableDisplays = displays
        self.availableWindows = windows
        lastHoveredDisplayID = nil
        lastHoveredWindowID = nil
        isSelected = false
        selectedDisplayID = nil
        selectedWindowID = nil
        hoveredDisplay = nil
        hoveredWindow = nil

        removeOverlays()
        stopMouseTracking()
        startMouseTracking()
        startClickTracking()
        handleMouseMoved(at: NSEvent.mouseLocation)
    }

    func updateMode(_ mode: CaptureMode) {
        removeOverlays()
        lastHoveredDisplayID = nil
        lastHoveredWindowID = nil
        isSelected = false
        selectedDisplayID = nil
        selectedWindowID = nil
        hoveredDisplay = nil
        hoveredWindow = nil
        currentMode = mode
        startClickTracking()
        handleMouseMoved(at: NSEvent.mouseLocation)
    }

    func deactivate() {
        isActive = false
        stopMouseTracking()
        stopClickTracking()
        removeOverlays()
        lastHoveredDisplayID = nil
        lastHoveredWindowID = nil
        isSelected = false
    }

    // MARK: - Show Selected Border

    func showSelectedBorder(for target: CaptureTarget) {
        removeOverlays()
        isSelected = true

        switch target {
        case .display(let display):
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == display.displayID
            }) {
                showBorderWindow(frame: screen.frame)
            }
        case .window(let window):
            let screenHeight = NSScreen.main?.frame.height ?? 0
            let appKitY = screenHeight - window.frame.origin.y - window.frame.height
            let appKitFrame = CGRect(
                x: window.frame.origin.x,
                y: appKitY,
                width: window.frame.width,
                height: window.frame.height
            )
            showBorderWindow(frame: appKitFrame)
        }
    }

    // MARK: - Mouse Tracking

    private func startMouseTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleMouseMoved(at: location)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleMouseMoved(at: location)
            }
            return event
        }
    }

    private func stopMouseTracking() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    // MARK: - Click Tracking

    private func startClickTracking() {
        stopClickTracking()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleClick(at: location)
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleClick(at: location)
            }
            return event
        }
    }

    private func stopClickTracking() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    // MARK: - Event Handlers

    private func handleMouseMoved(at mouseLocation: NSPoint) {
        // Don't update hover if already selected
        guard isActive, !isSelected, ignoredWindow?.frame.contains(mouseLocation) != true else { return }

        switch currentMode {
        case .entireScreen:
            handleScreenHover(at: mouseLocation)
        case .window:
            handleWindowHover(at: mouseLocation)
        }
    }

    private func handleClick(at point: NSPoint) {
        guard isActive, ignoredWindow?.frame.contains(point) != true else { return }
        switch currentMode {
        case .entireScreen:
            guard let display = display(at: point) else { return }
            // Toggle: clicking the same display deselects
            if isSelected, selectedDisplayID == display.displayID {
                deselectCurrent()
                return
            }
            isSelected = true
            selectedDisplayID = display.displayID
            hoverOverlayWindow?.orderOut(nil)
            hoverOverlayWindow = nil
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == display.displayID
            }) {
                showBorderWindow(frame: screen.frame)
            }
            onScreenClicked?(display)
        case .window:
            handleWindowHover(at: point)
            guard let window = hoveredWindow else { return }
            // Toggle: clicking the same window deselects
            if isSelected, selectedWindowID == window.windowID {
                deselectCurrent()
                return
            }
            isSelected = true
            selectedWindowID = window.windowID
            hoverOverlayWindow?.orderOut(nil)
            hoverOverlayWindow = nil
            let screenHeight = NSScreen.main?.frame.height ?? 0
            let appKitY = screenHeight - window.frame.origin.y - window.frame.height
            let appKitFrame = CGRect(
                x: window.frame.origin.x,
                y: appKitY,
                width: window.frame.width,
                height: window.frame.height
            )
            showBorderWindow(frame: appKitFrame)
            onWindowClicked?(window)
        }
    }

    private func deselectCurrent() {
        isSelected = false
        selectedDisplayID = nil
        selectedWindowID = nil
        selectedBorderWindow?.orderOut(nil)
        selectedBorderWindow = nil
        lastHoveredDisplayID = nil
        lastHoveredWindowID = nil
        onDeselected?()
    }

    private func handleScreenHover(at point: NSPoint) {
        let hoveredDisplayID = display(at: point)?.displayID

        guard hoveredDisplayID != lastHoveredDisplayID else { return }
        lastHoveredDisplayID = hoveredDisplayID

        // Remove previous hover overlay
        hoverOverlayWindow?.orderOut(nil)
        hoverOverlayWindow = nil

        hoveredDisplay = availableDisplays.first { $0.displayID == hoveredDisplayID }

        // Show dim on hovered screen
        if let displayID = hoveredDisplayID,
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID
           }) {
            let dim = createOverlayWindow(frame: screen.frame)
            dim.contentView = NSHostingViewCompat.makeBlackOverlay(opacity: 0.3)
            dim.orderFrontRegardless()
            hoverOverlayWindow = dim
        }

        onScreenHovered?(hoveredDisplay)
    }

    private func handleWindowHover(at point: NSPoint) {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: point.x, y: screenHeight - point.y)

        let orderedWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let orderedIDs = orderedWindows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let eligible = availableWindows.filter(CaptureTarget.isSelectableWindow)
        let foundID = Self.windowID(at: cgPoint, windows: eligible.map { ($0.windowID, $0.frame) }, orderedIDs: orderedIDs)
        let found = eligible.first { $0.windowID == foundID }

        let hoveredID = found?.windowID
        guard hoveredID != lastHoveredWindowID else { return }
        lastHoveredWindowID = hoveredID

        // Remove previous hover overlay
        hoverOverlayWindow?.orderOut(nil)
        hoverOverlayWindow = nil

        hoveredWindow = found

        if let window = found {
            let appKitY = screenHeight - window.frame.origin.y - window.frame.height
            let appKitFrame = CGRect(
                x: window.frame.origin.x,
                y: appKitY,
                width: window.frame.width,
                height: window.frame.height
            )

            let dim = createOverlayWindow(frame: appKitFrame)
            dim.contentView = NSHostingViewCompat.makeBlackOverlay(opacity: 0.3)
            dim.orderFrontRegardless()
            hoverOverlayWindow = dim
        }

        onWindowHovered?(found)
    }

    // MARK: - Border Window

    private func showBorderWindow(frame: CGRect) {
        selectedBorderWindow?.orderOut(nil)
        selectedBorderWindow = nil

        let border = createOverlayWindow(frame: frame)
        let borderView = BorderOverlayView(frame: border.contentView!.bounds)
        border.contentView = borderView
        border.orderFrontRegardless()
        selectedBorderWindow = border
    }

    // MARK: - Helpers

    static func windowID(at point: CGPoint, windows: [(id: CGWindowID, frame: CGRect)], orderedIDs: [CGWindowID]) -> CGWindowID? {
        let frames = Dictionary(windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        return orderedIDs.first { frames[$0]?.contains(point) == true }
    }

    static func displayID(at point: NSPoint, screens: [(id: CGDirectDisplayID, frame: CGRect)], availableIDs: Set<CGDirectDisplayID>) -> CGDirectDisplayID? {
        screens.first { availableIDs.contains($0.id) && $0.frame.contains(point) }?.id
    }

    private func display(at point: NSPoint) -> SCDisplay? {
        let screens = NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, frame: CGRect)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return (id, screen.frame)
        }
        let id = Self.displayID(at: point, screens: screens, availableIDs: Set(availableDisplays.map(\.displayID)))
        return availableDisplays.first { $0.displayID == id }
    }

    private func createOverlayWindow(frame: CGRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return window
    }

    private func removeOverlays() {
        hoverOverlayWindow?.orderOut(nil)
        hoverOverlayWindow = nil

        selectedBorderWindow?.orderOut(nil)
        selectedBorderWindow = nil
    }
}

// MARK: - Border Overlay NSView (red border)

private class BorderOverlayView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.red.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 4
        path.stroke()
    }
}

// MARK: - Helper to create black overlay NSView

enum NSHostingViewCompat {
    static func makeBlackOverlay(opacity: CGFloat) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(opacity).cgColor
        return view
    }
}
