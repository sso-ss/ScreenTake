import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

private enum SettingsPanel: String, CaseIterable {
    case canvas = "Canvas"
    case cursor = "Cursor"
    case camera = "Camera"
    case audio = "Audio"
    case output = "Output"

    var icon: String {
        switch self {
        case .canvas: return "rectangle.inset.filled"
        case .cursor: return "cursorarrow"
        case .camera: return "video.fill"
        case .audio: return "waveform"
        case .output: return "square.and.arrow.up"
        }
    }
}

// MARK: - Settings View (Home Screen)

struct SettingsView: View {

    @EnvironmentObject var appState: AppState
    var onStartRecording: (() -> Void)?
    var onOpenVideo: ((URL) -> Void)?

    @ObservedObject var session: EditorSession = AppState.shared.editorSession
    @State private var isDragging = false
    @State private var isCroppingScreen = false
    @State private var cropFrameTime = CMTime.zero
    @State private var selectedPanel: SettingsPanel = .canvas
    @State private var focusFrame: CGImage?
    @State private var editingZoomFocus = false
    @StateObject private var cameraPreview = CameraPreviewController()
    @StateObject private var cameraLayoutPlayback = TimelinePlayback()
    @State private var isShowingCameraPreview = false
    @State private var isShowingSavePanel = false
    @State private var pendingReplacement: VideoReplacementAction?
    @State private var isShowingAppSettings = false

    private var videoURL: URL? { session.videoURL }
    private var videoPlayer: AVPlayer? { session.player }
    private var layoutSourceURL: URL? { session.sourceURL }
    private var sourceDuration: Double { session.sourceDuration }
    private var sourceVideoSize: CGSize? { session.sourceVideoSize }
    private var previewAudioURL: URL? { session.audioURL }
    private var hasEditableAudio: Bool { session.hasEditableAudio }
    private var previewReady: Bool { session.previewReady }
    private var previewError: String? { session.previewError }
    private var renderedPreviewTimeline: EditedTimeline? { session.renderedPreviewTimeline }
    private var isExporting: Bool { session.isExporting }
    private var isSaving: Bool { session.isSaving }
    private var processingTitle: String? {
        appState.recording.processingStage?.title ?? (isExporting ? "Applying changes..." : nil)
    }
    private var processingProgress: Double? {
        // A new recording may be processing while the previous video is still
        // in the editor. Follow the active job, not the displayed video's URL.
        appState.recording.processingStage != nil
            ? appState.recording.processingProgress : session.exportEngine.progress
    }
    private var voiceOverRecorder: VoiceOverRecorder { session.voiceOverRecorder }
    private var videoOverlayRecorder: VideoOverlayRecorder { session.videoOverlayRecorder }

    private var selectedZoom: ZoomSegment? {
        (session.draft.zoomSegments ?? session.automaticZooms).first { $0.id == session.selectedZoomID }
    }

