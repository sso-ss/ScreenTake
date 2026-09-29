import AppKit
import SwiftUI

/// Floating panel for the capture/recording lifecycle.
/// Uses a plain NSWindow (not NSPanel) to guarantee SwiftUI button clicks work.
final class CaptureToolbarPanel: NSWindow {

    private var hostingView: NSHostingView<CaptureToolbarView>?
    private var escapeMonitor: Any?
    private weak var coordinator: CaptureToolbarCoordinator?

    init(coordinator: CaptureToolbarCoordinator) {
        self.coordinator = coordinator
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configureWindow()
        setupContent(coordinator: coordinator)
        positionOnScreen()
        installEscapeMonitor(coordinator: coordinator)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func configureWindow() {
        self.level = .floating
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
    }

    private func setupContent(coordinator: CaptureToolbarCoordinator) {
        let view = CaptureToolbarView(coordinator: coordinator)
        let hosting = NSHostingView(rootView: view)
        // Let SwiftUI size itself
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.contentView = hosting
    }

    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = self.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.maxY - panelSize.height - 40
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installEscapeMonitor(coordinator: CaptureToolbarCoordinator) {
        // Use global monitor so it works even when another app is focused
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in
                    coordinator?.dismiss()
                }
            }
        }
    }

    func show() {
        self.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    override func close() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        self.orderOut(nil)
        super.close()
    }
}
