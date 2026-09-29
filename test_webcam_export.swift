import AppKit
import AVFoundation
import CoreImage
import Combine

enum WebcamExportTestError: Error {
    case failed(String)
}

@main
struct WebcamExportTest {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw WebcamExportTestError.failed("Pass screen MOV, webcam MOV and no-click mouse JSON paths")
        }
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let webcam = URL(fileURLWithPath: CommandLine.arguments[2])
        let mouse = URL(fileURLWithPath: CommandLine.arguments[3])
        let keyframes = try await ClickZoomGenerator.generate(from: mouse, sourceVideoURL: source)
        guard !keyframes.contains(where: { $0.transform.zoom > 1.01 }) else {
            throw WebcamExportTestError.failed("Fixture must have no zoom clicks")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("webcam-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("TEST OUTPUT \(directory.path)")

        for generateZoom in [true, false] {
            let name = generateZoom ? "no-clicks" : "zoom-disabled"
            let videoURL = directory.appendingPathComponent("\(name).mov")
            let audioURL = directory.appendingPathComponent("\(name)-audio.mov")
            try FileManager.default.copyItem(at: source, to: videoURL)
            try FileManager.default.copyItem(at: source, to: audioURL)
            let state = RecordingState()
            state.lastRecordingURL = videoURL
            state.lastWebcamVideoURL = webcam
            state.lastMicAudioURL = audioURL
            var stages: [RecordingState.ProcessingStage] = []
            var progressValues: [Double] = []
            let stageSubscription = state.$processingStage.sink { stage in
                if let stage { stages.append(stage) }
            }
            let progressSubscription = state.$processingProgress.sink { progress in
                if let progress { progressValues.append(progress) }
            }
            await state.applyAutoZoom(
                videoURL: videoURL,
                mouseDataURL: generateZoom ? mouse : nil,
                generateZoom: generateZoom
            )
            stageSubscription.cancel()
            progressSubscription.cancel()
            guard stages.first == .processing, stages.last == .mergingAudio,
                  !progressValues.isEmpty, progressValues.allSatisfy({ (0...1).contains($0) }),
                  state.processingStage == nil, state.processingProgress == nil,
                  state.processingError == nil else {
                throw WebcamExportTestError.failed("\(name): incorrect processing progress lifecycle")
            }
            print("PASS \(name): processing -> merging audio -> idle, \(progressValues.count) progress updates")
            let expectedURL = directory.appendingPathComponent("\(name)_composited.mov")
            guard state.lastRecordingURL == expectedURL,
                  FileManager.default.fileExists(atPath: expectedURL.path) else {
                throw WebcamExportTestError.failed("\(name): webcam export was skipped or failed")
            }
            let asset = AVURLAsset(url: expectedURL)
            let sourceDuration = try await AVURLAsset(url: source).load(.duration)
            let exportDuration = try await asset.load(.duration)
            guard abs(sourceDuration.seconds - exportDuration.seconds) < 0.002 else {
                throw WebcamExportTestError.failed("\(name): video duration changed from \(sourceDuration.seconds) to \(exportDuration.seconds)")
            }
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            guard videos.count == 1, audios.count == 1 else {
                throw WebcamExportTestError.failed("\(name): expected video and merged audio")
            }
            let sourceAudio = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)[0].load(.timeRange)
            let exportedAudio = try await audios[0].load(.timeRange)
            guard abs(sourceAudio.duration.seconds - exportedAudio.duration.seconds) < 0.001 else {
                throw WebcamExportTestError.failed("\(name): audio duration changed")
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            let context = CIContext()
            let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
            guard let preview = context.createCGImage(scaled, from: scaled.extent),
                  let png = NSBitmapImageRep(cgImage: preview).representation(using: .png, properties: [:]) else {
                throw WebcamExportTestError.failed("\(name): cannot create export preview")
            }
            let previewURL = directory.appendingPathComponent("\(name).png")
            try png.write(to: previewURL)
            print("PASS \(name): composited video + audio \(exportedAudio.duration.seconds)s; preview=\(previewURL.path)")
        }

        let audioOnlyVideo = directory.appendingPathComponent("audio-only.mov")
        let audioOnlySidecar = directory.appendingPathComponent("audio-only-sidecar.mov")
        try FileManager.default.copyItem(at: source, to: audioOnlyVideo)
        try FileManager.default.copyItem(at: source, to: audioOnlySidecar)
        let audioOnlyState = RecordingState()
        audioOnlyState.lastRecordingURL = audioOnlyVideo
        audioOnlyState.lastMicAudioURL = audioOnlySidecar
        var audioStages: [RecordingState.ProcessingStage] = []
        let audioSubscription = audioOnlyState.$processingStage.sink { stage in
            if let stage { audioStages.append(stage) }
        }
        await audioOnlyState.applyAutoZoom(videoURL: audioOnlyVideo, mouseDataURL: nil, generateZoom: false)
        audioSubscription.cancel()
        guard audioStages == [.processing, .mergingAudio], audioOnlyState.processingStage == nil,
              audioOnlyState.processingProgress == nil, audioOnlyState.processingError == nil else {
            throw WebcamExportTestError.failed("Audio-only progress did not complete")
        }
        print("PASS audio-only: processing -> merging audio -> idle")

        let failedState = RecordingState()
        failedState.lastWebcamVideoURL = webcam
        await failedState.applyAutoZoom(videoURL: directory.appendingPathComponent("missing.mov"), mouseDataURL: nil, generateZoom: false)
        guard failedState.processingStage == nil, failedState.processingProgress == nil,
              failedState.processingError != nil else {
            throw WebcamExportTestError.failed("Failed export left processing active or hid its error")
        }
        print("PASS failure: progress cleared and error reported")
    }
}