    private func updateZoomFocus(_ change: (inout ZoomSegment) -> Void) {
        guard let id = session.selectedZoomID else { return }
        var updated = session.draft.zoomSegments ?? session.automaticZooms
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        change(&updated[index])
        session.draft.zoomSegments = updated
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Title bar
            titleBar

            Divider()

            if let title = processingTitle {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Text(LocalizedStringKey(title))
                            .foregroundColor(DesignColors.primaryLabel)
                        Spacer()
                        if let progress = processingProgress {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .foregroundColor(DesignColors.primaryLabel)
                        }
                    }
                    .font(Typography.caption)

                    ProgressView(value: processingProgress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(DesignColors.cameraTrack)
                        .localizedAccessibilityLabel(title)
                        .accessibilityIdentifier("videoProcessingProgress")
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .background(DesignColors.controlBackground)
                Divider()
            }

            // Two-column layout
            HStack(spacing: 0) {
                // Left — Preview or Video
                if let url = videoURL {
                    videoPreviewColumn(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    previewColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DesignColors.previewBackground)
                }

                Divider()

                // Right — Controls
                Group {
                    if videoURL != nil { editControlsColumn } else { controlsColumn }
                }
                    .frame(width: 356)
            }
            .frame(maxHeight: .infinity)
        }
        .background(DesignColors.windowBackground)
        .hoverHelpContainer()
    }

    var body: some View {
        settingsPresentation
        .sheet(isPresented: $isShowingAppSettings) {
            AppSettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAppSettings)) { _ in
            isShowingAppSettings = true
        }
        .alert("Export Error", isPresented: Binding(
            get: { session.exportError != nil },
            set: { if !$0 { session.exportError = nil } }
        )) {
            Button("OK") { session.exportError = nil }
        } message: {
            Text(LocalizedStringKey(session.exportError ?? "Unknown error"))
        }
        .alert("Processing Failed", isPresented: Binding(
            get: { appState.recording.processingError != nil },
            set: { if !$0 { appState.recording.processingError = nil } }
        )) {
            Button("OK") { appState.recording.processingError = nil }
        } message: {
            Text(LocalizedStringKey(appState.recording.processingError ?? ""))
        }
        .alert("Could Not Save Recording", isPresented: Binding(
            get: { session.saveError != nil },
            set: { if !$0 { session.saveError = nil } }
        )) {
            Button("OK") { session.saveError = nil }
        } message: {
            Text(LocalizedStringKey(session.saveError ?? ""))
        }
    }

    private var settingsPresentation: some View {
        mainContent
        .onChange(of: session.player.map(ObjectIdentifier.init)) { _ in
            cameraLayoutPlayback.detach()
            if let videoPlayer { cameraLayoutPlayback.attach(videoPlayer) }
        }
        .onDisappear {
            cameraLayoutPlayback.detach()
            if editingZoomFocus { session.endUndoGroup(); editingZoomFocus = false }
            voiceOverRecorder.cancel()
            videoOverlayRecorder.cancel()
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isDragging ? DesignColors.accent.opacity(0.6) : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.movie, .fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers)
        }
        .onDisappear { stopCameraPreview() }
        .onChange(of: appState.capture.isWebcamEnabled) { enabled in
            if !enabled { stopCameraPreview() }
        }
        .onChange(of: appState.capture.selectedWebcamDeviceID) { _ in
            if isShowingCameraPreview {
                cameraPreview.start(device: appState.capture.selectedWebcamDevice)
            }
        }
        .onChange(of: appState.isRecording) { recording in
            if recording { stopCameraPreview() }
        }
        .onChange(of: videoURL) { url in
            if url != nil { stopCameraPreview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openVideoFile)) { notification in
            if !editsBusy, let url = notification.userInfo?["url"] as? URL {
                requestImport(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFile)) { notification in
            if !editsBusy, let url = notification.userInfo?["url"] as? URL {
                requestOpen(url, project: true)
            }
        }
        .onAppear {
            if let videoPlayer { cameraLayoutPlayback.attach(videoPlayer) }
            if videoURL == nil, appState.recording.processingStage == nil,
               let url = appState.recording.lastRecordingURL { loadVideo(url) }
        }
        .onChange(of: appState.recording.processingStage) { stage in
            if !isExporting, stage == nil, appState.recording.processingError == nil,
               let url = appState.recording.lastRecordingURL {
                loadVideo(url)
            }
        }
        .onChange(of: videoURL == nil) { _ in selectedPanel = .canvas }
        .onChange(of: videoURL) { _ in
            if !isPanelAvailable(selectedPanel, editing: videoURL != nil) {
                selectedPanel = .canvas
            }
        }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: Spacing.lg) {
            // App identity
            HStack(spacing: 8) {
                Image("BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                Text("ScreenTake")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(DesignColors.primaryLabel)
            }

            Spacer()

            // Import button
            Button {
                openVideoPanel()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text("Import")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(CompactActionButtonStyle())
            .localizedAccessibilityLabel("Import video file")
            .disabled(editsBusy)
            .hoverHelp(editBusyReason ?? "Open a video file for editing.")

            // Record button
            Button {
                stopCameraPreview()
                onStartRecording?()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
                    Text("Record")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(CompactActionButtonStyle(prominent: true))
            .localizedAccessibilityLabel("Start recording")
            .disabled(editsBusy || !appState.capture.isLayoutReady)
            .hoverHelp(editBusyReason ?? (!appState.capture.isLayoutReady ? "Choose a phone video before recording this layout." : "Choose a source and start recording."))
        }
        .padding(.horizontal, Spacing.lg)
        .frame(height: 52)
        .background(DesignColors.controlBackground)
    }

    // MARK: - Preview Column

    private var previewColumn: some View {
        GeometryReader { geo in
            let padding: CGFloat = 32
            let availableWidth = max(1, geo.size.width - padding * 2)
            let availableHeight = max(1, geo.size.height - padding * 2 - 30)
            let source = appState.capture.deviceLayout.isPhone ? appState.capture.deviceLayout.phoneFrameSize : CGSize(width: 1440, height: 900)
            let canvasSize = appState.capture.canvasRatio.size(source: source)
            let aspect = canvasSize.width / canvasSize.height
            let previewWidth = min(availableWidth, availableHeight * aspect)
            let previewHeight = previewWidth / aspect

            VStack(spacing: 12) {
                Spacer()

                // Mock recording preview — centered, fills available width
                ZStack {
                    if let image = CanvasCompositor.preview(size: CGSize(width: previewWidth * 2, height: previewHeight * 2), layout: appState.capture.deviceLayout, wallpaper: appState.capture.selectedWallpaper, desktopCornerRadius: CGFloat(appState.capture.desktopCornerRadius)) {
                        Image(decorative: image, scale: 2)
                            .resizable()
                            .frame(width: previewWidth, height: previewHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .localizedAccessibilityLabel("\(appState.capture.deviceLayout.displayName), \(appState.capture.canvasRatio.displayName) preview")
                    }

                    // Mock cursor (positioned bottom-right of window)
                    if appState.capture.showCursor, appState.capture.deviceLayout == .desktop {
                        mockCursor
                            .offset(x: previewWidth * 0.15, y: previewHeight * 0.12)
                    }

                    // Camera placement preview, with a live feed on request.
                    if appState.capture.isWebcamEnabled {
                        webcamPreviewPiP(previewWidth: previewWidth, previewHeight: previewHeight)
                    }
                }

                // Preview label
                Text("Recording Preview")
                    .font(Typography.caption)
                    .foregroundColor(DesignColors.tertiaryLabel)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Mock Cursor

    private var mockCursor: some View {
        let baseSize: CGFloat = 24 * appState.capture.cursorScale
        return Group {
            if let nsImg = CursorImageProvider.nsImage(width: baseSize, shape: appState.capture.cursorShape) {
                Image(nsImage: nsImg)
                    .resizable()
                    .frame(width: nsImg.size.width, height: nsImg.size.height)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, x: 1, y: 1)
            }
        }
        .localizedAccessibilityLabel("Cursor preview, scale \(Int(appState.capture.cursorScale * 100))%")
    }

    // MARK: - Webcam Preview PiP

    private func webcamPreviewPiP(previewWidth: CGFloat, previewHeight: CGFloat) -> some View {
        let diameter = previewHeight * appState.capture.webcamPiPSize.fraction
        let padding: CGFloat = 8
        let position = appState.capture.webcamPiPPosition
        let xOffset = (previewWidth - diameter - 2 * padding) * (position.horizontalFraction - 0.5)
        let yOffset = (previewHeight - diameter - 2 * padding) * (position.verticalFraction - 0.5)

        let shape = appState.capture.webcamPiPShape
        let outline = RoundedRectangle(cornerRadius: shape == .circle ? diameter / 2 : diameter * 0.18)
        return ZStack {
            outline.fill(
                LinearGradient(
                    colors: [Color.blue.opacity(0.4), Color.purple.opacity(0.3)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            if isShowingCameraPreview, let recorder = cameraPreview.recorder, cameraPreview.session != nil {
                BeautyCameraFeedView(recorder: recorder, amount: appState.capture.faceBeautyAmount, makeup: appState.capture.faceMakeup)
                    .localizedAccessibilityLabel("Live camera preview")
                    .accessibilityIdentifier("inlineCameraPreview")
            } else if isShowingCameraPreview, cameraPreview.isStarting {
                ProgressView()
                    .controlSize(.small)
                    .localizedAccessibilityLabel("Preparing camera preview")
            } else if isShowingCameraPreview, cameraPreview.errorMessage != nil {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: diameter * 0.3))
                    .foregroundColor(.white.opacity(0.7))
                    .localizedAccessibilityLabel("Camera preview unavailable")
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: diameter * 0.35))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
            .frame(width: diameter, height: diameter)
            .clipShape(outline)
            .overlay(outline.stroke(Color.white.opacity(0.6), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .offset(x: xOffset, y: yOffset)
            .animation(.easeInOut(duration: 0.2), value: position)
            .animation(.easeInOut(duration: 0.2), value: appState.capture.webcamPiPSize)
            .animation(.easeInOut(duration: 0.2), value: shape)
    }

    private var mockWindowFrame: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: WindowChrome.trafficLightGap) {
                Circle().fill(WindowChrome.closeColor)
                    .frame(width: 10, height: 10)
                Circle().fill(WindowChrome.minimizeColor)
                    .frame(width: 10, height: 10)
                Circle().fill(WindowChrome.maximizeColor)
                    .frame(width: 10, height: 10)

                Spacer()

                Text("Window Title")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DesignColors.secondaryLabel)

                Spacer()

                Color.clear.frame(width: 50)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                LinearGradient(
                    colors: [WindowChrome.titleBarTop, WindowChrome.titleBarBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // Content area
            Rectangle()
                .fill(DesignColors.windowBackground)
                .overlay(
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DesignColors.inputBackground)
                            .frame(width: 200, height: 8)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DesignColors.inputBackground)
                            .frame(width: 160, height: 8)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DesignColors.inputBackground)
                            .frame(width: 180, height: 8)
                    }
                    .padding()
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DesignColors.inputBorder, lineWidth: 1)
        )
    }

    // MARK: - Controls Column

    private var editingRecording: Bool { session.editingRecording }
    private var editsBusy: Bool { isCroppingScreen || isShowingSavePanel || session.isBusy }
    private var editBusyReason: String? {
        if isCroppingScreen { return "Finish or cancel Crop Screen first." }
        if isShowingSavePanel { return "Finish or cancel the save dialog first." }
        if session.isDetectingBrowser { return "Wait for browser toolbar detection to finish." }
        if session.isLoading { return "Wait for the video to finish loading." }
        if isExporting || appState.recording.processingStage != nil { return "Wait for the video to finish processing." }
        if isSaving { return "Wait for the video to finish saving." }
        if voiceOverRecorder.isBusy { return "Finish or cancel the voiceover recording first." }
        if videoOverlayRecorder.isBusy { return "Finish or cancel the camera recording first." }
        if appState.isRecording { return "Stop the current recording first." }
        if session.isAnalyzing { return "Wait for video analysis to finish." }
        return nil
    }
    private var cropDisabledReason: String? {
        if phoneCropSource == nil { return "Record or open a video first." }
        if let reason = editBusyReason { return reason }
        if !previewReady {
            return previewError == nil ? "Wait for the video preview to finish loading." : "The video preview is unavailable. Reopen the video to try again."
        }
        return nil
    }
    private var applyDisabledReason: String? {
        if let reason = editBusyReason { return reason }
        if appState.updates.isPresenting { return "Close the app update dialog first." }
        if !hasValidTimeline { return "Keep at least one valid video section before applying changes." }
        if !hasEditChanges { return "Make an edit first; there are no pending changes to apply." }
        return nil
    }
    private var downloadDisabledReason: String? {
        if videoURL == nil { return "Record or open a video first." }
        if let reason = editBusyReason { return reason }
        if !hasValidTimeline { return "Keep at least one valid video section before downloading." }
        return nil
    }
    private var hasEditChanges: Bool { session.hasEditChanges }
    private var hasValidTimeline: Bool { session.hasValidTimeline }

    private var editControlsColumn: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Edit Video").font(.headline)
                    Spacer()
                    Button { session.resetPendingChanges() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain)
                        .hoverHelp(editBusyReason ?? (!hasEditChanges ? "There are no pending changes to reset." : "Reset pending changes"))
                        .localizedAccessibilityLabel("Reset pending changes")
                        .disabled(!hasEditChanges || editsBusy)
                }
                .padding(Spacing.xl)
                Divider()
                ScrollView {
                    editPanelContent
                        .padding(Spacing.xl)
                        .disabled(editsBusy && !voiceOverRecorder.isBusy && !videoOverlayRecorder.isBusy)
                }
                Divider()
                editActions
            }
            Divider()
            settingsPanelRail(editing: true)
                .disabled(voiceOverRecorder.isBusy || videoOverlayRecorder.isBusy)
        }
        .tint(DesignColors.accent)
    }

    private var controlsColumn: some View {
        HStack(spacing: 0) {
            ScrollView {
                capturePanelContent
                    .padding(Spacing.xl)
            }
            Divider()
            settingsPanelRail(editing: false)
        }
    }

    private func settingsPanelRail(editing: Bool) -> some View {
        VStack(spacing: Spacing.featureGap) {
            ForEach(SettingsPanel.allCases, id: \.self) { panel in
                let available = isPanelAvailable(panel, editing: editing)
                Button {
                    selectedPanel = panel
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: panel.icon)
                            .font(.system(size: 14, weight: .medium))
                            .frame(height: 16)
                        Text(LocalizedStringKey(panel.rawValue))
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedPanel == panel ? DesignColors.primaryLabel : DesignColors.secondaryLabel)
                    .frame(width: 40, height: 40)
                    .background(selectedPanel == panel ? DesignColors.inputBackground : .clear, in: RoundedRectangle(cornerRadius: CornerRadius.lg))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!available)
                .hoverHelp(editBusyReason ?? (!available
                    ? "Cursor editing requires pointer data from a ScreenTake recording."
                    : nil))
                .opacity(available ? 1 : 0.38)
                .localizedAccessibilityLabel(panel.rawValue)
                .accessibilityAddTraits(selectedPanel == panel ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Button {
                isShowingAppSettings = true
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .frame(height: 18)
                    Text("Settings")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(DesignColors.secondaryLabel)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .localizedAccessibilityLabel("Settings")
            .accessibilityIdentifier("appSettingsButton")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.lg)
        .frame(width: 56)
        .background(DesignColors.controlBackground.opacity(0.5))
    }

    private func isPanelAvailable(_ panel: SettingsPanel, editing: Bool) -> Bool {
        guard editing else { return true }
        switch panel {
        case .canvas: return true
        case .cursor: return session.mouseURL != nil
        case .camera, .audio: return true
        case .output: return true
        }
    }

    @ViewBuilder
    private var editPanelContent: some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            switch selectedPanel {
            case .canvas:
                settingsSection("Canvas") {
                    ratioPicker(selection: $session.draft.ratio)
                    deviceLayoutPicker(selection: $session.draft.layout)
                    if !session.draft.layout.isPhone {
                        desktopCornerRadiusSlider(selection: $session.draft.desktopCornerRadius)
                    }
                    if session.draft.layout.isPhone {
                        Picker("Content", selection: $session.draft.phoneMode) {
                            ForEach(PhoneContentMode.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    cropScreenButton
                    browserToolbarCropControl
                }
                Divider()
                settingsSection("Background") {
                    if session.draft.ratio == .original && session.draft.layout == .desktop {
                        settingsToggle(icon: "photo", label: "Background", isOn: $session.draft.backgroundEnabled)
                    }
                    if session.draft.backgroundEnabled || session.draft.ratio != .original || session.draft.layout != .desktop {
                        wallpaperGrid
                    }
                }
            case .cursor:
                settingsSection("Cursor") {
                    settingsToggle(icon: "cursorarrow", label: "Show Cursor", isOn: $session.draft.showCursor)
                    if session.draft.showCursor {
                        cursorShapePicker(selection: $session.draft.cursorShape)
                        cursorSizeSlider(selection: $session.draft.cursorScale)
                    }
                }
                Divider()
                settingsSection("Zoom") {
                    settingsToggle(icon: "plus.magnifyingglass", label: "Zoom", isOn: $session.draft.zoomEnabled)
                    if session.draft.zoomEnabled {
                        zoomLevelSlider(selection: $session.draft.zoomLevel)
                        if let selectedZoom, session.mouseURL != nil {
                            zoomFocusControls(selectedZoom)
                        }
                    }
                }
            case .camera:
                settingsSection("Camera") {
                    beautyControls(amount: Binding(get: { sessionBeautyAmount }, set: { session.draft.faceBeautyAmount = $0 }))
                    makeupControls(settings: Binding(get: { session.draft.faceMakeup ?? .init() }, set: { session.draft.faceMakeup = $0 }))
                        .disabled(videoOverlayRecorder.isBusy)
                    VStack(alignment: .leading, spacing: Spacing.labelToControl) {
                        Text("Place the playhead, then record a camera take while your video plays.")
                            .font(Typography.caption)
                            .foregroundStyle(DesignColors.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                        if videoOverlayRecorder.isBusy {
                            if videoOverlayRecorder.session != nil, let recorder = videoOverlayRecorder.camera {
                                BeautyCameraFeedView(recorder: recorder, amount: sessionBeautyAmount, makeup: session.draft.faceMakeup ?? .init())
                                    .frame(height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
                            }
                            HStack(spacing: 8) {
                                if videoOverlayRecorder.isRecording {
                                    Circle().fill(.red).frame(width: 8, height: 8)
                                } else { ProgressView().controlSize(.small) }
                                Text(LocalizedStringKey(videoOverlayRecorder.isRecording
                                     ? String(format: AppLanguage.text("Recording  %.1fs"), locale: AppLanguage.current.locale, videoOverlayRecorder.elapsed)
                                     : (videoOverlayRecorder.isFinishing ? "Saving camera take…" : "Preparing camera…")))
                                    .font(Typography.caption).monospacedDigit()
                            }
                            HStack(spacing: Spacing.labelToControl) {
                                Button("Stop & Keep") { videoOverlayRecorder.stop() }
                                    .buttonStyle(CompactActionButtonStyle(prominent: true))
                                    .disabled(!videoOverlayRecorder.isRecording)
                                    .hoverHelp(videoOverlayRecorder.isRecording ? "Stop and keep the camera recording." : videoOverlayRecorder.isFinishing ? "Wait for the camera recording to finish saving." : "Wait for the camera recording to start.")
                                Button("Cancel") { videoOverlayRecorder.cancel() }
                                    .buttonStyle(CompactActionButtonStyle())
                            }
                        } else {
                            webcamDevicePicker
                                .localizedAccessibilityLabel("Camera device")
                            VStack(alignment: .leading, spacing: Spacing.labelToControl) {
                                Button { startVideoOverlay() } label: { Label("Record Video", systemImage: "video.fill") }
                                    .buttonStyle(CompactActionButtonStyle())
                                    .disabled(!previewReady || editedVideoDuration <= 0)
                                    .hoverHelp(!previewReady ? (cropDisabledReason ?? "Wait for the video preview to finish loading.") : editedVideoDuration <= 0 ? "Keep a video section before recording camera video." : "Record camera video over the current timeline.")
                                Button { openVideoOverlayPanel() } label: { Label("Import Video…", systemImage: "video.badge.plus") }
                                    .buttonStyle(CompactActionButtonStyle())
                            }
                            Text("Camera video only. Add narration in Voiceover.")
                                .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                        }
                        if let error = videoOverlayRecorder.error {
                            Text(LocalizedStringKey(error)).font(Typography.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let overlay = editableVideoOverlayURL {
                        Divider()
                        EditorTakeRow(title: overlay.lastPathComponent, start: session.draft.videoOverlayTiming?.start ?? 0,
                                      end: session.draft.videoOverlayTiming.map { $0.start + $0.duration } ?? editedVideoDuration,
                                      isSelected: session.isVideoOverlaySelected, removeLabel: "Remove camera take", select: {
                            videoPlayer?.pause()
                            session.selectedVoiceOverID = nil
                            session.selectedZoomID = nil
                            session.isVideoOverlaySelected = true
                        }, remove: {
                            videoPlayer?.pause()
                            session.beginUndoGroup()
                            defer { session.endUndoGroup() }
                            session.draft.videoOverlayURL = nil
                            session.draft.videoOverlayTiming = nil
                            session.draft.webcamEnabled = false
                            session.isVideoOverlaySelected = false
                        })
                        .hoverHelp(videoOverlayRecorder.isBusy ? "Finish or cancel the camera recording before replacing its video." : overlay.lastPathComponent)
                        .accessibilityIdentifier("cameraTakeRow")
                        .disabled(videoOverlayRecorder.isBusy)
                        settingsToggle(icon: "video.fill", label: "Show Camera", isOn: $session.draft.webcamEnabled)
                            .disabled(videoOverlayRecorder.isBusy)
                            .hoverHelp(videoOverlayRecorder.isBusy ? "Finish or cancel the camera recording before changing its visibility." : nil)
                        if session.draft.webcamEnabled {
                            Group {
                                cameraLayoutControls
                                if currentCameraLayout.layout == .overlay {
                                    webcamShapePicker(selection: $session.draft.webcamShape)
                                    webcamPositionPicker(selection: $session.draft.webcamPosition)
                                    webcamSizePicker(selection: $session.draft.webcamSize)
                                } else {
                                    cameraFramingControls
                                }
                            }.disabled(videoOverlayRecorder.isBusy)
                                .hoverHelp(videoOverlayRecorder.isBusy ? "Finish or cancel the camera recording before editing its appearance." : nil)
                        }
                    }
                }
            case .audio:
                EditorAudioPanel(settings: $session.draft, selectedClip: $session.selectedVoiceOverID,
                                 recorder: voiceOverRecorder,
                                 microphoneDeviceID: Binding(
                                    get: { appState.capture.selectedMicrophoneDeviceID },
                                    set: { appState.capture.selectedMicrophoneDeviceID = $0 }
                                 ), microphones: appState.capture.availableMicrophones,
                                 duration: editedVideoDuration,
                                 hasOriginalAudio: hasEditableAudio,
                                 startRecording: startVoiceOver, importAudio: openVoiceOverPanel)
            case .output:
                settingsSection("Output") {
                    exportResolutionPicker(selection: $session.draft.exportResolution)
                    if let sourceVideoSize {
                        exportSizeDetails(settings: session.draft, source: sourceVideoSize)
                    }
                    Text("Zoom enlarges part of the recording and may still soften fine detail.")
                        .font(Typography.caption)
                        .foregroundStyle(DesignColors.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func zoomFocusControls(_ segment: ZoomSegment) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(LocalizedStringKey(String(format: AppLanguage.text("Zoom at %.1fs"), locale: AppLanguage.current.locale, segment.start)))
                .foregroundStyle(DesignColors.primaryLabel)
            if let focusFrame {
                GeometryReader { geometry in
                    let aspect = CGFloat(focusFrame.width) / CGFloat(focusFrame.height)
                    let imageWidth = min(geometry.size.width, geometry.size.height * aspect)
                    let imageHeight = imageWidth / aspect
                    let padding = Double(session.zoomPadding)
                    Image(decorative: focusFrame, scale: 1)
                        .resizable().frame(width: imageWidth, height: imageHeight)
                        .overlay {
                            Image(systemName: "scope")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white)
                                .shadow(color: .black, radius: 2)
                                .position(x: imageWidth * (padding + (1 - 2 * padding) * segment.centerX),
                                          y: imageHeight * (padding + (1 - 2 * padding) * segment.centerY))
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                if !editingZoomFocus { session.beginUndoGroup(); editingZoomFocus = true }
                                let contentScale = max(0.001, 1 - 2 * padding)
                                let x = min(1, max(0, (gesture.location.x / imageWidth - padding) / contentScale))
                                let y = min(1, max(0, (gesture.location.y / imageHeight - padding) / contentScale))
                                updateZoomFocus { $0.centerX = x; $0.centerY = y; $0.followsCursor = false }
                            }
                            .onEnded { _ in session.endUndoGroup(); editingZoomFocus = false })
                }
                .frame(height: 176)
                .localizedAccessibilityLabel("Drag to position zoom focus")
            }
            Picker("Focus", selection: Binding(get: { segment.followsCursor }, set: { value in
                updateZoomFocus { $0.followsCursor = value }
            })) {
                Text("Manual").tag(false)
                Text("Follow Cursor").tag(true)
            }.pickerStyle(.segmented)
        }
        .task(id: segment.id) {
            focusFrame = nil
            guard let source = layoutSourceURL else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 540, height: 300)
            if let image = try? await generator.image(at: CMTime(seconds: min(sourceDuration, segment.start + 0.3), preferredTimescale: 60000)), !Task.isCancelled {
                focusFrame = image.image
            }
        }
    }

    private var editActions: some View {
        VStack(spacing: 10) {
            Button { Task { await applyLayout() } } label: {
                Label("Apply Changes", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CompactActionButtonStyle(size: .medium))
            .disabled(!hasEditChanges || !hasValidTimeline || editsBusy || appState.updates.isPresenting)
            .hoverHelp(applyDisabledReason ?? "Render the video with your current edits.")
            .accessibilityIdentifier("applyVideoChanges")
            Button {
                if let videoURL { presentSavePanel(for: videoURL) }
            } label: {
                Label(isSaving ? "Downloading..." : "Download", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CompactActionButtonStyle(prominent: true, size: .medium))
            .keyboardShortcut("s", modifiers: .command)
            .disabled(videoURL == nil || !hasValidTimeline || editsBusy)
            .hoverHelp(downloadDisabledReason ?? "Save the finished video to a file.")
            .accessibilityIdentifier("downloadVideo")
        }
        .padding(Spacing.lg)
        .background(DesignColors.controlBackground)
    }

    @ViewBuilder
    private var capturePanelContent: some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            switch selectedPanel {
            case .canvas:
                settingsSection("Canvas") {
                    ratioPicker(selection: Binding(
                        get: { appState.capture.canvasRatio },
                        set: { appState.capture.canvasRatio = $0 }
                    ))
                    deviceLayoutPicker(selection: Binding(
                        get: { appState.capture.deviceLayout },
                        set: { appState.capture.deviceLayout = $0 }
                    ))
                    if !appState.capture.deviceLayout.isPhone {
                        desktopCornerRadiusSlider(selection: Binding(
                            get: { appState.capture.desktopCornerRadius },
                            set: { appState.capture.desktopCornerRadius = $0 }
                        ))
                    }
                    if appState.capture.deviceLayout.isPhone {
                        Picker("Content", selection: Binding(
                            get: { appState.capture.phoneContentMode },
                            set: { appState.capture.phoneContentMode = $0 }
                        )) {
                            ForEach(PhoneContentMode.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    cropScreenButton
                    browserToolbarCropControl
                }
                Divider()
                settingsSection("Background") { wallpaperGrid }
            case .cursor:
                settingsSection("Cursor") {
                    settingsToggle(icon: "cursorarrow", label: "Show Cursor", isOn: Binding(
                        get: { appState.capture.showCursor },
                        set: { appState.capture.showCursor = $0 }
                    ))
                    if appState.capture.showCursor {
                        cursorShapePicker(selection: Binding(
                            get: { appState.capture.cursorShape },
                            set: { appState.capture.cursorShape = $0 }
                        ))
                        cursorSizeSlider(selection: Binding(
                            get: { appState.capture.cursorScale },
                            set: { appState.capture.cursorScale = $0 }
                        ))
                    }
                    settingsToggle(icon: "circle.circle", label: "Highlight Clicks", isOn: Binding(
                        get: { appState.capture.highlightClicks },
                        set: { appState.capture.highlightClicks = $0 }
                    ))
                    if appState.capture.highlightClicks {
                        clickHighlightColorPicker(selection: Binding(
                            get: { appState.capture.clickHighlightColor },
                            set: { appState.capture.clickHighlightColor = $0 }
                        ))
                    }
                }
                Divider()
                settingsSection("Zoom") {
                    settingsToggle(icon: "plus.magnifyingglass", label: "Auto Zoom", isOn: Binding(
                        get: { appState.capture.autoZoomEnabled },
                        set: { appState.capture.autoZoomEnabled = $0 }
                    ))
                }
            case .camera:
                settingsSection("Camera") {
                    settingsToggle(icon: "video.fill", label: "Webcam Overlay", isOn: Binding(
                        get: { appState.capture.isWebcamEnabled },
                        set: { appState.capture.isWebcamEnabled = $0 }
                    ))
                    if appState.capture.isWebcamEnabled {
                        Text(LocalizedStringKey(appState.capture.isMicrophoneEnabled
                             ? "Microphone is on. Manage it in Audio."
                             : "Microphone is off. Manage it in Audio."))
                            .font(Typography.caption)
                            .foregroundStyle(DesignColors.secondaryLabel)
                        webcamDevicePicker
                        webcamShapePicker(selection: Binding(
                            get: { appState.capture.webcamPiPShape },
                            set: { appState.capture.webcamPiPShape = $0 }
                        ))
                        webcamPositionPicker(selection: Binding(
                            get: { appState.capture.webcamPiPPosition },
                            set: { appState.capture.webcamPiPPosition = $0 }
                        ))
                        webcamSizePicker(selection: Binding(
                            get: { appState.capture.webcamPiPSize },
                            set: { appState.capture.webcamPiPSize = $0 }
                        ))
                        beautyControls(amount: Binding(get: { appState.capture.faceBeautyAmount },
                                                       set: { appState.capture.faceBeautyAmount = $0 }))
                        makeupControls(settings: Binding(get: { appState.capture.faceMakeup }, set: { appState.capture.faceMakeup = $0 }))
                        Divider()
                        Button {
                            if isShowingCameraPreview {
                                stopCameraPreview()
                            } else {
                                isShowingCameraPreview = true
                                cameraPreview.start(device: appState.capture.selectedWebcamDevice)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "video")
                                    .font(.system(size: 11))
                                Text(LocalizedStringKey(isShowingCameraPreview ? "Stop Preview" : "Preview Camera"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CompactActionButtonStyle())
                        .accessibilityIdentifier("previewCamera")
                        .hoverHelp("Show your live camera in the recording preview.")
                        if let error = cameraPreview.errorMessage {
                            Text(LocalizedStringKey(error))
                                .font(Typography.caption)
                                .foregroundStyle(DesignColors.secondaryLabel)
                            if cameraPreview.needsPermission {
                                Button("Camera Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(CompactActionButtonStyle())
                            }
                        }
                    }
                }
            case .audio:
                settingsSection("Audio") {
                    settingsToggle(icon: "mic.fill", label: "Microphone", isOn: Binding(
                        get: { appState.capture.isMicrophoneEnabled },
                        set: { appState.capture.isMicrophoneEnabled = $0 }
                    ))
                    if appState.capture.isMicrophoneEnabled { microphonePicker }
                    settingsToggle(icon: "speaker.wave.2.fill", label: "System Audio", isOn: Binding(
                        get: { appState.capture.isSystemAudioEnabled },
                        set: { appState.capture.isSystemAudioEnabled = $0 }
                    ))
                }
            case .output:
                settingsSection("Output") {
                    frameRatePicker
                    exportResolutionPicker(selection: Binding(
                        get: { appState.capture.exportResolution },
                        set: { appState.capture.exportResolution = $0 }
                    ))
                    if let target = appState.capture.selectedTarget {
                        let configuration = CaptureConfiguration.forTarget(target)
                        exportSizeDetails(settings: VideoEditSettings(
                            ratio: appState.capture.canvasRatio,
                            layout: appState.capture.deviceLayout,
                            backgroundEnabled: target.isWindow || appState.capture.usesCanvas,
                            phoneMode: appState.capture.phoneContentMode,
                            exportResolution: appState.capture.exportResolution),
                            source: CGSize(width: configuration.width, height: configuration.height))
                    }
                }
            }
        }
        .disabled(isExporting || isSaving || appState.isRecording || appState.recording.processingStage != nil)
    }

    // MARK: - Settings Components

    private var cameraSourceTime: Double? {
        let time = CMTime(seconds: cameraLayoutPlayback.seconds, preferredTimescale: 60000)
        if let timing = session.draft.videoOverlayTiming {
            return timing.sampleTime(at: time.seconds)?.seconds
        }
        return renderedPreviewTimeline?.sourceTime(at: time).seconds
    }

    private var cameraLayoutChangeIndex: Int? {
        guard let time = cameraSourceTime else { return nil }
        return session.draft.cameraLayoutChanges.indices.filter { session.draft.cameraLayoutChanges[$0].start <= time + 0.0001 }
            .max { session.draft.cameraLayoutChanges[$0].start < session.draft.cameraLayoutChanges[$1].start }
    }

    private var sessionBeautyAmount: Double { FaceBeautyFilter.clamped(session.draft.faceBeautyAmount ?? 0) }

    private func beautyControls(amount: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            settingsToggle(icon: "sparkles", label: "Natural", isOn: Binding(
                get: { amount.wrappedValue > 0 },
                set: { amount.wrappedValue = $0 ? 0.5 : 0 }
            ))
            .accessibilityIdentifier("faceBeautyEnabled")
            if amount.wrappedValue > 0 {
                HStack {
                    Text("Intensity").font(Typography.caption)
                    Spacer()
                    Text(amount.wrappedValue, format: .percent.precision(.fractionLength(0)))
                        .font(Typography.caption).monospacedDigit().foregroundStyle(DesignColors.secondaryLabel)
                }
                primarySlider(selection: amount, range: 0.05...1, label: "Beauty intensity",
                              value: "\(Int(amount.wrappedValue * 100))%")
                    .accessibilityIdentifier("faceBeautyIntensity")
                Text("Softens skin and fine lines while tracking visible facial features. Fades out when tracking is lost.")
                    .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func makeupControls(settings: Binding<FaceMakeupSettings>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            settingsToggle(icon: "paintbrush.pointed", label: "Peach Makeup", isOn: Binding(
                get: { settings.wrappedValue.amount > 0 },
                set: { settings.wrappedValue.amount = $0 ? 0.7 : 0 }
            ))
            .accessibilityIdentifier("faceMakeupEnabled")
            if settings.wrappedValue.amount > 0 {
                makeupSlider("Intensity", key: \.amount, settings: settings, minimum: 0.05)
                DisclosureGroup("Customize makeup") {
                    VStack(spacing: Spacing.labelToControl) {
                        makeupSlider("Skin & fine lines", key: \.skin, settings: settings)
                        makeupSlider("Face definition", key: \.definition, settings: settings)
                        makeupSlider("Eyelashes", key: \.lashes, settings: settings)
                        makeupSlider("Eyebrows", key: \.brows, settings: settings)
                        makeupSlider("Peach blush", key: \.blush, settings: settings)
                        makeupSlider("Overlined lips", key: \.lips, settings: settings)
                        makeupSlider("Eyeshadow", key: \.eyeshadow, settings: settings)
                        makeupSlider("Under-eye shadow", key: \.underEyeShadow, settings: settings)
                        makeupSlider("Under-eye fullness · 애굣살", key: \.aegyo, settings: settings)
                        makeupSlider("Nose & chin contour", key: \.contour, settings: settings)
                        makeupSlider("Shorter face", key: \.shortening, settings: settings)
                    }.padding(.top, Spacing.labelToControl)
                }
                Text("Soft peach makeup that follows your face. Face shortening eases off as you turn sideways.")
                    .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func makeupSlider(_ title: String, key: WritableKeyPath<FaceMakeupSettings, Double>,
                              settings: Binding<FaceMakeupSettings>, minimum: Double = 0) -> some View {
        let value = Binding(get: { settings.wrappedValue[keyPath: key] }, set: { settings.wrappedValue[keyPath: key] = $0 })
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(LocalizedStringKey(title)).font(Typography.caption)
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .font(Typography.caption).monospacedDigit().foregroundStyle(DesignColors.secondaryLabel)
            }
            primarySlider(selection: value, range: minimum...1, label: title,
                          value: "\(Int(value.wrappedValue * 100))%")
        }
    }

    private var currentCameraLayout: CameraLayoutSettings {
        cameraLayoutChangeIndex.map { session.draft.cameraLayoutChanges[$0].settings } ?? session.draft.cameraLayout
    }

    private var canTransitionCameraSection: Bool {
        guard let index = cameraLayoutChangeIndex else { return false }
        return CameraLayoutChange.canTransition(into: session.draft.cameraLayoutChanges[index],
                                                initial: session.draft.cameraLayout, changes: session.draft.cameraLayoutChanges)
    }

    private func updateCameraLayout(_ change: (inout CameraLayoutSettings) -> Void) {
        videoPlayer?.pause()
        if let index = cameraLayoutChangeIndex { change(&session.draft.cameraLayoutChanges[index].settings) }
        else { change(&session.draft.cameraLayout) }
    }

    private var cameraLayoutControls: some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            cameraSettingLabel("Layout", symbol: "rectangle.on.rectangle")
            Picker("Camera layout", selection: Binding(
                get: { currentCameraLayout.layout },
                set: { layout in updateCameraLayout { $0.layout = layout } }
            )) {
                ForEach(CameraLayout.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("cameraLayout")
            cameraTransitionControls
            settingsToggle(icon: "viewfinder", label: "Follow face", isOn: Binding(
                get: { currentCameraLayout.followFace },
                set: { enabled in updateCameraLayout { $0.followFace = enabled } }
            ), isProcessing: currentCameraLayout.followFace && session.isPreparingFaceTracking)
            .accessibilityIdentifier("cameraFollowFace")
            if currentCameraLayout.followFace {
                Text(LocalizedStringKey(session.isPreparingFaceTracking
                     ? "Preparing face tracking… Longer clips may take a moment."
                     : "Gently crops to follow one face. If no face is visible, your framing is kept."))
                    .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(LocalizedStringKey(session.draft.cameraLayoutChanges.isEmpty
                 ? "Applies to the entire camera clip."
                 : "Applies to the camera section at the playhead."))
                .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cameraTransitionControls: some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            settingsToggle(icon: "arrow.up.left.and.arrow.down.right", label: "Smooth Transition", isOn: Binding(
                get: { canTransitionCameraSection && currentCameraLayout.smoothTransition },
                set: { enabled in updateCameraLayout { $0.smoothTransition = enabled } }
            ), disabledReason: !canTransitionCameraSection
                ? (cameraLayoutChangeIndex == nil
                    ? (session.draft.cameraLayoutChanges.isEmpty
                        ? "Split the camera clip, then change the next section’s layout or framing to enable Smooth Transition."
                        : "Select a later camera section. Smooth Transition applies at its start, from the previous section.")
                    : "Change this camera section’s layout or framing to enable Smooth Transition.")
                : nil)
            .accessibilityIdentifier("cameraSmoothTransition")
            if canTransitionCameraSection && currentCameraLayout.smoothTransition {
                VStack(alignment: .leading, spacing: Spacing.labelToControl) {
                    HStack {
                        cameraSettingLabel("Duration", symbol: "clock")
                        Spacer()
                        Text(LocalizedStringKey(String(format: "%.2g s", currentCameraLayout.clampedTransitionDuration)))
                            .font(Typography.caption).monospacedDigit()
                            .foregroundStyle(DesignColors.secondaryLabel)
                    }
                    primarySlider(selection: Binding(
                        get: { currentCameraLayout.clampedTransitionDuration },
                        set: { value in updateCameraLayout { $0.transitionDuration = (value * 100).rounded() / 100 } }
                    ), range: 0.1...2, label: "Camera transition duration",
                       value: String(format: "%.2g seconds", currentCameraLayout.clampedTransitionDuration))
                    .accessibilityIdentifier("cameraTransitionDuration")
                }
                VStack(alignment: .leading, spacing: Spacing.labelToControl) {
                    cameraSettingLabel("Motion", symbol: "waveform.path")
                    Picker("Transition motion", selection: Binding(
                        get: { currentCameraLayout.transitionMotion },
                        set: { motion in updateCameraLayout { $0.transitionMotion = motion } }
                    )) {
                        ForEach(CameraTransitionMotion.allCases, id: \.self) { motion in
                            Text(LocalizedStringKey(motion.displayName)).tag(motion)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("cameraTransitionMotion")
                }
                Text("Applies at the start of this camera section. Short sections use a shorter transition.")
                    .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cameraSettingLabel(_ title: String, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(DesignColors.secondaryLabel)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .font(Typography.body)
                .foregroundStyle(DesignColors.primaryLabel)
        }
    }

    private func cameraFramingBinding(_ keyPath: WritableKeyPath<CameraLayoutSettings, Double>) -> Binding<Double> {
        Binding(get: { currentCameraLayout[keyPath: keyPath] },
                set: { value in updateCameraLayout { $0[keyPath: keyPath] = value } })
    }

    private var cameraFramingControls: some View {
        VStack(alignment: .leading, spacing: Spacing.featureGap) {
            VStack(alignment: .leading, spacing: Spacing.labelToControl) {
                HStack {
                    cameraSettingLabel("Zoom", symbol: "plus.magnifyingglass")
                    Spacer()
                    NumericSettingInput(value: Binding(
                        get: { Int((currentCameraLayout.zoom * 100).rounded()) },
                        set: { value in updateCameraLayout { $0.zoom = Double(value) / 100 } }
                    ), range: 100...300, unit: "%", label: "Camera zoom in percent")
                }
                primarySlider(selection: cameraFramingBinding(\.zoom), range: 1...3,
                              label: "Camera zoom", value: "\(Int((currentCameraLayout.zoom * 100).rounded()))%")
            }
            cameraFramingSlider("Horizontal Framing", symbol: "arrow.left.and.right", keyPath: \.centerX)
                .disabled(currentCameraLayout.followFace)
                .hoverHelp(editBusyReason ?? (currentCameraLayout.followFace ? "Turn off Follow face to adjust framing manually." : "Adjust camera framing."))
            cameraFramingSlider("Vertical Framing", symbol: "arrow.up.and.down", keyPath: \.centerY)
                .disabled(currentCameraLayout.followFace)
                .hoverHelp(editBusyReason ?? (currentCameraLayout.followFace ? "Turn off Follow face to adjust framing manually." : "Adjust camera framing."))
            Button {
                updateCameraLayout { $0.zoom = 1; $0.centerX = 0.5; $0.centerY = 0.5 }
            } label: {
                Label("Reset Framing", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(CompactActionButtonStyle())
        }
    }

    private func cameraFramingSlider(_ title: String, symbol: String,
                                     keyPath: WritableKeyPath<CameraLayoutSettings, Double>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            cameraSettingLabel(title, symbol: symbol)
            primarySlider(selection: cameraFramingBinding(keyPath), range: 0...1,
                          label: "Camera \(title.lowercased())",
                          value: "\(Int((currentCameraLayout[keyPath: keyPath] * 100).rounded()))%")
        }
    }

    private var browserToolbarCropControl: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Toggle(isOn: Binding(
                get: { session.draft.isBrowserToolbarHidden || session.isDetectingBrowser },
                set: { hidden in Task { await session.setBrowserToolbarHidden(hidden) } }
            )) {
                HStack {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 13))
                        .foregroundColor(DesignColors.secondaryLabel)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text("Hide Browser Toolbar")
                        .font(Typography.body)
                        .foregroundColor(DesignColors.primaryLabel)
                    Spacer()
                }
            }
            .toggleStyle(.switch)
            .tint(DesignColors.accent)
            .frame(minHeight: ControlMetrics.actionHeight)
            .disabled(phoneCropSource == nil || !previewReady || editsBusy)
            .hoverHelp(cropDisabledReason ?? (session.draft.isBrowserToolbarHidden
                ? "Turn off to restore your previous crop."
                : "Detect and hide the toolbar in Edge, Chrome, or Safari videos."))
            if session.isDetectingBrowser {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Detecting Browser…").font(Typography.caption)
                }
                .foregroundColor(DesignColors.secondaryLabel)
            }
            if let message = session.browserCropMessage {
                Text(LocalizedStringKey(message))
                    .font(Typography.caption)
                    .foregroundColor(DesignColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cropScreenButton: some View {
        Button {
            guard !editsBusy, previewReady, let player = videoPlayer else { return }
            player.pause()
            cropFrameTime = renderedPreviewTimeline?.sourceTime(at: player.currentTime()) ?? .zero
            isCroppingScreen = true
        } label: { Label("Crop Screen", systemImage: "crop") }
        .buttonStyle(CompactActionButtonStyle())
        .disabled(phoneCropSource == nil || !previewReady || editsBusy)
        .hoverHelp(cropDisabledReason ?? "Adjust the crop directly in the preview.")
    }

    private func stopCameraPreview() {
        isShowingCameraPreview = false
        cameraPreview.stop()
    }

    private func deviceLayoutPicker(selection: Binding<DeviceLayout>) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.sm) {
            ForEach(DeviceLayout.allCases, id: \.self) { layout in
                Button {
                    selection.wrappedValue = layout
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: layout.symbol)
                            .font(.system(size: 19))
                            .frame(height: 22)
                        Text(LocalizedStringKey(layout.displayName)).font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(selection.wrappedValue == layout ? DesignColors.accent.opacity(0.25) : DesignColors.controlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection.wrappedValue == layout ? DesignColors.accent : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .hoverHelp(editBusyReason)
                .localizedAccessibilityLabel("\(layout.displayName) layout")
                .accessibilityAddTraits(selection.wrappedValue == layout ? .isSelected : [])
            }
        }
    }

    private func cursorShapePicker(selection: Binding<CursorShape>) -> some View {
        HStack(spacing: Spacing.sm) {
            ForEach(CursorShape.allCases, id: \.self) { shape in
                Button {
                    selection.wrappedValue = shape
                } label: {
                    Group {
                        if let image = CursorImageProvider.nsImage(width: 18, shape: shape) {
                            Image(nsImage: image)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(selection.wrappedValue == shape ? DesignColors.accent.opacity(0.25) : DesignColors.controlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection.wrappedValue == shape ? DesignColors.accent : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .hoverHelp(editBusyReason)
                .localizedAccessibilityLabel("\(shape.displayName) cursor")
                .accessibilityAddTraits(selection.wrappedValue == shape ? .isSelected : [])
            }
        }
    }

    private func clickHighlightColorPicker(selection: Binding<ClickHighlightColor>) -> some View {
        HStack(spacing: Spacing.sm) {
            ForEach(ClickHighlightColor.allCases, id: \.self) { highlightColor in
                Button {
                    selection.wrappedValue = highlightColor
                } label: {
                    Circle()
                        .fill(highlightColor.color)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                        .overlay {
                            if selection.wrappedValue == highlightColor {
                                Circle().stroke(DesignColors.accent, lineWidth: 2)
                                    .padding(-4)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.plain)
                .hoverHelp(editBusyReason)
                .localizedAccessibilityLabel("\(highlightColor.displayName) click highlight")
                .accessibilityAddTraits(selection.wrappedValue == highlightColor ? .isSelected : [])
            }
        }
    }

    private func exportResolutionPicker(selection: Binding<ExportResolution>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Picker("Resolution", selection: selection) {
                ForEach(ExportResolution.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("exportResolution")
            .hoverHelp(editBusyReason)
            Text(LocalizedStringKey(selection.wrappedValue == .preserveSource
                 ? "Keeps screen detail by allowing room for the background. Larger files."
                 : "Sets canvas size independently of its shape. Screen content may be reduced."))
                .font(Typography.caption)
                .foregroundStyle(DesignColors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func exportSizeDetails(settings: VideoEditSettings, source: CGSize) -> some View {
        let output = settings.outputSize(source: source)
        let content = settings.crop.pixelRect(in: source).size
        let scale = ExportResolution.contentScale(source: content, output: output, layout: settings.layout,
                                                 usesCanvas: settings.usesCanvas, phoneMode: settings.phoneMode)
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("\(Int(output.width)) × \(Int(output.height)) pixels")
                .font(Typography.body).monospacedDigit()
            Text(LocalizedStringKey(scale < 0.999
                 ? "Screen detail reduced to \(Int((scale * 100).rounded()))% of source size before zoom."
                 : "Screen detail preserved before zoom."))
                .font(Typography.caption)
                .foregroundStyle(DesignColors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ratioPicker(selection: Binding<CanvasRatio>) -> some View {
        HStack(spacing: Spacing.labelToControl) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 13))
                    .foregroundColor(DesignColors.secondaryLabel)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text("Ratio")
                    .font(Typography.body)
                    .foregroundColor(DesignColors.primaryLabel)
            }
            Picker("Ratio", selection: selection) {
                ForEach(CanvasRatio.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DesignColors.primaryLabel)

            VStack(alignment: .leading, spacing: Spacing.featureGap) {
                content()
            }
        }
    }

    private func settingsToggle(icon: String, label: String, isOn: Binding<Bool>,
                                isProcessing: Bool = false, disabledReason: String? = nil) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(DesignColors.secondaryLabel)
                    .frame(width: 20)
                Text(LocalizedStringKey(label))
                    .font(Typography.body)
                    .foregroundColor(DesignColors.primaryLabel)
                if isProcessing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .localizedAccessibilityLabel("Preparing face tracking")
                        .accessibilityIdentifier("faceTrackingProgress")
                }
                Spacer()
                ZStack {
                    Capsule()
                        .fill(isOn.wrappedValue ? DesignColors.accent : DesignColors.inputBorder)
                        .frame(width: 34, height: 20)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                        .offset(x: isOn.wrappedValue ? 7 : -7)
                }
                .animation(.easeInOut(duration: 0.15), value: isOn.wrappedValue)
            }
            .frame(minHeight: ControlMetrics.actionHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedAccessibilityLabel(label)
        .localizedAccessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .disabled(disabledReason != nil)
        .hoverHelp(editBusyReason ?? disabledReason)
    }

    private var microphonePicker: some View {
        MicrophoneDevicePicker(deviceID: Binding(
            get: { appState.capture.selectedMicrophoneDeviceID },
            set: { appState.capture.selectedMicrophoneDeviceID = $0 }
        ), devices: appState.capture.availableMicrophones)
    }

    private var frameRatePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            HStack {
                Image(systemName: "speedometer")
                    .font(.system(size: 13))
                    .foregroundColor(DesignColors.secondaryLabel)
                    .frame(width: 20)

                Text("Frame Rate")
                    .font(Typography.body)
                    .foregroundColor(DesignColors.primaryLabel)

                Spacer()
            }

            Picker("Frame Rate", selection: Binding(
                get: { appState.capture.captureFrameRate },
                set: { appState.capture.captureFrameRate = $0 }
            )) {
                Text("30 FPS").font(.system(size: 12, weight: .medium)).tag(30)
                Text("60 FPS").font(.system(size: 12, weight: .medium)).tag(60)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .hoverHelp(editBusyReason)
        }
        .accessibilityElement(children: .combine)
    }

    private func desktopCornerRadiusSlider(selection: Binding<Double>) -> some View {
        let source = videoURL == nil
            ? (appState.capture.selectedTarget.map {
                let configuration = CaptureConfiguration.forTarget($0)
                return CGSize(width: configuration.width, height: configuration.height)
            } ?? CGSize(width: 1440, height: 900))
            : (sourceVideoSize ?? CGSize(width: 1440, height: 900))
        let ratio = videoURL == nil ? appState.capture.canvasRatio : session.draft.ratio
        let layout = videoURL == nil ? appState.capture.deviceLayout : session.draft.layout
        let canvasSize = videoURL == nil
            ? appState.capture.exportResolution.size(source: source, ratio: ratio, layout: layout, usesCanvas: true)
            : session.draft.outputSize(source: source)
        let contentSource = videoURL == nil ? source : session.draft.crop.pixelRect(in: source).size
        let content = CanvasGeometry(size: canvasSize, layout: layout, sourceSize: contentSource).desktop
        let shortestSide = content.map { min($0.width, $0.height) } ?? 0
        let pixels = Int((shortestSide * selection.wrappedValue).rounded())
        let maximumPixels = Int((shortestSide * 0.1).rounded())
        let usesBackground = videoURL == nil || session.draft.backgroundEnabled || ratio != .original || layout != .desktop
        let help = editBusyReason ?? (!usesBackground
            ? "Turn on Background to adjust corner radius."
            : shortestSide <= 0 ? "Choose a desktop layout with visible screen content to adjust corner radius."
            : "Round the video corners inside the background.")
        return VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            HStack {
                Image(systemName: "rectangle.roundedtop")
                    .font(.system(size: 13))
                    .foregroundColor(DesignColors.secondaryLabel)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text("Corners")
                    .font(Typography.body)
                    .foregroundColor(DesignColors.primaryLabel)
                Spacer()
                NumericSettingInput(value: Binding(
                    get: { pixels },
                    set: { requestedPixels in
                        guard shortestSide > 0 else { return }
                        selection.wrappedValue = min(0.1, max(0, Double(requestedPixels) / Double(shortestSide)))
                    }
                ), range: 0...maximumPixels, unit: "px", label: "Corner radius in pixels", helpText: help)
                .disabled(shortestSide <= 0)
            }
            primarySlider(selection: selection, range: 0...0.1,
                          label: "Canvas content corner radius",
                          value: "\(pixels) pixels")
                .hoverHelp(help)
        }
        .disabled(!usesBackground || shortestSide <= 0)
        .opacity(usesBackground ? 1 : 0.45)
    }

    private func cursorSizeSlider(selection: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            HStack {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13))
                    .foregroundColor(DesignColors.secondaryLabel)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text("Size")
                    .font(Typography.body)
                    .foregroundColor(DesignColors.primaryLabel)
                Spacer()
                NumericSettingInput(value: Binding(
                    get: { Int((selection.wrappedValue * 100).rounded()) },
                    set: { selection.wrappedValue = Double($0) / 100 }
                ), range: 50...300, unit: "%", label: "Pointer size in percent")
            }
            primarySlider(selection: selection, range: 0.5...3.0,
                          label: "Cursor size",
                          value: "\(Int((selection.wrappedValue * 100).rounded()))%")
        }
    }

    private func primarySlider(selection: Binding<Double>, range: ClosedRange<Double>, label: String, value: String) -> some View {
        LineSlider(selection: selection, range: range, label: label, value: value)
            .hoverHelp(editBusyReason)
    }

    private func zoomLevelSlider(selection: Binding<Double>) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(DesignColors.tertiaryLabel)

            Slider(value: selection, in: 1.25...3, step: 0.25)
                .localizedAccessibilityLabel("Zoom magnification")
                .localizedAccessibilityValue("\(selection.wrappedValue.formatted(.number.precision(.fractionLength(0...2)))) times")

            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(DesignColors.secondaryLabel)

            Text("\(selection.wrappedValue.formatted(.number.precision(.fractionLength(0...2))))×")
                .font(Typography.monoSmall)
                .foregroundColor(DesignColors.secondaryLabel)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Webcam Controls

    private var webcamDevicePicker: some View {
        HStack {
            Picker("", selection: Binding(
                get: { appState.capture.selectedWebcamDeviceID },
                set: { appState.capture.selectedWebcamDeviceID = $0 }
            )) {
                Text("Default").tag("")
                ForEach(appState.capture.availableWebcams, id: \.uniqueID) { device in
                    Text(verbatim: device.localizedName).tag(device.uniqueID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func webcamShapePicker(selection: Binding<PiPShape>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            HStack {
                Image(systemName: "circle.square")
                    .font(.system(size: 13))
                    .foregroundColor(DesignColors.secondaryLabel)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text("Shape")
                    .font(Typography.body)
                    .foregroundColor(DesignColors.primaryLabel)
            }
            HStack(spacing: Spacing.sm) {
                ForEach(PiPShape.allCases, id: \.self) { shape in
                    Button {
                        selection.wrappedValue = shape
                    } label: {
                        Group {
                            switch shape {
                            case .circle:
                                Circle().fill(DesignColors.primaryLabel)
                            case .roundedSquare:
                                RoundedRectangle(cornerRadius: 4).fill(DesignColors.primaryLabel)
                            }
                        }
                        .frame(width: 18, height: 18)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(selection.wrappedValue == shape ? DesignColors.accent.opacity(0.25) : DesignColors.controlBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection.wrappedValue == shape ? DesignColors.accent : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .hoverHelp(editBusyReason)
                    .localizedAccessibilityLabel("\(shape.displayName) camera shape")
                    .accessibilityAddTraits(selection.wrappedValue == shape ? .isSelected : [])
                }
            }
        }
    }

    private func webcamPositionPicker(selection: Binding<PiPPosition>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            HStack {
                Image(systemName: "square.dashed.inset.filled")
                    .font(.system(size: 13))
                    .foregroundColor(DesignColors.secondaryLabel)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text("Position")
                    .font(Typography.body)
                    .foregroundColor(DesignColors.primaryLabel)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                ForEach(PiPPosition.allCases, id: \.self) { position in
                    Button {
                        selection.wrappedValue = position
                    } label: {
                        Circle()
                            .fill(selection.wrappedValue == position ? DesignColors.accent : DesignColors.secondaryLabel)
                            .frame(width: selection.wrappedValue == position ? 10 : 4,
                                   height: selection.wrappedValue == position ? 10 : 4)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(selection.wrappedValue == position ? DesignColors.accent.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHelp(editBusyReason)
                    .localizedAccessibilityLabel("\(position.displayName) camera position")
                    .accessibilityAddTraits(selection.wrappedValue == position ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
            .padding(5)
            .background(DesignColors.controlBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DesignColors.inputBorder, lineWidth: 1))
        }
    }

    private func webcamSizePicker(selection: Binding<PiPSize>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            HStack {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13))
                    .foregroundColor(DesignColors.secondaryLabel)
                    .frame(width: 20)
                Text("Size")
                    .font(Typography.body)
                    .foregroundColor(DesignColors.primaryLabel)
                Spacer()
            }
            Picker("Size", selection: selection) {
                ForEach(PiPSize.allCases, id: \.self) { size in
                    Text(LocalizedStringKey(size.displayName)).tag(size)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Wallpaper Grid

    private var wallpaperGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: Spacing.md),
            GridItem(.flexible(), spacing: Spacing.md),
            GridItem(.flexible(), spacing: Spacing.md),
        ]

        return LazyVGrid(columns: columns, spacing: Spacing.md) {
            ForEach(BackgroundStyle.WallpaperPreset.allCases, id: \.self) { preset in
                wallpaperTile(preset)
            }
        }
    }

    private func wallpaperTile(_ preset: BackgroundStyle.WallpaperPreset) -> some View {
        let isSelected = (videoURL == nil ? appState.capture.selectedWallpaper : session.draft.wallpaper) == preset

        return Button {
            if videoURL == nil { appState.capture.selectedWallpaper = preset }
            else { session.draft.wallpaper = preset }
        } label: {
            VStack(spacing: Spacing.sm) {
                wallpaperPreview(preset)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.sm)
                            .stroke(isSelected ? DesignColors.accent : DesignColors.inputBorder,
                                    lineWidth: isSelected ? 2 : 1)
                    )

                Text(LocalizedStringKey(preset.displayName))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isSelected ? DesignColors.primaryLabel : DesignColors.tertiaryLabel)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .localizedAccessibilityLabel("\(preset.displayName) background")
        .hoverHelp(editBusyReason)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func wallpaperPreview(_ preset: BackgroundStyle.WallpaperPreset) -> some View {
        if let imageName = preset.imageName {
            GeometryReader { geometry in
                Image(imageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        } else {
            let stops = preset.gradientColors
            LinearGradient(
                stops: stops.map { Gradient.Stop(color: $0.color.color, location: $0.location) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Video Preview Column

    private func videoPreviewColumn(url: URL) -> some View {
        VStack(spacing: 0) {
            // Close video bar
            HStack {
                Button {
                    session.close()
                    cameraLayoutPlayback.detach()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Close")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DesignColors.secondaryLabel)
                }
                .buttonStyle(.plain)
                .localizedAccessibilityLabel("Close video")
                .disabled(editsBusy)
                .hoverHelp(editBusyReason ?? "Close the current video.")

                Spacer()

                Text(verbatim: session.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DesignColors.primaryLabel)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, Spacing.lg)
            .frame(height: 36)
            .background(DesignColors.controlBackground.opacity(0.5))

            Divider()

            if isCroppingScreen, let source = phoneCropSource {
                InlineScreenCropEditor(sourceURL: source, sourceTime: cropFrameTime, initialCrop: session.draft.crop,
                                       onCancel: { isCroppingScreen = false }, onApply: { crop in
                    session.draft.crop = crop
                    isCroppingScreen = false
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let player = videoPlayer {
                NativeVideoPlayerView(player: player, showsControls: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if sourceDuration > 0, let player = videoPlayer, let source = layoutSourceURL {
                Divider()
                VideoTrimControls(trim: $session.draft.trim, zoomSegments: $session.draft.zoomSegments,
                                  zoomEnabled: session.draft.zoomEnabled, zoomLevel: session.draft.zoomLevel,
                                  mouse: session.mouseURL,
                                  duration: sourceDuration, player: player, source: source,
                                  audio: hasEditableAudio ? previewAudioURL : nil,
                                  voiceOvers: $session.draft.voiceOvers, selectedVoiceOverID: $session.selectedVoiceOverID,
                                  originalMuted: !session.draft.audioEnabled || session.draft.originalAudioVolume == 0,
                                  voiceOverMuted: !session.draft.voiceOverEnabled || session.draft.voiceOverVolume == 0,
                                  selectedZoomID: $session.selectedZoomID, automaticZooms: $session.automaticZooms,
                                  zoomPadding: $session.zoomPadding,
                                  videoOverlayURL: $session.draft.videoOverlayURL,
                                  videoOverlayTiming: $session.draft.videoOverlayTiming,
                                  videoOverlayEnabled: $session.draft.webcamEnabled,
                                  cameraLayout: session.draft.cameraLayout,
                                  cameraLayoutChanges: $session.draft.cameraLayoutChanges,
                                  isVideoOverlaySelected: $session.isVideoOverlaySelected,
                                  session: session)
                    .disabled(editsBusy)
                    .onChange(of: session.selectedRecordedAudioID) { id in
                        if id != nil { selectedPanel = .audio }
                    }
                    .onChange(of: session.selectedVoiceOverID) { id in
                        if id != nil { selectedPanel = .audio }
                    }
                    .onChange(of: session.selectedZoomID) { id in
                        if id != nil { selectedPanel = .cursor }
                    }
                    .onChange(of: session.isVideoOverlaySelected) { selected in
                        if selected { selectedPanel = .camera }
                    }
            }
            if let previewError {
                Text(LocalizedStringKey(previewError)).font(.caption).foregroundStyle(.red).padding(Spacing.md)
            }
        }
    }

    // MARK: - File Handling

    private func presentSavePanel(for source: URL) {
        guard !isShowingSavePanel, !isSaving else { return }
        let panel = NSSavePanel()
        panel.title = "Save Recording"
        panel.prompt = "Save"
        panel.allowedContentTypes = [UTType(filenameExtension: source.pathExtension) ?? .quickTimeMovie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = source == appState.recording.lastRecordingURL
            ? "ScreenTake Recording.\(source.pathExtension)" : source.lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        isShowingSavePanel = true
        videoPlayer?.pause()

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            isShowingSavePanel = false
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do { try await session.saveVideo(to: destination) }
                catch { session.saveError = error.localizedDescription }
            }
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: {
            $0.styleMask.contains(.titled) && $0.level == .normal && !($0 is NSPanel)
        }) {
            window.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func openVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            requestImport(url)
        }
    }

    private var hasUnsavedVideoWork: Bool { session.hasUnsavedWork }

    private func requestImport(_ url: URL) {
        requestOpen(url, project: false)
    }

    private func requestOpen(_ url: URL, project: Bool) {
        guard !editsBusy, pendingReplacement == nil, !appState.isConfirmingVideoReplacement else { return }
        let action: VideoReplacementAction = project ? .importProject(url) : .importVideo(url)
        if hasUnsavedVideoWork {
            videoPlayer?.pause()
            pendingReplacement = action
            Task { @MainActor in
                let approved = await appState.confirmVideoReplacement(action)
                pendingReplacement = nil
                if approved, !editsBusy { loadVideo(url, project: project) }
            }
        } else {
            loadVideo(url, project: project)
        }
    }

    private var editableVideoOverlayURL: URL? { session.draft.videoOverlayURL }

    private func startVideoOverlay() {
        guard !editsBusy, previewReady, let player = videoPlayer else {
            videoOverlayRecorder.error = "Wait for the video preview to finish loading, then try again."
            return
        }
        videoOverlayRecorder.start(player: player, device: appState.capture.selectedWebcamDevice,
                                   duration: editedVideoDuration) { url, timing in
            session.beginUndoGroup()
            defer { session.endUndoGroup() }
            session.draft.videoOverlayURL = url
            session.draft.videoOverlayTiming = timing
            session.draft.webcamEnabled = true
            session.draft.cameraLayout = CameraLayoutSettings()
            session.draft.cameraLayoutChanges = []
        }
    }

    private func openVideoOverlayPanel() {
        guard !editsBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Video Overlay"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let source = layoutSourceURL
            Task {
                do {
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration).seconds
                    guard duration.isFinite, duration > 0.05,
                          !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw ExportError.noVideoTrack }
                    guard source == layoutSourceURL, !editsBusy else { return }
                    session.beginUndoGroup()
                    defer { session.endUndoGroup() }
                    session.draft.videoOverlayURL = url
                    session.draft.videoOverlayTiming = VideoOverlayTiming(start: 0, duration: duration)
                    session.draft.webcamEnabled = true
                    session.draft.cameraLayout = CameraLayoutSettings()
                    session.draft.cameraLayoutChanges = []
                    videoOverlayRecorder.error = nil
                } catch { videoOverlayRecorder.error = error.localizedDescription }
            }
        }
    }

    private var editedVideoDuration: Double { session.editedDuration }

    private func startVoiceOver() {
        guard !editsBusy, previewReady, let player = videoPlayer else {
            voiceOverRecorder.error = "Wait for the video preview to finish loading, then try again."
            return
        }
        voiceOverRecorder.start(player: player, deviceID: appState.capture.selectedMicrophoneDeviceID,
                                duration: editedVideoDuration) { clip in
            session.beginUndoGroup()
            defer { session.endUndoGroup() }
            session.draft.voiceOvers.append(clip)
            session.draft.voiceOverEnabled = true
            session.selectedVoiceOverID = clip.id
        }
    }

    private func openVoiceOverPanel() {
        guard !editsBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Voiceover Audio"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let currentSource = layoutSourceURL
        let playhead = videoPlayer?.currentTime().seconds ?? 0
        let start = playhead.isFinite ? max(0, min(max(0, editedVideoDuration - 0.05), playhead)) : 0
        Task {
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0.05,
                      !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw CleanupError.noAudio }
                guard currentSource == layoutSourceURL, !editsBusy else { return }
                let clip = VoiceOverClip(url: url, start: start, duration: duration, sourceDuration: duration)
                session.beginUndoGroup()
                defer { session.endUndoGroup() }
                session.draft.voiceOvers.append(clip)
                session.draft.voiceOverEnabled = true
                session.selectedVoiceOverID = clip.id
            } catch { voiceOverRecorder.error = error.localizedDescription }
        }
    }

    private func loadVideo(_ url: URL, project: Bool = false) {
        guard !editsBusy else { return }
        isCroppingScreen = false
        Task { @MainActor in
            do {
                if project { try await session.openProject(url) }
                else { try await session.openVideo(url) }
            }
            catch is CancellationError { }
            catch { session.exportError = error.localizedDescription }
        }
    }

    private func openPhoneVideoPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Phone Video"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.capture.phoneVideoURL = url
        }
    }

    private var phoneCropSource: URL? {
        if let current = videoURL, current == appState.recording.lastRecordingURL,
           let source = appState.recording.lastSourceRecordingURL { return source }
        return layoutSourceURL
    }

    private func applyLayout() async {
        guard !editsBusy, hasEditChanges, hasValidTimeline else { return }
        do { try await session.applyChanges() }
        catch { session.exportError = error.localizedDescription }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !editsBusy else { return false }
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    let ext = url.pathExtension.lowercased()
                    guard ["mov", "mp4", "m4v", "avi", "mkv"].contains(ext) else { return }
                    DispatchQueue.main.async {
                        if !editsBusy { requestImport(url) }
                    }
                }
            }
            return true
        }
        return false
    }


}

struct VideoReplacementDialog: View {
    let action: VideoReplacementAction
    let onResolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.featureGap) {
            Text("Replace current video?")
                .font(Typography.heading)
                .foregroundStyle(DesignColors.primaryLabel)
            Text(LocalizedStringKey(action.message))
                .font(.system(size: 13))
                .foregroundStyle(DesignColors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.labelToControl) {
                Button(action.buttonTitle, role: .destructive) { onResolve(true) }
                    .buttonStyle(CompactActionButtonStyle())
                Spacer()
                Button("Keep Editing") { onResolve(false) }
                    .buttonStyle(CompactActionButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(DesignColors.windowBackground)
        .onExitCommand { onResolve(false) }
    }
}

/// Crop mode lives in the main preview; only Done changes the pending video edits.
struct InlineScreenCropEditor: View {
    let sourceURL: URL
    var sourceTime: CMTime = .zero
    let onCancel: () -> Void
    let onApply: (PhoneCrop) -> Void
    @State private var crop: PhoneCrop
    @State private var image: CGImage?
    @State private var error: String?

    init(sourceURL: URL, sourceTime: CMTime = .zero, initialCrop: PhoneCrop,
         onCancel: @escaping () -> Void, onApply: @escaping (PhoneCrop) -> Void) {
        self.sourceURL = sourceURL
        self.sourceTime = sourceTime
        self.onCancel = onCancel
        self.onApply = onApply
        _crop = State(initialValue: initialCrop)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.md) {
                Label("Crop Screen", systemImage: "crop")
                    .font(Typography.body)
                    .foregroundStyle(DesignColors.primaryLabel)
                Spacer()
                Button("Reset") { crop = PhoneCrop() }
                    .buttonStyle(CompactActionButtonStyle())
                    .disabled(image == nil)
                    .hoverHelp(image == nil ? (error == nil ? "Wait for the crop preview to finish loading." : "The crop preview could not be loaded. Cancel and reopen Crop Screen to try again.") : "Restore the full source frame")
            }
            .padding(Spacing.lg)

            if let image {
                PhoneCropSelection(image: image, crop: $crop)
                    .padding(.horizontal, Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(LocalizedStringKey(error))
                    .font(Typography.body)
                    .foregroundStyle(DesignColors.secondaryLabel)
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .localizedAccessibilityLabel("Loading crop preview")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: Spacing.md) {
                Text("Drag the corners to crop. Drag inside to reposition.")
                    .font(Typography.caption)
                    .foregroundStyle(DesignColors.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel", action: onCancel)
                    .buttonStyle(CompactActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Done") { onApply(crop) }
                    .buttonStyle(CompactActionButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(image == nil)
                    .hoverHelp(image == nil ? (error == nil ? "Wait for the crop preview to finish loading." : "The crop preview could not be loaded. Cancel and reopen Crop Screen to try again.") : "Apply the selected crop.")
            }
            .padding(Spacing.lg)
        }
        .background(DesignColors.previewBackground)
        .task(id: sourceURL) {
            do {
                let asset = AVURLAsset(url: sourceURL)
                let duration = try await asset.load(.duration).seconds
                let seconds = sourceTime.seconds.isFinite ? sourceTime.seconds : 0
                let time = CMTime(seconds: min(max(0, duration - 1.0 / 600), max(0, seconds)), preferredTimescale: 60000)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 2000, height: 2000)
                // Sparse recordings may not have a sample at the exact playhead time.
                generator.requestedTimeToleranceBefore = .positiveInfinity
                generator.requestedTimeToleranceAfter = .zero
                let frame = try await generator.image(at: time).image
                try Task.checkCancellation()
                image = frame
            } catch is CancellationError {
            } catch {
                self.error = "Could not load this frame. Cancel and try another point in the video."
            }
        }
    }
}

struct PhoneCropSelection: View {
    let image: CGImage
    @Binding var crop: PhoneCrop
    @State private var dragStart: PhoneCrop?

    var body: some View {
        GeometryReader { geometry in
            let fitted = CanvasGeometry.fit(CGSize(width: image.width, height: image.height), in: CGRect(origin: .zero, size: geometry.size).insetBy(dx: 8, dy: 8))
            let normalized = crop.normalized
            let selection = CGRect(x: normalized.minX * fitted.width, y: normalized.minY * fitted.height,
                                   width: normalized.width * fitted.width, height: normalized.height * fitted.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: fitted.width, height: fitted.height)
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: fitted.size))
                    path.addRect(selection)
                }
                .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle().fill(.clear)
                    .contentShape(Rectangle())
                    .overlay(Rectangle().stroke(.white, lineWidth: 1))
                    .overlay {
                        Path { path in
                            for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                                path.move(to: CGPoint(x: selection.width * fraction, y: 0))
                                path.addLine(to: CGPoint(x: selection.width * fraction, y: selection.height))
                                path.move(to: CGPoint(x: 0, y: selection.height * fraction))
                                path.addLine(to: CGPoint(x: selection.width, y: selection.height * fraction))
                            }
                        }
                        .stroke(.white.opacity(0.35), lineWidth: 1)
                        .allowsHitTesting(false)
                    }
                    .frame(width: selection.width, height: selection.height)
                    .position(x: selection.midX, y: selection.midY)
                    .gesture(drag(size: fitted.size))
                    .localizedAccessibilityLabel("Selected crop area")
                    .hoverHelp("Drag to reposition the crop")
                ForEach(Array(PhoneCrop.Corner.allCases.enumerated()), id: \.offset) { _, corner in
                    let left = corner == .topLeft || corner == .bottomLeft
                    let top = corner == .topLeft || corner == .topRight
                    Circle().fill(.white)
                        .overlay(Circle().stroke(DesignColors.accent, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .padding(5)
                        .contentShape(Rectangle())
                        .position(x: left ? selection.minX : selection.maxX, y: top ? selection.minY : selection.maxY)
                        .gesture(drag(size: fitted.size, corner: corner))
                        .localizedAccessibilityLabel("\(left ? "Left" : "Right") \(top ? "top" : "bottom") crop handle")
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .position(x: fitted.midX, y: fitted.midY)
        }
    }

    private func drag(size: CGSize, corner: PhoneCrop.Corner? = nil) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragStart == nil { dragStart = crop }
                crop = (dragStart ?? crop).dragged(by: CGSize(width: value.translation.width / size.width,
                                                            height: value.translation.height / size.height), corner: corner)
            }
            .onEnded { _ in dragStart = nil }
    }
}

// MARK: - Native Video Player (AVPlayerView wrapper)

@MainActor
final class TimelinePlayback: ObservableObject {
    @Published var seconds: Double = 0
    @Published var isPlaying = false
    private var player: AVPlayer?
    private var observer: Any?
    private var rateObserver: NSKeyValueObservation?

    func attach(_ player: AVPlayer) {
        guard self.player !== player || observer == nil else { return }
        detach()
        self.player = player
        seconds = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        isPlaying = player.rate > 0
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, let player, self.player === player else { return }
                self.seconds = time.seconds.isFinite ? time.seconds : 0
            }
        }
        rateObserver = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate > 0
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.isPlaying = playing
            }
        }
    }

    func detach() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        rateObserver = nil
        player = nil
    }

    deinit {
        if let observer { player?.removeTimeObserver(observer) }
        rateObserver?.invalidate()
    }
}

/// Follow playback and explicit seeks without snapping back when a paused user scrolls.
private struct TimelineScrollFollower: NSViewRepresentable {
    let seconds: Double
    let duration: Double
    let trackWidth: Double

    func makeNSView(context: Context) -> TimelineScrollTrackingView { TimelineScrollTrackingView() }

    func updateNSView(_ view: TimelineScrollTrackingView, context: Context) {
        let position = 12 + trackWidth * max(0, min(duration, seconds)) / duration
        guard view.playheadX != position else { return }
        view.playheadX = position
        // SwiftUI must finish laying out the scroll document before we adjust its viewport.
        DispatchQueue.main.async { [weak view] in view?.followPlayhead() }
    }
}

private final class TimelineScrollTrackingView: NSView {
    var playheadX: CGFloat?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func followPlayhead() {
        guard let playheadX, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let viewport = clip.bounds
        let x = convert(CGPoint(x: playheadX, y: 0), to: document).x
        let margin = min(40, viewport.width * 0.1)
        var origin = viewport.origin
        if x > viewport.maxX - margin {
            origin.x = x - viewport.width * 0.8
        } else if x < viewport.minX + margin {
            origin.x = x - viewport.width * 0.2
        } else { return }
        origin.x = max(0, min(max(0, document.bounds.width - viewport.width), origin.x))
        guard abs(origin.x - viewport.minX) > 0.5 else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }
}

@MainActor
final class SilenceReview: ObservableObject {
    @Published var settings = SilenceDetector.Settings()
    @Published private(set) var suggestions: [VideoCut] = []
    @Published var selected = Set<UUID>()
    @Published var activeID: UUID?
    @Published private(set) var analyzing = false
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?

    var active: VideoCut? { suggestions.first { $0.id == activeID } }
    var selectedCuts: [VideoCut] { suggestions.filter { selected.contains($0.id) } }

    func clear() {
        task?.cancel()
        task = nil
        analyzing = false
        suggestions = []
        selected = []
        activeID = nil
        message = nil
    }

    func analyze(audio: URL, trim: VideoTrim, duration: Double) {
        clear()
        analyzing = true
        let settings = settings
        task = Task { [weak self] in
            do {
                let found = try await SilenceDetector.suggestions(source: audio, settings: settings)
                try Task.checkCancellation()
                let ranges = try trim.timeline(duration: CMTime(seconds: duration, preferredTimescale: 60000)).ranges
                let suggestions = found.flatMap { cut in
                    ranges.compactMap { range -> VideoCut? in
                        let start = max(range.start.seconds, cut.start)
                        let end = min(range.end.seconds, cut.end)
                        return end > start ? VideoCut(start: start, end: end) : nil
                    }
                }
                guard let self else { return }
                self.suggestions = suggestions
                self.selected = Set(suggestions.map(\.id))
                self.activeID = suggestions.first?.id
                self.message = suggestions.isEmpty ? "No silence found" : nil
                self.analyzing = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.message = error.localizedDescription
                self?.analyzing = false
            }
        }
    }

    func applying(to trim: VideoTrim, duration: Double) -> VideoTrim? {
        guard !selectedCuts.isEmpty else { return nil }
        var result = trim
        result.cuts += selectedCuts
        if trim.clips != nil {
            var timeline = LinkedMediaTimeline(trim: trim, audioClips: [], sourceDuration: duration, hasAudio: false)
            guard timeline.cutSources(selectedCuts, closeGaps: true) else { return nil }
        }
        return (try? result.timeline(duration: CMTime(seconds: duration, preferredTimescale: 60000))) == nil ? nil : result
    }

    deinit { task?.cancel() }
}

private struct TimelineTooltipAnchor {
    let text: String
    let bounds: Anchor<CGRect>
}

private struct TimelineTooltipKey: PreferenceKey {
    static var defaultValue: [TimelineTooltipAnchor] = []
    static func reduce(value: inout [TimelineTooltipAnchor], nextValue: () -> [TimelineTooltipAnchor]) {
        value += nextValue()
    }
}

private struct TimelineTooltip: ViewModifier {
    let text: String
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .onHover { hovered = $0 }
            .anchorPreference(key: TimelineTooltipKey.self, value: .bounds) {
                hovered ? [TimelineTooltipAnchor(text: text, bounds: $0)] : []
            }
    }
}

struct VideoTrimControls: View {
    @Binding var videoOverlayURL: URL?
    @Binding var videoOverlayTiming: VideoOverlayTiming?
    @Binding var videoOverlayEnabled: Bool
    let cameraLayout: CameraLayoutSettings
    let session: EditorSession?
    @Binding var cameraLayoutChanges: [CameraLayoutChange]
    @Binding var isVideoOverlaySelected: Bool
    @Binding var voiceOvers: [VoiceOverClip]
    @Binding var selectedVoiceOverID: UUID?
    var originalMuted: Bool
    var voiceOverMuted: Bool
    @Binding var trim: VideoTrim
    @Binding var zoomSegments: [ZoomSegment]?
    @Binding var selectedZoomID: UUID?
    @Binding var automaticZooms: [ZoomSegment]
    @Binding var zoomHistory: [[ZoomSegment]?]
    @Binding var zoomPadding: CGFloat
    let zoomEnabled: Bool
    let zoomLevel: Double
    let mouse: URL?
    let duration: Double
    let player: AVPlayer
    let source: URL
    var audio: URL? = nil
    @MainActor init(trim: Binding<VideoTrim>, zoomSegments: Binding<[ZoomSegment]?> = .constant(nil),
         zoomEnabled: Bool = false, zoomLevel: Double = 2, mouse: URL? = nil,
         duration: Double, player: AVPlayer, source: URL, audio: URL? = nil,
         voiceOvers: Binding<[VoiceOverClip]> = .constant([]), selectedVoiceOverID: Binding<UUID?> = .constant(nil),
         originalMuted: Bool = false, voiceOverMuted: Bool = false,
         selectedZoomID: Binding<UUID?> = .constant(nil),
         automaticZooms: Binding<[ZoomSegment]> = .constant([]),
         zoomHistory: Binding<[[ZoomSegment]?]> = .constant([]),
         zoomPadding: Binding<CGFloat> = .constant(0),
         videoOverlayURL: Binding<URL?> = .constant(nil),
         videoOverlayTiming: Binding<VideoOverlayTiming?> = .constant(nil),
        videoOverlayEnabled: Binding<Bool> = .constant(false),
         cameraLayout: CameraLayoutSettings = CameraLayoutSettings(),
         cameraLayoutChanges: Binding<[CameraLayoutChange]> = .constant([]),
         isVideoOverlaySelected: Binding<Bool> = .constant(false),
         silence: SilenceReview? = nil, session: EditorSession? = nil) {
        self.session = session
        _playback = StateObject(wrappedValue: session?.playback ?? TimelinePlayback())
        _videoOverlayURL = videoOverlayURL
        _videoOverlayTiming = videoOverlayTiming
        _videoOverlayEnabled = videoOverlayEnabled
        self.cameraLayout = cameraLayout
        _cameraLayoutChanges = cameraLayoutChanges
        _isVideoOverlaySelected = isVideoOverlaySelected
        _trim = trim
        _zoomSegments = zoomSegments
        _selectedZoomID = selectedZoomID
        _automaticZooms = automaticZooms
        _zoomHistory = zoomHistory
        _zoomPadding = zoomPadding
        self.zoomEnabled = zoomEnabled
        self.zoomLevel = zoomLevel
        self.mouse = mouse
        self.duration = duration
        self.player = player
        self.source = source
        self.audio = audio
        _voiceOvers = voiceOvers
        _selectedVoiceOverID = selectedVoiceOverID
        self.originalMuted = originalMuted
        self.voiceOverMuted = voiceOverMuted
        _silence = StateObject(wrappedValue: silence ?? SilenceReview())
    }
    @StateObject var silence = SilenceReview()
    @State private var dragging: VideoTrim?
    @StateObject private var playback: TimelinePlayback
    @State private var thumbnails: [CGImage] = []
    @State private var zoom: Double = 1
    @State private var localSelectedSegment: CMTimeRange?
    private var selectedSegment: CMTimeRange? {
        get { session?.selectedSegment ?? (session == nil ? localSelectedSegment : nil) }
        nonmutating set {
            if let session { session.selectedSegment = newValue }
            else { localSelectedSegment = newValue }
        }
    }
    private var mediaTimeline: LinkedMediaTimeline? { session?.mediaTimeline }
    private var selectedAudioID: UUID? {
        get { session?.selectedRecordedAudioID }
        nonmutating set { session?.selectedRecordedAudioID = newValue }
    }
    private var selectedMedia: (clip: MediaTimelineClip, track: LinkedMediaTimeline.Track)? {
        guard let mediaTimeline else { return nil }
        if let selectedAudioID, let clip = mediaTimeline.clip(selectedAudioID, on: .audio) { return (clip, .audio) }
        if let selectedSegment, let clip = mediaTimeline.video.first(where: { $0.sourceRange == selectedSegment }) { return (clip, .screen) }
        return nil
    }
    private var selectionLinked: Bool {
        guard let selectedMedia, let mediaTimeline else { return mediaTimeline?.audio.contains { $0.linkID != nil } ?? (audio != nil) }
        return mediaTimeline.partner(of: selectedMedia.clip, on: selectedMedia.track) != nil
    }
    private var timelineBusyReason: String? {
        session?.isBusy == true ? "Wait for the current recording or processing to finish before editing the timeline." : nil
    }
    private var linkDisabledReason: String? {
        if let timelineBusyReason { return timelineBusyReason }
        guard audio != nil else { return "This video has no recorded audio to link." }
        guard let selectedMedia, let mediaTimeline else { return "Select a screen or recorded audio section to link or unlink." }
        if mediaTimeline.partner(of: selectedMedia.clip, on: selectedMedia.track) != nil { return nil }
        return mediaTimeline.linkCandidate(for: selectedMedia.clip, on: selectedMedia.track) == nil
            ? "Align this section with its matching video or audio section before linking." : nil
    }
    private func toggleMediaLink() {
        guard let selectedMedia else { return }
        session?.editMediaTimeline { $0.toggleLink(selectedMedia.clip.id, on: selectedMedia.track) }
        if selectedMedia.track == .audio {
            if let state = session?.mediaTimeline, let clip = state.clip(selectedMedia.clip.id, on: .audio) {
                selectedSegment = state.partner(of: clip, on: .audio)?.sourceRange
            }
        }
    }
    private func selectAudio(_ clip: MediaTimelineClip) {
        player.pause()
        selectedAudioID = clip.id
        selectedSegment = mediaTimeline?.partner(of: clip, on: .audio)?.sourceRange
        selectedVoiceOverID = nil; selectedZoomID = nil; focusedZoomID = nil
        isVideoOverlaySelected = false; filmstripFocused = true
    }
    private func canDeleteMedia(_ clip: MediaTimelineClip, on track: LinkedMediaTimeline.Track) -> Bool {
        guard var mediaTimeline else { return false }
        return mediaTimeline.delete(clip.id, on: track, closeGaps: session?.draft.closesTimelineGaps ?? true)
    }
    private func deleteSelectedMedia() {
        guard let selectedMedia else { return }
        let close = session?.draft.closesTimelineGaps ?? true
        if session?.editMediaTimeline({ $0.delete(selectedMedia.clip.id, on: selectedMedia.track, closeGaps: close) }) == true {
            selectedAudioID = nil; selectedSegment = nil
        }
    }
    private func trimMedia(_ id: UUID, on track: LinkedMediaTimeline.Track, beginning: Bool, delta: Double) {
        let closeGaps = session?.draft.closesTimelineGaps ?? true
        session?.editMediaTimeline { $0.trim(id, on: track, beginning: beginning, by: delta,
                                           sourceDuration: duration, closeGaps: closeGaps) }
    }
    private var canUndoEdit: Bool { session?.canUndo ?? !history.isEmpty }
    private var canRedoEdit: Bool { session?.canRedo ?? !redoHistory.isEmpty }
    private var canUndoZoom: Bool { session?.canUndo ?? !zoomHistory.isEmpty }
    private enum TimelineEdit {
        case screen(VideoTrim)
        case camera([CameraLayoutChange])
        case recording(VideoTrim, [CameraLayoutChange])

        var withoutCamera: Self? {
            switch self {
            case .screen: return self
            case .camera: return nil
            case .recording(let trim, _): return .screen(trim)
            }
        }
    }
    @State private var history: [TimelineEdit] = []
    @State private var redoHistory: [TimelineEdit] = []
    @State private var cameraDuration: Double = 0
    @State private var movingSegment: Int?
    @State private var moveDestination: Int?
    @State private var draggingZooms: [ZoomSegment]?
    @State private var automaticZoomsReady = false
    @State private var zoomDragOrigin: ZoomSegment?
    @State private var zoomDragOutputStart: Double = 0
    @State private var zoomDragSourceOffset: Double = 0
    @FocusState private var focusedZoomID: UUID?
    @FocusState private var filmstripFocused: Bool
    @State private var hoveredZoomGapID: String?
    @State private var hoveredZoomPosition: Double?
    @State private var pendingZoomRange: ClosedRange<Double>?
    @State private var pendingZoomGapID: String?

    private var selection: VideoTrim { dragging ?? trim }
    private var minimumLength: Double { min(0.1, duration) }
    private var mediaDuration: CMTime { CMTime(seconds: duration, preferredTimescale: 60000) }
    private var timeline: EditedTimeline? { try? trim.timeline(duration: mediaDuration) }
    private var sourceSeconds: Double {
        timeline?.sourceTime(at: CMTime(seconds: playback.seconds, preferredTimescale: 60000)).seconds ?? 0
    }
    private var segments: [CMTimeRange] { (try? selection.segments(duration: mediaDuration)) ?? [] }
    private var editedDuration: Double { (try? selection.timeline(duration: mediaDuration).duration.seconds) ?? 0 }
    private var visibleZooms: [ZoomSegment] { draggingZooms ?? zoomSegments ?? automaticZooms }
    private var selectedZoom: ZoomSegment? { visibleZooms.first { $0.id == selectedZoomID } }

    private struct ZoomGap {
        let id: String
        let start: Double
        let end: Double
        let outputStart: Double
    }

    private var zoomGaps: [ZoomGap] {
        guard zoomSegments != nil || automaticZoomsReady else { return [] }
        var gaps: [ZoomGap] = []
        for index in segments.indices {
            let clip = segments[index]
            let offset = segmentOffset(index)
            var start = clip.start.seconds
            let occupied = visibleZooms.filter { $0.end > start && $0.start < clip.end.seconds }
                .sorted { $0.start < $1.start }
            for zoomSegment in occupied {
                let end = min(zoomSegment.start, clip.end.seconds)
                if end - start >= 0.2 {
                    gaps.append(ZoomGap(id: "\(index)-\(gaps.count)", start: start, end: end,
                                        outputStart: offset + start - clip.start.seconds))
                }
                start = max(start, zoomSegment.end)
            }
            if clip.end.seconds - start >= 0.2 {
                gaps.append(ZoomGap(id: "\(index)-\(gaps.count)", start: start, end: clip.end.seconds,
                                    outputStart: offset + start - clip.start.seconds))
            }
        }
        return gaps
    }

    private func segmentOffset(_ index: Int) -> Double {
        guard segments.indices.contains(index) else { return editedDuration }
        return (try? selection.timeline(duration: mediaDuration).outputTime(at: segments[index].start).seconds) ?? 0
    }

    private func moveSegment(from: Int, to: Int) {
        if let session {
            session.editMediaTimeline { $0.reorderVideo(from: from, to: to) }
            selectedSegment = nil
            return
        }
        var candidate = trim
        if candidate.moveSegment(from: from, to: to, duration: mediaDuration) { commit(candidate) }
    }

    private func commitZooms(_ updated: [ZoomSegment]) {
        zoomDragOrigin = nil
        guard updated != (zoomSegments ?? automaticZooms) else { draggingZooms = nil; return }
        player.pause()
        hoveredZoomGapID = nil
        if session == nil { zoomHistory.append(zoomSegments) }
        zoomSegments = updated.sorted { $0.start < $1.start }
        draggingZooms = nil
    }

    private func removeSelectedZoom() {
        guard let selectedZoomID, visibleZooms.contains(where: { $0.id == selectedZoomID }) else { return }
        commitZooms(visibleZooms.filter { $0.id != selectedZoomID })
        self.selectedZoomID = nil
        focusedZoomID = nil
    }

    private func undoZoomEdit() {
        if let session { session.undo(); focusedZoomID = nil; return }
        guard let previous = zoomHistory.popLast() else { return }
        player.pause()
        zoomSegments = previous
        selectedZoomID = nil
        focusedZoomID = nil
    }

    private func selectZoom(_ id: UUID) {
        selectedAudioID = nil
        isVideoOverlaySelected = false
        selectedVoiceOverID = nil
        selectedSegment = nil
        selectedZoomID = id
        focusedZoomID = id
    }

    private func addZoom(from start: Double, to end: Double) {
        guard zoomSegments != nil || automaticZoomsReady else { return }
        let existing = zoomSegments ?? automaticZooms
        let next = existing.filter { $0.start > start }.map(\.start).min() ?? duration
        let previous = existing.filter { $0.end <= start }.map(\.end).max() ?? 0
        guard start >= previous, end <= next, end - start >= 0.2,
              !existing.contains(where: { start < $0.end && end > $0.start }) else { return }
        let segment = ZoomSegment(start: start, end: end, zoom: zoomLevel,
                                  centerX: 0.5, centerY: 0.5)
        commitZooms(existing + [segment])
        selectZoom(segment.id)
    }

    private func zoomRange(in gap: ZoomGap, from start: Double, to end: Double) -> ClosedRange<Double> {
        let left = min(gap.end - 0.2, max(gap.start, min(start, end)))
        let right = min(gap.end, max(left + 0.2, max(start, end)))
        return left...right
    }

    private func adjustedZoom(_ segment: ZoomSegment, delta: Double, edge: Int) -> [ZoomSegment] {
        var updated = zoomSegments ?? automaticZooms
        guard let index = updated.firstIndex(where: { $0.id == segment.id }) else { return updated }
        let previousEnd = updated.filter { $0.id != segment.id && $0.end <= segment.start }.map(\.end).max() ?? 0
        let nextStart = updated.filter { $0.id != segment.id && $0.start >= segment.end }.map(\.start).min() ?? duration
        if edge < 0 { updated[index].start = min(segment.end - 0.2, max(previousEnd, segment.start + delta)) }
        else if edge > 0 { updated[index].end = max(segment.start + 0.2, min(nextStart, segment.end + delta)) }
        else {
            let shift = min(nextStart - segment.end, max(previousEnd - segment.start, delta))
            updated[index].start = segment.start + shift
            updated[index].end = segment.end + shift
        }
        return updated
    }

    private func movedZoom(_ segment: ZoomSegment, outputStart: Double, sourceOffset: Double, delta: Double) -> [ZoomSegment] {
        guard let timeline else { return zoomSegments ?? automaticZooms }
        let outputTime = CMTime(seconds: min(editedDuration, max(0, outputStart + delta)), preferredTimescale: 60000)
        let newStart = timeline.sourceTime(at: outputTime).seconds - sourceOffset
        guard newStart.isFinite else { return zoomSegments ?? automaticZooms }
        var updated = zoomSegments ?? automaticZooms
        guard let index = updated.firstIndex(where: { $0.id == segment.id }) else { return updated }
        let length = segment.end - segment.start
        guard newStart >= 0, newStart + length <= duration,
              !updated.contains(where: { $0.id != segment.id && newStart < $0.end && newStart + length > $0.start }) else { return updated }
        updated[index].start = newStart
        updated[index].end = newStart + length
        return updated
    }

    private func seekOutput(_ seconds: Double) {
        player.pause()
        player.currentItem?.forwardPlaybackEndTime = .invalid
        let time = CMTime(seconds: max(0, min(editedDuration, seconds)), preferredTimescale: 60000)
        playback.seconds = time.seconds
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private var canSplit: Bool {
        if isVideoOverlaySelected { return cameraSplit != nil }
        if var mediaTimeline {
            let track: LinkedMediaTimeline.Track = selectedAudioID == nil ? .screen : .audio
            let clip = selectedMedia?.clip ?? mediaTimeline.video.first { playback.seconds >= $0.start && playback.seconds < $0.end }
            guard let clip, selectedVoiceOverID == nil, selectedZoomID == nil else { return false }
            return mediaTimeline.split(clip.id, on: track, at: playback.seconds)
        }
        guard selectedVoiceOverID == nil, selectedZoomID == nil else { return false }
        var candidate = trim
        return candidate.split(at: sourceSeconds, duration: mediaDuration)
    }

    private var cameraSplit: CameraLayoutChange? {
        guard videoOverlayURL != nil, let timeline else { return nil }
        return VideoOverlayTimelineRange.visible(timing: videoOverlayTiming, timeline: timeline,
                                                sourceDuration: cameraDuration).compactMap {
            CameraLayoutChange.split(at: playback.seconds, in: $0, initial: cameraLayout, changes: cameraLayoutChanges)
        }.first
    }

    private var splitLabel: String { isVideoOverlaySelected ? "Split Camera" : selectedAudioID != nil ? "Split Audio" : "Split Screen" }

    private func splitSelectedTrack() {
        guard canSplit else { return }
        if isVideoOverlaySelected, let split = cameraSplit {
            player.pause()
            session?.beginUndoGroup()
            defer { session?.endUndoGroup() }
            if session == nil {
                history.append(.camera(cameraLayoutChanges))
                redoHistory = []
            }
            cameraLayoutChanges.append(split)
            cameraLayoutChanges.sort { $0.start < $1.start }
        } else if let session {
            let state = session.mediaTimeline
            let track: LinkedMediaTimeline.Track = selectedAudioID == nil ? .screen : .audio
            if let clip = selectedMedia?.clip ?? state.video.first(where: { playback.seconds >= $0.start && playback.seconds < $0.end }) {
                session.beginUndoGroup()
                defer { session.endUndoGroup() }
                if session.editMediaTimeline({ $0.split(clip.id, on: track, at: playback.seconds) }),
                   track == .screen, let split = cameraSplit {
                    cameraLayoutChanges.append(split)
                    cameraLayoutChanges.sort { $0.start < $1.start }
                }
            }
        } else {
            var candidate = trim
            if candidate.split(at: sourceSeconds, duration: mediaDuration) {
                commit(candidate, cameraSplit: cameraSplit)
            }
        }
    }

    private func restore(_ edit: TimelineEdit) -> TimelineEdit {
        player.pause()
        switch edit {
        case .screen(let value):
            let previous = trim
            trim = value
            selectedSegment = nil
            return .screen(previous)
        case .camera(let value):
            let previous = cameraLayoutChanges
            cameraLayoutChanges = value
            selectVideoOverlay()
            return .camera(previous)
        case .recording(let value, let changes):
            let previous = TimelineEdit.recording(trim, cameraLayoutChanges)
            trim = value
            cameraLayoutChanges = changes
            selectedSegment = nil
            isVideoOverlaySelected = false
            selectedVoiceOverID = nil
            selectedZoomID = nil
            return previous
        }
    }
    private var removableSelection: VideoTrim? {
        guard let selectedSegment, segments.contains(selectedSegment) else { return nil }
        var candidate = trim
        candidate.cuts.append(VideoCut(start: selectedSegment.start.seconds, end: selectedSegment.end.seconds))
        return (try? candidate.timeline(duration: mediaDuration)) == nil ? nil : candidate
    }

    private func commit(_ value: VideoTrim, cameraSplit: CameraLayoutChange? = nil) {
        guard value != trim else { return }
        if let session {
            try? session.updateEdits { $0.trim = value }
            selectedSegment = nil
            return
        }
        player.pause()
        session?.beginUndoGroup()
        defer { session?.endUndoGroup() }
        if session == nil {
            history.append(cameraSplit == nil ? .screen(trim) : .recording(trim, cameraLayoutChanges))
            redoHistory = []
        }
        trim = value
        if let cameraSplit {
            cameraLayoutChanges.append(cameraSplit)
            cameraLayoutChanges.sort { $0.start < $1.start }
        }
        selectedSegment = nil
    }

    private func seek(source seconds: Double) {
        guard let timeline else { return }
        player.pause()
        player.currentItem?.forwardPlaybackEndTime = .invalid
        let time = timeline.outputTime(at: CMTime(seconds: max(0, min(duration, seconds)), preferredTimescale: 60000))
        playback.seconds = time.seconds
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func timestamp(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        return String(format: "%02d:%04.1f", Int(safe) / 60, safe.truncatingRemainder(dividingBy: 60))
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 28)
        }
        .buttonStyle(.plain)
        .modifier(TimelineTooltip(text: label))
        .localizedAccessibilityLabel(label)
    }

    private func timelineToggle(_ symbol: String, label: String, isOn: Bool,
                                disabledReason: String?, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(isOn ? DesignColors.accent : DesignColors.secondaryLabel)
                .background(isOn ? DesignColors.accent.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedAccessibilityLabel(label)
        .localizedAccessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
        .accessibilityHint(Text(LocalizedStringKey(disabledReason ?? label)))
        .disabled(disabledReason != nil)
        .modifier(TimelineTooltip(text: disabledReason ?? label))
    }

    private func adjusted(_ value: Double, isStart: Bool, from original: VideoTrim) -> VideoTrim {
        guard value.isFinite else { return original }
        var result = original
        if isStart {
            result.start = max(0, min(value, (original.end ?? duration) - minimumLength))
        } else {
            let end = min(duration, max(value, original.start + minimumLength))
            result.end = end >= duration ? nil : end
        }
        return (try? result.timeline(duration: mediaDuration)) == nil ? original : result
    }

    private func adjustedEdge(delta: Double, isStart: Bool, from original: VideoTrim) -> VideoTrim {
        if original.clipOrder.isEmpty {
            return adjusted((isStart ? original.start : (original.end ?? duration)) + delta,
                            isStart: isStart, from: original)
        }
        let originalSegments = (try? original.segments(duration: mediaDuration)) ?? []
        guard let edge = isStart ? originalSegments.first : originalSegments.last else { return original }
        var result = original
        let removed = min(max(0, isStart ? delta : -delta), max(0, edge.duration.seconds - minimumLength))
        if removed > 0 {
            result.cuts.append(VideoCut(start: isStart ? edge.start.seconds : edge.end.seconds - removed,
                                       end: isStart ? edge.start.seconds + removed : edge.end.seconds))
        }
        return result
    }

    var body: some View {
        // Read playback in this view's body, before entering GeometryReader's
        // deferred closures, so time changes invalidate both the ruler and
        // transport controls even when the layout itself is unchanged.
        let playbackSeconds = playback.seconds
        let isPlaying = playback.isPlaying
        VStack(spacing: Spacing.md) {
            GeometryReader { geometry in
                toolbar(expanded: geometry.size.width > 650, seconds: playbackSeconds, isPlaying: isPlaying)
            }.frame(height: 32)
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    filmstrip(width: max(1, geometry.size.width - 24) * zoom, seconds: playbackSeconds)
                }
            }.frame(height: timelineHeight + 14)
            if silence.analyzing || !silence.suggestions.isEmpty || silence.message != nil {
                silenceReviewBar
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(DesignColors.primaryLabel)
        .padding(Spacing.lg)
        .background(DesignColors.controlBackground)
        .focusable()
        .focused($filmstripFocused)
        .onDeleteCommand {
            if selectedMedia != nil {
                deleteSelectedMedia()
            } else if isVideoOverlaySelected {
                removeVideoOverlay()
            } else if let id = selectedVoiceOverID {
                player.pause()
                voiceOvers.removeAll { $0.id == id }
                selectedVoiceOverID = nil
            } else if focusedZoomID != nil, focusedZoomID == selectedZoomID {
                removeSelectedZoom()
            } else if let removableSelection {
                commit(removableSelection)
            }
        }
        .overlayPreferenceValue(TimelineTooltipKey.self) { tooltips in
            GeometryReader { geometry in
                if let tooltip = tooltips.last {
                    let bounds = geometry[tooltip.bounds]
                    let textWidth = (tooltip.text as NSString).size(withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium)
                    ]).width
                    let width = min(260, geometry.size.width - 24, ceil(textWidth) + 20)
                    Text(LocalizedStringKey(tooltip.text))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignColors.primaryLabel)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(width: width, alignment: .leading)
                        .background(DesignColors.inputBackground, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DesignColors.inputBorder, lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: width, height: 70, alignment: .bottom)
                        .position(x: min(geometry.size.width - width / 2 - 8, max(width / 2 + 8, bounds.midX)),
                                  y: bounds.minY - 43)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onAppear { if session == nil { playback.attach(player) } }
        .onDisappear {
            if session == nil { playback.detach() }
            silence.clear()
        }
        .onChange(of: ObjectIdentifier(player)) { _ in
            if session == nil { playback.attach(player) }
        }
        .onChange(of: trim) { _ in
            if let selectedSegment, !segments.contains(selectedSegment) { self.selectedSegment = nil }
            hoveredZoomGapID = nil
            hoveredZoomPosition = nil
            pendingZoomGapID = nil
            pendingZoomRange = nil
            silence.clear()
        }
        .onChange(of: audio) { _ in silence.clear() }
        .onChange(of: videoOverlayURL) { _ in
            isVideoOverlaySelected = false
            history = history.compactMap(\.withoutCamera)
            redoHistory = redoHistory.compactMap(\.withoutCamera)
        }
        .onChange(of: selectedVoiceOverID) { id in
            if id != nil { isVideoOverlaySelected = false; selectedAudioID = nil; selectedSegment = nil }
        }
        .onChange(of: selectedZoomID) { id in
            if id != nil { selectedAudioID = nil; selectedSegment = nil }
        }
        .onChange(of: isVideoOverlaySelected) { selected in
            if selected { selectedAudioID = nil; selectedSegment = nil }
        }
        .task(id: videoOverlayURL) {
            cameraDuration = 0
            guard let url = videoOverlayURL else { return }
            let duration = try? await AVURLAsset(url: url).load(.duration).seconds
            guard !Task.isCancelled, url == videoOverlayURL,
                  let duration, duration.isFinite, duration > 0 else { return }
            cameraDuration = duration
        }
        .task(id: "\(mouse?.path ?? "")-\(source.path)-\(zoomLevel)-\(duration)-\(zoomEnabled)") {
            automaticZoomsReady = false
            automaticZooms = []
            guard zoomEnabled, let mouse, duration > 0,
                  let data = try? Data(contentsOf: mouse),
                let recording = try? JSONDecoder().decode(MouseDataRecorder.MouseRecording.self, from: data) else { return }
            let padding = await ClickZoomGenerator.detectPaddingRatio(videoURL: source, recording: recording)
            guard !Task.isCancelled else { return }
            zoomPadding = padding
            automaticZooms = ClickZoomGenerator.editableSegments(from: recording, duration: duration, zoomLevel: zoomLevel)
            automaticZoomsReady = true
        }
        .onChange(of: silence.settings) { _ in silence.clear() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            if let item = notification.object as? AVPlayerItem, item === player.currentItem {
                item.forwardPlaybackEndTime = .invalid
            }
        }
        .task(id: source) {
            thumbnails = []
            hoveredZoomGapID = nil
            hoveredZoomPosition = nil
            pendingZoomGapID = nil
            pendingZoomRange = nil
            history = []
            redoHistory = []
            if session == nil {
                selectedSegment = nil
                selectedZoomID = nil
                zoomHistory = []
                zoomSegments = nil
            }
            focusedZoomID = nil
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            var images: [CGImage] = []
            for index in 0..<24 {
                guard !Task.isCancelled else { return }
                if let result = try? await generator.image(at: CMTime(seconds: duration * (Double(index) + 0.5) / 24, preferredTimescale: 60000)) {
                    images.append(result.image)
                }
            }
            guard !Task.isCancelled else { return }
            thumbnails = images
        }
    }

    private func toolbar(expanded: Bool, seconds: Double, isPlaying: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: splitSelectedTrack) {
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .stroke(lineWidth: 1)
                            .frame(width: 6, height: 12)
                        RoundedRectangle(cornerRadius: 1.5)
                            .stroke(lineWidth: 1)
                            .frame(width: 6, height: 12)
                    }
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .localizedAccessibilityLabel(splitLabel)
                .accessibilityIdentifier("splitAtPlayhead")
                .disabled(!canSplit)
                .modifier(TimelineTooltip(text: canSplit ? "\(splitLabel) at the playhead"
                    : "Select a screen or camera section and move the playhead inside it to split"))
                icon("arrow.uturn.backward", "Undo timeline edit") {
                    if let session { session.undo() }
                    else if let previous = history.popLast() {
                        redoHistory.append(restore(previous))
                    }
                }.disabled(!canUndoEdit)
                    .modifier(TimelineTooltip(text: !canUndoEdit ? "No timeline edits to undo" : "Undo the last split, removal, trim, or reorder"))
                icon("arrow.uturn.forward", "Redo timeline edit") {
                    if let session { session.redo() }
                    else if let next = redoHistory.popLast() {
                        history.append(restore(next))
                    }
                }.disabled(!canRedoEdit)
                    .modifier(TimelineTooltip(text: !canRedoEdit ? "No timeline edits to redo" : "Redo the last timeline edit"))
                Divider().frame(height: 16).padding(.horizontal, 6)
                timelineToggle("link", label: selectionLinked ? "Unlink" : "Link", isOn: selectionLinked,
                               disabledReason: linkDisabledReason, identifier: "linkRecordedAudio") { toggleMediaLink() }
                timelineToggle("arrow.left.to.line", label: "Close gaps", isOn: session?.draft.closesTimelineGaps ?? true,
                               disabledReason: timelineBusyReason ?? (session == nil ? "Open a video to change gap closing." : nil),
                               identifier: "closeTimelineGaps") {
                    guard let session else { return }
                    session.draft.closeTimelineGaps = !session.draft.closesTimelineGaps
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            playbackControls(isPlaying: isPlaying)
            HStack(spacing: 4) {
                Text(verbatim: expanded ? "\(timestamp(seconds)) / \(timestamp(timeline?.duration.seconds ?? 0))" : timestamp(seconds))
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
                    .localizedAccessibilityLabel("Playback time")
                    .modifier(TimelineTooltip(text: "Current playback time / edited video duration"))
                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 6)
                icon("minus", "Zoom timeline out") { zoom = max(1, zoom - 1) }
                    .disabled(zoom <= 1)
                    .modifier(TimelineTooltip(text: zoom <= 1 ? "The timeline is already fully zoomed out" : "Zoom timeline out"))
                if expanded {
                    LineSlider(selection: $zoom, range: 1...8, label: "Timeline zoom",
                               value: String(format: "%.2f×", zoom), thumbSize: 14, height: 24, keyboardStep: 0.25)
                        .frame(width: 80)
                }
                icon("plus", "Zoom timeline in") { zoom = min(8, zoom + 1) }
                    .disabled(zoom >= 8)
                    .modifier(TimelineTooltip(text: zoom >= 8 ? "The timeline is at its maximum zoom" : "Zoom timeline in"))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func playbackControls(isPlaying: Bool) -> some View {
            HStack(spacing: 4) {
                icon("backward.end.fill", "Go to start") { seekOutput(0) }
                Button {
                    if player.rate > 0 { player.pause() }
                    else {
                        player.currentItem?.forwardPlaybackEndTime = .invalid
                        if playback.seconds >= (timeline?.duration.seconds ?? 0) - 0.01 {
                            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                        player.play()
                    }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 32, height: 32)
                        .background(DesignColors.inputBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .modifier(TimelineTooltip(text: isPlaying ? "Pause" : "Play"))
                .localizedAccessibilityLabel(isPlaying ? "Pause" : "Play")
                icon("forward.end.fill", "Go to end") { seekOutput(editedDuration) }
            }
    }

    private func reviewPause(_ cut: VideoCut, play: Bool = false) {
        silence.activeID = cut.id
        seek(source: cut.start)
        guard play, let timeline else { return }
        let start = timeline.outputTime(at: CMTime(seconds: cut.start, preferredTimescale: 60000))
        player.currentItem?.forwardPlaybackEndTime = CMTimeAdd(start, CMTime(seconds: cut.end - cut.start, preferredTimescale: 60000))
        player.play()
    }

    private func nextPause(_ offset: Int) {
        guard !silence.suggestions.isEmpty else { return }
        let current = silence.suggestions.firstIndex { $0.id == silence.activeID } ?? 0
        let index = (current + offset + silence.suggestions.count) % silence.suggestions.count
        reviewPause(silence.suggestions[index])
    }

    private var silenceReviewBar: some View {
        HStack(spacing: 6) {
            if silence.analyzing {
                ProgressView().controlSize(.small)
                Text("Finding silences...")
                Spacer(minLength: 4)
                Button("Cancel") { silence.clear() }
            } else if let message = silence.message {
                Text(LocalizedStringKey(message)).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                icon("xmark", "Dismiss silence review") { silence.clear() }
            } else {
                Image(systemName: "waveform.badge.minus").foregroundStyle(DesignColors.warning)
                Text("\(silence.suggestions.count) pauses").monospacedDigit()
                icon("chevron.left", "Previous silence") { nextPause(-1) }
                icon("chevron.right", "Next silence") { nextPause(1) }
                if let active = silence.active {
                    icon("play.fill", "Preview selected silence") { reviewPause(active, play: true) }
                    Toggle("Remove", isOn: Binding(
                        get: { silence.selected.contains(active.id) },
                        set: { if $0 { silence.selected.insert(active.id) } else { silence.selected.remove(active.id) } }
                    ))
                    .toggleStyle(.checkbox)
                    .hoverHelp("Include this pause in the removal")
                }
                Spacer(minLength: 4)
                Button("Remove \(silence.selected.count)") {
                    if let result = silence.applying(to: trim, duration: duration) {
                        commit(result)
                        silence.clear()
                    }
                }
                .disabled(silence.applying(to: trim, duration: duration) == nil)
                .hoverHelp(silence.applying(to: trim, duration: duration) == nil ? "Select pauses to remove while keeping at least one video section." : "Remove the checked pauses; Undo restores them")
                icon("xmark", "Dismiss silence suggestions") {
                    player.pause()
                    player.currentItem?.forwardPlaybackEndTime = .invalid
                    silence.clear()
                }
            }
        }
        .font(.system(size: 11))
        .frame(minHeight: 28)
    }

    private var videoLaneBottom: Double { zoomEnabled && mouse != nil ? 93 : 70 }
    private var audioLaneHeight: Double { (audio == nil ? 0 : 50) + (voiceOvers.isEmpty ? 0 : 50) }
    private var cameraLaneHeight: Double { videoOverlayURL == nil ? 0 : 50 }
    private var audioLaneTop: Double { videoLaneBottom + cameraLaneHeight }
    private var timelineHeight: Double { audioLaneTop + audioLaneHeight }

    private func selectVideoOverlay() {
        selectedAudioID = nil
        player.pause()
        selectedSegment = nil
        selectedVoiceOverID = nil
        selectedZoomID = nil
        focusedZoomID = nil
        filmstripFocused = true
        isVideoOverlaySelected = true
    }

    private func removeVideoOverlay() {
        session?.beginUndoGroup()
        defer { session?.endUndoGroup() }
        player.pause()
        videoOverlayURL = nil
        videoOverlayTiming = nil
        videoOverlayEnabled = false
        isVideoOverlaySelected = false
    }

    @ViewBuilder
    private func cameraLane(width: Double) -> some View {
        if let url = videoOverlayURL, let timeline {
            VideoOverlayFilmstrip(url: url, timing: $videoOverlayTiming, timeline: timeline,
                                  width: width, enabled: videoOverlayEnabled, selected: isVideoOverlaySelected,
                                  cameraLayout: cameraLayout, cameraLayoutChanges: cameraLayoutChanges,
                                  playhead: playback.seconds, select: selectVideoOverlay, remove: removeVideoOverlay,
                                  seek: seekOutput)
                .offset(x: 12, y: videoLaneBottom)
        }
    }

    @ViewBuilder
    private func audioLanes(width: Double, total: Double) -> some View {
        if let audio, let mediaTimeline {
            ForEach(mediaTimeline.audio) { clip in
                let linked = mediaTimeline.partner(of: clip, on: .audio) != nil
                let highlighted = selectedAudioID == clip.id || (linked && selectedSegment == clip.sourceRange)
                RecordedAudioTimelineClip(url: audio, clip: clip, selected: highlighted, linked: linked,
                    muted: originalMuted, scale: width / total,
                    select: { selectAudio(clip) }, seek: seekOutput,
                    move: { delta in session?.editMediaTimeline { $0.move(clip.id, on: .audio, by: delta) } },
                    trim: { beginning, delta in trimMedia(clip.id, on: .audio, beginning: beginning, delta: delta) },
                    delete: { selectAudio(clip); deleteSelectedMedia() },
                    canDelete: canDeleteMedia(clip, on: .audio),
                    toggleLink: { selectAudio(clip); toggleMediaLink() },
                    canLink: linked || mediaTimeline.linkCandidate(for: clip, on: .audio) != nil)
                    .offset(x: 12 + width * clip.start / total, y: audioLaneTop)
            }
        } else if let audio {
            AudioWaveformStrip(url: audio, title: "Original audio", color: .teal, muted: originalMuted,
                               duration: total, timeline: timeline)
                .frame(width: width, height: 44)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { seekOutput($0.location.x / width * total) })
                .offset(x: 12, y: audioLaneTop)
        }
        ForEach($voiceOvers) { $clip in
            if clip.start < total {
                VoiceOverTimelineClip(clip: $clip, selected: $selectedVoiceOverID,
                                      total: total, scale: width / total, muted: voiceOverMuted,
                                      number: (voiceOvers.firstIndex(where: { $0.id == clip.id }) ?? 0) + 1,
                                      pause: { player.pause(); selectedAudioID = nil; selectedSegment = nil; selectedZoomID = nil; isVideoOverlaySelected = false })
                    .offset(x: 12 + width * clip.start / total, y: audioLaneTop + (audio == nil ? 0 : 50))
            }
        }
    }

    private func filmstrip(width: Double, seconds: Double) -> some View {
        let total = max(0.001, editedDuration)
        return ZStack(alignment: .topLeading) {
            ForEach(0...Int(8 * zoom), id: \.self) { tick in
                let fraction = Double(tick) / Double(Int(8 * zoom))
                VStack(spacing: 3) {
                    Text(LocalizedStringKey(timestamp(total * fraction))).font(.system(size: 9, design: .monospaced))
                    Rectangle().frame(width: 1, height: 4)
                }
                .foregroundStyle(DesignColors.secondaryLabel)
                .frame(width: 44)
                .offset(x: max(0, min(width - 20, width * fraction - 10)))
            }
            ForEach(segments.indices, id: \.self) { index in
                clipStrip(index: index, width: width, total: total)
                    .offset(x: width * segmentOffset(index) / total + 12, y: zoomEnabled && mouse != nil ? 48 : 25)
            }
            if zoomEnabled && mouse != nil { zoomLane(width: width, total: total) }
            cameraLane(width: width)
            audioLanes(width: width, total: total)
            Rectangle().fill(.clear).contentShape(Rectangle())
                .frame(width: width, height: 24).offset(x: 12)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimTimeline"))
                    .onChanged { gesture in
                        seekOutput((gesture.location.x - 12) / width * total)
                    })
                .localizedAccessibilityLabel("Timeline playhead")
                .localizedAccessibilityValue(timestamp(seconds))
                .accessibilityAdjustableAction { direction in seekOutput(playback.seconds + (direction == .increment ? 1 : -1) / 30) }
            ForEach(silence.suggestions) { cut in
                ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                let start = max(cut.start, segment.start.seconds)
                let end = min(cut.end, segment.end.seconds)
                if end > start {
                let highlighted = silence.selected.contains(cut.id)
                Button { reviewPause(cut) } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DesignColors.warning.opacity(highlighted ? 0.45 : 0.1))
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(DesignColors.warning, style: StrokeStyle(lineWidth: silence.activeID == cut.id ? 3 : 1, dash: highlighted ? [] : [3])))
                        .overlay(alignment: .top) {
                            if width * (end - start) / total > 22 {
                                Image(systemName: highlighted ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DesignColors.warning)
                                    .padding(.top, 3)
                            }
                        }
                        .frame(width: max(2, width * (end - start) / total), height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .localizedAccessibilityLabel("Suggested silence \(timestamp(cut.start)) to \(timestamp(cut.end))")
                .hoverHelp("Suggested silence: \(timestamp(cut.start)) to \(timestamp(cut.end))")
                .offset(x: width * (segmentOffset(index) + start - segment.start.seconds) / total + 12, y: zoomEnabled && mouse != nil ? 48 : 25)
                }
                }
            }
            if session == nil || selectedSegment == nil {
                trimHandle(isStart: true, width: width)
                    .offset(x: width * (mediaTimeline?.video.first?.start ?? 0) / total, y: zoomEnabled && mouse != nil ? 48 : 25)
                trimHandle(isStart: false, width: width)
                    .offset(x: width * (mediaTimeline?.video.last?.end ?? total) / total + 12, y: zoomEnabled && mouse != nil ? 48 : 25)
            }
            if let movingSegment, let moveDestination {
                let boundary = segmentOffset(moveDestination + (moveDestination > movingSegment ? 1 : 0))
                Rectangle().fill(DesignColors.cameraTrack)
                    .frame(width: 3, height: 48)
                    .offset(x: 12 + width * boundary / total - 1.5, y: zoomEnabled && mouse != nil ? 45 : 22)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9))
                Rectangle().frame(width: 1, height: timelineHeight - 12)
            }
            .foregroundStyle(DesignColors.primaryLabel)
            .frame(width: 12)
            .offset(x: width * max(0, min(total, seconds)) / total + 6, y: 3)
            .allowsHitTesting(false)
        }
        .frame(width: width + 24, height: timelineHeight, alignment: .topLeading)
        .background {
            TimelineScrollFollower(seconds: seconds, duration: total, trackWidth: width)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .coordinateSpace(name: "trimTimeline")
    }

    private func zoomLane(width: Double, total: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(zoomGaps, id: \.id) { gap in
                zoomGapView(gap, width: width, total: total)
                    .offset(x: 12 + width * gap.outputStart / total)
            }
            zoomBlocks(width: width, total: total)
        }
        .frame(width: width + 24, height: 21, alignment: .topLeading)
        .offset(y: 25)
    }

    @ViewBuilder
    private func zoomBlocks(width: Double, total: Double) -> some View {
        ForEach(visibleZooms) { zoomSegment in
            ForEach(segments.indices, id: \.self) { index in
                let clip = segments[index]
                let start = max(zoomSegment.start, clip.start.seconds)
                let end = min(zoomSegment.end, clip.end.seconds)
                if end > start {
                    let outputStart = segmentOffset(index) + start - clip.start.seconds
                    zoomBlock(zoomSegment, width: max(4, width * (end - start) / total),
                              scale: width / total,
                              outputStart: outputStart,
                              sourceOffset: start - zoomSegment.start)
                        .offset(x: 12 + width * outputStart / total)
                }
            }
        }
    }

    private func zoomGapView(_ gap: ZoomGap, width: Double, total: Double) -> some View {
        let gapWidth = width * (gap.end - gap.start) / total
        let currentRange = pendingZoomGapID == gap.id ? pendingZoomRange
            : hoveredZoomGapID == gap.id ? hoveredZoomPosition.map { zoomRange(in: gap, from: $0, to: $0) } : nil
        return Rectangle().fill(.clear)
            .frame(width: gapWidth, height: 19)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if let currentRange {
                    let previewWidth = min(gapWidth, max(20, width * (currentRange.upperBound - currentRange.lowerBound) / total))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(DesignColors.cameraTrack.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(DesignColors.cameraTrack.opacity(0.7),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .overlay(Image(systemName: "plus").font(.system(size: 11, weight: .semibold)))
                        .frame(width: previewWidth, height: 19)
                        .offset(x: min(max(0, gapWidth - previewWidth), width * (currentRange.lowerBound - gap.start) / total))
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredZoomGapID = gap.id
                    hoveredZoomPosition = gap.start + min(gapWidth, max(0, location.x)) / width * total
                case .ended:
                    if hoveredZoomGapID == gap.id { hoveredZoomGapID = nil; hoveredZoomPosition = nil }
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let start = gap.start + gesture.startLocation.x / width * total
                    let end = gap.start + gesture.location.x / width * total
                    pendingZoomGapID = gap.id
                    pendingZoomRange = zoomRange(in: gap, from: start, to: end)
                }
                .onEnded { gesture in
                    let start = gap.start + gesture.startLocation.x / width * total
                    let end = gap.start + gesture.location.x / width * total
                    let range = zoomRange(in: gap, from: start, to: end)
                    pendingZoomRange = nil
                    pendingZoomGapID = nil
                    addZoom(from: range.lowerBound, to: range.upperBound)
                })
            .localizedAccessibilityLabel("Add zoom in empty section")
            .hoverHelp("Click or drag to add a zoom")
            .contextMenu {
                Button("Undo Zoom Edit") { undoZoomEdit() }.disabled(!canUndoZoom)
                    .hoverHelp(!canUndoZoom ? "There are no zoom edits to undo." : "Undo the last zoom edit.")
            }
    }

    private func zoomBlock(_ segment: ZoomSegment, width: Double, scale: Double,
                           outputStart: Double, sourceOffset: Double) -> some View {
        HStack(spacing: 0) {
            zoomEdge(segment, scale: scale, edge: -1)
            Text(LocalizedStringKey(String(format: "%.1fx", zoomLevel)))
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { gesture in
                        selectZoom(segment.id)
                        if zoomDragOrigin == nil {
                            zoomDragOrigin = segment
                            zoomDragOutputStart = outputStart
                            zoomDragSourceOffset = sourceOffset
                        }
                        draggingZooms = movedZoom(zoomDragOrigin ?? segment,
                                                  outputStart: zoomDragOutputStart, sourceOffset: zoomDragSourceOffset,
                                                  delta: gesture.translation.width / scale)
                    }
                    .onEnded { _ in
                        if let draggingZooms { commitZooms(draggingZooms) }
                        zoomDragOrigin = nil
                    })
                .onTapGesture { selectZoom(segment.id); seek(source: segment.start) }
            zoomEdge(segment, scale: scale, edge: 1)
        }
        .frame(width: width, height: 19)
        .background(DesignColors.cameraTrack.opacity(selectedZoomID == segment.id ? 0.85 : 0.5), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(DesignColors.cameraTrack, lineWidth: 1))
        .localizedAccessibilityLabel("Zoom from \(timestamp(segment.start)) to \(timestamp(segment.end))")
        .focusable()
        .focused($focusedZoomID, equals: segment.id)
        .contextMenu {
            Button("Delete Zoom") { selectZoom(segment.id); removeSelectedZoom() }
            Button("Undo Zoom Edit") { undoZoomEdit() }.disabled(!canUndoZoom)
                    .hoverHelp(!canUndoZoom ? "There are no zoom edits to undo." : "Undo the last zoom edit.")
            Button("Restore Automatic Zooms") {
                if session == nil { zoomHistory.append(zoomSegments) }
                zoomSegments = nil
                selectedZoomID = nil
            }.disabled(zoomSegments == nil || !automaticZoomsReady)
                .hoverHelp(zoomSegments == nil ? "Automatic zooms are already in use." : !automaticZoomsReady ? "Wait for automatic zoom analysis to finish." : "Restore automatically detected zooms.")
        }
        .hoverHelp("Drag to move zoom; drag ends to change duration")
    }

    private func zoomEdge(_ segment: ZoomSegment, scale: Double, edge: Int) -> some View {
        Rectangle().fill(DesignColors.cameraTrack)
            .frame(width: 6, height: 19)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { gesture in
                    selectZoom(segment.id)
                    if zoomDragOrigin == nil { zoomDragOrigin = segment }
                    draggingZooms = adjustedZoom(zoomDragOrigin ?? segment,
                                                 delta: gesture.translation.width / scale, edge: edge)
                }
                .onEnded { _ in
                    if let draggingZooms { commitZooms(draggingZooms) }
                    zoomDragOrigin = nil
                })
    }

    private func clipStrip(index: Int, width: Double, total: Double) -> some View {
        let segment = segments[index]
        let clipWidth = max(1, width * segment.duration.seconds / total)
        let mediaClip = mediaTimeline?.video.first { $0.sourceRange == segment }
        return HStack(spacing: 0) {
            ForEach(thumbnails.indices, id: \.self) { thumbnail in
                Image(decorative: thumbnails[thumbnail], scale: 1)
                    .resizable().scaledToFill()
                    .frame(width: width * duration / total / Double(max(1, thumbnails.count)), height: 42)
                    .clipped()
            }
        }
        .offset(x: -width * segment.start.seconds / total)
        .frame(width: clipWidth, height: 42, alignment: .leading)
        .background(DesignColors.inputBackground)
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 3)
            .strokeBorder(selectedSegment == segment ? DesignColors.cameraTrack : DesignColors.accent,
                          lineWidth: selectedSegment == segment ? 3 : 1.5))
        .overlay(alignment: .topTrailing) {
            if let mediaClip, mediaTimeline?.partner(of: mediaClip, on: .screen) != nil {
                Image(systemName: "link").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white).padding(4)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if selectedSegment == segment, let mediaClip { screenClipHandle(mediaClip, beginning: true, scale: width / total) }
        }
        .overlay(alignment: .trailing) {
            if selectedSegment == segment, let mediaClip { screenClipHandle(mediaClip, beginning: false, scale: width / total) }
        }
        .opacity(movingSegment == index ? 0.5 : 1)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimTimeline"))
            .onChanged { gesture in
                selectedAudioID = nil
                selectedSegment = segment
                isVideoOverlaySelected = false
                selectedVoiceOverID = nil
                selectedZoomID = nil
                focusedZoomID = nil
                filmstripFocused = true
                player.pause()
                if abs(gesture.translation.width) > 6 {
                    movingSegment = index
                    let seconds = max(0, min(total, (gesture.location.x - 12) / width * total))
                    moveDestination = segments.indices.first { seconds < segmentOffset($0 + 1) } ?? segments.count - 1
                }
            }
            .onEnded { gesture in
                if let session, !session.draft.closesTimelineGaps, let mediaClip, abs(gesture.translation.width) > 6 {
                    session.editMediaTimeline { $0.move(mediaClip.id, on: .screen, by: gesture.translation.width / width * total) }
                } else if let movingSegment, let moveDestination {
                    moveSegment(from: movingSegment, to: moveDestination)
                } else {
                    seekOutput((gesture.location.x - 12) / width * total)
                }
                movingSegment = nil
                moveDestination = nil
            })
        .contextMenu {
            if let mediaClip, let mediaTimeline {
                let linked = mediaTimeline.partner(of: mediaClip, on: .screen) != nil
                Button(linked ? "Unlink" : "Link") {
                    selectedAudioID = nil; selectedSegment = segment; toggleMediaLink()
                }.disabled(!linked && mediaTimeline.linkCandidate(for: mediaClip, on: .screen) == nil)
                Button("Delete Screen Section") {
                    selectedAudioID = nil; selectedSegment = segment; deleteSelectedMedia()
                }.disabled(!canDeleteMedia(mediaClip, on: .screen))
                Divider()
            }
            Button("Move Earlier") { moveSegment(from: index, to: index - 1) }.disabled(index == 0)
                .hoverHelp(index == 0 ? "This is already the first video section." : "Move this section earlier.")
            Button("Move Later") { moveSegment(from: index, to: index + 1) }.disabled(index == segments.count - 1)
                .hoverHelp(index == segments.count - 1 ? "This is already the last video section." : "Move this section later.")
        }
        .localizedAccessibilityLabel("Clip \(index + 1), \(timestamp(segment.duration.seconds))")
        .accessibilityAction(named: "Move Earlier") { moveSegment(from: index, to: index - 1) }
        .accessibilityAction(named: "Move Later") { moveSegment(from: index, to: index + 1) }
        .hoverHelp(session?.draft.closesTimelineGaps == false ? "Click to select; drag to move" : "Click to select; drag to reorder")
    }

    private func screenClipHandle(_ clip: MediaTimelineClip, beginning: Bool, scale: Double) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(DesignColors.accent)
            .frame(width: 5, height: 26)
            .frame(width: 12, height: 42).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in player.pause(); filmstripFocused = true }
                .onEnded { trimMedia(clip.id, on: .screen, beginning: beginning, delta: $0.translation.width / scale) })
            .localizedAccessibilityLabel(beginning ? "Trim screen section beginning" : "Trim screen section end")
            .accessibilityAdjustableAction { direction in
                trimMedia(clip.id, on: .screen, beginning: beginning, delta: direction == .increment ? 1.0 / 30 : -1.0 / 30)
            }
    }

    private func trimHandle(isStart: Bool, width: Double) -> some View {
        Image(systemName: "line.3.horizontal")
            .rotationEffect(.degrees(90))
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 12, height: 42)
            .background(DesignColors.accent, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimTimeline"))
                .onChanged { gesture in
                    player.pause()
                    if session != nil { return }
                    let originalSegments = (try? trim.segments(duration: mediaDuration)) ?? []
                    let originalDuration = originalSegments.reduce(0) { $0 + $1.duration.seconds }
                    let delta = gesture.translation.width / width * originalDuration
                    dragging = adjustedEdge(delta: delta, isStart: isStart, from: trim)
                }
                .onEnded { gesture in
                    if let session, let clip = isStart ? session.mediaTimeline.video.first : session.mediaTimeline.video.last {
                        trimMedia(clip.id, on: .screen, beginning: isStart, delta: gesture.translation.width / width * editedDuration)
                    } else if let dragging { commit(dragging) }
                    dragging = nil
                })
            .localizedAccessibilityLabel(isStart ? "Trim start" : "Trim end")
            .localizedAccessibilityValue(String(format: "%.2f seconds", isStart ? (segments.first?.start.seconds ?? 0) : (segments.last?.end.seconds ?? duration)))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.1 : -0.1
                if let session, let clip = isStart ? session.mediaTimeline.video.first : session.mediaTimeline.video.last {
                    trimMedia(clip.id, on: .screen, beginning: isStart, delta: delta)
                } else { commit(adjustedEdge(delta: delta, isStart: isStart, from: trim)) }
            }
            .hoverHelp(isStart ? "Drag to trim the beginning" : "Drag to trim the end")
    }
}

struct VideoCutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var trim: VideoTrim
    let duration: Double
    let request: LiveVideoPreview.Request
    let hasAudio: Bool
    @State private var player = AVPlayer()
    @State private var cutStart: Double = 0
    @State private var cutEnd: Double = 1
    @State private var editingCut: UUID?
    @State private var message: String?

    private var fullRequest: LiveVideoPreview.Request {
        var settings = request.settings
        settings.trim = VideoTrim()
        return .init(source: request.source, audio: request.audio, mouse: request.mouse, webcam: request.webcam, settings: settings)
    }

    private func canAdd(_ cuts: [VideoCut]) -> Bool {
        guard !cuts.isEmpty, cuts.allSatisfy({ $0.start >= 0 && $0.end <= duration && $0.end > $0.start }) else { return false }
        var proposed = trim
        if let editingCut { proposed.cuts.removeAll { $0.id == editingCut } }
        proposed.cuts += cuts
        return (try? proposed.timeline(duration: CMTime(seconds: duration, preferredTimescale: 60000))) != nil
    }

    private func play(_ cut: VideoCut) {
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: cut.end, preferredTimescale: 60000)
        player.seek(to: CMTime(seconds: cut.start, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Removed Sections").font(.headline)
                Spacer()
                Text("Original timeline").foregroundStyle(.secondary).font(.caption)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            NativeVideoPlayerView(player: player)
                .frame(height: 210)
            HStack(spacing: 8) {
                Text("In")
                TextField("In seconds", value: $cutStart, format: .number.precision(.fractionLength(2)))
                    .frame(width: 76).localizedAccessibilityLabel("Cut start in seconds")
                Button { cutStart = max(0, min(duration, player.currentTime().seconds)) } label: { Image(systemName: "arrow.left.to.line") }
                    .hoverHelp("Set start at playhead").localizedAccessibilityLabel("Set cut start at playhead")
                Text("Out")
                TextField("Out seconds", value: $cutEnd, format: .number.precision(.fractionLength(2)))
                    .frame(width: 76).localizedAccessibilityLabel("Cut end in seconds")
                Button { cutEnd = max(0, min(duration, player.currentTime().seconds)) } label: { Image(systemName: "arrow.right.to.line") }
                    .hoverHelp("Set end at playhead").localizedAccessibilityLabel("Set cut end at playhead")
                Spacer()
                Button { play(.init(start: cutStart, end: cutEnd)) } label: { Image(systemName: "play.fill") }
                    .hoverHelp(!canAdd([.init(start: cutStart, end: cutEnd)]) ? "Choose a nonoverlapping range inside the video and keep at least one section." : "Preview selected section").localizedAccessibilityLabel("Preview selected section")
                    .disabled(!canAdd([.init(start: cutStart, end: cutEnd)]))
                Button {
                    if let editingCut { trim.cuts.removeAll { $0.id == editingCut } }
                    trim.cuts.append(.init(start: cutStart, end: cutEnd))
                    editingCut = nil
                } label: { Label(editingCut == nil ? "Remove" : "Update", systemImage: "scissors") }
                    .accessibilityIdentifier("saveCut")
                    .disabled(!canAdd([.init(start: cutStart, end: cutEnd)]))
                    .hoverHelp(!canAdd([.init(start: cutStart, end: cutEnd)]) ? "Choose a nonoverlapping range inside the video and keep at least one section." : "Remove the selected section from the video.")
                if editingCut != nil {
                    Button { editingCut = nil } label: { Image(systemName: "xmark") }
                        .hoverHelp("Cancel cut adjustment").localizedAccessibilityLabel("Cancel cut adjustment")
                }
            }
            .textFieldStyle(.roundedBorder)
            Divider()
            if let message { Text(LocalizedStringKey(message)).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(trim.cuts) { cut in
                        HStack {
                            Image(systemName: "scissors").foregroundStyle(.secondary)
                            Text(LocalizedStringKey(String(format: AppLanguage.text("Removed: %.2f - %.2f s"), locale: AppLanguage.current.locale, cut.start, cut.end))).monospacedDigit()
                            Spacer()
                            Button {
                                cutStart = cut.start
                                cutEnd = cut.end
                                editingCut = cut.id
                            } label: { Image(systemName: "pencil") }
                                .hoverHelp("Adjust section").localizedAccessibilityLabel("Adjust removed section")
                            Button { play(cut) } label: { Image(systemName: "play.fill") }
                                .hoverHelp("Preview removed section").localizedAccessibilityLabel("Preview removed section")
                            Button {
                                trim.cuts.removeAll { $0.id == cut.id }
                                if editingCut == cut.id { editingCut = nil }
                            } label: { Image(systemName: "arrow.uturn.backward") }
                                .hoverHelp("Restore section").localizedAccessibilityLabel("Restore section")
                        }
                    }
                }
            }
            .frame(minHeight: 70, maxHeight: .infinity)
            Divider()
            HStack {
                Button { trim.cuts = []; editingCut = nil } label: { Label("Restore All Cuts", systemImage: "arrow.counterclockwise") }
                    .accessibilityIdentifier("restoreAllCuts")
                    .disabled(trim.cuts.isEmpty)
                    .hoverHelp(trim.cuts.isEmpty ? "There are no removed sections to restore." : "Restore all removed sections.")
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 660, height: 620)
        .task(id: fullRequest) {
            do {
                let item = try await LiveVideoPreview.makeItem(fullRequest)
                try Task.checkCancellation()
                player.replaceCurrentItem(with: item)
                player.isMuted = false
                cutStart = trim.start
                cutEnd = min(trim.end ?? duration, cutStart + 1)
            } catch is CancellationError {
            } catch { message = error.localizedDescription }
        }
        .onDisappear { player.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            if let item = notification.object as? AVPlayerItem, item === player.currentItem {
                item.forwardPlaybackEndTime = .invalid
            }
        }
    }
}

struct NativeVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var showsControls = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = showsControls ? .inline : .none
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        nsView.controlsStyle = showsControls ? .inline : .none
    }
}

@MainActor
private final class CameraPreviewController: ObservableObject {
    @Published private(set) var session: AVCaptureSession?
    @Published private(set) var rotationAngle: CGFloat = 0
    @Published private(set) var isStarting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsPermission = false

    private(set) var recorder: WebcamRecorder?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    func start(device: AVCaptureDevice?) {
        stop()
        isStarting = true
        let previousStop = stopTask
        startTask = Task { [weak self] in
            await previousStop?.value
            guard !Task.isCancelled else { return }
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                if !Task.isCancelled {
                    self?.errorMessage = "Camera access is off. Enable it in System Settings."
                    self?.needsPermission = true
                    self?.isStarting = false
                }
                return
            }
            guard !Task.isCancelled else { return }

            let recorder = WebcamRecorder()
            do {
                try await Task.detached(priority: .userInitiated) {
                    try recorder.prepare(device: device)
                }.value
                guard !Task.isCancelled, let self else {
                    await Task.detached { recorder.tearDown() }.value
                    return
                }
                self.recorder = recorder
                self.rotationAngle = recorder.rotationAngle
                self.session = recorder.session
                self.isStarting = false
            } catch {
                await Task.detached { recorder.tearDown() }.value
                if !Task.isCancelled {
                    self?.errorMessage = error.localizedDescription
                    self?.isStarting = false
                }
            }
        }
    }

    func stop() {
        let previousStart = startTask
        let previousStop = stopTask
        startTask?.cancel()
        startTask = nil
        session = nil
        rotationAngle = 0
        isStarting = false
        errorMessage = nil
        needsPermission = false
        let recorder = self.recorder
        self.recorder = nil
        stopTask = Task.detached {
            await previousStop?.value
            await previousStart?.value
            recorder?.tearDown()
        }
    }
}

private struct CameraFeedView: NSViewRepresentable {
    let session: AVCaptureSession
    let rotationAngle: CGFloat

    func makeNSView(context: Context) -> CameraFeedNSView {
        let view = CameraFeedNSView(frame: .zero)
        view.configure(session: session, rotationAngle: rotationAngle)
        return view
    }

    func updateNSView(_ nsView: CameraFeedNSView, context: Context) {
        nsView.configure(session: session, rotationAngle: rotationAngle)
    }
}

private struct NumericSettingInput: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String
    let label: String
    var helpText: String? = nil
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(String(range.lowerBound), text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .localizedAccessibilityLabel(label)
                .onSubmit {
                    commit()
                    isFocused = false
                }
                .onExitCommand {
                    draft = String(value)
                    isFocused = false
                }
            Text(LocalizedStringKey(unit))
                .foregroundColor(DesignColors.secondaryLabel)
        }
        .font(Typography.monoSmall)
        .foregroundColor(DesignColors.primaryLabel)
        .padding(.horizontal, 8)
        .frame(width: 76, height: 32)
        .background(DesignColors.controlBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .stroke(isFocused ? DesignColors.accent : DesignColors.inputBorder, lineWidth: 1)
        )
        .hoverHelp(helpText ?? "\(label): \(range.lowerBound)–\(range.upperBound)\(unit). Press Return to apply.")
        .onAppear { draft = String(value) }
        .onChange(of: value) { newValue in
            if !isFocused { draft = String(newValue) }
        }
        .onChange(of: isFocused) { focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        if let requested = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let clamped = min(range.upperBound, max(range.lowerBound, requested))
            value = clamped
            draft = String(clamped)
        } else {
            draft = String(value)
        }
    }
}

private final class CameraFeedNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    private var rotationAngle: CGFloat = 0

    func configure(session: AVCaptureSession, rotationAngle: CGFloat) {
        previewLayer.session = session
        self.rotationAngle = rotationAngle
        updateRotation()
    }

    private func updateRotation() {
        guard rotationAngle == 90, let connection = previewLayer.connection else { return }
        if #available(macOS 14.0, *) {
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { return nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        updateRotation()
    }
}

private struct LineSlider: View {
    let selection: Binding<Double>
    let range: ClosedRange<Double>
    let label: String
    let value: String
    var thumbSize: CGFloat = 18
    var height: CGFloat = 32
    var keyboardStep: Double? = nil
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geometry in
            let progress = CGFloat((selection.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
            let trackWidth = max(0, geometry.size.width - thumbSize)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignColors.inputBorder)
                    .frame(width: trackWidth, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(DesignColors.accent)
                            .frame(width: trackWidth * min(1, max(0, progress)), height: 4)
                    }
                    .padding(.leading, thumbSize / 2)
                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(Circle().strokeBorder(isEnabled ? DesignColors.accent : DesignColors.secondaryLabel,
                                                  lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
                    .offset(x: trackWidth * min(1, max(0, progress)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled, trackWidth > 0 else { return }
                        let fraction = Double(min(1, max(0, (drag.location.x - thumbSize / 2) / trackWidth)))
                        selection.wrappedValue = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                    }
            )
            .accessibilityElement(children: .ignore)
            .localizedAccessibilityLabel(label)
            .localizedAccessibilityValue(value)
            .accessibilityAdjustableAction { direction in
                guard isEnabled else { return }
                let step = keyboardStep ?? (range.upperBound - range.lowerBound) / 100
                switch direction {
                case .increment:
                    selection.wrappedValue = min(range.upperBound, selection.wrappedValue + step)
                case .decrement:
                    selection.wrappedValue = max(range.lowerBound, selection.wrappedValue - step)
                @unknown default: break
                }
            }
            .focusable()
            .onMoveCommand { direction in
                guard isEnabled else { return }
                let step = keyboardStep ?? (range.upperBound - range.lowerBound) / 100
                switch direction {
                case .right, .up:
                    selection.wrappedValue = min(range.upperBound, selection.wrappedValue + step)
                case .left, .down:
                    selection.wrappedValue = max(range.lowerBound, selection.wrappedValue - step)
                @unknown default: break
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - App Settings

private struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system
    @AppStorage(AppLanguage.defaultsKey) private var language: AppLanguage = .system
    @State private var page: Page = .appearance

    private enum Page: String, CaseIterable {
        case appearance = "Appearance", language = "Language", aiConnection = "AI Connection"
        var symbol: String {
            switch self {
            case .appearance: return "circle.lefthalf.filled"
            case .language: return "globe"
            case .aiConnection: return "point.3.connected.trianglepath.dotted"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(CompactActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading) {
                    ForEach(Page.allCases, id: \.self) { item in
                        Button { page = item } label: {
                            Label(LocalizedStringKey(item.rawValue), systemImage: item.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(page == item ? DesignColors.accent.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(page == item ? [.isSelected] : [])
                        .accessibilityIdentifier("settings-\(item.rawValue.lowercased())")
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 170)
                .background(DesignColors.windowBackground)
                Divider()
                VStack(alignment: .leading, spacing: 28) {
                    Text(LocalizedStringKey(page.rawValue))
                        .font(.system(size: 24, weight: .semibold))
                    if page == .appearance {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Visual style")
                                .font(.system(size: 13, weight: .medium))
                            HStack(spacing: 12) {
                                Text("Mode")
                                    .font(.system(size: 13))
                                Spacer(minLength: 16)
                                ForEach(AppAppearance.allCases) { option in
                                    modeButton(option)
                                }
                            }
                            .padding(16)
                            .background(DesignColors.controlBackground, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DesignColors.inputBorder.opacity(0.5)))
                            Text("Follow System automatically matches your Mac’s light or dark appearance.")
                                .font(.system(size: 12))
                                .foregroundStyle(DesignColors.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if page == .aiConnection {
                        AIConnectionSettingsView(connection: AppState.shared.editorConnection)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 16) {
                                Text("App language")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 8)
                                Picker("App language", selection: $language) {
                                    ForEach(AppLanguage.allCases) { option in
                                        if option == .system {
                                            Text("Follow System").tag(option)
                                        } else {
                                            Text(verbatim: option.nativeName).tag(option)
                                        }
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 240)
                                .accessibilityIdentifier("appLanguagePicker")
                            }
                            .padding(16)
                            .background(DesignColors.controlBackground, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DesignColors.inputBorder.opacity(0.5)))
                            Text("Changes apply immediately. Follow System uses your Mac’s preferred language.")
                                .font(.system(size: 12))
                                .foregroundStyle(DesignColors.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if page != .aiConnection { Spacer(minLength: 0) }
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(DesignColors.primaryLabel)
        .frame(width: 760, height: 420)
        .background(DesignColors.controlBackground)
        .environment(\.locale, language.locale)
        .onExitCommand { dismiss() }
    }

    private func modeButton(_ option: AppAppearance) -> some View {
        Button {
            appearance = option
        } label: {
            VStack(spacing: 8) {
                AppearanceThumbnail(mode: option)
                    .padding(4)
                    .background(DesignColors.inputBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(appearance == option ? DesignColors.accent : DesignColors.inputBorder.opacity(0.5),
                                      lineWidth: appearance == option ? 2 : 1))
                Text(LocalizedStringKey(option.title))
                    .font(.system(size: 11, weight: appearance == option ? .semibold : .regular))
                    .foregroundStyle(appearance == option ? DesignColors.primaryLabel : DesignColors.secondaryLabel)
            }
            .frame(width: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedAccessibilityLabel(option.title)
        .accessibilityAddTraits(appearance == option ? .isSelected : [])
        .accessibilityIdentifier("appearance-\(option.rawValue)")
    }
}

private struct AIConnectionSettingsView: View {
    @ObservedObject var connection: EditorLocalServer
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect an AI assistant using MCP.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColors.secondaryLabel)
                HStack {
                    Label {
                        Text(connection.isEnabled ? "Ready to connect" : "Connection disabled")
                    } icon: {
                        Image(systemName: connection.isEnabled ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundStyle(connection.isEnabled ? DesignColors.success : DesignColors.secondaryLabel)
                    }
                    .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button(connection.isEnabled ? "Disable" : "Enable / Retry") {
                        connection.setEnabled(!connection.isEnabled)
                    }
                    .buttonStyle(CompactActionButtonStyle())
                    .accessibilityIdentifier("aiConnectionToggle")
                }
                .padding(16)
                .background(DesignColors.windowBackground, in: RoundedRectangle(cornerRadius: 12))
                if !connection.isEnabled && connection.status != "Disabled" {
                    Text(verbatim: connection.status)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColors.error)
                        .textSelection(.enabled)
                }
                Text("Connected AI clients can read media, edit, save, and export the project open in this app.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("How to set up")
                    .font(.system(size: 16, weight: .semibold))
                setupStep(1, title: "Prepare ScreenTake",
                          detail: "Enable the connection above, open a video or project, and keep ScreenTake running.")
                setupStep(2, title: "Add ScreenTake to your AI client",
                          detail: "In your AI client’s MCP server settings, add a local server with these values. The client must support local stdio connections.")
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Server name")
                        Spacer()
                        Text(verbatim: "screentake").textSelection(.enabled)
                    }
                    HStack {
                        Text("Connection type")
                        Spacer()
                        Text(verbatim: "stdio")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command")
                        Text(verbatim: connection.setupCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DesignColors.secondaryLabel)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text("Arguments")
                        Spacer()
                        Text("Leave empty")
                    }
                }
                .font(.system(size: 12))
                .padding(16)
                .background(DesignColors.windowBackground, in: RoundedRectangle(cornerRadius: 12))
                Button {
                    copied = connection.copySetup()
                } label: {
                    Label(copied ? "Copied" : "Copy Setup", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(CompactActionButtonStyle(prominent: true, size: .medium))
                .disabled(!connection.helperAvailable)
                .accessibilityIdentifier("copyAISetup")
                Text("For clients that accept mcpServers JSON, copy this configuration and merge it with any existing servers.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                if let json = connection.setupJSON {
                    DisclosureGroup("JSON configuration") {
                        Text(verbatim: json)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(DesignColors.windowBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .font(.system(size: 12))
                    .accessibilityIdentifier("aiSetupConfiguration")
                }
                if !connection.helperAvailable {
                    Text("The connection helper is missing. Reinstall ScreenTake to restore AI setup.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColors.error)
                }
                setupStep(3, title: "Reconnect and verify",
                          detail: "Save the configuration, reconnect or restart your AI client, and enable its ScreenTake tools. Then ask:")
                Text("In ScreenTake, make this video square, use the Ocean background, and round the corners.")
                    .font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignColors.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                Text("Your assistant should update the video’s canvas and styling in ScreenTake. Ready to connect means ScreenTake is available; it does not confirm that your AI client has connected.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("Connection not working?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Keep only one ScreenTake instance connected. If you move or reinstall the app, copy the setup again so your AI client uses the current command path.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setupStep(_ number: Int, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: String(number))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignColors.accent)
                .frame(width: 22, height: 22)
                .background(DesignColors.accent.opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Fixed light/dark miniatures keep every mode recognizable in either app appearance.
private struct AppearanceThumbnail: View {
    let mode: AppAppearance

    var body: some View {
        miniature(dark: mode == .dark)
            .overlay(alignment: .trailing) {
                if mode == .system {
                    miniature(dark: true)
                        .frame(width: 40, alignment: .trailing)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }

    private func miniature(dark: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 5) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 6))
                RoundedRectangle(cornerRadius: 1).frame(width: 6, height: 2)
                RoundedRectangle(cornerRadius: 1).frame(width: 6, height: 2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(dark ? Color.gray : Color.gray.opacity(0.5))
            .padding(.top, 6)
            .frame(width: 17)
            .background(dark ? Color(white: 0.21) : Color(white: 0.94))
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(DesignColors.accent.opacity(0.6))
                    .frame(width: 30, height: 2)
                RoundedRectangle(cornerRadius: 1).frame(height: 2)
                RoundedRectangle(cornerRadius: 1).frame(width: 24, height: 2)
                RoundedRectangle(cornerRadius: 1).frame(height: 2)
                HStack {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(DesignColors.accent)
                        .frame(width: 20, height: 3)
                }
            }
            .foregroundStyle(dark ? Color(white: 0.38) : Color(white: 0.85))
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dark ? Color(white: 0.1) : Color.white)
        }
        .frame(width: 80, height: 50)
    }
}
