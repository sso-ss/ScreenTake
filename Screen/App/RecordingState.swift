import Foundation
import Combine
import AVFoundation
import os

/// Recording lifecycle state.
@MainActor
final class RecordingState: ObservableObject {

    // MARK: - Published

    @Published var isRecording: Bool = false
    @Published var isPaused: Bool = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastRecordingURL: URL?
    private(set) var lastSavedRecordingURL: URL?
    @Published private(set) var lastSourceRecordingURL: URL?
    private var lastRecordingUsedZoom = false
    @Published private(set) var lastAppliedEdits: VideoEditSettings?
    private(set) var initialEdits = VideoEditSettings()
    private var previewAudioURL: URL?
    private(set) var lastUntrimmedRecordingURL: URL?
    private var recordingUsesBackground = false
    @Published var lastMouseDataURL: URL?
    @Published var lastMicAudioURL: URL?
    @Published var lastSystemAudioURL: URL?
    @Published var lastWebcamVideoURL: URL?
    @Published private(set) var processingStage: ProcessingStage?
    @Published private(set) var processingProgress: Double?
    @Published var processingError: String?

    enum ProcessingStage {
        case processing
        case mergingAudio

        var title: String {
            switch self {
            case .processing: return "Processing recording..."
            case .mergingAudio: return "Merging audio..."
            }
        }
    }

    // MARK: - Recording Coordinator

    @Published var recordingCoordinator: RecordingCoordinator?

    // MARK: - Private

    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private var pausedAt: Date?
    private var totalPausedDuration: TimeInterval = 0
    private weak var captureSettings: CaptureSettings?
    private weak var navigationState: NavigationState?
    private var lastMicAudioStartOffset: CMTime = .zero
    private var lastSystemAudioStartOffset: CMTime = .zero
    private var lastBrowserContentRect: CGRect?

    func configure(captureSettings: CaptureSettings, navigationState: NavigationState) {
        self.captureSettings = captureSettings
        self.navigationState = navigationState
    }

    // MARK: - Recording Control

    func saveRecording(from source: URL, to destination: URL) async throws {
        try await VideoFileStore.copy(from: source, to: destination)
        if lastRecordingURL == source {
            lastRecordingURL = destination
            lastSavedRecordingURL = destination
        }
    }

    func startRecording(appState: AppState) async throws {
        guard processingStage == nil else { return }
        guard let captureSettings else { return }
        guard captureSettings.isLayoutReady else {
            throw ExportError.missingPhoneVideo
        }
        guard let target = captureSettings.selectedTarget else {
            navigationState?.errorMessage = "Please select a capture source first"
            return
        }

        let coordinator = RecordingCoordinator()
        self.recordingCoordinator = coordinator
        recordingUsesBackground = target.isWindow || captureSettings.usesCanvas

        try await coordinator.startRecording(
            target: target,
            backgroundStyle: nil,
            frameRate: captureSettings.captureFrameRate,
            showCursor: captureSettings.showCursor,
            cursorScale: captureSettings.cursorScale,
            highlightClicks: captureSettings.highlightClicks,
            clickHighlightColor: captureSettings.clickHighlightColor,
            isSystemAudioEnabled: captureSettings.isSystemAudioEnabled,
            isMicrophoneEnabled: captureSettings.isMicrophoneEnabled,
            microphoneDevice: captureSettings.selectedMicrophoneDevice,
            isWebcamEnabled: captureSettings.isWebcamEnabled,
            webcamDevice: captureSettings.selectedWebcamDevice
        )

        isRecording = true
        isPaused = false
        recordingDuration = 0
        startDurationTimer()
    }

    func stopRecording() async {
        guard let coordinator = recordingCoordinator else {
            Log.recording.error("stopRecording called but recordingCoordinator is nil")
            return
        }

        Log.recording.info("Stopping recording…")
        guard processingStage == nil else { return }
        processingError = nil
        processingProgress = nil
        processingStage = .processing
        let result = await coordinator.stopRecording()
        stopDurationTimer()

        acceptCompletedRecording(result)
    }

