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
    @AppStorage("exportResolution") var exportResolution: ExportResolution = .preserveSource

    @AppStorage("canvasRatio") var canvasRatio: CanvasRatio = .original
    @AppStorage("desktopCornerRadius") var desktopCornerRadius: Double = 0.025
    @AppStorage("phoneCornerRadius") var phoneCornerRadius: Double?
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

    var usesCanvas: Bool { canvasRatio != .original || deviceLayout != .desktop || customBackgroundImage != nil }
    var isLayoutReady: Bool { deviceLayout != .duo || phoneVideoURL != nil }

    // MARK: - Cursor

    @AppStorage("showCursor") var showCursor: Bool = true
    @AppStorage("cursorScale") var cursorScale: Double = 1.0
    @AppStorage("cursorShape") var cursorShape: CursorShape = .arrow
    @AppStorage("highlightClicks") var highlightClicks: Bool = false
    @AppStorage("clickHighlightColor") var clickHighlightColor: ClickHighlightColor = .white

    // MARK: - Background

    @AppStorage("backgroundWallpaper") var backgroundWallpaperRaw: String = "sonoma"
    @AppStorage("customBackgroundImage") private var customBackgroundData: Data = Data()

    var customBackgroundImage: Data? {
        get { customBackgroundData.isEmpty ? nil : customBackgroundData }
        set { customBackgroundData = newValue ?? Data() }
    }

    // MARK: - Auto Zoom

    @AppStorage("captureZoomEnabled") var zoomEnabled: Bool = true
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
    @AppStorage("isCameraMirrored") var isCameraMirrored = false
    @AppStorage("selectedWebcamDeviceID") var selectedWebcamDeviceID: String = ""
    @AppStorage("webcamPiPPositionRaw") var webcamPiPPositionRaw: String = PiPPosition.bottomRight.rawValue
    @AppStorage("webcamPiPSizeRaw") var webcamPiPSizeRaw: String = PiPSize.medium.rawValue
    @AppStorage("webcamPiPShapeRaw") var webcamPiPShapeRaw: String = PiPShape.circle.rawValue
    @AppStorage("faceBeautyAmount") private var savedFaceBeautyAmount: Double = 0
    var faceBeautyAmount: Double {
        get { FaceBeautyFilter.clamped(savedFaceBeautyAmount) }
        set {
            let value = FaceBeautyFilter.clamped(newValue)
            guard value != savedFaceBeautyAmount else { return }
            objectWillChange.send()
            savedFaceBeautyAmount = value
        }
    }

    @AppStorage("faceMakeupSettings") private var savedFaceMakeup: Data = Data()
    var faceMakeup: FaceMakeupSettings {
        get { ((try? JSONDecoder().decode(FaceMakeupSettings.self, from: savedFaceMakeup)) ?? .init()).clamped }
        set {
            guard let data = try? JSONEncoder().encode(newValue.clamped), data != savedFaceMakeup else { return }
            objectWillChange.send()
            savedFaceMakeup = data
        }
    }

    @AppStorage("cameraEffectSelection") private var savedCameraEffectSelection: Data = Data()
    var cameraEffectsEnabled: Bool { faceBeautyAmount > 0 || faceMakeup.amount > 0 }
    var cameraEffectSelection: CameraEffectSelection {
        .current(preferred: try? JSONDecoder().decode(CameraEffectSelection.self, from: savedCameraEffectSelection),
                 natural: faceBeautyAmount, makeup: faceMakeup)
    }

    func setCameraEffect(_ selection: CameraEffectSelection, enabled: Bool) {
        let selection = selection.clamped
        let amounts = selection.amounts(enabled: enabled, makeup: faceMakeup)
        objectWillChange.send()
        if let data = try? JSONEncoder().encode(selection) { savedCameraEffectSelection = data }
        faceBeautyAmount = amounts.natural
        faceMakeup = amounts.makeup
    }

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
        if let customBackgroundImage { return .image(customBackgroundImage) }
        return .wallpaper(selectedWallpaper)
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
