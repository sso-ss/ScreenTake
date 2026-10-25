#if SCREENTAKE_RUNTIME && arch(arm64)
import Foundation
import CoreImage
import CoreGraphics
import simd

/// One ordered MediaPipe VIDEO graph per preview/export stream. Cached geometry
/// can be repainted when controls change without sending a duplicate timestamp.
final class FaceEffectsPipeline {
    private var landmarker: LashFaceLandmarker?
    private let hands = ScreenTakeHandOcclusion()
    private var source: CIImage?
    private var timestamp: Double?
    private var extent = CGRect.zero
    private var graphTime = -Double.infinity
    private var photo: PhotoGeometry?
    private var protection: HandProtection?
    private(set) var detectionCount = 0
    private(set) var geometry: FaceBeautyGeometry?
    var error: String? { landmarker?.error }
    var handMask: CIImage? { protection?.mask }

    func reset() {
        landmarker = nil; hands.reset(); source = nil; timestamp = nil
        photo = nil; protection = nil; geometry = nil; graphTime = -.infinity
    }

    func render(_ image: CIImage, at time: Double, amount: Double, makeup: FaceMakeupSettings) -> CIImage {
        let bounds = image.extent
        guard time.isFinite, time >= 0, !bounds.isEmpty, !bounds.isInfinite,
              amount > 0 || makeup.amount > 0 else { reset(); return image }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        guard let raster = LashRendering.ci.createCGImage(normalized, from: normalized.extent,
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { reset(); return image }
        if source !== image || timestamp != time || extent != bounds {
            // Seeking, replacing a frame at the same time, or a discontinuity
            // starts a fresh graph. Other streams never share graph history.
            if extent != bounds || timestamp.map({ time <= $0 || time - $0 > 0.25 }) == true {
                landmarker = nil; graphTime = -.infinity; hands.reset()
            }
            if landmarker == nil { landmarker = LashFaceLandmarker(video: true) }
            let scale = min(1, 960 / max(bounds.width, bounds.height))
            let small = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let sample = scale == 1 ? raster : LashRendering.ci.createCGImage(small, from: small.extent,
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            // The API accepts integer milliseconds; preserve ordering for
            // distinct frames whose source times fall inside the same ms.
            graphTime = max(time, graphTime + 0.001001)
            photo = sample.flatMap { landmarker?.detect($0, at: graphTime) }?.scaled(by: 1 / scale)
            detectionCount += 1
            if photo != nil, let sample, let mask = hands.detect(sample, at: time)?.mask {
                protection = HandProtection(mask: mask.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
                    .cropped(to: normalized.extent), size: normalized.extent.size)
            } else { hands.reset(); protection = nil }
            geometry = photo.flatMap { FaceBeautyGeometry(photo: $0, size: bounds.size) }
            source = image; timestamp = time; extent = bounds
        }
        guard let photo, let geometry else { return image }
        let output: CIImage
        if makeup.amount > 0 && makeup.preset == .softPeach {
            var options = MakeupLook.softPeach.defaults
            options.intensity = CGFloat(makeup.lashes * makeup.amount)
            options.makeup.intensity = CGFloat(makeup.amount)
            options.makeup.skin = CGFloat(max(makeup.skin, amount / makeup.amount))
            options.makeup.faceShape = CGFloat(makeup.definition)
            options.makeup.contour = CGFloat(makeup.contour)
            options.makeup.blush = CGFloat(makeup.blush)
            options.makeup.eyes = CGFloat(makeup.eyeshadow)
            options.makeup.brows = CGFloat(makeup.brows)
            options.makeup.lips = CGFloat(makeup.lips)
            options.makeup.lipVolume = CGFloat(makeup.lipVolume)
            options.makeup.lipBlur = CGFloat(makeup.lipBlur)
            var result = CIImage(cgImage: LashRendering.photo(raster, face: photo, options: options, handProtection: protection))
            if makeup.shortening > 0 {
                let interior = FaceBeautyFilter.surfaceProtection(normalized, face: geometry)
                    .flatMap { FaceBeautyFilter.shapingSurfaceProtection($0, face: geometry) }
                let mask: CIImage?
                if let interior, let hand = protection?.mask {
                    mask = interior.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: hand])
                } else { mask = interior ?? protection?.mask }
                result = FaceMakeupRenderer.shapeLowerFace(result, face: geometry,
                    shortening: CGFloat(makeup.shortening * makeup.amount), protection: mask)
            }
            output = result
        } else {
            // Sharing detection must not replace the existing two looks with
            // Lash Lab's skin finish. Natural remains a skin-only CI pass.
            let peachSkin = makeup.amount * makeup.skin
            let skinAmount = max(amount, peachSkin)
            let maskScale = min(1, (makeup.amount > 0 ? 960 : 512) / max(bounds.width, bounds.height))
            var result = FaceBeautyFilter.renderSkin(normalized, face: geometry, current: geometry,
                amount: skinAmount, fineLines: peachSkin,
                maskSize: CGSize(width: bounds.width * maskScale, height: bounds.height * maskScale))
            if makeup.amount > 0 {
                let tonal = FaceBeautyFilter.surfaceProtection(normalized, face: geometry)
                let cosmetic: CIImage?
                if let tonal, let hand = protection?.mask {
                    cosmetic = tonal.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: hand])
                } else { cosmetic = tonal ?? protection?.mask }
                let interior = tonal.flatMap { FaceBeautyFilter.shapingSurfaceProtection($0, face: geometry) }
                let shaping: CIImage?
                if let interior, let hand = protection?.mask {
                    shaping = interior.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: hand])
                } else { shaping = interior ?? protection?.mask }
                result = FaceMakeupRenderer.render(result, face: geometry, current: geometry,
                    settings: makeup, opacity: 1, unfiltered: normalized,
                    handProtection: shaping, cosmeticProtection: cosmetic)
            }
            if let hand = protection?.mask {
                result = normalized.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: hand])
            }
            output = result
        }
        return output.transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY)).cropped(to: bounds)
    }
}