    /// Retain the source and sidecars for live editing; rendering happens on export.
    func acceptCompletedRecording(_ result: RecordingResult) {
        processingError = nil
        processingProgress = nil
        lastRecordingURL = result.videoURL
        lastSourceRecordingURL = result.videoURL
        lastAppliedEdits = nil
        lastUntrimmedRecordingURL = nil
        lastMouseDataURL = result.mouseDataURL
        lastMicAudioURL = result.micAudioURL
        lastSystemAudioURL = result.systemAudioURL
        lastWebcamVideoURL = result.webcamVideoURL
        lastMicAudioStartOffset = result.micAudioStartOffset
        lastSystemAudioStartOffset = result.systemAudioStartOffset
        lastBrowserContentRect = result.browserContentRect
        previewAudioURL = nil

        isRecording = false
        isPaused = false
        recordingCoordinator = nil

        Log.recording.info("Recording stopped: video=\(result.videoURL?.lastPathComponent ?? "nil")")

        if let videoURL = result.videoURL {
            let mouseURL = result.mouseDataURL
            let hasManualZoom = mouseURL.map { hasManualZoomMarkers(mouseDataURL: $0) } ?? false
            let autoEnabled = captureSettings?.autoZoomEnabled == true
            let shouldApplyZoom = autoEnabled || hasManualZoom
            lastRecordingUsedZoom = shouldApplyZoom
            initialEdits = recordingEdits(for: videoURL, generateZoom: shouldApplyZoom)
            processingStage = nil
            Log.recording.info("Recording ready for live editing from original media")
        } else {
            processingStage = nil
            processingError = "The recording could not be saved."
        }
        navigationState?.showEditor = true
    }

    /// One audio-only passthrough file gives preview, cleanup and saved projects
    /// the same synchronized tracks without decoding or re-encoding the video.
    func preparePreviewAudio() async throws -> URL? {
        if let previewAudioURL { return previewAudioURL }
        guard let videoURL = lastSourceRecordingURL else { return nil }
        let audioURL = try await MediaMuxer.recordingAudio(
            videoURL: videoURL, systemAudioURL: lastSystemAudioURL, micAudioURL: lastMicAudioURL,
            systemAudioStartOffset: lastSystemAudioStartOffset, micAudioStartOffset: lastMicAudioStartOffset)
        guard lastSourceRecordingURL == videoURL else {
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            throw CancellationError()
        }
        previewAudioURL = audioURL
        return previewAudioURL
    }

    func pauseRecording() {
        recordingCoordinator?.pauseRecording()
        isPaused = true
        pausedAt = Date()
    }

    func resumeRecording() {
        recordingCoordinator?.resumeRecording()
        isPaused = false
        if let pauseStart = pausedAt {
            totalPausedDuration += Date().timeIntervalSince(pauseStart)
            pausedAt = nil
        }
    }

    func togglePause() {
        if isPaused {
            resumeRecording()
        } else {
            pauseRecording()
        }
    }

    func toggleZoom() {
        guard let coordinator = recordingCoordinator else {
            Log.recording.warning("toggleZoom: recordingCoordinator is nil")
            return
        }
        Log.recording.info("toggleZoom: forwarding to coordinator")
        coordinator.toggleZoom()
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        recordingStartTime = Date()
        totalPausedDuration = 0
        pausedAt = nil
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                guard !self.isPaused else { return }
                let elapsed = Date().timeIntervalSince(start) - self.totalPausedDuration
                self.recordingDuration = max(0, elapsed)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
        pausedAt = nil
        totalPausedDuration = 0
    }

