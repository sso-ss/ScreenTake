import SwiftUI

/// Permission setup wizard shown on first launch
struct PermissionSetupWizardView: View {

    var onComplete: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentStep = 0

    private var permissions: PermissionsManager { appState.permissions }

    private let steps: [(title: String, icon: String, description: String)] = [
        ("Screen Recording", "rectangle.inset.filled.and.person.filled",
         "Capture your display or application windows."),
        ("Microphone", "mic.fill",
         "Capture audio during screen recordings."),
        ("Accessibility", "accessibility",
         "Track mouse, keyboard, and UI elements for smart zoom."),
    ]

    var body: some View {
        VStack(spacing: Spacing.xxxl) {
            Spacer()

            // Icon
            Image(systemName: steps[currentStep].icon)
                .font(.system(size: 48))
                .foregroundColor(DesignColors.accent)

            // Title
            Text(steps[currentStep].title)
                .font(Typography.display)

            // Description
            Text(steps[currentStep].description)
                .font(Typography.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            // Status
            statusView

            // Buttons
            HStack(spacing: Spacing.xl) {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                    .buttonStyle(.bordered)
                }

                Button(currentStep < steps.count - 1 ? "Next" : "Get Started") {
                    if currentStep < steps.count - 1 {
                        requestCurrentPermission()
                        withAnimation { currentStep += 1 }
                    } else {
                        requestCurrentPermission()
                        onComplete()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            // Skip
            Button("Skip Setup") {
                onComplete()
            }
            .font(Typography.caption)
            .foregroundColor(DesignColors.tertiaryLabel)

            Spacer()

            // Step indicator
            HStack(spacing: Spacing.md) {
                ForEach(0..<steps.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentStep ? DesignColors.accent : DesignColors.tertiaryLabel)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, Spacing.xxl)
        }
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

    @ViewBuilder
    private var statusView: some View {
        let granted: Bool = {
            switch currentStep {
            case 0: return permissions.screenRecordingGranted
            case 1: return permissions.microphoneGranted
            case 2: return permissions.accessibilityGranted
            default: return false
            }
        }()

        HStack(spacing: Spacing.md) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundColor(granted ? DesignColors.success : DesignColors.tertiaryLabel)
            Text(granted ? "Permission granted" : "Permission required")
                .font(Typography.caption)
                .foregroundColor(granted ? DesignColors.success : .secondary)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.lg)
                .fill(granted ? DesignColors.success.opacity(0.1) : DesignColors.controlBackground)
        )
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
