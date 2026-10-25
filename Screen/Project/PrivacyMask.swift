import Foundation
import CoreGraphics
import CoreImage
import AVFoundation
import Vision

enum PrivacyMaskStyle: String, Codable, CaseIterable {
    case cover, blur

    var displayName: String { self == .cover ? "Cover" : "Blur" }
}

enum PrivacyMaskTrackingTarget: String, CaseIterable {
    case automatic, text, person, visual

    var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .text: return "Text"
        case .person: return "Person"
        case .visual: return "Image or UI"
        }
    }
}

/// Rectangles use top-left normalized coordinates in the final video canvas.
struct PrivacyMaskKeyframe: Equatable, Codable {
    var time: Double
    var rect: CGRect
}

struct PrivacyMask: Identifiable, Equatable, Codable {
    var id = UUID()
    var start: Double
    var duration: Double
    var style: PrivacyMaskStyle = .cover
    var keyframes: [PrivacyMaskKeyframe]

    var end: Double { start + duration }

    init(start: Double, duration: Double, rect: CGRect) {
        self.start = start
        self.duration = duration
        keyframes = [.init(time: start, rect: rect)]
    }

    func rect(at time: Double) -> CGRect? {
        guard time.isFinite, time >= start, time < end, let first = keyframes.first else { return nil }
        if time <= first.time { return first.rect }
        guard let last = keyframes.last else { return nil }
        if time >= last.time { return last.rect }
        guard let next = keyframes.firstIndex(where: { $0.time > time }), next > 0 else { return first.rect }
        let a = keyframes[next - 1], b = keyframes[next]
        let fraction = (time - a.time) / (b.time - a.time)
        return CGRect(x: a.rect.minX + (b.rect.minX - a.rect.minX) * fraction,
                      y: a.rect.minY + (b.rect.minY - a.rect.minY) * fraction,
                      width: a.rect.width + (b.rect.width - a.rect.width) * fraction,
                      height: a.rect.height + (b.rect.height - a.rect.height) * fraction)
    }

    mutating func setRect(_ rect: CGRect, at time: Double) {
        let moment = min(max(time, start), max(start, end - 0.001))
        if let index = keyframes.firstIndex(where: { abs($0.time - moment) < 0.025 }) {
            keyframes[index] = .init(time: moment, rect: rect)
        } else {
            keyframes.append(.init(time: moment, rect: rect))
            keyframes.sort { $0.time < $1.time }
        }
    }

    /// Keep tracked coverage aligned when a screen section is removed with ripple.
    /// A mask crossing the removed interval becomes two independently timed pieces.
    func removingTimelineInterval(_ cut: Range<Double>) -> [Self] {
        guard cut.lowerBound < cut.upperBound else { return [self] }
        func piece(_ lower: Double, _ upper: Double, shift: Double, id: UUID) -> Self? {
            guard upper - lower >= 0.05, let rect = rect(at: lower) else { return nil }
            var result = self
            result.id = id
            result.start = lower - shift
            result.duration = upper - lower
            result.keyframes = [.init(time: result.start, rect: rect)]
            result.keyframes += keyframes.filter { $0.time > lower && $0.time < upper }
                .map { .init(time: $0.time - shift, rect: $0.rect) }
            return result
        }
        var pieces: [Self] = []
        if let before = piece(start, min(end, cut.lowerBound), shift: 0, id: id) { pieces.append(before) }
        if let after = piece(max(start, cut.upperBound), end, shift: cut.upperBound - cut.lowerBound,
                             id: pieces.isEmpty ? id : UUID()) { pieces.append(after) }
        return pieces
    }

    func validate(maxDuration: Double) throws {
        func validRect(_ rect: CGRect) -> Bool {
            let values = [rect.minX, rect.minY, rect.width, rect.height]
            return values.allSatisfy(\.isFinite) && rect.minX >= 0 && rect.minY >= 0
                && rect.width >= 0.005 && rect.height >= 0.005
                && rect.maxX <= 1.000001 && rect.maxY <= 1.000001
        }
        guard start.isFinite, duration.isFinite, start >= 0, duration >= 0.05,
              end <= maxDuration + 0.001, !keyframes.isEmpty, keyframes.count <= 600,
              keyframes.allSatisfy({ $0.time.isFinite && $0.time >= start - 0.001
                && $0.time < end && validRect($0.rect) }),
              zip(keyframes, keyframes.dropFirst()).allSatisfy({ $0.time < $1.time }) else {
            throw EditValidationError.invalid("Invalid privacy mask settings.")
        }
    }
}

