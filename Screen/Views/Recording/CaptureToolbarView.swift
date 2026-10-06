import SwiftUI
import ScreenCaptureKit

/// SwiftUI content for the floating capture toolbar — styled like the native macOS screenshot toolbar.
struct CaptureToolbarView: View {

    @ObservedObject var coordinator: CaptureToolbarCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var systemAccent: Color { Color(nsColor: .controlAccentColor) }

    var body: some View {
        VStack(spacing: 8) {
            // Status / mode label above the toolbar
            if coordinator.toolbarPhase == .selecting {
                if !coordinator.statusMessage.isEmpty {
                    statusBanner
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    modeLabel
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            // Main toolbar pill
            switch coordinator.toolbarPhase {
            case .selecting:
                selectingToolbar
                    .disabled(coordinator.isStarting)
            case .recording:
                recordingToolbar
            }
        }
        .padding(48)
        .fixedSize()
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: coordinator.toolbarPhase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: coordinator.captureMode)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: coordinator.statusMessage)
    }

    // MARK: - Status / Relaunch Banners

    private var statusBanner: some View {
        Text(coordinator.statusMessage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .modifier(CaptureToolbarSurface(isToolbar: false))
    }

    // MARK: - Mode Label

    private var modeLabel: some View {
        Text(modeLabelText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .modifier(CaptureToolbarSurface(isToolbar: false))
    }

    private var modeLabelText: String {
        switch coordinator.captureMode {
        case .entireScreen:
            if let display = coordinator.selectedDisplay {
                return "Record Display \(display.displayID)"
            }
            return "Record Entire Screen"
        case .window:
            if let window = coordinator.selectedWindow {
                let name = window.title ?? window.owningApplication?.applicationName ?? "Window"
                return "Record \"\(name)\""
            }
            return "Record Selected Window"
        }
    }

    // MARK: - Selecting Toolbar

    private var selectingToolbar: some View {
        HStack(spacing: 0) {
            // Close button
            toolbarIconButton(systemName: "xmark.circle.fill", size: 20) {
                coordinator.dismiss()
            }
            .accessibilityLabel("Close")
            .padding(.leading, 10)
            .padding(.trailing, 4)

            nativeDivider

            // Mode group
            HStack(spacing: 2) {
                // Record Entire Screen
                toolbarModeIcon(
                    systemName: "menubar.dock.rectangle",
                    isSelected: coordinator.captureMode == .entireScreen,
                    tooltip: "Record Entire Screen"
                ) {
                    coordinator.setCaptureMode(.entireScreen)
                }

                // Record Window
                toolbarModeIcon(
                    systemName: "macwindow",
                    isSelected: coordinator.captureMode == .window,
                    tooltip: "Record Selected Window"
                ) {
                    coordinator.setCaptureMode(.window)
                }
            }
            .padding(.horizontal, 6)

            nativeDivider

            // Record button
            Button {
                coordinator.confirmAndRecord()
            } label: {
                Text("Record")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(systemAccent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(coordinator.isLoadingSources)
            .padding(.trailing, 6)
            .padding(.leading, 4)
        }
        .frame(height: 48)
        .modifier(CaptureToolbarSurface(isToolbar: true))
    }

    // MARK: - Recording Toolbar

    private var recordingToolbar: some View {
        HStack(spacing: 12) {
            // Recording indicator dot
            Circle()
                .fill(DesignColors.recording)
                .frame(width: 10, height: 10)
                .opacity(coordinator.isPaused ? 0.3 : 1.0)

            // Duration
            Text(formatDuration(coordinator.recordingDuration))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize()

            nativeDivider

            // Pause/Resume
            toolbarIconButton(
                systemName: coordinator.isPaused ? "play.fill" : "pause.fill",
                size: 14
            ) {
                coordinator.togglePause()
            }
            .accessibilityLabel(coordinator.isPaused ? "Resume recording" : "Pause recording")
            .help(coordinator.isPaused ? "Resume (Ctrl+Space)" : "Pause (Ctrl+Space)")

            // Zoom toggle
            Button {
                coordinator.toggleZoom()
            } label: {
                Image(systemName: coordinator.isZoomedIn ? "minus.magnifyingglass" : "plus.magnifyingglass")
                    .font(.system(size: 14, weight: coordinator.isZoomedIn ? .bold : .regular))
                    .foregroundStyle(coordinator.isZoomedIn ? .white : .secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(coordinator.isZoomedIn ? systemAccent : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(coordinator.isZoomedIn ? "Zoom out" : "Zoom in")
            .help(coordinator.isZoomedIn ? "Zoom out (Ctrl+Z)" : "Zoom in (Ctrl+Z)")
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: coordinator.isZoomedIn)

            // Webcam toggle
            if coordinator.isWebcamAvailable {
                Button {
                    coordinator.toggleWebcam()
                } label: {
                    Image(systemName: coordinator.isWebcamActive ? "video.fill" : "video.slash.fill")
                        .font(.system(size: 14, weight: coordinator.isWebcamActive ? .bold : .regular))
                        .foregroundStyle(coordinator.isWebcamActive ? .white : .secondary)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(coordinator.isWebcamActive ? systemAccent.opacity(0.8) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(coordinator.isWebcamActive ? "Disable webcam" : "Enable webcam")
                .help(coordinator.isWebcamActive ? "Webcam On" : "Webcam Off")
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: coordinator.isWebcamActive)
            }

            // Stop
            Button {
                coordinator.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DesignColors.recording))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
            .help("Stop recording (Esc)")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .modifier(CaptureToolbarSurface(isToolbar: true))
    }

    // MARK: - Toolbar Components

    private func toolbarModeIcon(
        systemName: String,
        isSelected: Bool,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 40, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private func toolbarIconButton(
        systemName: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var nativeDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

private struct CaptureToolbarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var isToolbar: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background {
                Capsule()
                    .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
                    .overlay {
                        Capsule().strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.08), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(isToolbar ? 0.22 : 0.12), radius: isToolbar ? 12 : 4, y: isToolbar ? 5 : 2)
            }
        }
    }
}
