import SwiftUI

/// Permission setup wizard shown on first launch
struct PermissionSetupWizardView: View {

    var onComplete: () -> Void

    @EnvironmentObject var appState: AppState

    var body: some View {
        PermissionSetupContent(permissions: appState.permissions, onComplete: onComplete)
    }
}

struct PermissionSetupContent: View {
    @ObservedObject var permissions: PermissionsManager
    var onComplete: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var currentStep = 0

    private let steps: [(title: String, icon: String, description: String, action: String)] = [
        ("Record your screen", "rectangle.inset.filled.and.person.filled",
         "Allow ScreenTake to capture your display\nor a selected app window.", "Allow Screen Recording"),
        ("Add your voice", "mic.fill",
         "Allow microphone access to narrate\nyour screen recordings.", "Allow Microphone"),
        ("Make every detail clear", "accessibility",
         "Allow accessibility access so smart zoom\ncan follow your clicks and keyboard activity.", "Allow Accessibility"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("SETUP · STEP \(currentStep + 1) OF \(steps.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(DesignColors.secondaryLabel)
                    .padding(.bottom, 28)

                Image(systemName: steps[currentStep].icon)
                    .font(.system(size: 32))
                    .foregroundColor(DesignColors.accent)
                    .frame(width: 64, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(DesignColors.accent.opacity(0.12))
                    )
                    .accessibilityHidden(true)
                    .padding(.bottom, 20)

                VStack(spacing: 10) {
                    Text(steps[currentStep].title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(DesignColors.primaryLabel)
                        .accessibilityAddTraits(.isHeader)

                    Text(steps[currentStep].description)
                        .font(Typography.body)
                        .foregroundColor(DesignColors.secondaryLabel)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)

                statusView
                    .padding(.top, 16)

                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        if currentStep > 0 {
                            Button("Back") {
                                withAnimation { currentStep -= 1 }
                            }
                            .buttonStyle(SetupButtonStyle(isPrimary: false))
                        }

                        Button(primaryActionTitle) {
                            if currentPermissionGranted {
                                advance()
                            } else {
                                requestCurrentPermission()
                            }
                        }
                        .buttonStyle(SetupButtonStyle(isPrimary: true))
                        .keyboardShortcut(.defaultAction)
                    }

                    Button {
                        onComplete()
                    } label: {
                        Text("Skip setup for now")
                            .font(Typography.caption)
                            .foregroundColor(DesignColors.secondaryLabel)
                            .padding(.horizontal, Spacing.xl)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 28)
            }
            .frame(maxWidth: 440)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignColors.windowBackground)
        .onAppear {
            permissions.refreshAll()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                permissions.refreshAll()
            }
        }
    }

    private var currentPermissionGranted: Bool {
        switch currentStep {
        case 0: return permissions.screenRecordingGranted
        case 1: return permissions.microphoneGranted
        case 2: return permissions.accessibilityGranted
        default: return false
        }
    }

    private var primaryActionTitle: String {
        currentPermissionGranted
            ? (currentStep == steps.count - 1 ? "Get Started" : "Continue")
            : steps[currentStep].action
    }

    private var permissionStatus: String {
        if currentPermissionGranted { return "Permission granted" }
        return currentStep == 0
            ? "Required for screen recording"
            : "Optional · You can set this up later"
    }

    private var statusView: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: currentPermissionGranted ? "checkmark.circle.fill" : "info.circle")
                .accessibilityHidden(true)
            Text(permissionStatus)
        }
        .font(Typography.caption)
        .foregroundColor(currentPermissionGranted ? DesignColors.success : DesignColors.secondaryLabel)
    }

    private func advance() {
        if currentStep < steps.count - 1 {
            withAnimation { currentStep += 1 }
        } else {
            onComplete()
        }
    }

    private func requestCurrentPermission() {
        switch currentStep {
        case 0: permissions.requestScreenRecording()
        case 1: permissions.requestMicrophone()
        case 2: permissions.requestAccessibility()
        default: break
        }
    }
}

/// Matches the purple primary and neutral secondary actions in the main window.
private struct SetupButtonStyle: ButtonStyle {
    var isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(isPrimary ? .white : DesignColors.primaryLabel)
            .padding(.horizontal, Spacing.xxl)
            .frame(minWidth: 120, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .fill(isPrimary ? DesignColors.accent : DesignColors.inputBackground)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