/// Applies the same output-space masks to live preview and exported frames.
final class PrivacyMaskRenderer {
    private var masks: [PrivacyMask]
    private let lock = NSLock()
    private let bounds: CGRect

    init(masks: [PrivacyMask], size: CGSize) {
        self.masks = masks
        bounds = CGRect(origin: .zero, size: size)
    }

    func updateMasks(_ masks: [PrivacyMask]) {
        lock.withLock { self.masks = masks }
    }

    func composite(over image: CIImage, at time: Double) -> CIImage {
        let masks: [PrivacyMask] = lock.withLock { self.masks }
        return masks.reduce(image) { result, mask in
            guard let rect = mask.rect(at: time) else { return result }
            let area = CGRect(x: rect.minX * bounds.width,
                              y: (1 - rect.maxY) * bounds.height,
                              width: rect.width * bounds.width,
                              height: rect.height * bounds.height).integral.intersection(bounds)
            guard !area.isEmpty else { return result }
            let replacement: CIImage
            switch mask.style {
            case .cover:
                replacement = CIImage(color: .black).cropped(to: area)
            case .blur:
                replacement = result.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(16, min(bounds.width, bounds.height) * 0.025)])
                    .cropped(to: area)
            }
            return replacement.composited(over: result).cropped(to: bounds)
        }
    }
}

enum PrivacyMaskTrackingError: LocalizedError {
    case unavailable, targetNotFound(PrivacyMaskTrackingTarget), lost(Double)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apply other video edits before tracking this mask. The current rendered video must match the preview."
        case .targetNotFound(let target): return "Could not identify the selected \(target.displayName.lowercased()) in the starting frame. Adjust the mask around the target or choose another tracking target."
        case .lost(let time): return String(format: "Tracking lost the selected area near %.1f seconds. Adjust positions manually and review the full video before sharing.", time)
        }
    }
}

struct PrivacyMaskTrackingResult {
    let keyframes: [PrivacyMaskKeyframe]
    let duration: Double
    let endedWhenTargetLeftFrame: Bool
}

enum PrivacyMaskTracker {
    /// Tracks the marked area in the rendered video. A failed track never creates partial coverage.
    static func track(videoURL: URL, mask: PrivacyMask,
                      target: PrivacyMaskTrackingTarget = .automatic) async throws -> PrivacyMaskTrackingResult {
        guard let initial = mask.keyframes.first?.rect else { throw PrivacyMaskTrackingError.unavailable }
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: target == .text || target == .automatic ? 1600 : 960,
                                       height: target == .text || target == .automatic ? 1600 : 960)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.06, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.06, preferredTimescale: 600)
        let firstImage = try await generator.image(at: CMTime(seconds: mask.start, preferredTimescale: 600)).image
        var anchor = try PrivacyMaskTargetAnchor.select(image: firstImage, mask: initial, target: target)
        var template = anchor == nil ? PrivacyMaskTemplate(image: firstImage, area: initial) : nil
        guard anchor != nil || template != nil else { throw PrivacyMaskTrackingError.targetNotFound(target) }
        var points = [PrivacyMaskKeyframe(time: mask.start, rect: initial)]
        let count = min(599, Int(ceil(mask.duration * (anchor?.isText == true ? 16 : 8))))
        guard count > 0 else {
            return PrivacyMaskTrackingResult(keyframes: points, duration: mask.duration,
                                             endedWhenTargetLeftFrame: false)
        }
        var firstMissingTime: Double?
        for step in 1...count {
            try Task.checkCancellation()
            let moment = min(mask.end - 0.001, mask.start + mask.duration * Double(step) / Double(count))
            guard moment > points.last!.time else { break }
            let image = try await generator.image(at: CMTime(seconds: moment, preferredTimescale: 600)).image
            if anchor != nil {
                guard let rect = try anchor?.match(image: image) else {
                    if firstMissingTime == nil { firstMissingTime = moment }
                    continue
                }
                if let missing = firstMissingTime {
                    let briefExitGap = anchor?.isHand == true
                        && moment - missing <= 0.35 && anchor?.likelyExitedFrame == true
                    guard briefExitGap else { throw PrivacyMaskTrackingError.lost(missing) }
                    firstMissingTime = nil
                }
                points.append(.init(time: moment, rect: rect))
            } else if template != nil {
                guard let offset = template?.match(image: image) else {
                    throw PrivacyMaskTrackingError.lost(moment)
                }
                let x = min(1 - initial.width, max(0, initial.minX + offset.x))
                let y = min(1 - initial.height, max(0, initial.minY + offset.y))
                points.append(.init(time: moment, rect: CGRect(x: x, y: y, width: initial.width, height: initial.height)))
            }
        }
        if let missing = firstMissingTime {
            guard anchor?.canEndAtFrameEdge == true, anchor?.likelyExitedFrame == true else {
                throw PrivacyMaskTrackingError.lost(missing)
            }
            return PrivacyMaskTrackingResult(keyframes: points,
                                             duration: max(0.05, min(mask.duration, missing - mask.start)),
                                             endedWhenTargetLeftFrame: true)
        }
        return PrivacyMaskTrackingResult(keyframes: points, duration: mask.duration,
                                         endedWhenTargetLeftFrame: false)
    }
}

