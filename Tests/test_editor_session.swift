import AppKit
import AVFoundation
import CoreImage
import SwiftUI
import Darwin

@main
struct EditorSessionChecks {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("editor-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeVideo(source)
        let audio = directory.appendingPathComponent("audio.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)!
        samples.frameLength = samples.frameCapacity
        for index in 0..<144000 {
            samples.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48000) * 0.2)
        }
        try AVAudioFile(forWriting: audio, settings: format.settings).write(from: samples)
        _ = try await MediaMuxer.mux(videoURL: source, systemAudioURL: audio, micAudioURL: nil)
        let original = try Data(contentsOf: source)

        let session = EditorSession()
        try await session.openVideo(source)
        precondition(session.sourceURL == source && session.videoURL == source)
        precondition(session.sourceVideoSize == CGSize(width: 320, height: 200))
        precondition(session.previewReady && session.hasEditableAudio && !session.isBusy)
        precondition(!session.hasEditChanges && !session.hasUnsavedWork && !session.canUndo)
        let player = session.player!
        // Observation must begin before any timeline view exists.
        try await checkPlayback(session)

        // One direct edit operation updates the same draft and preview used by the UI.
        try session.updateEdits {
            $0.trim.cuts = [.init(start: 1, end: 2)]
            $0.ratio = .portrait
            $0.backgroundEnabled = true
        }
        await session.waitForPreview()
        precondition(session.hasEditChanges && session.hasUnsavedWork && session.canUndo)
        precondition(session.editedDuration == 2 && session.previewReady)
        precondition(session.player === player, "Editing must retain the player and playback identity")
        try await checkPlayback(session)
        let edited = session.draft
        let preview = session.player!.currentItem!
        let previewDuration = try await preview.asset.load(.duration).seconds
        precondition(abs(previewDuration - 2) < 0.002)
        let expectedSize = edited.outputSize(source: session.sourceVideoSize!)
        precondition(preview.videoComposition!.renderSize == expectedSize)
        try await checkFrames(asset: preview.asset, composition: preview.videoComposition)

        session.selectedZoomID = UUID()
        session.undo()
        precondition(session.draft == session.appliedEdits && session.selectedZoomID == nil && session.canRedo)
        session.redo()
        precondition(session.draft == edited && !session.canRedo)
        session.resetPendingChanges()
        precondition(!session.hasEditChanges)
        session.undo()
        precondition(session.draft == edited, "Reset must be undoable")

        let beforeInvalid = session.draft
        do {
            try session.updateEdits { $0.trim.start = .nan }
            preconditionFailure("Invalid trim accepted")
        } catch VideoTrimError.invalidRange { }
        precondition(session.draft == beforeInvalid)
        do {
            try await session.openVideo(directory.appendingPathComponent("missing.mov"))
            preconditionFailure("Missing source accepted")
        } catch { }
        precondition(session.sourceURL == source && session.draft == beforeInvalid && !session.isBusy)

        // Production bindings enter the same history pipeline, including compound edits.
        session.beginUndoGroup()
        session.draft.wallpaper = .ocean
        session.draft.desktopCornerRadius = 0.04
        session.endUndoGroup()
        session.undo()
        precondition(session.draft == edited, "A compound edit must undo in one operation")
        session.redo()
        session.undo()

