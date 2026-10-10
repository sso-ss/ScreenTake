import AVFoundation
import Combine
import Photos
import PhotosUI
import SwiftUI

@MainActor
final class EditorModel: ObservableObject {
    @Published var settings = EditSettings()
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceSize = CGSize(width: 1080, height: 1920)
    @Published private(set) var duration = 0.0
    @Published private(set) var position = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isImporting = false
    @Published private(set) var isExporting = false
    @Published private(set) var progress = 0.0
    @Published private(set) var exportedURL: URL?
    @Published private(set) var savedToPhotos = false
    @Published private(set) var isSaving = false
    @Published private(set) var thumbnails: [UIImage] = []
    @Published var errorMessage: String?
    let player = AVPlayer()

    private var asset: AVURLAsset?
    private var frameRate: Float = 30
    private var timeObserver: Any?
    private var exportSession: AVAssetExportSession?
    private var exportTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var restored = false
    private let folder = URL.documentsDirectory.appendingPathComponent("Screen", isDirectory: true)

    var busy: Bool { isImporting || isExporting }
    var canvasSize: CGSize { settings.format.size(for: sourceSize) }

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                       queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                position = min(settings.trimEnd, max(settings.trimStart, time.seconds))
                if time.seconds >= settings.trimEnd - 0.025 {
                    pause()
                }
                isPlaying = player.rate > 0
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func importPhoto(_ item: PhotosPickerItem) async {
        guard !busy else { return }
        isImporting = true
        pause()
        defer { isImporting = false }
        do {
            guard let movie = try await item.loadTransferable(type: MovieTransfer.self) else {
                throw EditorError.unreadableVideo
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            try await importCopy(movie.url)
        } catch { errorMessage = error.localizedDescription }
    }

    func importFile(_ url: URL) async {
        guard !busy else { return }
        isImporting = true
        pause()
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
            isImporting = false
        }
        do { try await importCopy(url) }
        catch { errorMessage = error.localizedDescription }
    }

    private func importCopy(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: destination)
        let previous = sourceURL
        do {
            try await load(destination)
            saveDraft()
            if let previous { try? FileManager.default.removeItem(at: previous) }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func load(_ url: URL, draft: EditSettings? = nil) async throws {
        let imported = AVURLAsset(url: url)
        let playable = try await imported.load(.isPlayable)
        let protected = try await imported.load(.hasProtectedContent)
        guard playable, !protected,
              let track = try await imported.loadTracks(withMediaType: .video).first else {
            throw EditorError.unreadableVideo
        }
        let duration = try await imported.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw EditorError.unreadableVideo }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard size.width > 0, size.height > 0 else { throw EditorError.unreadableVideo }
        let rate = try await track.load(.nominalFrameRate)
        var edits = draft ?? EditSettings()
        if draft == nil {
            edits.trimEnd = duration
            edits.zoomEnd = min(duration, 3)
        }
        edits.constrain(to: duration)
        asset = imported
        sourceURL = url
        sourceSize = size
        self.duration = duration
        frameRate = rate > 0 ? rate : 30
        settings = edits
        thumbnails = []
        clearExport()
        let item = AVPlayerItem(asset: imported)
        item.videoComposition = VideoRenderer.composition(asset: imported, sourceSize: size,
                                                          settings: edits, frameRate: frameRate)
        item.forwardPlaybackEndTime = CMTime(seconds: edits.trimEnd, preferredTimescale: 600)
        player.replaceCurrentItem(with: item)
        player.isMuted = edits.muted
        seek(edits.trimStart)
        let generator = AVAssetImageGenerator(asset: imported)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let times = (0..<8).map { CMTime(seconds: duration * Double($0) / 8, preferredTimescale: 600) }
        for await result in generator.images(for: times) {
            if let image = try? result.image { thumbnails.append(UIImage(cgImage: image)) }
        }
    }

