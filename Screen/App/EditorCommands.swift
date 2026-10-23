import AppKit
import AVFoundation
import ImageIO

struct EditorEdits: Codable {
    var trim: VideoTrim?
    var removeRanges: [VideoCut]?
    var removeOutputRanges: [VideoCut]?
    var ratio: CanvasRatio?
    var layout: DeviceLayout?
    var wallpaper: BackgroundStyle.WallpaperPreset?
    var customBackgroundImagePath: String?
    var clearCustomBackgroundImage: Bool?
    var backgroundEnabled: Bool?
    var desktopCornerRadius: Double?
    var phoneCornerRadius: Double?
    var crop: PhoneCrop?
    var phoneMode: PhoneContentMode?
    var phoneVideoURL: URL?
    var showCursor: Bool?
    var cursorShape: CursorShape?
    var cursorScale: Double?
    var zoomEnabled: Bool?
    var zoomLevel: Double?
    var zoomTransitionMotion: ZoomTransitionMotion?
    var zoomSegments: [ZoomSegment]?
    var restoreAutomaticZooms: Bool?
    var webcamEnabled: Bool?
    var webcamShape: PiPShape?
    var webcamPosition: PiPPosition?
    var webcamSize: PiPSize?
    var cameraMirrored: Bool?
    var faceBeautyAmount: Double?
    var faceMakeup: FaceMakeupSettings?
    var cameraEffectSelection: CameraEffectSelection?
    var cameraEffectsEnabled: Bool?
    var videoOverlayURL: URL?
    var cameraLayout: CameraLayoutSettings?
    var cameraLayoutChanges: [CameraLayoutChange]?
    var videoOverlayTiming: VideoOverlayTiming?
    var voiceOvers: [VoiceOverClip]?
    var recordedAudioClips: [MediaTimelineClip]?
    var closeTimelineGaps: Bool?
    var textOverlays: [TextOverlay]?
    var audioEnabled: Bool?
    var originalAudioVolume: Double?
    var voiceOverEnabled: Bool?
    var voiceOverVolume: Double?
    var exportResolution: ExportResolution?

    func apply(to settings: inout VideoEditSettings) {
        if let trim { settings.trim = trim }
        if let removeRanges { settings.trim.cuts += removeRanges }
        if let ratio { settings.ratio = ratio }
        if let layout { settings.layout = layout }
        if let wallpaper {
            settings.wallpaper = wallpaper
            settings.customBackgroundImage = nil
        }
        if clearCustomBackgroundImage == true { settings.customBackgroundImage = nil }
        if let backgroundEnabled { settings.backgroundEnabled = backgroundEnabled }
        if let desktopCornerRadius { settings.desktopCornerRadius = desktopCornerRadius }
        if let phoneCornerRadius { settings.phoneCornerRadius = phoneCornerRadius }
        if let crop { settings.crop = crop }
        if let phoneMode { settings.phoneMode = phoneMode }
        if let phoneVideoURL { settings.phoneVideoURL = phoneVideoURL }
        if let showCursor { settings.showCursor = showCursor }
        if let cursorShape { settings.cursorShape = cursorShape }
        if let cursorScale { settings.cursorScale = cursorScale }
        if let zoomEnabled { settings.zoomEnabled = zoomEnabled }
        if let zoomLevel { settings.zoomLevel = zoomLevel }
        if let zoomTransitionMotion { settings.zoomTransitionMotion = zoomTransitionMotion }
        if let zoomSegments { settings.zoomSegments = zoomSegments }
        if restoreAutomaticZooms == true { settings.zoomSegments = nil }
        if let webcamEnabled { settings.webcamEnabled = webcamEnabled }
        if let webcamShape { settings.webcamShape = webcamShape }
        if let webcamPosition { settings.webcamPosition = webcamPosition }
        if let webcamSize { settings.webcamSize = webcamSize }
        if let cameraMirrored { settings.cameraMirrored = cameraMirrored }
        if let faceBeautyAmount { settings.faceBeautyAmount = faceBeautyAmount }
        if let faceMakeup { settings.faceMakeup = faceMakeup }
        if cameraEffectSelection != nil || cameraEffectsEnabled != nil {
            let selection = cameraEffectSelection ?? settings.resolvedCameraEffectSelection
            let enabled = cameraEffectsEnabled ?? settings.cameraEffectsEnabled
            // Retain the requested intensity so native validation rejects invalid input.
            settings.cameraEffectSelection = selection
            let amounts = selection.amounts(enabled: enabled, makeup: settings.faceMakeup ?? .init())
            settings.faceBeautyAmount = amounts.natural
            settings.faceMakeup = amounts.makeup
        }
        if let videoOverlayURL { settings.videoOverlayURL = videoOverlayURL }
        if let cameraLayout { settings.cameraLayout = cameraLayout }
        if let cameraLayoutChanges { settings.cameraLayoutChanges = cameraLayoutChanges }
        if let videoOverlayTiming { settings.videoOverlayTiming = videoOverlayTiming }
        if let voiceOvers { settings.voiceOvers = voiceOvers }
        if let recordedAudioClips { settings.recordedAudioClips = recordedAudioClips }
        if let closeTimelineGaps { settings.closeTimelineGaps = closeTimelineGaps }
        if let textOverlays { settings.textOverlays = textOverlays }
        if let audioEnabled { settings.audioEnabled = audioEnabled }
        if let originalAudioVolume { settings.originalAudioVolume = originalAudioVolume }
        if let voiceOverEnabled { settings.voiceOverEnabled = voiceOverEnabled }
        if let voiceOverVolume { settings.voiceOverVolume = voiceOverVolume }
        if let exportResolution { settings.exportResolution = exportResolution }
    }
}

