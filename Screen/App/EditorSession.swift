import AVFoundation
import Combine

/// The editable video, shared by the native editor and future automation clients.
/// Original media is retained; preview and export always evaluate the draft from it.
@MainActor
final class EditorSession: ObservableObject {
    let id = UUID()
    @Published private(set) var projectID = UUID()
    @Published private(set) var revision = 0
    @Published private(set) var projectURL: URL?
    @Published private(set) var projectName = "Untitled"
    private var savedProjectRevision: Int?
    private var requiresRender = false
    @Published private(set) var videoURL: URL?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var audioURL: URL?
    @Published private(set) var mouseURL: URL?
    @Published private(set) var player: AVPlayer? {
        didSet {
            if let player { playback.attach(player) }
            else { playback.detach() }
        }
    }
    // Playback observation has the same lifetime as the player, including while
    // SwiftUI recreates the timeline or replaces the live preview item.
    let playback = TimelinePlayback()
    @Published private(set) var sourceDuration: Double = 0
    @Published private(set) var sourceVideoSize: CGSize?
    @Published private(set) var hasEditableAudio = false
    @Published private(set) var appliedEdits = VideoEditSettings()
    @Published var draft = VideoEditSettings() {
        didSet {
            guard draft != oldValue, !restoring, !normalizingDraft else { return }
            if draft.crop != oldValue.crop {
                browserCropMessage = nil
                // A manual crop takes ownership. It must not leave the toggle
                // on with a stale restore point that would discard that edit.
                if draft.browserToolbarCrop == oldValue.browserToolbarCrop {
                    normalizingDraft = true
                    draft.browserToolbarCrop = nil
                    normalizingDraft = false
                }
            }
            revision += 1
            if groupDepth == 0 { remember(oldValue) }
            schedulePreview()
            synchronizeUnsavedWork()
        }
    }

    // Selection belongs to the session so it survives recreation of the editor view.
    @Published var selectedVoiceOverID: UUID?
    @Published var selectedZoomID: UUID?
    @Published var isVideoOverlaySelected = false
    @Published var selectedSegment: CMTimeRange?
    @Published var selectedRecordedAudioID: UUID?
    @Published var automaticZooms: [ZoomSegment] = []
    @Published var zoomPadding: CGFloat = 0

    @Published private(set) var previewReady = false
    @Published private(set) var previewError: String?
    @Published private(set) var renderedPreviewTimeline: EditedTimeline?
    @Published private(set) var isPreparingFaceTracking = false
    @Published private(set) var isLoading = false
    @Published private(set) var isExporting = false
    @Published private(set) var isSaving = false
    @Published var isAnalyzing = false
    @Published private(set) var isDetectingBrowser = false
    @Published private(set) var browserCropMessage: String?
    @Published private(set) var undoEdits: [VideoEditSettings] = []
    @Published private(set) var redoEdits: [VideoEditSettings] = []
    @Published var exportError: String?
    @Published var saveError: String?
    let exportEngine = ExportEngine()
    let voiceOverRecorder = VoiceOverRecorder()
    let videoOverlayRecorder = VideoOverlayRecorder()

    private weak var appState: AppState?
    private var videoWork = VideoReplacementState<VideoEditSettings>()
    private var previewTask: Task<Void, Never>?
    private var previewID = UUID()
    private var loadID = UUID()
    private var restoring = false
    private var normalizingDraft = false
    private var groupDepth = 0
    private var groupStart: VideoEditSettings?
    private var cancellables = Set<AnyCancellable>()

    init() {
        for publisher in [exportEngine.objectWillChange, voiceOverRecorder.objectWillChange,
                          videoOverlayRecorder.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
        voiceOverRecorder.$isBusy.combineLatest(videoOverlayRecorder.$isBusy)
            .dropFirst()
            .sink { [weak self] voice, camera in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appState?.isRecordingVoiceOver = voice
                    self.appState?.isRecordingCameraOverlay = camera
                    if !voice && !camera { self.schedulePreview() }
                }
            }.store(in: &cancellables)
    }

    func configure(appState: AppState) { self.appState = appState }

