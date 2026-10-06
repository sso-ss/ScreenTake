import Foundation
import AVFoundation
import CoreImage
import Vision

/// Immutable source-time framing, shared by preview and export. Coordinates use
/// the upright camera image's bottom-left origin, like Core Image and Vision.
struct FaceTrackingTrack {
    struct Focus {
        var center: CGPoint
        var strength: Double

        func crop(in source: CGRect, fallback: CGRect) -> CGRect {
            let amount = CGFloat(min(1, max(0, strength)))
            // A modest extra crop gives tracking room even in a matching aspect ratio.
            let size = CGSize(width: fallback.width / (1 + 0.2 * amount),
                              height: fallback.height / (1 + 0.2 * amount))
            let x = min(source.maxX - size.width, max(source.minX, source.minX + center.x * source.width - size.width / 2))
            let y = min(source.maxY - size.height, max(source.minY, source.minY + center.y * source.height - size.height / 2))
            let baseX = fallback.midX - size.width / 2
            let baseY = fallback.midY - size.height / 2
            return CGRect(x: baseX + (x - baseX) * amount, y: baseY + (y - baseY) * amount,
                          width: size.width, height: size.height)
        }
    }

    struct Sample {
        var time: Double
        var focus: Focus
    }
    var samples: [Sample] = []

    func focus(at time: Double) -> Focus? {
        guard time.isFinite, let first = samples.first, let last = samples.last else { return nil }
        if time <= first.time { return first.focus }
        if time >= last.time { return last.focus }
        var lower = 0
        var upper = samples.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if samples[middle].time <= time { lower = middle } else { upper = middle }
        }
        let a = samples[lower], b = samples[upper]
        let fraction = (time - a.time) / max(0.000001, b.time - a.time)
        return Focus(center: CGPoint(x: a.focus.center.x + (b.focus.center.x - a.focus.center.x) * fraction,
                                     y: a.focus.center.y + (b.focus.center.y - a.focus.center.y) * fraction),
                     strength: a.focus.strength + (b.focus.strength - a.focus.strength) * fraction)
    }
}

/// Tracks the nearest plausible face, holds short gaps, and eases back to manual
/// framing after a longer gap. This is positional tracking, not identification.
struct FaceTrackingSmoother {
    private var previousFace: CGRect?
    private var lastSeen: Double?
    private var previousTime: Double?
    private var focus = FaceTrackingTrack.Focus(center: CGPoint(x: 0.5, y: 0.5), strength: 0)

    mutating func sample(at time: Double, faces: [CGRect]) -> FaceTrackingTrack.Sample {
        let delta = max(0, time - (previousTime ?? time))
        let candidates = faces.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        let selected: CGRect?
        if let previousFace, let lastSeen, time - lastSeen <= 1 {
            selected = candidates.filter {
                hypot($0.midX - previousFace.midX, $0.midY - previousFace.midY) < 0.25
                    && $0.width / previousFace.width > 0.4 && $0.width / previousFace.width < 2.5
            }.min {
                hypot($0.midX - previousFace.midX, $0.midY - previousFace.midY)
                    < hypot($1.midX - previousFace.midX, $1.midY - previousFace.midY)
            }
        } else {
            selected = candidates.max { $0.width * $0.height < $1.width * $1.height }
        }
        if let face = selected {
            // Place the face slightly above the crop center to leave shoulder room.
            let target = CGPoint(x: face.midX, y: face.midY - face.height * 0.15)
            let alpha = previousTime == nil ? 1 : 1 - exp(-delta / 0.35)
            if focus.strength < 0.001 { focus.center = target }
            if hypot(target.x - focus.center.x, target.y - focus.center.y) > 0.012 {
                focus.center.x += (target.x - focus.center.x) * alpha
                focus.center.y += (target.y - focus.center.y) * alpha
            }
            focus.strength += (1 - focus.strength) * alpha
            previousFace = face
            lastSeen = time
        } else if lastSeen == nil || time - lastSeen! > 1 {
            focus.strength *= exp(-delta / 0.6)
            if focus.strength < 0.001 { focus.strength = 0 }
        }
        previousTime = time
        return .init(time: time, focus: focus)
    }
}

/// Analysis runs off the main actor once per camera asset. Only a small list of
/// positions is retained; original video stays untouched. The bounded cache also
/// avoids repeating analysis when changing layout, trimming, or exporting.
actor FaceTrackingAnalyzer {
    static let shared = FaceTrackingAnalyzer()

    private struct Key: Equatable {
        var url: URL
        var modified: Date?
        var size: Int?
    }
    private var cache: [(Key, FaceTrackingTrack)] = []

    func track(for url: URL) async throws -> FaceTrackingTrack {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = Key(url: url.standardizedFileURL, modified: values.contentModificationDate, size: values.fileSize)
        if let index = cache.firstIndex(where: { $0.0 == key }) {
            let entry = cache.remove(at: index)
            cache.append(entry)
            return entry.1
        }
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let transform = try await video.load(.preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FaceTrackingError.analysisFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FaceTrackingError.analysisFailed }
        defer { reader.cancelReading() }
        var result = FaceTrackingTrack()
        var smoother = FaceTrackingSmoother()
        var nextTime = 0.0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite, time >= nextTime, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let point = try autoreleasepool { () throws -> FaceTrackingTrack.Sample in
                let upright = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                let normalized = upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
                let scale = min(1, 512 / max(normalized.extent.width, normalized.extent.height))
                let image = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let request = VNDetectFaceRectanglesRequest()
                try VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
                let faces = (request.results ?? []).filter { $0.confidence >= 0.5 }.map(\.boundingBox)
                return smoother.sample(at: time, faces: faces)
            }
            result.samples.append(point)
            nextTime = time + 0.125 // Eight detections/sec; renderers interpolate at their own frame rate.
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? FaceTrackingError.analysisFailed }
        guard !result.samples.isEmpty else { throw FaceTrackingError.analysisFailed }
        cache.append((key, result))
        if cache.count > 3 { cache.removeFirst(cache.count - 3) }
        return result
    }
}

private enum FaceTrackingError: LocalizedError {
    case analysisFailed
    var errorDescription: String? { "Could not analyze the camera video. Try again or turn off Follow face." }
}
