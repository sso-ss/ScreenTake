import AppKit
import QuartzCore

/// Overlay that shows the capture area boundary during recording.
///
/// - **Border mode**: Purple border around the full capture area (always visible while recording).
/// - **Zoom mode**: Border shrinks to the zoom viewport, dark overlay dims outside, follows cursor.
///
/// The app excludes itself from screen capture, so this overlay won't appear in recordings.
@MainActor
final class ZoomIndicatorOverlay {

    private var overlayWindow: NSWindow?
    private var regionView: ZoomRegionView?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let zoomLevel: CGFloat = 2.0

    private var captureBounds: CGRect = .zero
    private var screenFrame: CGRect = .zero
    private var isZoomed = false
    private var lastTrackingUpdate: CFAbsoluteTime = 0
    private let trackingInterval: CFAbsoluteTime = 1.0 / 30.0  // throttle to 30fps

    // Dead zone panning state — viewport center moves independently of cursor
    private var viewportCenterX: CGFloat = 0
    private var viewportCenterY: CGFloat = 0

    // MARK: - Public

    /// Show the purple border around the full capture area. No dimming, no cursor tracking.
    func showBorder(captureBounds: CGRect) {
        self.isZoomed = false
        self.captureBounds = captureBounds
        ensureWindow()
        let localCapture = captureRectInViewCoords()
        regionView?.animateTo(region: localCapture, dimmed: false)
    }

    /// Shrink the border to the zoom viewport, add dimming, and follow cursor.
    func enterZoom() {
        isZoomed = true
        // Initialize viewport center to current cursor position
        let cursor = NSEvent.mouseLocation
        viewportCenterX = cursor.x
        viewportCenterY = cursor.y
        updateZoomRegion(animated: true)
        startTracking()
    }

    /// Expand the border back to the full capture area and stop cursor tracking.
    func exitZoom() {
        isZoomed = false
        viewportCenterX = 0
        viewportCenterY = 0
        stopTracking()
        let localCapture = captureRectInViewCoords()
        regionView?.animateTo(region: localCapture, dimmed: false)
    }

    /// Remove the overlay entirely.
    func deactivate() {
        isZoomed = false
        stopTracking()
        guard let window = overlayWindow else { return }
        overlayWindow = nil
        regionView = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }

    // MARK: - Window Setup

    private func ensureWindow() {
        guard let screen = NSScreen.main else { return }
        screenFrame = screen.frame

        if overlayWindow != nil {
            // Already showing — just update
            return
        }

        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(NSWindow.Level.floating.rawValue - 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = ZoomRegionView(frame: NSRect(origin: .zero, size: screenFrame.size))
        window.contentView = view
        self.regionView = view

        // Start with the full capture border, no dim
        let localCapture = captureRectInViewCoords()
        view.setRegion(localCapture, dimmed: false)

        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 1.0
        }
        self.overlayWindow = window
    }

    // MARK: - Coordinate Helpers

    private func captureRectInViewCoords() -> NSRect {
        NSRect(
            x: captureBounds.minX - screenFrame.minX,
            y: captureBounds.minY - screenFrame.minY,
            width: captureBounds.width,
            height: captureBounds.height
        )
    }

    // MARK: - Cursor Tracking (zoom mode only)

