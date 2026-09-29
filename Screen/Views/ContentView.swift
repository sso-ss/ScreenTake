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
        .onReceive(NotificationCenter.default.publisher(for: .openVideoFile)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                // SettingsView handles this via its own notification listener
                _ = url
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFile)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                Log.app.info("Open project file: \(url.path)")
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