    var editingRecording: Bool {
        sourceURL != nil && sourceURL == appState?.recording.lastSourceRecordingURL
    }
    var hasEditChanges: Bool { requiresRender || draft != appliedEdits }
    var hasUnsavedWork: Bool {
        guard videoURL != nil else { return false }
        if projectURL != nil { return savedProjectRevision != revision }
        return videoWork.needsConfirmation(for: draft)
    }
    var hasValidTimeline: Bool { sourceDuration > 0 && (try? draft.trim.timeline(duration: EditorAudio.time(sourceDuration))) != nil }
    var editedDuration: Double { (try? draft.trim.timeline(duration: EditorAudio.time(sourceDuration)).duration.seconds) ?? 0 }
    var exportProgress: Double? {
        editingRecording ? appState?.recording.processingProgress : exportEngine.progress
    }
    var isBusy: Bool {
        isLoading || isExporting || isSaving || isAnalyzing || voiceOverRecorder.isBusy || videoOverlayRecorder.isBusy
            || appState?.isRecording == true || appState?.recording.processingStage != nil
    }
    var canUndo: Bool { !undoEdits.isEmpty && !isBusy && groupDepth == 0 }
    var canRedo: Bool { !redoEdits.isEmpty && !isBusy && groupDepth == 0 }

    /// Validates the new source before replacing the active session.
    func openVideo(_ url: URL) async throws {
        try await openSource(url, project: nil)
    }

    func openProject(_ package: URL) async throws {
        guard !isBusy else { throw SessionError.busy }
        isLoading = true
        let requestID = UUID()
        loadID = requestID
        do {
            let project = try await EditorProjectStore.load(from: package)
            guard loadID == requestID else { throw CancellationError() }
            isLoading = false
            try await openSource(project.source, project: project, package: package)
        } catch {
            if loadID == requestID { isLoading = false }
            throw error
        }
    }

    private func openSource(_ url: URL, project: EditorProject?, package: URL? = nil) async throws {
        guard !isBusy else { throw SessionError.busy }
        isLoading = true
        let requestID = UUID()
        loadID = requestID
        defer { if loadID == requestID { isLoading = false } }
        let recording = appState?.recording
        let rawSource = project == nil && url == recording?.lastRecordingURL ? recording?.lastSourceRecordingURL : nil
        let source = rawSource ?? url
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let recordingAudio = rawSource != nil ? try await recording?.preparePreviewAudio() : nil
        try Task.checkCancellation()
        guard loadID == requestID else { throw CancellationError() }

        var settings = project?.settings ?? (rawSource != nil
            ? (recording?.lastAppliedEdits ?? recording?.initialEdits ?? VideoEditSettings())
            : VideoEditSettings(backgroundEnabled: false, showCursor: false))
        if rawSource != nil, recording?.lastAppliedEdits == nil { settings.videoOverlayURL = recording?.lastWebcamVideoURL }
        if rawSource != nil, settings.phoneVideoURL == nil { settings.phoneVideoURL = appState?.capture.phoneVideoURL }
        try settings.validate(duration: duration)

        invalidatePreview()
        player?.pause()
        videoURL = url
        sourceURL = source
        sourceDuration = duration
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        sourceVideoSize = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        audioURL = project?.audio ?? (rawSource != nil ? (recordingAudio ?? source) : url)
        mouseURL = project?.mouse ?? (rawSource != nil ? recording?.lastMouseDataURL : nil)
        hasEditableAudio = !audio.isEmpty || audioURL != source
        restoring = true
        draft = settings
        restoring = false
        appliedEdits = settings
        projectID = project?.id ?? UUID()
        revision = project?.revision ?? 0
        projectName = project?.name ?? url.deletingPathExtension().lastPathComponent
        projectURL = package
        savedProjectRevision = package == nil ? nil : revision
        requiresRender = project != nil || (rawSource != nil && recording?.lastAppliedEdits == nil)
        videoWork.beginVideo(edits: settings, needsDownload: url == recording?.lastRecordingURL && url != recording?.lastSavedRecordingURL)
        clearSelection()
        automaticZooms = []
        zoomPadding = 0
        undoEdits = []
        redoEdits = []
        groupDepth = 0
        groupStart = nil
        exportError = nil
        saveError = nil
        renderedPreviewTimeline = nil
        browserCropMessage = nil
        player = AVPlayer()
        synchronizeUnsavedWork()
        schedulePreview()
        await waitForPreview()
        try Task.checkCancellation()
        guard loadID == requestID else { throw CancellationError() }
    }