extension PhotoGeometry {
    func scaled(by factor: CGFloat) -> Self {
        func scale(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * factor, y: point.y * factor) }
        var result = self
        result.eyes = eyes.map { $0.map(scale) }; result.brows = brows.map { $0.map(scale) }
        result.bounds = bounds.applying(CGAffineTransform(scaleX: factor, y: factor))
        if var g = makeup {
            g.points = g.points.map(scale); g.depths = g.depths.map { $0 * factor }
            g.outerLips = g.outerLips.map(scale); g.innerLips = g.innerLips.map(scale)
            g.faceContour = g.faceContour.map(scale); result.makeup = g
        }
        return result
    }
}

extension FaceBeautyGeometry {
    init?(photo: PhotoGeometry, size: CGSize) {
        guard let g = photo.makeup, g.points.count == 468, size.width > 0, size.height > 0 else { return nil }
        func normalized(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / size.width, y: p.y / size.height) }
        func polygon(_ indices: [Int]) -> [CGPoint] { indices.map { normalized(g.points[$0]) } }
        imageSize = size
        bounds = CGRect(x: photo.bounds.minX / size.width, y: photo.bounds.minY / size.height,
            width: photo.bounds.width / size.width, height: photo.bounds.height / size.height)
        // Peach draws filled brow pigment; a five-point upper brow line from
        // the lash lab is not the closed perimeter expected by that renderer.
        features = photo.eyes.map { $0.map(normalized) } + DenseFaceMesh.brows.map(polygon)
            + [polygon([98,97,2,326,327,1]), polygon([168,6,197,195,5,4]), g.outerLips.map(normalized)]
        contour = polygon(DenseFaceMesh.jaw); forehead = polygon([10,338,297,332,284,251,389,356,454,234,127,162,21,54,103,67,109])
        innerLips = g.innerLips.map(normalized)
        yaw = Double(photo.yaw); pitch = Double(photo.pitch); lashYaw = yaw
        lashLidPitch = photo.eyes.map { eye in
            FaceMakeupRenderer.eyelids(eye, right: CGPoint(x: 1, y: 0)).map { FaceMakeupRenderer.lidPitch($0) } ?? 0
        }
        isProfile = abs(yaw) > 0.45
        mesh = DenseFaceMesh(points: g.points.indices.map { i in
            let p = normalized(g.points[i])
            return SIMD3(Float(p.x), Float(p.y), Float(g.depths.count > i ? g.depths[i] / size.width : 0))
        }, confidence: 1)
    }
}
#endif
