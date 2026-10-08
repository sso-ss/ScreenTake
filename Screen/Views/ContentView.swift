import SwiftUI
import AVKit

// MARK: - Content View

struct ContentView: View {

    @EnvironmentObject var appState: AppState
    @AppStorage("hasCompletedPermissionSetup") private var hasCompletedSetup: Bool = false
    @State private var showErrorAlert = false
    @State private var errorAlertMessage = ""

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
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") {}
        } message: {
            Text(errorAlertMessage)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let openVideoFile = Notification.Name("openVideoFile")
    static let openProjectFile = Notification.Name("openProjectFile")
}
