import AppKit
import AVFoundation

struct EditorEdits: Codable {
    var trim: VideoTrim?
    var removeRanges: [VideoCut]?
    var ratio: CanvasRatio?
    var layout: DeviceLayout?
    var wallpaper: BackgroundStyle.WallpaperPreset?
    var backgroundEnabled: Bool?
    var desktopCornerRadius: Double?
    var crop: PhoneCrop?
    var phoneMode: PhoneContentMode?
    var phoneVideoURL: URL?
    var showCursor: Bool?
    var cursorShape: CursorShape?
    var cursorScale: Double?
    var zoomEnabled: Bool?
    var zoomLevel: Double?
    var zoomSegments: [ZoomSegment]?
    var restoreAutomaticZooms: Bool?
    var webcamEnabled: Bool?
    var webcamShape: PiPShape?
    var webcamPosition: PiPPosition?
    var webcamSize: PiPSize?
    var videoOverlayURL: URL?
    var cameraLayout: CameraLayoutSettings?
    var cameraLayoutChanges: [CameraLayoutChange]?
    var videoOverlayTiming: VideoOverlayTiming?
    var voiceOvers: [VoiceOverClip]?
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
        if let wallpaper { settings.wallpaper = wallpaper }
        if let backgroundEnabled { settings.backgroundEnabled = backgroundEnabled }
        if let desktopCornerRadius { settings.desktopCornerRadius = desktopCornerRadius }
        if let crop { settings.crop = crop }
        if let phoneMode { settings.phoneMode = phoneMode }
        if let phoneVideoURL { settings.phoneVideoURL = phoneVideoURL }
        if let showCursor { settings.showCursor = showCursor }
        if let cursorShape { settings.cursorShape = cursorShape }
        if let cursorScale { settings.cursorScale = cursorScale }
        if let zoomEnabled { settings.zoomEnabled = zoomEnabled }
        if let zoomLevel { settings.zoomLevel = zoomLevel }
        if let zoomSegments { settings.zoomSegments = zoomSegments }
        if restoreAutomaticZooms == true { settings.zoomSegments = nil }
        if let webcamEnabled { settings.webcamEnabled = webcamEnabled }
        if let webcamShape { settings.webcamShape = webcamShape }
        if let webcamPosition { settings.webcamPosition = webcamPosition }
        if let webcamSize { settings.webcamSize = webcamSize }
        if let videoOverlayURL { settings.videoOverlayURL = videoOverlayURL }
        if let cameraLayout { settings.cameraLayout = cameraLayout }
        if let cameraLayoutChanges { settings.cameraLayoutChanges = cameraLayoutChanges }
        if let videoOverlayTiming { settings.videoOverlayTiming = videoOverlayTiming }
        if let voiceOvers { settings.voiceOvers = voiceOvers }
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
        case applyEdits = "apply_edits", findSilences = "find_silences", renderPreview = "render_preview"
        case exportVideo = "export_video", getJob = "get_job", cancelJob = "cancel_job", undo, redo
    }
    var id = UUID()
    var operation: Operation
    var projectID: UUID?
    var expectedRevision: Int?
    var path: String?
    var discardUnsaved: Bool?
    var edits: EditorEdits?
    var silence: SilenceDetector.Settings?
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

/// In-process, typed command boundary. A future MCP adapter only needs to transport
/// these requests; it must not implement separate edits or rendering behavior.
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
                    .init(command: $0.rawValue, requiresRevision: [.applyEdits, .undo, .redo, .saveProject, .exportVideo, .renderPreview, .findSilences].contains($0),
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
                try session.updateEdits { edits.apply(to: &$0) }
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
                guard let audio = session.audioURL else { throw CleanupError.noAudio }
                let cuts = try await SilenceDetector.suggestions(source: audio, settings: request.silence ?? .init())
                let ranges = try session.draft.trim.timeline(duration: EditorAudio.time(session.sourceDuration)).ranges
                jobs[id]?.suggestions = cuts.flatMap { cut in ranges.compactMap { range in
                    let start = max(cut.start, range.start.seconds), end = min(cut.end, range.end.seconds)
                    return end > start ? VideoCut(start: start, end: end) : nil
                } }
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