    func close() {
        guard !isExporting, !isSaving, !isAnalyzing, !voiceOverRecorder.isBusy, !videoOverlayRecorder.isBusy else { return }
        loadID = UUID()
        isLoading = false
        invalidatePreview()
        player?.pause()
        player = nil
        videoURL = nil
        sourceURL = nil
        audioURL = nil
        mouseURL = nil
        sourceDuration = 0
        sourceVideoSize = nil
        projectURL = nil
        savedProjectRevision = nil
        requiresRender = false
        hasEditableAudio = false
        renderedPreviewTimeline = nil
        browserCropMessage = nil
        undoEdits = []
        redoEdits = []
        groupDepth = 0
        groupStart = nil
        clearSelection()
        synchronizeUnsavedWork()
    }

    /// Apply through the ordinary crop pipeline so preview, export, project save,
    /// manual adjustment, and undo all use exactly the same bounds.
    func setBrowserToolbarHidden(_ hidden: Bool) async {
        guard !isBusy, let sourceURL, let player else { return }
        guard hidden != draft.isBrowserToolbarHidden else { return }
        if !hidden {
            guard let toolbar = draft.browserToolbarCrop else { return }
            player.pause()
            var settings = draft
            settings.crop = toolbar.previousCrop
            settings.browserToolbarCrop = nil
            draft = settings
            browserCropMessage = nil
            return
        }
        guard previewReady else { return }
        player.pause()
        let requestID = loadID
        let previousCrop = draft.crop
        let time = renderedPreviewTimeline?.sourceTime(at: player.currentTime()).seconds ?? 0
        browserCropMessage = nil
        isDetectingBrowser = true
        isAnalyzing = true
        defer { isDetectingBrowser = false; isAnalyzing = false }
        do {
            let content: CGRect
            if let recorded = draft.recordedBrowserContentRect, BrowserContentDetector.valid(recorded) {
                content = recorded
            } else {
                content = try await BrowserContentDetector.detect(in: sourceURL, at: time)
            }
            guard requestID == loadID, self.sourceURL == sourceURL, draft.crop == previousCrop else { return }
            let rect = previousCrop.normalized.intersection(content)
            guard !rect.isNull, rect.width >= 0.02, rect.height >= 0.02 else {
                throw BrowserContentDetector.DetectionError.notFound
            }
            var settings = draft
            settings.crop = PhoneCrop(rect: rect)
            settings.browserToolbarCrop = BrowserToolbarCrop(previousCrop: previousCrop)
            draft = settings
            browserCropMessage = nil
        } catch {
            guard requestID == loadID else { return }
            browserCropMessage = error.localizedDescription
        }
    }

    /// Native bindings and direct callers both enter the same draft/history pipeline.
    func updateEdits(_ change: (inout VideoEditSettings) -> Void) throws {
        guard !isBusy else { throw SessionError.busy }
        guard videoURL != nil else { throw SessionError.noVideo }
        var candidate = draft
        change(&candidate)
        if draft.trim.clips != nil, candidate.trim.clips == draft.trim.clips,
           candidate.trim != draft.trim {
            // Existing source-based commands and silence cleanup still honor independent audio.
            _ = try candidate.trim.timeRange(duration: EditorAudio.time(sourceDuration))
            let cuts = candidate.trim.cuts.filter { !draft.trim.cuts.contains($0) }
                + (candidate.trim.start > draft.trim.start ? [VideoCut(start: 0, end: candidate.trim.start)] : [])
                + ((candidate.trim.end ?? sourceDuration) < (draft.trim.end ?? sourceDuration)
                    ? [VideoCut(start: candidate.trim.end ?? sourceDuration, end: sourceDuration)] : [])
            if !cuts.isEmpty {
                var timeline = mediaTimeline
                guard timeline.cutSources(cuts, closeGaps: candidate.closesTimelineGaps) else { throw VideoTrimError.emptySelection }
                candidate.trim = VideoTrim()
                candidate.trim.clips = timeline.video
                candidate.trim.timelineLength = timeline.duration
                candidate.recordedAudioClips = timeline.audio
            }
        }
        try candidate.validate(duration: sourceDuration)
        draft = candidate
    }