/// Uses a recognized word or detected person part as the identity of the selected
/// area. A missing or ambiguous observation stops tracking instead of jumping
/// to another similar-looking part of the video.
private struct PrivacyMaskTargetAnchor {
    private enum Kind {
        case text(String), face, person, hand
    }

    private let kind: Kind
    private let initialBox: CGRect
    private let initialMask: CGRect
    private var lastBox: CGRect

    var isText: Bool { if case .text = kind { return true }; return false }
    var isHand: Bool { if case .hand = kind { return true }; return false }
    var canEndAtFrameEdge: Bool { isText || isHand }
    var likelyExitedFrame: Bool {
        let dx = lastBox.midX - initialBox.midX
        let dy = lastBox.midY - initialBox.midY
        return (lastBox.maxY > 0.72 && dy > 0.15)
            || (lastBox.minY < 0.28 && dy < -0.15)
            || (lastBox.maxX > 0.78 && dx > 0.15)
            || (lastBox.minX < 0.22 && dx < -0.15)
    }

    static func select(image: CGImage, mask: CGRect,
                       target: PrivacyMaskTrackingTarget) throws -> Self? {
        switch target {
        case .visual: return nil
        case .text:
            guard let anchor = try textAnchor(image: image, mask: mask) else {
                throw PrivacyMaskTrackingError.targetNotFound(.text)
            }
            return anchor
        case .person:
            guard let anchor = try personAnchor(image: image, mask: mask) else {
                throw PrivacyMaskTrackingError.targetNotFound(.person)
            }
            return anchor
        case .automatic:
            if mask.height < 0.20, let anchor = try? textAnchor(image: image, mask: mask) { return anchor }
            if let anchor = try? personAnchor(image: image, mask: mask) { return anchor }
            return nil
        }
    }

    mutating func match(image: CGImage) throws -> CGRect? {
        let candidates: [CGRect]
        switch kind {
        case .text(let text): candidates = try Self.textBoxes(image: image, matching: text)
        case .face: candidates = try Self.personBoxes(image: image, face: true)
        case .person: candidates = try Self.personBoxes(image: image, face: false)
        case .hand: candidates = try Self.handBoxes(image: image)
        }
        let ranked = candidates.map { box in
            (box, hypot(box.midX - lastBox.midX, box.midY - lastBox.midY))
        }.sorted { $0.1 < $1.1 }
        guard let best = ranked.first else { return nil }
        if isText {
            // The exact words can jump across the screen during a fast scroll.
            // Multiple copies have no reliable identity, so do not switch copies.
            guard ranked.count == 1 else { return nil }
        } else {
            guard best.1 <= max(0.10, max(lastBox.width, lastBox.height) * 1.2),
                  !(ranked.count > 1 && ranked[1].1 - best.1 < 0.015) else { return nil }
        }
        lastBox = best.0
        let center = CGPoint(x: initialMask.midX + best.0.midX - initialBox.midX,
                             y: initialMask.midY + best.0.midY - initialBox.midY)
        let scale: CGFloat
        switch kind {
        case .text: scale = 1
        case .face, .person:
            scale = max(1, min(3, max(best.0.width / initialBox.width,
                                     best.0.height / initialBox.height)))
        case .hand:
            scale = max(0.3, min(3, max(best.0.width / initialBox.width,
                                        best.0.height / initialBox.height)))
        }
        let size = CGSize(width: min(1, initialMask.width * scale),
                          height: min(1, initialMask.height * scale))
        return CGRect(x: min(1 - size.width, max(0, center.x - size.width / 2)),
                      y: min(1 - size.height, max(0, center.y - size.height / 2)),
                      width: size.width, height: size.height)
    }