struct EditorCommandRequest: Codable {
    enum Operation: String, Codable, CaseIterable {
        case getCapabilities = "get_capabilities", getProject = "get_project"
        case openVideo = "open_video", openProject = "open_project", saveProject = "save_project"
        case applyEdits = "apply_edits", setBrowserToolbarHidden = "set_browser_toolbar_hidden"
        case findSilences = "find_silences", renderPreview = "render_preview"
        case exportVideo = "export_video", getJob = "get_job", cancelJob = "cancel_job", undo, redo
    }
    var id = UUID()
    var operation: Operation
    var projectID: UUID?
    var expectedRevision: Int?
    var path: String?
    var discardUnsaved: Bool?
    var edits: EditorEdits?
    var hidden: Bool?
    var silence: SilenceDetector.Settings?
    var audioTrackID: UUID?
    var outputTime: Bool?
    var times: [Double]?
    var jobID: UUID?
}

struct EditorProjectSnapshot: Codable {
    let id: UUID
    let revision: Int
    let name: String
    let source: URL?
    let project: URL?
    let sourceDuration: Double
    let editedDuration: Double
    let settings: VideoEditSettings
    let hasUnsavedWork: Bool
    let needsRender: Bool
    let busy: Bool
    let canUndo: Bool
    let canRedo: Bool
}

struct EditorJob: Codable {
    enum Status: String, Codable { case queued, running, cancelling, cancelled, succeeded, failed }
    struct Frame: Codable { let time: Double; let url: URL }
    let id: UUID
    let operation: EditorCommandRequest.Operation
    let projectID: UUID
    let revision: Int
    var status: Status = .queued
    var progress: Double?
    var output: URL?
    var frames: [Frame]?
    var suggestions: [VideoCut]?
    var suggestionTimebase: String?
    var error: EditorCommandResponse.Failure?
}

struct EditorCommandResponse: Codable {
    struct Failure: Codable { let code: String; let message: String }
    struct Capability: Codable { let command: String; let requiresRevision: Bool; let returnsJob: Bool }
    var id: UUID?
    var ok = true
    var project: EditorProjectSnapshot?
    var job: EditorJob?
    var capabilities: [Capability]?
    var error: Failure?
}

/// Shared typed command boundary for native callers and the local MCP connection.
@MainActor
final class EditorCommandDispatcher {
    let session: EditorSession
    private var executing = false
    private var activeJob: UUID?
    private var jobs: [UUID: EditorJob] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var cache: [UUID: (Data, EditorCommandResponse)] = [:]
    private var cacheOrder: [UUID] = []
    private var jobOrder: [UUID] = []

    init(session: EditorSession) { self.session = session }

