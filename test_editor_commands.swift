import AppKit
import AVFoundation
import CoreImage

@main
struct EditorCommandChecks {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("editor-commands-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let audio = directory.appendingPathComponent("audio.caf")
        try await fixture(source, audio: audio)
        let original = try Data(contentsOf: source)
        let originalAudio = try Data(contentsOf: audio)
        let session = EditorSession()
        try await session.openVideo(source)
        var trim = VideoTrim(start: 0.2, end: 5.8, cuts: [.init(start: 2.5, end: 3)], splits: [1, 2, 4])
        precondition(trim.moveSegment(from: 4, to: 0, duration: EditorAudio.time(6)))
        try session.updateEdits {
            $0.trim = trim
            $0.ratio = .portrait
            $0.crop = PhoneCrop(rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
            $0.videoOverlayURL = source
            $0.phoneVideoURL = source
            $0.webcamEnabled = true
            $0.videoOverlayTiming = .init(start: 0.3, duration: 2, sourceStart: 1)
            $0.cameraLayoutChanges = [.init(start: 1.5, settings: .init(layout: .fullScreen, zoom: 1.5))]
            $0.voiceOvers = [.init(url: audio, start: 0.5, duration: 1, sourceDuration: 6)]
            $0.originalAudioVolume = 0.8
            $0.voiceOverVolume = 0.6
            $0.zoomSegments = [.init(start: 0.3, end: 0.9, zoom: 2, centerX: 0.4, centerY: 0.5)]
        }
        let first = directory.appendingPathComponent("Demo.screenize")
        try await session.saveProject(to: first)
        await session.waitForPreview()
        precondition(!session.hasUnsavedWork && session.projectURL == first)
        let data = try Data(contentsOf: first.appendingPathComponent("project.json"))
        let manifest = try JSONDecoder().decode(EditorProject.self, from: data)
        precondition(manifest.version == 2 && manifest.source.scheme == nil && manifest.settings.trim == trim)
        precondition(manifest.settings.voiceOvers[0].url.scheme == nil && manifest.settings.videoOverlayURL?.scheme == nil)
        precondition(manifest.settings.phoneVideoURL?.scheme == nil)
        precondition(tryData(session.sourceURL!) == original)
        // Recordings can keep their master audio separately from raw capture video.
        var separateAudio = manifest
        separateAudio.audio = manifest.settings.voiceOvers[0].url
        try JSONEncoder().encode(separateAudio).write(to: first.appendingPathComponent("project.json"))
        try await session.openProject(first)
        let reopened = EditorSession()
        try await reopened.openProject(first)
        precondition(reopened.draft == session.draft && reopened.revision == session.revision && reopened.projectID == session.projectID)
        precondition(reopened.hasEditChanges && !reopened.hasUnsavedWork)
        try await comparePreview(session, reopened)

        // Replacing the same bundle must update live and undo media references.
        try reopened.updateEdits { $0.wallpaper = .ocean; $0.videoOverlayURL = nil; $0.webcamEnabled = false }
        try await reopened.saveProject(to: first)
        precondition(FileManager.default.fileExists(atPath: reopened.sourceURL!.path))
        reopened.undo()
        precondition(reopened.draft.videoOverlayURL != nil && FileManager.default.fileExists(atPath: reopened.draft.videoOverlayURL!.path))
        precondition(reopened.hasUnsavedWork)
        let second = directory.appendingPathComponent("Portable.screenize")
        try await reopened.saveProject(to: second)
        let portable = EditorSession()
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: audio)
        try await portable.openProject(second)
        precondition(portable.draft == reopened.draft && portable.sourceURL == reopened.sourceURL)
        await reopened.waitForPreview()
        try await comparePreview(portable, reopened)
        let exported = try await portable.applyChanges()
        let duration = try await AVURLAsset(url: exported).load(.duration).seconds
        precondition(abs(duration - portable.editedDuration) < 0.002)
        let tracks = try await AVURLAsset(url: exported).loadTracks(withMediaType: .audio)
        precondition(!tracks.isEmpty)
        precondition(tryData(portable.audioURL!) == originalAudio)
        precondition(FileManager.default.fileExists(atPath: portable.draft.phoneVideoURL!.path))
        print("PASS: full project serialization, exact reordered timeline, portable media, same preview/export, save replacement, and undo media retention")

        // Malformed, future-version, and missing-media packages cannot replace work.
        let bad = directory.appendingPathComponent("Bad.screenize")
        try FileManager.default.copyItem(at: second, to: bad)
        let badManifest = bad.appendingPathComponent("project.json")
        var invalid = try JSONDecoder().decode(EditorProject.self, from: Data(contentsOf: badManifest))
        invalid.version = 99
        try JSONEncoder().encode(invalid).write(to: badManifest)
        do { try await portable.openProject(bad); preconditionFailure("Future format accepted") }
        catch EditorProjectStore.ProjectError.unsupportedVersion(99) { }
        invalid.version = 2
        invalid.source = URL(string: "media/../../escape.mov")!
        try JSONEncoder().encode(invalid).write(to: badManifest)
        do { try await portable.openProject(bad); preconditionFailure("Escaping media path accepted") }
        catch EditorProjectStore.ProjectError.invalidManifest { }
        invalid.source = URL(string: "media/missing.mov")!
        try JSONEncoder().encode(invalid).write(to: badManifest)
        do { try await portable.openProject(bad); preconditionFailure("Missing media accepted") }
        catch EditorProjectStore.ProjectError.missingMedia { }
        precondition(portable.projectURL == second && !portable.isBusy)
        print("PASS: version, malformed-path, and missing-media errors preserve the active project")

        let savedManifest = try Data(contentsOf: second.appendingPathComponent("project.json"))
        var missingSettings = portable.draft
        missingSettings.videoOverlayURL = directory.appendingPathComponent("missing-camera.mov")
        let missingProject = EditorProject(id: portable.projectID, revision: portable.revision,
            name: portable.projectName, source: portable.sourceURL!, audio: portable.audioURL,
            mouse: portable.mouseURL, settings: missingSettings)
        do { _ = try await EditorProjectStore.save(missingProject, to: second); preconditionFailure("Missing take was saved") }
        catch EditorProjectStore.ProjectError.missingMedia { }
        precondition(tryData(second.appendingPathComponent("project.json")) == savedManifest)
        precondition(tryData(portable.sourceURL!) == original)
        print("PASS: a failed project replacement preserves the previous manifest and source media")

        let closing = EditorSession()
        let loading = Task { try await closing.openProject(second) }
        for _ in 0..<1000 {
            if closing.sourceURL != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(closing.isLoading)
        closing.close()
        do { try await loading.value; preconditionFailure("Closed project load completed") }
        catch is CancellationError { }
        precondition(closing.sourceURL == nil && closing.projectURL == nil && !closing.isBusy)
        print("PASS: closing during project preview preparation cannot republish stale project state")

        let commands = EditorCommandDispatcher(session: portable)
        func call(_ operation: EditorCommandRequest.Operation, path: String? = nil, edits: EditorEdits? = nil,
                  times: [Double]? = nil) async -> EditorCommandResponse {
            await commands.execute(.init(operation: operation, projectID: portable.projectID,
                expectedRevision: portable.revision, path: path, edits: edits, times: times))
        }
        func finish(_ job: EditorJob) async throws -> EditorJob {
            for _ in 0..<1000 {
                let response = await commands.execute(.init(operation: .getJob, jobID: job.id))
                guard let current = response.job else { preconditionFailure("Job disappeared") }
                if [.succeeded, .failed, .cancelled].contains(current.status) { return current }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure("Job did not finish")
        }
        let capabilities = await commands.execute(.init(operation: .getCapabilities))
        precondition(capabilities.capabilities!.count == EditorCommandRequest.Operation.allCases.count)
        let get = await commands.execute(.init(operation: .getProject))
        precondition(get.project?.revision == portable.revision)
        var edits = EditorEdits()
        edits.trim = VideoTrim()
        edits.ratio = .square
        edits.removeRanges = [.init(start: 1, end: 2)]
        edits.webcamEnabled = false
        edits.voiceOvers = []
        let request = EditorCommandRequest(operation: .applyEdits, projectID: portable.projectID,
                                          expectedRevision: portable.revision, edits: edits)
        let wire = try JSONEncoder().encode(request)
        let changed = try JSONDecoder().decode(EditorCommandResponse.self, from: await commands.executeJSON(wire))
        precondition(changed.ok && portable.editedDuration == 5)
        let revision = portable.revision
        let retry = await commands.execute(request)
        precondition(retry.ok && portable.revision == revision && portable.draft.trim.cuts.count == 1)
        var reused = request
        reused.edits?.ratio = .vertical
        let collision = await commands.execute(reused)
        precondition(collision.error?.code == "request_id_reused")
        var stale = request
        stale.id = UUID()
        let rejected = await commands.execute(stale)
        precondition(rejected.error?.code == "stale_project")
        let missingRevision = await commands.execute(.init(operation: .undo))
        precondition(missingRevision.error?.code == "revision_required")
        let undone = await call(.undo)
        precondition(undone.ok && portable.draft.trim == trim)
        let redone = await call(.redo)
        precondition(redone.ok && portable.draft.trim.cuts.count == 1)
        var invalidEdits = EditorEdits()
        invalidEdits.zoomLevel = -1
        let invalidResult = await call(.applyEdits, edits: invalidEdits)
        precondition(invalidResult.error?.code == "invalid_edits" && portable.revision == redone.project?.revision)
        let malformed = await commands.executeJSON(Data("{\"operation\":\"typo\"}".utf8))
        precondition(tryDecode(malformed).error?.code == "invalid_request")
        print("PASS: JSON command workflow, capability discovery, one-operation undo/redo, retry idempotence, stale revision protection, and invalid input rejection")

        let previewResponse = await call(.renderPreview, times: [0.5, 3])
        let previewJob = try await finish(previewResponse.job!)
        precondition(previewJob.status == .succeeded && previewJob.frames?.count == 2)
        for frame in previewJob.frames! { precondition(NSImage(contentsOf: frame.url) != nil) }
        let pausesResponse = await call(.findSilences)
        let pauses = try await finish(pausesResponse.job!)
        precondition(pauses.status == .succeeded && !pauses.suggestions!.isEmpty)
        let destination = directory.appendingPathComponent("Final.mov")
        let exportRequest = EditorCommandRequest(operation: .exportVideo, projectID: portable.projectID,
                                                expectedRevision: portable.revision, path: destination.path)
        let exportResponse = await commands.execute(exportRequest)
        let locked = await call(.applyEdits, edits: edits)
        precondition(locked.error?.code == "busy")
        let exportedJob = try await finish(exportResponse.job!)
        precondition(exportedJob.status == .succeeded && exportedJob.output == destination && exportedJob.progress == 1)
        let repeated = await commands.execute(exportRequest)
        precondition(repeated.job?.id == exportedJob.id && repeated.job?.status == .succeeded)
        let commandDuration = try await AVURLAsset(url: destination).load(.duration).seconds
        precondition(abs(commandDuration - 5) < 0.002)
        let waveform = try await AudioWaveform.load(destination)
        precondition(waveform.level(at: 0.2) > 0.1 && waveform.level(at: 0.2) < 0.22,
                     "Separate master audio was duplicated or lost")
        precondition(tryData(portable.audioURL!) == originalAudio)
        do { try await portable.saveVideo(to: portable.sourceURL!); preconditionFailure("Original media was overwritten") }
        catch EditorSession.SessionError.retainedMediaDestination { }
        precondition(tryData(portable.sourceURL!) == original)
        print("PASS: asynchronous preview artifacts, silence suggestions, real export jobs, progress, job locking, and export retries")

        let failedPreview = await call(.renderPreview, times: [999])
        let failedJob = try await finish(failedPreview.job!)
        precondition(failedJob.status == .failed && failedJob.error?.code == "invalid_times" && !portable.isBusy)
        let cancelledResponse = await call(.renderPreview, times: [0])
        let cancelled = await commands.execute(.init(operation: .cancelJob, jobID: cancelledResponse.job!.id))
        precondition([.cancelling, .cancelled].contains(cancelled.job!.status))
        let cancelledJob = try await finish(cancelledResponse.job!)
        precondition(cancelledJob.status == .cancelled && !portable.isBusy)

        var largeExport = EditorEdits()
        largeExport.exportResolution = .uhd4k
        let largeEditResponse = await call(.applyEdits, edits: largeExport)
        precondition(largeEditResponse.ok)
        let previousOutput = try Data(contentsOf: destination)
        let activeExport = await call(.exportVideo, path: destination.path)
        for _ in 0..<1000 {
            if portable.exportEngine.isExporting && portable.exportEngine.progress > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(portable.isExporting && portable.exportEngine.isExporting && portable.exportEngine.progress > 0,
                     "Did not reach an active export")
        _ = await commands.execute(.init(operation: .cancelJob, jobID: activeExport.job!.id))
        let cancelledExport = try await finish(activeExport.job!)
        precondition(cancelledExport.status == .cancelled && !portable.isBusy && !portable.exportEngine.isExporting)
        precondition(tryData(destination) == previousOutput && portable.hasEditChanges)
        let restoreResolution = await call(.undo)
        precondition(restoreResolution.ok)
        print("PASS: cancelling an active 4K export stops encoding, preserves the existing destination, and releases the editor")
        let deniedOpen = await call(.openProject, path: second.path)
        precondition(deniedOpen.error?.code == "unsaved_work")
        let savedCommand = await call(.saveProject, path: second.path)
        precondition(savedCommand.ok && !portable.hasUnsavedWork)
        print("PASS: failed/cancelled jobs release the session, unsaved work is protected, and project saves work through commands")

        var duoEdits = EditorEdits()
        duoEdits.layout = .duo
        duoEdits.ratio = .landscape
        let duoResult = await call(.applyEdits, edits: duoEdits)
        precondition(duoResult.ok)
        let duoPreview = await call(.renderPreview, times: [0.5])
        let duoPreviewJob = try await finish(duoPreview.job!)
        precondition(duoPreviewJob.status == .succeeded)
        let previewBitmap = NSBitmapImageRep(data: try Data(contentsOf: duoPreviewJob.frames![0].url))!
        let previewSize = CGSize(width: previewBitmap.pixelsWide, height: previewBitmap.pixelsHigh)
        let previewPhone = CanvasGeometry(size: previewSize, layout: .duo,
                                          sourceSize: portable.draft.crop.pixelRect(in: portable.sourceVideoSize!).size).phone!
        let previewColor = previewBitmap.colorAt(x: Int(previewPhone.midX),
            y: previewBitmap.pixelsHigh - 1 - Int(previewPhone.midY))!.usingColorSpace(.sRGB)!
        precondition(previewColor.redComponent > 0.7 && previewColor.greenComponent < 0.25, "Duo preview lost the phone video")
        let duoExport = await call(.exportVideo, path: directory.appendingPathComponent("Duo.mov").path)
        let duoExportJob = try await finish(duoExport.job!)
        precondition(duoExportJob.status == .succeeded)
        let duoGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: duoExportJob.output!))
        duoGenerator.requestedTimeToleranceBefore = .zero
        duoGenerator.requestedTimeToleranceAfter = .zero
        let duoFrame = try await duoGenerator.image(at: EditorAudio.time(0.5)).image
        let exportBitmap = NSBitmapImageRep(cgImage: duoFrame)
        let exportSize = CGSize(width: exportBitmap.pixelsWide, height: exportBitmap.pixelsHigh)
        let exportPhone = CanvasGeometry(size: exportSize, layout: .duo,
                                        sourceSize: portable.draft.crop.pixelRect(in: portable.sourceVideoSize!).size).phone!
        let exportColor = exportBitmap.colorAt(x: Int(exportPhone.midX),
            y: exportBitmap.pixelsHigh - 1 - Int(exportPhone.midY))!.usingColorSpace(.sRGB)!
        precondition(exportColor.redComponent > 0.7 && exportColor.greenComponent < 0.25, "Duo export lost the phone video")
        print("PASS: portable Duo media renders in preview and export after the external input is deleted")

        let engine = ExportEngine()
        let directExport = Task {
            try await engine.export(sourceURL: portable.sourceURL!, keyframes: [],
                configuration: .init(outputURL: destination, outputSize: CGSize(width: 3840, height: 2160), preserveSourceAudio: true))
        }
        for _ in 0..<1000 {
            if engine.isExporting && engine.progress > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(engine.isExporting && engine.progress > 0)
        directExport.cancel()
        do { _ = try await directExport.value; preconditionFailure("Direct active export was not cancelled") }
        catch is CancellationError { }
        precondition(!engine.isExporting && tryData(destination) == previousOutput)
        print("PASS: the export engine stages replacements and preserves a prior output when active encoding is cancelled")
    }

    static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }
    static func tryDecode(_ data: Data) -> EditorCommandResponse { try! JSONDecoder().decode(EditorCommandResponse.self, from: data) }

    @MainActor
    static func comparePreview(_ a: EditorSession, _ b: EditorSession) async throws {
        await a.waitForPreview(); await b.waitForPreview()
        precondition(a.previewReady && b.previewReady)
        for time in [0.5, 1.5, 3] {
            func frame(_ session: EditorSession) async throws -> Data {
                let item = session.player!.currentItem!
                let generator = AVAssetImageGenerator(asset: item.asset)
                generator.videoComposition = item.videoComposition
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let image = try await generator.image(at: EditorAudio.time(time)).image
                return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            }
            let original = try await frame(a)
            let reopened = try await frame(b)
            precondition(original == reopened, "Reopened project rendered different frames")
        }
    }

    static func fixture(_ url: URL, audio: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<180 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, nil, &buffer)
            context.render(CIImage(color: frame < 60 ? .red : (frame < 120 ? .green : .blue)), to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: EditorAudio.time(6))
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 288000)!
        samples.frameLength = samples.frameCapacity
        for index in 0..<288000 {
            let time = Double(index) / 48000
            samples.floatChannelData![0][index] = time >= 1 && time < 3 ? 0 : Float(sin(time * 2 * .pi * 440) * 0.2)
        }
        try AVAudioFile(forWriting: audio, settings: format.settings).write(from: samples)
        _ = try await MediaMuxer.mux(videoURL: url, systemAudioURL: audio, micAudioURL: nil, removeSourceAudio: false)
    }
}