    private static func textAnchor(image: CGImage, mask: CGRect) throws -> Self? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let choices = (request.results ?? []).compactMap { observation -> (String, CGRect, CGFloat)? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
            let text = normalized(candidate.string)
            guard text.count >= 2 else { return nil }
            let box = topRect(observation.boundingBox)
            let overlap = box.intersection(mask)
            guard !overlap.isNull, !overlap.isEmpty else { return nil }
            let score = overlap.width * overlap.height / min(box.width * box.height, mask.width * mask.height)
            return score >= 0.45 ? (text, box, score) : nil
        }
        guard let best = choices.max(by: { $0.2 < $1.2 }) else { return nil }
        return Self(kind: .text(best.0), initialBox: best.1, initialMask: mask,
                    lastBox: best.1)
    }

    private static func textBoxes(image: CGImage, matching text: String) throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            let allowedErrors = max(1, Int(Double(text.count) * 0.12))
            guard observation.topCandidates(3).contains(where: {
                let candidate = normalized($0.string)
                return abs(candidate.count - text.count) <= allowedErrors
                    && editDistance(candidate, text, limit: allowedErrors) <= allowedErrors
            }) else { return nil }
            return topRect(observation.boundingBox)
        }
    }

    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let left = Array(a), right = Array(b)
        if abs(left.count - right.count) > limit { return limit + 1 }
        var previous = Array(0...right.count)
        for (row, character) in left.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: right.count)
            for column in right.indices {
                current[column + 1] = min(current[column] + 1, previous[column + 1] + 1,
                                          previous[column] + (character == right[column] ? 0 : 1))
            }
            if current.min()! > limit { return limit + 1 }
            previous = current
        }
        return previous[right.count]
    }

    private static func personAnchor(image: CGImage, mask: CGRect) throws -> Self? {
        for face in [true, false] {
            let choices = try personBoxes(image: image, face: face).compactMap { box -> (CGRect, CGFloat)? in
                let boxArea = box.width * box.height
                let maskArea = mask.width * mask.height
                guard max(boxArea, maskArea) / min(boxArea, maskArea) <= 4 else { return nil }
                let overlap = box.intersection(mask)
                guard !overlap.isNull, !overlap.isEmpty else { return nil }
                let score = overlap.width * overlap.height / min(boxArea, maskArea)
                return score >= 0.45 ? (box, score) : nil
            }
            if let best = choices.max(by: { $0.1 < $1.1 }) {
                return Self(kind: face ? .face : .person, initialBox: best.0,
                            initialMask: mask, lastBox: best.0)
            }
        }
        let hands = try handBoxes(image: image).compactMap { box -> (CGRect, CGFloat)? in
            let overlap = box.intersection(mask)
            guard !overlap.isNull, !overlap.isEmpty else { return nil }
            let score = overlap.width * overlap.height / (box.width * box.height)
            return score >= 0.65 ? (box, score) : nil
        }
        if let best = hands.max(by: { $0.1 < $1.1 }) {
            return Self(kind: .hand, initialBox: best.0,
                        initialMask: mask, lastBox: best.0)
        }
        return nil
    }

    private static func handBoxes(image: CGImage) throws -> [CGRect] {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        try VNImageRequestHandler(cgImage: image).perform([request])
        return try (request.results ?? []).compactMap { observation in
            let points = try observation.recognizedPoints(.all).values.filter { $0.confidence >= 0.3 }
            guard points.count >= 6 else { return nil }
            let xs = points.map { $0.location.x }
            let ys = points.map { 1 - $0.location.y }
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max(),
                  maxX - minX >= 0.01, maxY - minY >= 0.01 else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    private static func personBoxes(image: CGImage, face: Bool) throws -> [CGRect] {
        if face {
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).map { topRect($0.boundingBox) }
        }
        let request = VNDetectHumanRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).map { topRect($0.boundingBox) }
    }

    private static func topRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