    /// Serve only registered preview artifacts, never a client-supplied file path.
    /// Thumbnails keep MCP responses bounded even for full-resolution exports.
    func previewFrameJSON(jobID: UUID, index: Int) async -> Data {
        struct FrameResult: Encodable {
            let time: Double
            let data: String
            let mimeType = "image/png"
            let width: Int
            let height: Int
        }
        struct Result: Encodable { let ok = true; let frame: FrameResult }
        do {
            guard let job = jobs[jobID], job.status == .succeeded, let frames = job.frames,
                  frames.indices.contains(index) else {
                throw CommandError("unknown_frame", "Read get_job for a completed preview job and use a valid frame index.")
            }
            let frame = frames[index]
            let result = try await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(frame.url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1024,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary),
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw CommandError("artifact_unavailable", "The preview artifact is no longer available. Render a new preview.")
                }
                return Result(frame: .init(time: frame.time, data: data.base64EncodedString(), width: image.width, height: image.height))
            }.value
            return try JSONEncoder().encode(result)
        } catch {
            return try! JSONEncoder().encode(EditorCommandResponse(ok: false, error: failure(error)))
        }
    }

    var snapshot: EditorProjectSnapshot {
        .init(id: session.projectID, revision: session.revision, name: session.projectName,
              source: session.sourceURL, project: session.projectURL, sourceDuration: session.sourceDuration,
              editedDuration: session.editedDuration, settings: session.draft,
              hasUnsavedWork: session.hasUnsavedWork, needsRender: session.hasEditChanges,
              busy: session.isBusy || activeJob != nil || executing, canUndo: session.canUndo, canRedo: session.canRedo)
    }

    func executeJSON(_ data: Data) async -> Data {
        let response: EditorCommandResponse
        do { response = await execute(try JSONDecoder().decode(EditorCommandRequest.self, from: data)) }
        catch {
            struct Header: Decodable { let id: UUID? }
            response = .init(id: (try? JSONDecoder().decode(Header.self, from: data))?.id,
                             ok: false, error: .init(code: "invalid_request", message: error.localizedDescription))
        }
        return (try? JSONEncoder().encode(response)) ?? Data("{\"ok\":false,\"error\":{\"code\":\"encoding_failed\",\"message\":\"Cannot encode the result.\"}}".utf8)
    }

    func execute(_ request: EditorCommandRequest) async -> EditorCommandResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let fingerprint = try encoder.encode(request)
            if let (original, response) = cache[request.id] {
                guard original == fingerprint else { throw CommandError("request_id_reused", "Use a new request ID for a different command.") }
                var replay = response
                if let id = response.job?.id { replay.job = jobSnapshot(id) }
                return replay
            }
            switch request.operation {
            case .getCapabilities:
                return .init(id: request.id, capabilities: EditorCommandRequest.Operation.allCases.map {
                    .init(command: $0.rawValue, requiresRevision: [.applyEdits, .setBrowserToolbarHidden, .undo, .redo, .saveProject, .exportVideo, .renderPreview, .findSilences].contains($0),
                          returnsJob: [.exportVideo, .renderPreview, .findSilences].contains($0))
                })
            case .getProject: return .init(id: request.id, project: snapshot)
            case .getJob:
                guard let id = request.jobID, let job = jobSnapshot(id) else { throw CommandError("unknown_job", "The job was not found.") }
                return .init(id: request.id, job: job)
            case .cancelJob:
                guard let id = request.jobID, var job = jobs[id] else { throw CommandError("unknown_job", "The job was not found.") }
                if [.queued, .running, .cancelling].contains(job.status) {
                    job.status = .cancelling
                    jobs[id] = job
                    tasks[id]?.cancel()
                }
                return .init(id: request.id, job: jobSnapshot(id))
            default: break
            }
            guard !executing, activeJob == nil, !session.isBusy else { throw EditorSession.SessionError.busy }
            executing = true
            defer { executing = false }
            switch request.operation {
            case .openVideo, .openProject:
                if session.videoURL != nil { try checkRevision(request) }
                guard !session.hasUnsavedWork || request.discardUnsaved == true else {
                    throw CommandError("unsaved_work", "Save the current project, or explicitly set discardUnsaved before replacing it.")
                }
                let url = try path(request.path)
                if request.operation == .openVideo { try await session.openVideo(url) }
                else { try await session.openProject(url) }
            case .saveProject:
                try checkRevision(request)
                try await session.saveProject(to: path(request.path))
            case .applyEdits:
                try checkRevision(request)
                guard let edits = request.edits else { throw CommandError("invalid_request", "Provide an edits object.") }
                let image: Data?
                if let imagePath = edits.customBackgroundImagePath {
                    let url = try path(imagePath)
                    image = try await Task.detached(priority: .userInitiated) {
                        try CustomBackgroundImage.load(from: url)
                    }.value
                } else {
                    image = nil
                }
                try checkRevision(request)
                var candidate = session.draft
                edits.apply(to: &candidate)
                if let image { candidate.customBackgroundImage = image }
                if let cuts = edits.removeOutputRanges {
                    var timeline = LinkedMediaTimeline(trim: candidate.trim, audioClips: candidate.recordedAudioClips,
                        sourceDuration: session.sourceDuration, hasAudio: session.hasEditableAudio)
                    guard timeline.cutOutput(cuts) else {
                        throw CommandError("invalid_output_ranges", "Choose nonoverlapping output-time ranges while keeping video content.")
                    }
                    candidate.trim = VideoTrim()
                    candidate.trim.clips = timeline.video
                    candidate.trim.timelineLength = timeline.duration
                    candidate.recordedAudioClips = timeline.audio
                    candidate.voiceOvers = VoiceOverClip.removing(cuts, from: candidate.voiceOvers)
                }
                try session.updateEdits { $0 = candidate }
            case .setBrowserToolbarHidden:
                try checkRevision(request)
                guard let hidden = request.hidden else { throw CommandError("invalid_request", "Provide hidden as true or false.") }
                await session.waitForPreview()
                try checkRevision(request)
                await session.setBrowserToolbarHidden(hidden)
                guard session.draft.isBrowserToolbarHidden == hidden else {
                    throw CommandError("browser_crop_failed", session.browserCropMessage ?? "The browser content could not be detected in this frame.")
                }
            case .undo:
                try checkRevision(request)
                guard session.canUndo else { throw CommandError("nothing_to_undo", "There are no edits to undo.") }
                session.undo()
            case .redo:
                try checkRevision(request)
                guard session.canRedo else { throw CommandError("nothing_to_redo", "There are no edits to redo.") }
                session.redo()
            case .findSilences, .renderPreview, .exportVideo:
                try checkRevision(request)
                if request.operation == .exportVideo { _ = try path(request.path) }
                let job = EditorJob(id: UUID(), operation: request.operation, projectID: session.projectID, revision: session.revision)
                jobs[job.id] = job
                jobOrder.append(job.id)
                activeJob = job.id
                tasks[job.id] = Task { [weak self] in await self?.runJob(job.id, request: request) }
                let response = EditorCommandResponse(id: request.id, job: job)
                remember(request.id, fingerprint, response)
                return response
            default: break
            }
            var state = snapshot
            state = EditorProjectSnapshot(id: state.id, revision: state.revision, name: state.name,
                source: state.source, project: state.project, sourceDuration: state.sourceDuration,
                editedDuration: state.editedDuration, settings: state.settings, hasUnsavedWork: state.hasUnsavedWork,
                needsRender: state.needsRender, busy: session.isBusy, canUndo: state.canUndo, canRedo: state.canRedo)
            let response = EditorCommandResponse(id: request.id, project: state)
            remember(request.id, fingerprint, response)
            return response
        } catch {
            return .init(id: request.id, ok: false, error: failure(error))
        }
    }

    private func checkRevision(_ request: EditorCommandRequest) throws {
        guard session.videoURL != nil else { throw EditorSession.SessionError.noVideo }
        guard let id = request.projectID, let revision = request.expectedRevision else {
            throw CommandError("revision_required", "Read get_project and supply its project ID and expected revision.")
        }
        guard id == session.projectID, revision == session.revision else {
            throw CommandError("stale_project", "The project changed. Read get_project before submitting another edit.")
        }
    }

    private func path(_ value: String?) throws -> URL {
        guard let value, value.hasPrefix("/"), !value.contains("\0") else {
            throw CommandError("invalid_path", "Provide an absolute local file path.")
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private func remember(_ id: UUID, _ fingerprint: Data, _ response: EditorCommandResponse) {
        cache[id] = (fingerprint, response)
        cacheOrder.append(id)
        if cacheOrder.count > 100 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    private func jobSnapshot(_ id: UUID) -> EditorJob? {
        guard var job = jobs[id] else { return nil }
        if job.status == .running && job.operation == .exportVideo {
            job.progress = session.exportProgress
        }
        return job
    }

    private func runJob(_ id: UUID, request: EditorCommandRequest) async {
        defer {
            session.isAnalyzing = false
            activeJob = nil
            tasks[id] = nil
            while jobOrder.count > 50 { jobs.removeValue(forKey: jobOrder.removeFirst()) }
        }
        do {
            try Task.checkCancellation()
            try checkRevision(request)
            jobs[id]?.status = .running
            switch request.operation {
            case .exportVideo:
                try await session.applyChanges()
                try Task.checkCancellation()
                let destination = try path(request.path)
                try await session.saveVideo(to: destination)
                jobs[id]?.output = destination
            case .findSilences:
                session.isAnalyzing = true
                let selectedClip: VoiceOverClip?
                let audio: URL
                if let audioTrackID = request.audioTrackID {
                    guard let clip = session.draft.voiceOvers.first(where: { $0.id == audioTrackID }) else {
                        throw CommandError("unknown_audio_track", "The added audio track was not found.")
                    }
                    selectedClip = clip
                    audio = clip.url
                } else {
                    guard let original = session.audioURL else { throw CleanupError.noAudio }
                    selectedClip = nil
                    audio = original
                }
                let cuts = try await SilenceDetector.suggestions(source: audio, settings: request.silence ?? .init())
                let timeline = try session.draft.trim.timeline(duration: EditorAudio.time(session.sourceDuration))
                if selectedClip != nil || request.outputTime == true {
                    let placements: [(source: Double, output: Double, duration: Double)]
                    if let clip = selectedClip {
                        placements = [(clip.sourceStart, clip.start, clip.duration)]
                    } else if let recorded = session.draft.recordedAudioClips {
                        placements = recorded.map { ($0.sourceStart, $0.start, $0.duration) }
                    } else {
                        placements = zip(timeline.ranges, timeline.outputStarts).map {
                            ($0.start.seconds, $1.seconds, $0.duration.seconds)
                        }
                    }
                    let outputCuts = cuts.flatMap { cut in placements.compactMap { placement -> VideoCut? in
                        let start = max(placement.source, cut.start)
                        let end = min(placement.source + placement.duration, cut.end)
                        return end > start ? VideoCut(start: placement.output + start - placement.source,
                                                      end: placement.output + end - placement.source) : nil
                    } }
                    jobs[id]?.suggestions = outputCuts.flatMap { cut in
                        zip(timeline.ranges, timeline.outputStarts).compactMap { range, output -> VideoCut? in
                            let start = max(output.seconds, cut.start)
                            let end = min(output.seconds + range.duration.seconds, cut.end)
                            return end > start ? VideoCut(start: start, end: end) : nil
                        }
                    }.sorted { $0.start < $1.start }
                    jobs[id]?.suggestionTimebase = "output"
                } else {
                    jobs[id]?.suggestions = cuts.flatMap { cut in timeline.ranges.compactMap { range in
                        let start = max(cut.start, range.start.seconds), end = min(cut.end, range.end.seconds)
                        return end > start ? VideoCut(start: start, end: end) : nil
                    } }
                    jobs[id]?.suggestionTimebase = "source"
                }
            case .renderPreview:
                session.isAnalyzing = true
                await session.waitForPreview()
                try Task.checkCancellation()
                guard session.previewReady, let item = session.player?.currentItem else {
                    throw CommandError("preview_unavailable", session.previewError ?? "The preview is not ready.")
                }
                let times = request.times ?? [0]
                let duration = try await item.asset.load(.duration).seconds
                guard !times.isEmpty, times.count <= 12,
                      times.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < duration }) else {
                    throw CommandError("invalid_times", "Request 1–12 timestamps inside the edited video.")
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenTake-preview-\(id)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let generator = AVAssetImageGenerator(asset: item.asset)
                generator.videoComposition = item.videoComposition
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                var frames: [EditorJob.Frame] = []
                do {
                    for (index, time) in times.enumerated() {
                        try Task.checkCancellation()
                        let image = try await generator.image(at: EditorAudio.time(time)).image
                        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                            throw CommandError("preview_failed", "The preview image could not be encoded.")
                        }
                        let url = directory.appendingPathComponent("frame-\(index).png")
                        try data.write(to: url, options: .atomic)
                        frames.append(.init(time: time, url: url))
                    }
                    jobs[id]?.frames = frames
                } catch {
                    generator.cancelAllCGImageGeneration()
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
            default: break
            }
            try Task.checkCancellation()
            jobs[id]?.status = .succeeded
            jobs[id]?.progress = 1
        } catch {
            jobs[id]?.status = Task.isCancelled || error is CancellationError ? .cancelled : .failed
            jobs[id]?.error = failure(error)
        }
    }

    private func failure(_ error: Error) -> EditorCommandResponse.Failure {
        if let error = error as? CommandError { return .init(code: error.code, message: error.message) }
        if error is CancellationError || Task.isCancelled { return .init(code: "cancelled", message: "The operation was cancelled.") }
        let code: String
        switch error {
        case EditorSession.SessionError.busy: code = "busy"
        case EditorSession.SessionError.noVideo: code = "no_video"
        case is EditValidationError, is VideoTrimError: code = "invalid_edits"
        case EditorProjectStore.ProjectError.missingMedia: code = "missing_media"
        case EditorProjectStore.ProjectError.unsupportedVersion: code = "unsupported_project_version"
        default: code = "operation_failed"
        }
        return .init(code: code, message: error.localizedDescription)
    }

    private struct CommandError: Error {
        let code: String
        let message: String
        init(_ code: String, _ message: String) { self.code = code; self.message = message }
    }
}