        // Recreating the editor must retain draft edits, selection, and undo history.
        session.selectedSegment = try session.draft.trim.segments(duration: EditorAudio.time(3)).first
        let selected = session.selectedSegment
        let undoCount = session.undoEdits.count
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1050, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SettingsView(session: session).environmentObject(AppState.shared))
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 400_000_000)
        window.contentView = NSHostingView(rootView: SettingsView(session: session).environmentObject(AppState.shared))
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(session.draft == edited && session.undoEdits.count == undoCount && session.selectedSegment == selected)
        try await checkPlayback(session)
        window.contentView = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        try await checkPlayback(session)
        window.orderOut(nil)
        print("PASS: direct edits, shared native bindings, preview dimensions/timing, undo/redo, validation, and editor recreation")

        // Export and download require no controls or save panel.
        let output = try await session.applyChanges()
        let exportedAsset = AVURLAsset(url: output)
        precondition(session.sourceURL == source && session.player === player && !session.hasEditChanges)
        precondition(session.hasUnsavedWork && !session.isExporting)
        let exportedDuration = try await exportedAsset.load(.duration).seconds
        precondition(abs(exportedDuration - 2) < 0.002)
        let video = try await exportedAsset.loadTracks(withMediaType: .video).first!
        let exportedSize = try await video.load(.naturalSize)
        precondition(exportedSize == expectedSize)
        let exportedAudio = try await exportedAsset.loadTracks(withMediaType: .audio)
        precondition(!exportedAudio.isEmpty)
        try await checkFrames(asset: exportedAsset, composition: nil)
        let destination = directory.appendingPathComponent("download.mov")
        try Data("old destination".utf8).write(to: destination)
        try await session.saveVideo(to: destination)
        let downloadedData = try Data(contentsOf: destination)
        let outputData = try Data(contentsOf: output)
        precondition(downloadedData == outputData)
        precondition(session.videoURL == destination && session.sourceURL == source && !session.hasUnsavedWork)
        let remainingSource = try Data(contentsOf: source)
        precondition(remainingSource == original, "Original media was modified")
        print("PASS: real export dimensions, cut pixels and audio, atomic download, and original source preservation")

        // A long imported clip can produce several large intermediate files.
        // Keep only the active render, including when the audio stage fails.
        let firstRenderDirectory = output.deletingLastPathComponent()
        let firstRenderFiles = try FileManager.default.contentsOfDirectory(at: firstRenderDirectory, includingPropertiesForKeys: nil)
        precondition(firstRenderFiles.count == 1, "Trim intermediate was retained")
        session.draft.originalAudioVolume = 0.5
        let currentRender = try await session.applyChanges()
        let currentDirectory = currentRender.deletingLastPathComponent()
        precondition(!FileManager.default.fileExists(atPath: firstRenderDirectory.path), "Obsolete render was retained")
        let currentFiles = try FileManager.default.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: nil)
        precondition(currentFiles.count == 1 && currentFiles[0].standardizedFileURL.resolvingSymlinksInPath()
            == currentRender.standardizedFileURL.resolvingSymlinksInPath(), "Audio intermediate was retained")
        let lostVoiceOver = directory.appendingPathComponent("missing-voiceover.mov")
        session.draft.voiceOvers = [.init(url: lostVoiceOver, duration: 1, sourceDuration: 3)]
        func renderDirectories() throws -> Set<URL> {
            Set(try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("ScreenTake-export-") })
        }
        let beforeFailure = try renderDirectories()
        do {
            _ = try await session.applyChanges()
            preconditionFailure("Missing voiceover succeeded")
        } catch { }
        let afterFailure = try renderDirectories()
        precondition(afterFailure == beforeFailure, "Failed pipeline left partial renders")
        precondition(session.videoURL == currentRender && FileManager.default.fileExists(atPath: currentRender.path))
        let sourceAfterFailure = try Data(contentsOf: source)
        let downloadAfterFailure = try Data(contentsOf: destination)
        precondition(sourceAfterFailure == original && downloadAfterFailure == downloadedData)
        session.draft.voiceOvers = []
        print("PASS: obsolete and intermediate renders removed; failed audio export preserves current render and user media")

        // Rapid edits must publish only the newest preview, and close must invalidate it.
        session.draft.trim = VideoTrim(start: 0, end: 0.5)
        session.draft.trim = VideoTrim(start: 2, end: 3)
        await session.waitForPreview()
        precondition(session.previewReady && session.renderedPreviewTimeline!.ranges.first!.start.seconds == 2)
        session.draft.ratio = .original
        session.close()
        await Task.yield()
        precondition(!FileManager.default.fileExists(atPath: currentDirectory.path), "Closing the editor retained temporary renders")
        precondition(session.player == nil && session.sourceURL == nil && !session.previewReady && !session.hasUnsavedWork)
        try await session.openVideo(source)
        precondition(session.draft.trim == VideoTrim() && !session.canUndo && session.previewReady)
        // A discarded player's callbacks must not move the reopened project's ruler.
        await player.seek(to: EditorAudio.time(1.5), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(session.playback.seconds < 0.1)
        try await checkPlayback(session)
        session.close()
        print("PASS: rapid preview replacement, close cancellation, and clean session reopening")

        // A render reopened as a source must survive subsequent renders. An
        // explicitly saved project takes ownership even inside the work folder.
        try await session.openVideo(source)
        session.draft.originalAudioVolume = 0.4
        let ownedSource = try await session.applyChanges()
        try await session.openVideo(ownedSource)
        session.draft.originalAudioVolume = 0.6
        let replacement = try await session.applyChanges()
        precondition(FileManager.default.fileExists(atPath: ownedSource.path), "Reopened source was removed")
        let beforeCancellation = try renderDirectories()
        session.draft.exportResolution = .uhd4k
        let exportTask = Task { try await session.applyChanges() }
        while !session.exportEngine.isExporting || session.exportEngine.progress == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        exportTask.cancel()
        do { _ = try await exportTask.value; preconditionFailure("Cancelled render succeeded") }
        catch is CancellationError { }
        let afterCancellation = try renderDirectories()
        precondition(beforeCancellation == afterCancellation && session.videoURL == replacement,
                     "Cancelled pipeline left files or replaced the current render")
        precondition(FileManager.default.fileExists(atPath: ownedSource.path))
        session.draft.exportResolution = .preserveSource
        let userOwnedDirectory = replacement.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: userOwnedDirectory) }
        let savedProject = userOwnedDirectory.appendingPathComponent("user-saved.screentake")
        try await session.saveProject(to: savedProject)
        session.close()
        let reopenedProject = try await EditorProjectStore.load(from: savedProject)
        precondition(FileManager.default.fileExists(atPath: reopenedProject.source.path)
                     && FileManager.default.fileExists(atPath: replacement.path))
        print("PASS: cancellation cleans partial files; reopened render sources and explicitly saved projects are retained")
    }

    @MainActor
    static func checkPlayback(_ session: EditorSession) async throws {
        let player = session.player!
        await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        let deadline = Date().addingTimeInterval(4)
        while session.playback.seconds < 0.25 && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(session.playback.seconds >= 0.25 && session.playback.isPlaying,
                     "Timeline stopped observing playback: player=\(player.currentTime().seconds), ruler=\(session.playback.seconds)")
        precondition(abs(session.playback.seconds - player.currentTime().seconds) < 0.1)
        player.pause()
        await player.seek(to: EditorAudio.time(0.6), toleranceBefore: .zero, toleranceAfter: .zero)
        let seekDeadline = Date().addingTimeInterval(2)
        while (abs(session.playback.seconds - 0.6) > 0.02 || session.playback.isPlaying) && Date() < seekDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(abs(session.playback.seconds - 0.6) < 0.02 && !session.playback.isPlaying,
                     "Paused seek did not update timeline")
    }

    static func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, nil, &buffer)
            context.render(CIImage(color: frame < 30 ? .red : (frame < 60 ? .green : .blue)), to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: EditorAudio.time(3))
        await writer.finishWriting()
        precondition(writer.status == .completed)
    }

    static func checkFrames(asset: AVAsset, composition: AVVideoComposition?) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let context = CIContext()
        for (time, channel) in [(0.4, 0), (1.4, 2)] {
            let image = try await generator.image(at: EditorAudio.time(time)).image
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            precondition(pixel[channel] > 180, "Wrong frame after middle cut: \(pixel)")
        }
    }
}
