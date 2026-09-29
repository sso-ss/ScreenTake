import AppKit
import SwiftUI

/// Displays a 3-2-1 countdown before recording starts
final class CountdownPanel: NSPanel {

    private var countdownValue = 3
    private var timer: Timer?
    private var onComplete: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func start(completion: @escaping () -> Void) {
        self.onComplete = completion
        self.countdownValue = 3

        positionCenter()
        updateContent()
        self.orderFrontRegardless()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.countdownValue -= 1
            if self.countdownValue <= 0 {
                self.timer?.invalidate()
                self.timer = nil
                self.close()
                self.onComplete?()
            } else {
                self.updateContent()
            }
        }
    }

    private func positionCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let x = screenFrame.midX - 60
        let y = screenFrame.midY - 60
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func updateContent() {
        let view = CountdownView(value: countdownValue)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 120, height: 120)
        self.contentView = hosting
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }
}

// MARK: - Countdown View

struct CountdownView: View {
    let value: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 100, height: 100)

            Circle()
                .stroke(DesignColors.accent, lineWidth: 3)
                .frame(width: 100, height: 100)

            Text("\(value)")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: 120, height: 120)
    }
}
