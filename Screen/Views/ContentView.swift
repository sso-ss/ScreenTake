import SwiftUI
import AVKit

// MARK: - Content View

struct ContentView: View {

    @EnvironmentObject var appState: AppState
    @AppStorage("hasCompletedPermissionSetup") private var hasCompletedSetup: Bool = false

    var body: some View {
        Group {
            if !hasCompletedSetup {
                PermissionSetupWizardView(onComplete: {
                    hasCompletedSetup = true
                })
            } else {
                SettingsView(
                    onStartRecording: {
                        Task {
                            await appState.showCaptureToolbar()
                        }
                    }
                )
            }
        }
        .reportableError("Error", error: Binding(
            get: { appState.errorMessage }, set: { appState.errorMessage = $0 }
        ))
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let exportEditorVideo = Notification.Name("exportEditorVideo")
    static let openAppSettings = Notification.Name("openAppSettings")
    static let openVideoFile = Notification.Name("openVideoFile")
    static let openProjectFile = Notification.Name("openProjectFile")
}