    /// Quick check if the mouse data file contains manual zoom markers.
    private func hasManualZoomMarkers(mouseDataURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: mouseDataURL),
              let recording = try? JSONDecoder().decode(
                  MouseDataRecorder.MouseRecording.self, from: data
              ) else { return false }
        return !recording.zoomMarkers.isEmpty
    }

    // MARK: - Audio Mux (no zoom)

    private func muxAudioIntoRecording() async {
        defer {
            processingStage = nil
            processingProgress = nil
        }
        guard let videoURL = lastRecordingURL,
              (lastMicAudioURL != nil || lastSystemAudioURL != nil) else { return }

        processingProgress = nil
        processingStage = .mergingAudio
        do {
            let resultURL = try await MediaMuxer.mux(
                videoURL: videoURL,
                systemAudioURL: lastSystemAudioURL,
                micAudioURL: lastMicAudioURL,
                systemAudioStartOffset: lastSystemAudioStartOffset,
                micAudioStartOffset: lastMicAudioStartOffset
            )
            lastRecordingURL = resultURL
            Log.recording.info("Audio muxed into recording")
        } catch {
            Log.recording.error("Audio mux failed: \(error)")
            processingError = "Audio could not be merged. The original recording has been kept."
        }
    }

    // MARK: - Auto Zoom

    func reapplyCursor() async {
        guard !isRecording, processingStage == nil, let source = lastSourceRecordingURL else { return }
        await applyAutoZoom(videoURL: source, mouseDataURL: lastMouseDataURL, generateZoom: lastRecordingUsedZoom)
    }

    func applyEdits(_ edits: VideoEditSettings) async {
        guard !isRecording, processingStage == nil, let source = lastSourceRecordingURL else { return }
        await applyAutoZoom(videoURL: source, mouseDataURL: lastMouseDataURL, generateZoom: edits.zoomEnabled, edits: edits)
    }

    private func recordingEdits(for videoURL: URL, generateZoom: Bool) -> VideoEditSettings {
        VideoEditSettings(
            ratio: captureSettings?.canvasRatio ?? .original,
            layout: captureSettings?.deviceLayout ?? .desktop,
            wallpaper: captureSettings?.selectedWallpaper ?? .sonoma,
            desktopCornerRadius: captureSettings?.desktopCornerRadius ?? 0.025,
            backgroundEnabled: recordingUsesBackground,
            crop: captureSettings?.phoneCrop(for: videoURL) ?? PhoneCrop(),
            phoneMode: captureSettings?.phoneContentMode ?? .fit,
            phoneVideoURL: captureSettings?.phoneVideoURL,
            showCursor: captureSettings?.showCursor ?? true,
            cursorShape: captureSettings?.cursorShape ?? .arrow,
            cursorScale: captureSettings?.cursorScale ?? 1,
            zoomEnabled: generateZoom,
            webcamEnabled: lastWebcamVideoURL != nil,
            webcamShape: captureSettings?.webcamPiPShape ?? .circle,
            webcamPosition: captureSettings?.webcamPiPPosition ?? .bottomRight,
            webcamSize: captureSettings?.webcamPiPSize ?? .medium,
            faceBeautyAmount: captureSettings?.faceBeautyAmount,
            faceMakeup: captureSettings?.faceMakeup,
            videoOverlayURL: lastWebcamVideoURL,
            exportResolution: captureSettings?.exportResolution ?? .preserveSource,
            recordedBrowserContentRect: lastBrowserContentRect)
    }

    func applyAutoZoom(videoURL: URL, mouseDataURL: URL?, generateZoom: Bool, edits: VideoEditSettings? = nil) async {
        Log.export.info("Auto-zoom: starting post-recording export")
        processingError = nil
        processingProgress = nil
        processingStage = .processing
        defer {
            processingStage = nil
            processingProgress = nil
        }

        do {
            let settings = edits ?? recordingEdits(for: videoURL, generateZoom: generateZoom)
            var keyframes: [CameraKeyframe] = []
            if generateZoom, let mouseDataURL {
                keyframes = try await ClickZoomGenerator.generate(
                    from: mouseDataURL,
                    sourceVideoURL: videoURL,
                    settings: .init(zoomLevel: settings.zoomLevel),
                    segments: settings.zoomSegments
                )
            }

            if settings.audioEnabled {
                for audioURL in [lastMicAudioURL, lastSystemAudioURL].compactMap({ $0 }) {
                    guard FileManager.default.fileExists(atPath: audioURL.path) else {
                        throw CocoaError(.fileReadNoSuchFile)
                    }
                }
            }
            let hasZoom = keyframes.contains { $0.transform.zoom > 1.01 }
            let dir = videoURL.deletingLastPathComponent()
            let baseName = videoURL.deletingPathExtension().lastPathComponent
            let suffix = hasZoom ? "zoomed" : "composited"
            let outputURL = dir.appendingPathComponent("\(baseName)_\(suffix)_\(UUID().uuidString.prefix(8)).mov")

            let config = ExportEngine.Configuration(
                outputURL: outputURL,
                codec: .hevc,
                fileType: .mov,
                webcamVideoURL: settings.webcamEnabled ? settings.videoOverlayURL : nil,
                videoOverlayTiming: settings.videoOverlayTiming,
                videoOverlayTrim: settings.trim,
                pipPosition: settings.webcamPosition,
                pipSize: settings.webcamSize,
                pipShape: settings.webcamShape,
                cameraLayout: settings.cameraLayout,
                cameraLayoutChanges: settings.cameraLayoutChanges,
                faceBeautyAmount: settings.faceBeautyAmount ?? 0,
                    faceMakeup: settings.faceMakeup ?? .init(),
                mouseDataURL: mouseDataURL,
                cursorScale: settings.cursorScale,
                cursorShape: settings.cursorShape,
                showCursor: settings.showCursor,
                canvasRatio: settings.ratio,
                deviceLayout: settings.layout,
                wallpaper: settings.wallpaper,
                desktopCornerRadius: settings.desktopCornerRadius,
                phoneVideoURL: settings.phoneVideoURL ?? captureSettings?.phoneVideoURL,
                phoneCrop: settings.crop,
                phoneContentMode: settings.phoneMode,
                forceCanvas: settings.backgroundEnabled,
                exportResolution: settings.exportResolution
            )

            let engine = ExportEngine()
            let progressSubscription = engine.$progress.sink { [weak self] progress in
                guard let self, self.processingStage == .processing, progress.isFinite else { return }
                self.processingProgress = max(self.processingProgress ?? 0, min(1, max(0, progress)))
            }
            defer { progressSubscription.cancel() }
            var resultURL = try await engine.export(
                sourceURL: videoURL,
                keyframes: keyframes,
                configuration: config
            )

            // Keep the untrimmed original audio separate from narration and volume edits.
            if lastMicAudioURL != nil || lastSystemAudioURL != nil {
                processingProgress = nil
                processingStage = .mergingAudio
                do {
                    resultURL = try await MediaMuxer.mux(
                        videoURL: resultURL,
                        systemAudioURL: lastSystemAudioURL,
                        micAudioURL: lastMicAudioURL,
                        systemAudioStartOffset: lastSystemAudioStartOffset,
                        micAudioStartOffset: lastMicAudioStartOffset,
                        removeSourceAudio: false
                    )
                    Log.export.info("Auto-zoom: audio muxed into exported video")
                } catch {
                    Log.export.error("Auto-zoom: audio mux failed: \(error)")
                    processingError = "Audio could not be merged. The video and audio files have been kept."
                    return
                }
            }

            let untrimmedURL = resultURL
            resultURL = try await settings.trim.export(source: untrimmedURL)
            resultURL = try await EditorAudio.export(video: resultURL, originalEnabled: settings.audioEnabled,
                                                    originalVolume: settings.originalAudioVolume,
                                                    clips: settings.voiceOverEnabled ? settings.voiceOvers : [],
                                                    voiceOverVolume: settings.voiceOverVolume,
                                                    recordedSource: untrimmedURL, recordedClips: settings.recordedAudioClips)
            if settings.audioEnabled || lastUntrimmedRecordingURL == nil {
                lastUntrimmedRecordingURL = untrimmedURL
            }
            lastRecordingURL = resultURL
            if processingError == nil { lastAppliedEdits = settings }
            Log.export.info("Auto-zoom: export complete → \(resultURL.lastPathComponent)")
        } catch {
            Log.export.error("Auto-zoom failed (original video preserved): \(error)")
            processingError = "Recording processing failed. The original recording has been kept."
        }
    }
}
