import Foundation
import SwiftUI
import ScreenCaptureKit
import AVFoundation

enum ClickHighlightColor: String, CaseIterable, Codable {
    case white
    case yellow
    case coral
    case green
    case blue
    case pink

    var displayName: String { rawValue.capitalized }

    var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch self {
        case .white: return (1, 1, 1)
        case .yellow: return (1, 0.82, 0.18)
        case .coral: return (1, 0.32, 0.28)
        case .green: return (0.25, 0.86, 0.48)
        case .blue: return (0.22, 0.58, 1)
        case .pink: return (1, 0.3, 0.68)
        }
    }

    var color: Color {
        let value = components
        return Color(red: value.red, green: value.green, blue: value.blue)
    }
}

/// Capture source selection, audio settings, and frame rate preferences.
@MainActor
final class CaptureSettings: ObservableObject {

    // MARK: - Audio Settings

    @AppStorage("isMicrophoneEnabled") var isMicrophoneEnabled: Bool = false
    @AppStorage("isSystemAudioEnabled") var isSystemAudioEnabled: Bool = true
    @AppStorage("selectedMicrophoneDeviceID") var selectedMicrophoneDeviceID: String = ""

    // MARK: - Frame Rate

    @AppStorage("captureFrameRate") var captureFrameRate: Int = 60

    @AppStorage("canvasRatio") var canvasRatio: CanvasRatio = .original
    @AppStorage("desktopCornerRadius") var desktopCornerRadius: Double = 0.025
    @AppStorage("deviceLayout") private var deviceLayoutRaw: String = DeviceLayout.desktop.rawValue
    var deviceLayout: DeviceLayout {
        get { DeviceLayout.allCases.first { $0.rawValue == deviceLayoutRaw } ?? .desktop }
        set { deviceLayoutRaw = newValue.rawValue }
    }
    @Published var phoneVideoURL: URL?
    @AppStorage("phoneContentMode") var phoneContentMode: PhoneContentMode = .fit
    @Published private var phoneCrop = PhoneCrop()
    private var phoneCropSourceURL: URL?

    func phoneCrop(for source: URL) -> PhoneCrop {
        phoneCropSourceURL == source ? phoneCrop : PhoneCrop()
    }

    func setPhoneCrop(_ crop: PhoneCrop, for source: URL) {
        phoneCropSourceURL = source
        phoneCrop = crop
    }

    var usesCanvas: Bool { canvasRatio != .original || deviceLayout != .desktop }
    var isLayoutReady: Bool { deviceLayout != .duo || phoneVideoURL != nil }

    // MARK: - Cursor

    @AppStorage("showCursor") var showCursor: Bool = true
    @AppStorage("cursorScale") var cursorScale: Double = 1.0
    @AppStorage("cursorShape") var cursorShape: CursorShape = .arrow
    @AppStorage("highlightClicks") var highlightClicks: Bool = false
    @AppStorage("clickHighlightColor") var clickHighlightColor: ClickHighlightColor = .white

    // MARK: - Background

    @AppStorage("backgroundWallpaper") var backgroundWallpaperRaw: String = "sonoma"

    // MARK: - Auto Zoom

    @AppStorage("autoZoomEnabled") var autoZoomEnabled: Bool = false

    // MARK: - Webcam

    @AppStorage("isWebcamEnabled") private var webcamEnabled: Bool = false

    var isWebcamEnabled: Bool {
        get { webcamEnabled }
        set {
            guard newValue != webcamEnabled else { return }
            objectWillChange.send()
            webcamEnabled = newValue
            // Enable narration when the camera is switched on. Afterwards the
            // microphone remains independent, including when the camera is off.
            if newValue { isMicrophoneEnabled = true }
        }
    }
    @AppStorage("selectedWebcamDeviceID") var selectedWebcamDeviceID: String = ""
    @AppStorage("webcamPiPPositionRaw") var webcamPiPPositionRaw: String = PiPPosition.bottomRight.rawValue
    @AppStorage("webcamPiPSizeRaw") var webcamPiPSizeRaw: String = PiPSize.medium.rawValue
    @AppStorage("webcamPiPShapeRaw") var webcamPiPShapeRaw: String = PiPShape.circle.rawValue

    var webcamPiPPosition: PiPPosition {
        get { PiPPosition(rawValue: webcamPiPPositionRaw) ?? .bottomRight }
        set {
            webcamPiPPositionRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    var webcamPiPSize: PiPSize {
        get { PiPSize(rawValue: webcamPiPSizeRaw) ?? .medium }
        set { webcamPiPSizeRaw = newValue.rawValue }
    }

    var webcamPiPShape: PiPShape {
        get { PiPShape(rawValue: webcamPiPShapeRaw) ?? .circle }
        set {
            webcamPiPShapeRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    var selectedWallpaper: BackgroundStyle.WallpaperPreset {
        get { BackgroundStyle.WallpaperPreset(rawValue: backgroundWallpaperRaw) ?? .sonoma }
        set { backgroundWallpaperRaw = newValue.rawValue }
    }

    // MARK: - Source Selection

    @Published var selectedTarget: CaptureTarget?
    @Published var availableDisplays: [SCDisplay] = []
    @Published var availableWindows: [SCWindow] = []

    // MARK: - Background Style

    var backgroundStyle: BackgroundStyle {
        .wallpaper(selectedWallpaper)
    }

    // MARK: - Computed

    var selectedMicrophoneDevice: AVCaptureDevice? {
        guard !selectedMicrophoneDeviceID.isEmpty else {
            return AVCaptureDevice.default(for: .audio)
        }
        return AVCaptureDevice(uniqueID: selectedMicrophoneDeviceID)
    }

    var availableMicrophones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    // MARK: - Webcam Computed

    var selectedWebcamDevice: AVCaptureDevice? {
        guard !selectedWebcamDeviceID.isEmpty else {
            return AVCaptureDevice.default(for: .video)
        }
        return AVCaptureDevice(uniqueID: selectedWebcamDeviceID)
    }

    var availableWebcams: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}