    func resetPendingChanges() {
        guard !isBusy else { return }
        draft = appliedEdits
        clearSelection()
    }

    func beginUndoGroup() {
        if groupDepth == 0 { groupStart = draft }
        groupDepth += 1
    }

    func endUndoGroup() {
        guard groupDepth > 0 else { return }
        groupDepth -= 1
        if groupDepth == 0, let start = groupStart {
            groupStart = nil
            if start != draft { remember(start) }
        }
    }

    var mediaTimeline: LinkedMediaTimeline {
        LinkedMediaTimeline(trim: draft.trim, audioClips: draft.recordedAudioClips,
                            sourceDuration: sourceDuration, hasAudio: hasEditableAudio)
    }

    /// One assignment keeps the paired tracks, preview and Undo in a single transaction.
    @discardableResult
    func editMediaTimeline(_ edit: (inout LinkedMediaTimeline) -> Bool) -> Bool {
        guard !isBusy else { return false }
        var timeline = mediaTimeline
        guard edit(&timeline) else { return false }
        var settings = draft
        settings.trim = VideoTrim()
        settings.trim.clips = timeline.video
        settings.trim.timelineLength = timeline.duration
        settings.recordedAudioClips = timeline.audio
        guard (try? settings.validate(duration: sourceDuration)) != nil else { return false }
        player?.pause()
        draft = settings
        return true
    }

    func undo() {
        guard canUndo, let previous = undoEdits.popLast() else { return }
        redoEdits.append(draft)
        restore(previous)
    }

    func redo() {
        guard canRedo, let next = redoEdits.popLast() else { return }
        undoEdits.append(draft)
        restore(next)
    }

    private func remember(_ edits: VideoEditSettings) {
        undoEdits.append(edits)
        if undoEdits.count > 100 { undoEdits.removeFirst() }
        redoEdits = []
    }

    private func restore(_ edits: VideoEditSettings) {
        player?.pause()
        browserCropMessage = nil
        restoring = true
        draft = edits
        restoring = false
        revision += 1
        clearSelection()
        schedulePreview()
        synchronizeUnsavedWork()
    }

    private func clearSelection() {
        selectedVoiceOverID = nil
        selectedRecordedAudioID = nil
        selectedZoomID = nil
        selectedSegment = nil
        isVideoOverlaySelected = false
    }

    private func synchronizeUnsavedWork() {
        appState?.updateUnsavedVideoWork(session: id, hasUnsavedWork: hasUnsavedWork)
    }

    var previewRequest: LiveVideoPreview.Request? {
        guard videoURL != nil, let sourceURL else { return nil }
        var settings = draft
        settings.trim.splits = []
        return .init(source: sourceURL, audio: audioURL, mouse: mouseURL,
                     webcam: settings.videoOverlayURL, settings: settings)
    }

    private func invalidatePreview() {
        previewTask?.cancel()
        previewTask = nil
        previewID = UUID()
        previewReady = false
        previewError = nil
        isPreparingFaceTracking = false
    }

    private func schedulePreview() {
        guard !voiceOverRecorder.isBusy, !videoOverlayRecorder.isBusy,
              let request = previewRequest, let player else { return }
        invalidatePreview()
        let requestID = previewID
        isPreparingFaceTracking = request.settings.usesFaceTracking && request.webcam != nil
        previewTask = Task { [weak self] in
            await self?.refreshPreview(request, player: player, requestID: requestID)
        }
    }

    func waitForPreview() async { await previewTask?.value }