/// A local appearance match keeps screen details aligned when Vision's object
/// tracker cannot recognize a UI element as a conventional object.
private struct PrivacyMaskTemplate {
    private struct Sample {
        let x: Int
        let y: Int
        let value: Int
        let weight: Int
    }

    private let width: Int
    private let height: Int
    private let originX: Int
    private let originY: Int
    private let samples: [Sample]
    private let totalWeight: Int
    private var offsetX = 0
    private var offsetY = 0

    init?(image: CGImage, area: CGRect) {
        guard let frame = Self.pixels(image) else { return nil }
        width = frame.width
        height = frame.height
        originX = Int(area.minX * CGFloat(width))
        originY = Int(area.minY * CGFloat(height))
        let spanX = max(1, Int(area.width * CGFloat(width)))
        let spanY = max(1, Int(area.height * CGFloat(height)))
        guard spanX >= 12, spanY >= 12 else { return nil }
        var gathered: [Sample] = []
        for row in 0..<12 {
            for column in 0..<20 {
                let x = min(width - 1, originX + (column * spanX + spanX / 2) / 20)
                let y = min(height - 1, originY + (row * spanY + spanY / 2) / 12)
                let value = frame.gray[y * width + x]
                let left = frame.gray[y * width + max(0, x - 2)]
                let right = frame.gray[y * width + min(width - 1, x + 2)]
                let up = frame.gray[max(0, y - 2) * width + x]
                let down = frame.gray[min(height - 1, y + 2) * width + x]
                let contrast = max(abs(left - right), abs(up - down))
                gathered.append(Sample(x: x - originX, y: y - originY,
                                       value: value, weight: min(6, max(1, contrast / 20))))
            }
        }
        guard let darkest = gathered.map({ $0.value }).min(), let lightest = gathered.map({ $0.value }).max(),
              lightest - darkest >= 20 else { return nil }
        samples = gathered
        totalWeight = gathered.reduce(0) { $0 + $1.weight }
    }

    mutating func match(image: CGImage) -> CGPoint? {
        guard let frame = Self.pixels(image), frame.width == width, frame.height == height else { return nil }
        let radiusX = min(48, max(12, width / 20))
        let radiusY = min(36, max(10, height / 20))
        var bestScore = Int.max
        var bestAppearanceScore = Int.max
        var bestX = offsetX, bestY = offsetY
        for dy in -radiusY...radiusY {
            let candidateY = originY + offsetY + dy
            for dx in -radiusX...radiusX {
                let candidateX = originX + offsetX + dx
                var appearanceScore = 0
                var valid = true
                for sample in samples {
                    let x = candidateX + sample.x, y = candidateY + sample.y
                    if x < 0 || x >= width || y < 0 || y >= height { valid = false; break }
                    appearanceScore += abs(frame.gray[y * width + x] - sample.value) * sample.weight
                    if appearanceScore >= bestScore { break }
                }
                let score = appearanceScore + (abs(dx) + abs(dy)) * totalWeight / 4
                if valid && score < bestScore {
                    bestScore = score
                    bestAppearanceScore = appearanceScore
                    bestX = offsetX + dx
                    bestY = offsetY + dy
                }
            }
        }
        guard bestAppearanceScore < totalWeight * 22 else { return nil }
        offsetX = bestX
        offsetY = bestY
        return CGPoint(x: CGFloat(offsetX) / CGFloat(width), y: CGFloat(offsetY) / CGFloat(height))
    }

    private static func pixels(_ image: CGImage) -> (width: Int, height: Int, gray: [Int])? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var gray = [Int](repeating: 0, count: width * height)
        for index in gray.indices {
            let pixel = index * 4
            gray[index] = (Int(rgba[pixel]) * 3 + Int(rgba[pixel + 1]) * 6 + Int(rgba[pixel + 2])) / 10
        }
        return (width, height, gray)
    }
}
