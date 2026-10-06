import Foundation

@main
struct CaptureAudioDefaultsChecks {
    @MainActor
    static func main() async throws {
        let defaults = UserDefaults.standard
        let keys = ["isWebcamEnabled", "isMicrophoneEnabled", "isSystemAudioEnabled"]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, originals) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.set(true, forKey: "isWebcamEnabled")
        defaults.set(false, forKey: "isMicrophoneEnabled")
        defaults.set(false, forKey: "isSystemAudioEnabled")
        let capture = CaptureSettings()
        precondition(capture.isWebcamEnabled && !capture.isMicrophoneEnabled,
                     "Loading saved settings must preserve an explicit mic-off choice")
        capture.isWebcamEnabled = false
        precondition(!capture.isMicrophoneEnabled)
        capture.isMicrophoneEnabled = true
        precondition(!capture.isWebcamEnabled, "Microphone must work independently")
        capture.isMicrophoneEnabled = false
        capture.isWebcamEnabled = true
        precondition(capture.isMicrophoneEnabled, "Enabling the camera must enable the microphone")
        capture.isMicrophoneEnabled = false
        precondition(capture.isWebcamEnabled, "Turning the mic off must leave the camera on")
        capture.isWebcamEnabled = true
        precondition(!capture.isMicrophoneEnabled, "Keeping the camera on must respect mic-off")
        capture.isWebcamEnabled = false
        capture.isWebcamEnabled = true
        precondition(capture.isMicrophoneEnabled, "Switching the camera back on must enable the mic again")
        capture.isWebcamEnabled = false
        precondition(capture.isMicrophoneEnabled, "Disabling the camera must preserve narration")
        precondition(!capture.isSystemAudioEnabled, "Camera changes must preserve system audio")
        print("PASS: camera defaults, independent microphone, saved mic-off and unchanged system audio")

        capture.isMicrophoneEnabled = false
        let appState = AppState.shared
        let toolbar = CaptureToolbarCoordinator(appState: appState)
        toolbar.toggleWebcam()
        precondition(toolbar.isWebcamActive && toolbar.isMicrophoneEnabled && appState.capture.isMicrophoneEnabled)
        toolbar.toggleMicrophone()
        precondition(toolbar.isWebcamActive && !toolbar.isMicrophoneEnabled && !appState.capture.isMicrophoneEnabled)
        toolbar.toggleWebcam()
        toolbar.toggleMicrophone()
        precondition(!toolbar.isWebcamActive && toolbar.isMicrophoneEnabled && appState.capture.isMicrophoneEnabled)
        print("PASS: toolbar and capture settings agree when camera and mic are toggled independently")

        let recording = RecordingCoordinator()
        do {
            try await recording.setMicrophoneEnabled(true, device: nil)
            preconditionFailure("Microphone must not start outside a recording")
        } catch is CancellationError {}
        print("PASS: microphone cannot start after recording has stopped")
    }
}
