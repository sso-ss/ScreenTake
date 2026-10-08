import AVFoundation
import CoreImage

enum LiveVideoPreview {
    struct Request: Equatable {
        let source: URL
        let audio: URL?
        let mouse: URL?
        let webcam: URL?
        let settings: VideoEditSettings
    }

    static func makeItem(_ request: Request) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: request.source)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let duration = try await asset.load(.duration)
        let timeline = try request.settings.trim.timeline(duration: duration)
        let size = try await sourceTrack.load(.naturalSize)
        let transform = try await sourceTrack.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let sourceSize = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ExportError.readerSetupFailed }
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
        video.preferredTransform = transform
        if request.settings.audioEnabled, let audioURL = request.audio {
            let audioAsset = AVURLAsset(url: audioURL)
            for sourceAudio in try await audioAsset.loadTracks(withMediaType: .audio) {
                let range = try await sourceAudio.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(range, otherRange: CMTimeRange(start: .zero, duration: duration))
                if intersection.duration > .zero,
                   let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try audio.insertTimeRange(intersection, of: sourceAudio, at: intersection.start)
                }
            }
        }
        try timeline.apply(to: composition, sourceDuration: duration)
        let audioMix = try await EditorAudio.mix(into: composition, duration: timeline.duration,
                                                originalVolume: request.settings.originalAudioVolume,
                                                clips: request.settings.voiceOverEnabled ? request.settings.voiceOvers : [],
                                                voiceOverVolume: request.settings.voiceOverVolume)
        let mouse = try request.mouse.map { try JSONDecoder().decode(MouseDataRecorder.MouseRecording.self, from: Data(contentsOf: $0)) }
        let keyframes: [CameraKeyframe]
        if request.settings.zoomEnabled, let mouseURL = request.mouse {
            keyframes = try await ClickZoomGenerator.generate(
                from: mouseURL,
                sourceVideoURL: request.source,
                settings: .init(zoomLevel: request.settings.zoomLevel),
                segments: request.settings.zoomSegments
            )
        } else { keyframes = [] }
        try Task.checkCancellation()
        let faceTrack: FaceTrackingTrack?
        if request.settings.usesFaceTracking, let webcamURL = request.webcam {
            faceTrack = try await FaceTrackingAnalyzer.shared.track(for: webcamURL)
        } else { faceTrack = nil }
        try Task.checkCancellation()
        let renderer = LiveEditFrameRenderer(sourceSize: sourceSize, settings: request.settings, keyframes: keyframes,
                                             mouse: mouse, faceTrack: faceTrack)
        let webcam = request.settings.webcamEnabled ? request.webcam.map {
            OverlayVideoFrames(url: $0, maximumSize: request.settings.cameraLayout.layout == .fullScreen
                               || request.settings.cameraLayoutChanges.contains { $0.settings.layout == .fullScreen }
                               ? .zero : CGSize(width: 960, height: 960), preciseTiming: faceTrack != nil)
        } : nil
        let webcamDuration: CMTime?
        if request.settings.webcamEnabled, let webcamURL = request.webcam {
            webcamDuration = try await AVURLAsset(url: webcamURL).load(.duration)
        } else { webcamDuration = nil }
        let phone: OverlayVideoFrames?
        if request.settings.layout == .duo {
            guard let url = request.settings.phoneVideoURL else { throw ExportError.missingPhoneVideo }
            phone = OverlayVideoFrames(url: url, maximumSize: CGSize(width: 1280, height: 1280))
        } else { phone = nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        let filters = AVMutableVideoComposition(asset: composition) { frame in
            autoreleasepool {
                let image = frame.sourceImage
                    .transformed(by: CGAffineTransform(translationX: -frame.sourceImage.extent.minX, y: -frame.sourceImage.extent.minY))
                let sourceTime = timeline.sourceTime(at: frame.compositionTime)
                let webcamTime: CMTime?
                if let timing = request.settings.videoOverlayTiming {
                    webcamTime = timing.sampleTime(at: frame.compositionTime.seconds)
                } else { webcamTime = sourceTime }
                let result = renderer.render(image, at: sourceTime.seconds,
                                             webcamImage: webcamTime.flatMap {
                                                 guard let webcamDuration, $0 >= .zero, $0 < webcamDuration else { return nil }
                                                 return webcam?.image(at: $0)
                                             },
                                             webcamTime: webcamTime?.seconds, phoneImage: phone?.image(at: sourceTime))
                frame.finish(with: result, context: context)
            }
        }
        filters.renderSize = renderer.outputSize
        filters.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        filters.frameDuration = CMTime(value: 1, timescale: 60)
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = filters
        item.audioMix = audioMix
        return item
    }
}