    func applyEdits() {
        guard let asset, !busy else { return }
        settings.constrain(to: duration)
        player.currentItem?.videoComposition = VideoRenderer.composition(asset: asset, sourceSize: sourceSize,
                                                                         settings: settings, frameRate: frameRate)
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: settings.trimEnd, preferredTimescale: 600)
        player.isMuted = settings.muted
        let target = min(settings.trimEnd, max(settings.trimStart, position))
        if !isPlaying || target != position { seek(target) }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    func seek(_ time: Double) {
        position = min(settings.trimEnd, max(settings.trimStart, time))
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlayback() {
        guard !busy else { return }
        if isPlaying { pause(); return }
        if position >= settings.trimEnd - 0.05 { seek(settings.trimStart) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func addZoomAtPlayhead() {
        settings.zoomStart = min(position, max(settings.trimStart, settings.trimEnd - 0.5))
        settings.zoomEnd = min(settings.trimEnd, settings.zoomStart + 3)
        settings.zoomEnabled = true
    }

    func beginExport() {
        guard let asset, !busy else { return }
        pause()
        saveDraft()
        clearExport()
        isExporting = true
        progress = 0
        let snapshot = settings
        let composition = VideoRenderer.composition(asset: asset, sourceSize: sourceSize,
                                                    settings: snapshot, frameRate: frameRate)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("Screen-\(UUID().uuidString.prefix(8)).mp4")
        exportTask = Task {
            defer { isExporting = false; exportSession = nil }
            do {
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
                      session.supportedFileTypes.contains(.mp4) else { throw EditorError.exportUnavailable }
                exportSession = session
                session.videoComposition = composition
                session.timeRange = CMTimeRange(start: CMTime(seconds: snapshot.trimStart, preferredTimescale: 600),
                                                duration: CMTime(seconds: snapshot.trimmedDuration, preferredTimescale: 600))
                session.shouldOptimizeForNetworkUse = true
                if snapshot.muted {
                    let mix = AVMutableAudioMix()
                    mix.inputParameters = try await asset.loadTracks(withMediaType: .audio).map { track in
                        let parameters = AVMutableAudioMixInputParameters(track: track)
                        parameters.setVolume(0, at: .zero)
                        return parameters
                    }
                    session.audioMix = mix
                }
                let progressTask = Task {
                    while !Task.isCancelled {
                        progress = Double(session.progress)
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                defer { progressTask.cancel() }
                try Task.checkCancellation()
                try await session.export(to: output, as: .mp4)
                try Task.checkCancellation()
                exportedURL = output
                progress = 1
            } catch {
                try? FileManager.default.removeItem(at: output)
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportSession?.cancelExport()
    }

    func saveToPhotos() async {
        guard let exportedURL, !isSaving, !savedToPhotos else { return }
        isSaving = true
        defer { isSaving = false }
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else {
            errorMessage = "Allow Screen to add videos in Settings > Privacy & Security > Photos, then try again. You can also use Share to save to Files."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: exportedURL)
            }
            savedToPhotos = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func clearExport() {
        if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
        exportedURL = nil
        savedToPhotos = false
    }

    func saveDraft() {
        guard let sourceURL else { return }
        do {
            let data = try JSONEncoder().encode(Draft(filename: sourceURL.lastPathComponent, settings: settings))
            try data.write(to: folder.appendingPathComponent("draft.json"), options: .atomic)
        } catch { errorMessage = "Your edits couldn't be saved: \(error.localizedDescription)" }
    }

    func restoreDraft() async {
        guard !restored, !busy else { return }
        restored = true
        let url = folder.appendingPathComponent("draft.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: url))
            try await load(folder.appendingPathComponent(draft.filename), draft: draft.settings)
        } catch { errorMessage = "Your last video couldn't be opened. You can import it again. \(error.localizedDescription)" }
    }

    private struct Draft: Codable {
        let filename: String
        let settings: EditSettings
    }
}

enum EditorError: LocalizedError {
    case unreadableVideo, exportUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadableVideo: return "This video can't be opened. Choose a playable, unprotected video."
        case .exportUnavailable: return "This video couldn't be prepared for MP4 export. Try a different recording."
        }
    }
}