    private func startTracking() {
        stopTracking()
        lastTrackingUpdate = 0
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastTrackingUpdate >= self.trackingInterval else { return }
            self.lastTrackingUpdate = now
            Task { @MainActor [weak self] in
                self?.updateZoomRegion(animated: false)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] event in
            guard let self else { return event }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastTrackingUpdate >= self.trackingInterval else { return event }
            self.lastTrackingUpdate = now
            Task { @MainActor [weak self] in
                self?.updateZoomRegion(animated: false)
            }
            return event
        }
    }

    private func stopTracking() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func updateZoomRegion(animated: Bool) {
        guard isZoomed else { return }
        let cursor = NSEvent.mouseLocation

        let regionW = captureBounds.width / zoomLevel
        let regionH = captureBounds.height / zoomLevel

        // Dead zone: camera only pans when cursor is in the outer 20% of the viewport.
        // Center 60% = dead zone (no panning).
        let deadZoneW = regionW * 0.6
        let deadZoneH = regionH * 0.6

        // Initialize viewport center on first call
        if viewportCenterX == 0 && viewportCenterY == 0 {
            viewportCenterX = cursor.x
            viewportCenterY = cursor.y
        }

        // Distance from cursor to viewport center
        let dx = cursor.x - viewportCenterX
        let dy = cursor.y - viewportCenterY

        // Only pan if cursor exceeds dead zone
        let excessX = max(0, abs(dx) - deadZoneW / 2)
        let excessY = max(0, abs(dy) - deadZoneH / 2)

        if excessX > 0 {
            viewportCenterX += (dx > 0 ? 1 : -1) * excessX
        }
        if excessY > 0 {
            viewportCenterY += (dy > 0 ? 1 : -1) * excessY
        }

        // Clamp so viewport stays within capture bounds
        let regionX = max(captureBounds.minX, min(viewportCenterX - regionW / 2, captureBounds.maxX - regionW))
        let regionY = max(captureBounds.minY, min(viewportCenterY - regionH / 2, captureBounds.maxY - regionH))

        let localRegion = NSRect(
            x: regionX - screenFrame.minX,
            y: regionY - screenFrame.minY,
            width: regionW,
            height: regionH
        )

        if animated {
            regionView?.animateTo(region: localRegion, dimmed: true)
        } else {
            regionView?.setRegion(localRegion, dimmed: true)
        }
    }
}

// MARK: - Zoom Region View

private class ZoomRegionView: NSView {
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let borderColor = NSColor(
        calibratedRed: 0.345, green: 0.337, blue: 0.839, alpha: 0.8
    ).cgColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.0).cgColor
        dimLayer.fillRule = .evenOdd
        layer?.addSublayer(dimLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = borderColor
        borderLayer.lineWidth = 2.5
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Instant update (used during cursor tracking).
    func setRegion(_ rect: NSRect, dimmed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Kill any running explicit animations (from animateTo) before
        // setting model values. Overlapping CABasicAnimations + direct
        // CATransaction commits on full-screen CAShapeLayers saturates
        // the WindowServer compositor and permanently stalls
        // AVCaptureVideoPreviewLayer's IOSurface rendering pipeline.
        borderLayer.removeAllAnimations()
        dimLayer.removeAllAnimations()
        applyPaths(rect: rect, dimmed: dimmed)
        CATransaction.commit()
    }

    /// Animated transition (used when toggling zoom on/off).
    func animateTo(region rect: NSRect, dimmed: Bool) {
        let duration: CFTimeInterval = 0.3

        // Animate border path
        let newBorderPath = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        let borderAnim = CABasicAnimation(keyPath: "path")
        borderAnim.fromValue = borderLayer.path
        borderAnim.toValue = newBorderPath
        borderAnim.duration = duration
        borderAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        borderLayer.add(borderAnim, forKey: "path")
        borderLayer.path = newBorderPath

        // Animate dim layer path
        let newDimPath = CGMutablePath()
        newDimPath.addRect(bounds)
        newDimPath.addRoundedRect(in: rect, cornerWidth: 8, cornerHeight: 8)
        let dimPathAnim = CABasicAnimation(keyPath: "path")
        dimPathAnim.fromValue = dimLayer.path
        dimPathAnim.toValue = newDimPath
        dimPathAnim.duration = duration
        dimPathAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dimLayer.add(dimPathAnim, forKey: "path")
        dimLayer.path = newDimPath

        // Animate dim opacity
        let targetAlpha: CGFloat = dimmed ? 0.3 : 0.0
        let dimColorAnim = CABasicAnimation(keyPath: "fillColor")
        dimColorAnim.fromValue = dimLayer.fillColor
        dimColorAnim.toValue = NSColor.black.withAlphaComponent(targetAlpha).cgColor
        dimColorAnim.duration = duration
        dimColorAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dimLayer.add(dimColorAnim, forKey: "fillColor")
        dimLayer.fillColor = NSColor.black.withAlphaComponent(targetAlpha).cgColor
    }

    private func applyPaths(rect: NSRect, dimmed: Bool) {
        let outer = CGMutablePath()
        outer.addRect(bounds)
        outer.addRoundedRect(in: rect, cornerWidth: 8, cornerHeight: 8)
        dimLayer.path = outer
        dimLayer.fillColor = NSColor.black.withAlphaComponent(dimmed ? 0.3 : 0.0).cgColor

        borderLayer.path = CGPath(
            roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil
        )
    }
}
