import AppKit
import AVFoundation
import QuartzCore
import CoreImage

/// Floating circular webcam preview overlay shown during recording.
///
/// Renders frames on a **background queue** using a `DispatchSourceTimer`,
/// then flips the resulting CGImage onto the layer on the main thread.
/// This keeps the preview alive even when the main RunLoop / WindowServer
/// compositor is saturated by zoom‑overlay animations.
@MainActor
final class WebcamPiPOverlay {

    private var overlayWindow: NSWindow?
    private var frameLayer: CALayer?
    private weak var webcamRecorder: WebcamRecorder?
    private var beautyRenderer: CameraBeautyPreviewRenderer?

    // MARK: - Show / Hide

    /// Show the live PiP overlay.
    func show(
        webcamRecorder: WebcamRecorder,
        position: PiPPosition,
        pipSize: PiPSize,
        shape: PiPShape,
        screenBounds: CGRect,
        beautyAmount: Double = 0, makeup: FaceMakeupSettings = .init()
    ) {
        hide()
        self.webcamRecorder = webcamRecorder

        let diameter = pipSize.fraction * screenBounds.height
        let padding: CGFloat = 20
        let origin = cornerOrigin(
            position: position,
            diameter: diameter,
            padding: padding,
            screenBounds: screenBounds
        )

        let frame = NSRect(x: origin.x, y: origin.y, width: diameter, height: diameter)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let containerView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = shape == .circle ? diameter / 2 : diameter * 0.18
        containerView.layer?.masksToBounds = true
        containerView.layer?.borderColor = NSColor.white.cgColor
        containerView.layer?.borderWidth = 3

        // Shadow on the backing view
        let backingView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        backingView.wantsLayer = true
        backingView.layer?.cornerRadius = containerView.layer?.cornerRadius ?? 0
        backingView.layer?.shadowColor = NSColor.black.cgColor
        backingView.layer?.shadowOpacity = 0.4
        backingView.layer?.shadowRadius = 8
        backingView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        backingView.addSubview(containerView)

        // Create a plain CALayer for manual frame rendering.
        // Expand it to 4:3 aspect so the square circle crops width, not squeezes.
        let aspectRatio: CGFloat = 4.0 / 3.0
        let layerW = diameter * aspectRatio
        let layerX = (diameter - layerW) / 2
        let fLayer = CALayer()
        fLayer.frame = CGRect(x: layerX, y: 0, width: layerW, height: diameter)
        fLayer.contentsGravity = .resizeAspectFill
        fLayer.isGeometryFlipped = true  // CVPixelBuffer is top-down
        containerView.layer?.addSublayer(fLayer)
        self.frameLayer = fLayer

        window.contentView = backingView

        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            window.animator().alphaValue = 1.0
        }
        self.overlayWindow = window

        // Start a 30fps background render timer
        let renderer = CameraBeautyPreviewRenderer(layer: fLayer)
        renderer.setDisplayPixelSize(CGSize(width: fLayer.bounds.width * window.backingScaleFactor,
                                           height: fLayer.bounds.height * window.backingScaleFactor))
        renderer.configure(recorder: webcamRecorder, amount: beautyAmount, makeup: makeup)
        beautyRenderer = renderer
    }

    /// Fade out and remove the overlay.
    func hide() {
        beautyRenderer?.stop()
        beautyRenderer = nil
        guard let window = overlayWindow else { return }
        overlayWindow = nil
        frameLayer = nil
        webcamRecorder = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }

    /// Update position on-the-fly (e.g. user changed the PiP corner while recording).
    func updatePosition(_ position: PiPPosition, pipSize: PiPSize, screenBounds: CGRect) {
        guard let window = overlayWindow else { return }
        let diameter = pipSize.fraction * screenBounds.height
        let padding: CGFloat = 20
        let origin = cornerOrigin(
            position: position,
            diameter: diameter,
            padding: padding,
            screenBounds: screenBounds
        )
        window.setFrame(NSRect(x: origin.x, y: origin.y, width: diameter, height: diameter), display: true)
    }

    // MARK: - Helpers

    private func cornerOrigin(
        position: PiPPosition,
        diameter: CGFloat,
        padding: CGFloat,
        screenBounds: CGRect
    ) -> CGPoint {
        return CGPoint(
            x: screenBounds.minX + padding
                + (screenBounds.width - diameter - 2 * padding) * position.horizontalFraction,
            y: screenBounds.minY + padding
                + (screenBounds.height - diameter - 2 * padding) * (1 - position.verticalFraction)
        )
    }
}