    private func refreshPreview(_ request: LiveVideoPreview.Request, player: AVPlayer, requestID: UUID) async {
        defer { if previewID == requestID { isPreparingFaceTracking = false } }
        do {
            let item = try await LiveVideoPreview.makeItem(request)
            try Task.checkCancellation()
            guard previewID == requestID, player === self.player else { return }
            let time = player.currentTime()
            let rate = player.rate
            let sourceTime = renderedPreviewTimeline?.sourceTime(at: time) ?? .zero
            let duration = try await AVURLAsset(url: request.source).load(.duration)
            let timeline = try request.settings.trim.timeline(duration: duration)
            let itemDuration = try await item.asset.load(.duration)
            try Task.checkCancellation()
            guard previewID == requestID, player === self.player else { return }
            player.replaceCurrentItem(with: item)
            renderedPreviewTimeline = timeline
            player.isMuted = false
            let mappedTime = sourceTime.isNumeric ? timeline.outputTime(at: sourceTime) : time
            await player.seek(to: mappedTime.isNumeric ? CMTimeMinimum(mappedTime, itemDuration) : .zero,
                              toleranceBefore: .zero, toleranceAfter: .zero)
            try Task.checkCancellation()
            guard previewID == requestID, player === self.player else { return }
            if rate > 0 { player.rate = rate }
            previewReady = true
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, previewID == requestID else { return }
            previewError = "Preview unavailable: \(error.localizedDescription)"
        }
    }

    /// Renders the current draft from the retained source. No view or save panel is needed.
    @discardableResult
    func applyChanges() async throws -> URL {
        guard !isBusy, appState?.updates.isPresenting != true else { throw SessionError.busy }
        guard let sourceURL else { throw SessionError.noVideo }
        guard hasValidTimeline else { throw VideoTrimError.invalidRange }
        try draft.validate(duration: sourceDuration)
        player?.pause()
        let settings = draft
        isExporting = true
        appState?.isExportingVideo = true
        exportError = nil
        defer { isExporting = false; appState?.isExportingVideo = false }
        do {
            let result: URL
            if editingRecording, let recording = appState?.recording {
                await recording.applyEdits(settings)
                if let error = recording.processingError { throw SessionError.processingFailed(error) }
                guard let url = recording.lastRecordingURL else { throw SessionError.noVideo }
                result = url
            } else {
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("Screen-layout-\(UUID().uuidString).mov")
                let keyframes = settings.zoomEnabled && mouseURL != nil
                    ? try await ClickZoomGenerator.generate(from: mouseURL!, sourceVideoURL: sourceURL,
                        settings: .init(zoomLevel: settings.zoomLevel), segments: settings.zoomSegments) : []
                var rendered = try await exportEngine.export(sourceURL: sourceURL, keyframes: keyframes, configuration: .init(
                    outputURL: output,
                    webcamVideoURL: settings.webcamEnabled ? settings.videoOverlayURL : nil,
                    videoOverlayTiming: settings.videoOverlayTiming, videoOverlayTrim: settings.trim,
                    pipPosition: settings.webcamPosition, pipSize: settings.webcamSize, pipShape: settings.webcamShape,
                    cameraLayout: settings.cameraLayout, cameraLayoutChanges: settings.cameraLayoutChanges,
                    faceBeautyAmount: settings.faceBeautyAmount ?? 0,
                    faceMakeup: settings.faceMakeup ?? .init(),
                    mouseDataURL: mouseURL, cursorScale: settings.cursorScale, cursorShape: settings.cursorShape,
                    showCursor: settings.showCursor && mouseURL != nil, canvasRatio: settings.ratio, deviceLayout: settings.layout,
                    wallpaper: settings.wallpaper, desktopCornerRadius: settings.desktopCornerRadius,
                    phoneVideoURL: settings.phoneVideoURL,
                    preserveSourceAudio: settings.audioEnabled && audioURL == sourceURL, phoneCrop: settings.crop,
                    phoneContentMode: settings.phoneMode, forceCanvas: settings.backgroundEnabled,
                    exportResolution: settings.exportResolution))
                if settings.audioEnabled, let audioURL, audioURL != sourceURL {
                    rendered = try await MediaMuxer.mux(videoURL: rendered, systemAudioURL: audioURL,
                                                       micAudioURL: nil, removeSourceAudio: false)
                }
                let trimmed = try await settings.trim.export(source: rendered)
                result = try await EditorAudio.export(video: trimmed, originalEnabled: settings.audioEnabled,
                    originalVolume: settings.originalAudioVolume,
                    clips: settings.voiceOverEnabled ? settings.voiceOvers : [], voiceOverVolume: settings.voiceOverVolume,
                    recordedSource: audioURL, recordedClips: settings.recordedAudioClips)
            }
            try Task.checkCancellation()
            videoURL = result
            appliedEdits = settings
            requiresRender = false
            videoWork.markRendered()
            synchronizeUnsavedWork()
            return result
        } catch {
            exportError = error.localizedDescription
            throw error
        }
    }

