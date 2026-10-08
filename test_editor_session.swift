import AppKit
import AVFoundation
import CoreImage
import SwiftUI

@main
struct EditorSessionChecks {
    @MainActor
    static func main() async throws {
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

        // Rapid edits must publish only the newest preview, and close must invalidate it.
        session.draft.trim = VideoTrim(start: 0, end: 0.5)
        session.draft.trim = VideoTrim(start: 2, end: 3)
        await session.waitForPreview()
        precondition(session.previewReady && session.renderedPreviewTimeline!.ranges.first!.start.seconds == 2)
        session.draft.ratio = .original
        session.close()
        await Task.yield()
        precondition(session.player == nil && session.sourceURL == nil && !session.previewReady && !session.hasUnsavedWork)
        try await session.openVideo(source)
        precondition(session.draft.trim == VideoTrim() && !session.canUndo && session.previewReady)
        session.close()
        print("PASS: rapid preview replacement, close cancellation, and clean session reopening")
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
