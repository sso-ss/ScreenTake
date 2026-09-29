import Foundation
import ScreenCaptureKit
import AppKit
import AVFoundation
import CoreGraphics

/// Manages checking and requesting system permissions
final class PermissionsManager: ObservableObject {

    @Published var screenRecordingGranted: Bool = false
    @Published var microphoneGranted: Bool = false
    @Published var cameraGranted: Bool = false
    @Published var accessibilityGranted: Bool = false

    init() {
        self.screenRecordingGranted = checkScreenRecordingAccess()
        self.microphoneGranted = checkMicrophone()
        self.cameraGranted = checkCamera()
        self.accessibilityGranted = checkAccessibility()
    }

    // MARK: - Refresh

    func refreshAll() {
        screenRecordingGranted = checkScreenRecordingAccess()
        microphoneGranted = checkMicrophone()
        cameraGranted = checkCamera()
        accessibilityGranted = checkAccessibility()
    }

    /// Explicitly check screen recording — only call when user initiates recording
    @MainActor
    func checkAndUpdateScreenRecording() async {
        screenRecordingGranted = await checkScreenRecording()
    }

    // MARK: - Screen Recording

    func checkScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func checkScreenRecording() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    func requestScreenRecording() {
        screenRecordingGranted = CGRequestScreenCaptureAccess()

        if !screenRecordingGranted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Microphone

    func checkMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.microphoneGranted = granted
            }
        }
    }

    // MARK: - Camera

    func checkCamera() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.cameraGranted = granted
            }
        }
    }

    // MARK: - Accessibility

    func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        // Poll until granted
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                if AXIsProcessTrusted() {
                    self?.accessibilityGranted = true
                    timer.invalidate()
                }
            }
        }
    }

    // MARK: - Overall

    var allRequiredGranted: Bool {
        screenRecordingGranted && microphoneGranted
    }

    var allGranted: Bool {
        screenRecordingGranted && microphoneGranted && accessibilityGranted
    }
}