    func saveVideo(to destination: URL) async throws {
        guard !isBusy else { throw SessionError.busy }
        guard videoURL != nil else { throw SessionError.noVideo }
        let retained = [sourceURL, audioURL, mouseURL] + ([draft, appliedEdits] + undoEdits + redoEdits).flatMap {
            [$0.videoOverlayURL, $0.phoneVideoURL] + $0.voiceOvers.map { Optional($0.url) }
        }
        let resolvedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !retained.compactMap({ $0 }).contains(where: {
            $0.standardizedFileURL.resolvingSymlinksInPath() == resolvedDestination
        }) || (videoURL != sourceURL && videoURL?.standardizedFileURL.resolvingSymlinksInPath() == resolvedDestination) else {
            throw SessionError.retainedMediaDestination
        }
        if hasEditChanges { try await applyChanges() }
        guard let source = videoURL else { throw SessionError.noVideo }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            if let recording = appState?.recording {
                try await recording.saveRecording(from: source, to: destination)
            } else {
                try await VideoFileStore.copy(from: source, to: destination)
            }
            videoURL = destination
            videoWork.markDownloaded(edits: appliedEdits)
            synchronizeUnsavedWork()
        } catch {
            saveError = "The original recording is still available. \(error.localizedDescription)"
            throw error
        }
    }

    func saveProject(to destination: URL, name: String? = nil) async throws {
        guard !isBusy else { throw SessionError.busy }
        guard let sourceURL else { throw SessionError.noVideo }
        try draft.validate(duration: sourceDuration)
        let project = EditorProject(id: projectID, revision: revision, name: name ?? projectName,
                                    source: sourceURL, audio: audioURL, mouse: mouseURL, settings: draft)
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EditorProjectStore.ProjectError.invalidManifest
        }
        isSaving = true
        defer { isSaving = false }
        let result = try await EditorProjectStore.save(project, to: destination,
                                                       retaining: [appliedEdits] + undoEdits + redoEdits)
        func remap(_ settings: VideoEditSettings) -> VideoEditSettings {
            var value = settings
            value.phoneVideoURL = value.phoneVideoURL.map { result.mediaMappings[$0.standardizedFileURL] ?? $0 }
            value.videoOverlayURL = value.videoOverlayURL.map { result.mediaMappings[$0.standardizedFileURL] ?? $0 }
            for index in value.voiceOvers.indices {
                value.voiceOvers[index].url = result.mediaMappings[value.voiceOvers[index].url.standardizedFileURL] ?? value.voiceOvers[index].url
            }
            return value
        }
        if sourceURL == videoURL { videoURL = result.project.source }
        self.sourceURL = result.project.source
        audioURL = result.project.audio
        mouseURL = result.project.mouse
        restoring = true
        draft = remap(draft)
        appliedEdits = remap(appliedEdits)
        undoEdits = undoEdits.map(remap)
        redoEdits = redoEdits.map(remap)
        restoring = false
        projectURL = destination
        projectName = project.name
        savedProjectRevision = project.revision
        schedulePreview()
        synchronizeUnsavedWork()
    }

    enum SessionError: LocalizedError {
        case busy, noVideo, pendingChanges, retainedMediaDestination, processingFailed(String)
        var errorDescription: String? {
            switch self {
            case .busy: return "Wait for the current operation to finish."
            case .noVideo: return "Open a video before editing."
            case .pendingChanges: return "Apply your changes before downloading the video."
            case .retainedMediaDestination: return "Choose a different destination to keep the project's original media intact."
            case .processingFailed(let message): return message
            }
        }
    }
}
