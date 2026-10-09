import Foundation
import CoreImage
import CoreGraphics
import CoreML
import Vision

/// Upright, normalized Core Image coordinates. No identity information is stored.
struct FaceBeautyGeometry {
    var bounds: CGRect
    var features: [[CGPoint]]
    var contour: [CGPoint]
    var forehead: [CGPoint]
    var isProfile: Bool
    var innerLips: [CGPoint]
    var yaw: Double
    /// Vision reports positive pitch for a downward nod.
    var pitch: Double
    var lashYaw: Double
    /// Lid rotation is distinct from head pitch (eyes can look down with a
    /// stationary head). Sparse Vision landmarks provide an estimate, not gaze.
    var lashLidPitch: [CGFloat]
    var mesh: DenseFaceMesh?
    var imageSize: CGSize

    init?(observation: VNFaceObservation, imageSize: CGSize = CGSize(width: 1, height: 1)) {
        guard observation.confidence >= 0.6, let landmarks = observation.landmarks else { return nil }
        self.imageSize = imageSize
        bounds = observation.boundingBox
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.normalizedPoints.map {
                CGPoint(x: observation.boundingBox.minX + CGFloat($0.x) * observation.boundingBox.width,
                        y: observation.boundingBox.minY + CGFloat($0.y) * observation.boundingBox.height)
            }
        }
        let left = points(landmarks.leftEye), right = points(landmarks.rightEye)
        let nose = points(landmarks.nose), lips = points(landmarks.outerLips)
        guard max(left.count, right.count) >= 3, nose.count >= 3, lips.count >= 3 else { return nil }
        let brows = [points(landmarks.leftEyebrow), points(landmarks.rightEyebrow)]
        features = [left, right] + brows + [nose, points(landmarks.noseCrest), lips]
        innerLips = points(landmarks.innerLips)
        yaw = observation.yaw?.doubleValue ?? 0
        pitch = observation.pitch?.doubleValue ?? 0
        lashYaw = yaw
        lashLidPitch = [left,right].map { eye in
            let pixelEye = eye.map { CGPoint(x:$0.x*imageSize.width,y:$0.y*imageSize.height) }
            guard let lids = FaceMakeupRenderer.eyelids(pixelEye,right:CGPoint(x:1,y:0)) else { return 0 }
            return FaceMakeupRenderer.lidPitch(lids)
        }
        contour = points(landmarks.faceContour)
        func center(_ points: [CGPoint]) -> CGPoint {
            CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                    y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        let separation = left.isEmpty || right.isEmpty ? 0 : hypot(center(right).x - center(left).x, center(right).y - center(left).y)
        isProfile = abs(observation.yaw?.doubleValue ?? 0) > 0.45 || separation < bounds.width * 0.18
        forehead = []
        if isProfile && contour.count < 5 { return nil }
        if !left.isEmpty, !right.isEmpty, brows.allSatisfy({ !$0.isEmpty }) {
            let a = center(left), b = center(right)
            let dx = (b.x - a.x) * imageSize.width, dy = (b.y - a.y) * imageSize.height
            let length = max(0.0001, hypot(dx, dy))
            let axis = CGPoint(x: dx / length, y: dy / length)
            let up = CGPoint(x: -axis.y, y: axis.x)
            let browA = center(brows[0]), browB = center(brows[1])
            let c = CGPoint(x: (browA.x + browB.x) / 2 * imageSize.width + up.x * bounds.width * imageSize.width * 0.15,
                            y: (browA.y + browB.y) / 2 * imageSize.height + up.y * bounds.width * imageSize.width * 0.15)
            forehead = (0..<32).map { index in
                let angle = Double(index) * .pi / 16
                let dx = cos(angle) * bounds.width * imageSize.width * 0.26, dy = sin(angle) * bounds.height * imageSize.height * 0.18
                return CGPoint(x: (c.x + dx * axis.x + dy * up.x) / imageSize.width,
                               y: (c.y + dx * axis.y + dy * up.y) / imageSize.height)
            }
        }
    }

    /// Carry the old geometry with this frame's translation, scale and roll
    /// before smoothing local landmark noise. Smoothing absolute coordinates
    /// makes brows and the jaw trail behind a moving face.
    func blended(from previous: Self, amount: CGFloat, poseAmount: CGFloat) -> Self {
        var result = self
        func center(_ points: [CGPoint]) -> CGPoint {
            CGPoint(x: points.map(\.x).reduce(0,+)/CGFloat(points.count),
                    y: points.map(\.y).reduce(0,+)/CGFloat(points.count))
        }
        guard features.count == previous.features.count,
              features.prefix(2).allSatisfy({ !$0.isEmpty }),
              previous.features.prefix(2).allSatisfy({ !$0.isEmpty }) else { return self }
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x:p.x*imageSize.width,y:p.y*imageSize.height) }
        let oldA = pixel(center(previous.features[0])), oldB = pixel(center(previous.features[1]))
        let newA = pixel(center(features[0])), newB = pixel(center(features[1]))
        let oldDX = oldB.x-oldA.x, oldDY = oldB.y-oldA.y
        let newDX = newB.x-newA.x, newDY = newB.y-newA.y
        let denominator = oldDX*oldDX + oldDY*oldDY
        guard denominator > 0.000001 else { return self }
        let real = (newDX*oldDX+newDY*oldDY)/denominator
        let imaginary = (newDY*oldDX-newDX*oldDY)/denominator
        let scale = hypot(real,imaginary)
        guard scale > 0.7, scale < 1.4 else { return self }
        func transport(_ point: CGPoint) -> CGPoint {
            let p = pixel(point), x = p.x-oldA.x, y = p.y-oldA.y
            return CGPoint(x:(newA.x+real*x-imaginary*y)/imageSize.width,
                           y:(newA.y+imaginary*x+real*y)/imageSize.height)
        }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b-a)*amount }
        func mix(_ old: [CGPoint], _ new: [CGPoint]) -> [CGPoint] {
            guard old.count == new.count else { return new }
            return zip(old.map(transport),new).map { CGPoint(x:mix($0.x,$1.x),y:mix($0.y,$1.y)) }
        }
        let oldCenter = transport(CGPoint(x:previous.bounds.midX,y:previous.bounds.midY))
        let width = mix(previous.bounds.width*scale,bounds.width)
        let height = mix(previous.bounds.height*scale,bounds.height)
        result.bounds = CGRect(x:mix(oldCenter.x,bounds.midX)-width/2,
                               y:mix(oldCenter.y,bounds.midY)-height/2,width:width,height:height)
        result.innerLips = mix(previous.innerLips,innerLips)
        result.contour = mix(previous.contour,contour)
        result.forehead = mix(previous.forehead,forehead)
        result.features = zip(previous.features,features).map { mix($0,$1) }
        result.yaw = previous.yaw + (yaw-previous.yaw)*Double(poseAmount)
        result.pitch = previous.pitch + (pitch-previous.pitch)*Double(amount)
        result.lashYaw = previous.lashYaw + (lashYaw-previous.lashYaw)*Double(amount)
        result.lashLidPitch = zip(previous.lashLidPitch,lashLidPitch).map { $0+($1-$0)*amount }
        if var mesh, let old = previous.mesh, mesh.points.count == old.points.count {
            for i in mesh.points.indices {
                let p = transport(CGPoint(x:CGFloat(old.points[i].x),y:CGFloat(old.points[i].y)))
                let prior = SIMD3<Float>(Float(p.x),Float(p.y),old.points[i].z*Float(scale))
                mesh.points[i] = prior+(mesh.points[i]-prior)*Float(amount)
            }
            result.mesh = mesh
        }
        return result
    }

    /// Vision's yaw is quantized. Keep shaping through a three-quarter turn and
    /// smoothly reduce it toward a true profile, where symmetric warping is unsafe.
    var shapingVisibility: CGFloat {
        let t = min(1,max(0,(abs(yaw)-0.35)/1.10))
        return CGFloat(1-t*t*(3-2*t))
    }

}

/// Each camera stream/renderer owns a tracker. Out-of-order requests and seeks
/// reset it; one failed detection fades out over 100 ms, never holds for seconds.
struct FaceBeautyTracker {
    private(set) var geometry: FaceBeautyGeometry?
    private(set) var opacity: Double = 0
    private var time: Double?
    private var lastSeen: Double?

    mutating func update(_ detected: FaceBeautyGeometry?, at nextTime: Double) {
        guard nextTime.isFinite else { self = Self(); return }
        if let time, nextTime < time || nextTime - time > 0.25 { self = Self() }
        let starting = time == nil
        let delta = min(0.1, max(0, nextTime - (time ?? nextTime - 1.0 / 30)))
        if let detected {
            if let previous = geometry,
               hypot(previous.bounds.midX - detected.bounds.midX, previous.bounds.midY - detected.bounds.midY) < 0.06 {
                geometry = detected.blended(from: previous, amount: CGFloat(1 - exp(-delta / 0.085)),
                                            poseAmount: CGFloat(1 - exp(-delta / 0.12)))
            } else {
                // Snap geometry on large motion rather than drag a skin mask over an eye.
                geometry = detected
                if starting { opacity = 1 }
            }
            opacity = min(1, opacity + delta / 0.1)
            lastSeen = nextTime
        } else {
            opacity = max(0, opacity - delta / 0.1)
            if lastSeen == nil || nextTime - lastSeen! >= 0.1 { opacity = 0; geometry = nil }
        }
        time = nextTime
    }
}

/// Cosmetics resume only after consecutive reliable observations. A single
/// recovered frame during an occlusion must not flash the full effect back on.
struct FaceMakeupVisibility {
    private(set) var amount = 1.0
    private var seen = false
    private var clearSince: Double?
    private var time: Double?

    init(seen: Bool = false) { self.seen = seen }

    mutating func update(detected: Bool, at next: Double) {
        if let time, next < time || next-time > 0.25 { self = Self() }
        let delta = max(0,next-(time ?? next))
        defer { time = next }
        guard detected else {
            amount = 0; clearSince = nil
            return
        }
        if !seen { seen = true; amount = 1; return }
        if amount == 1 { return }
        if clearSince == nil { clearSince = next }
        guard next-clearSince! >= 0.22 else { return }
        amount = min(1,amount+delta/0.24)
    }
}

/// Articulated hand geometry leaves gaps between fingers unmasked.
struct FaceHandGeometry {
    var palm: [CGPoint]
    var fingers: [[CGPoint]]
    var wrist: CGPoint
    var knuckles: CGPoint
    var palmWidth: CGFloat

    init?(observation: VNHumanHandPoseObservation, imageSize: CGSize) {
        guard let joints = try? observation.recognizedPoints(.all) else { return nil }
        func point(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let p = joints[name], p.confidence > 0.2 else { return nil }
            return p.location
        }
        guard let w = point(.wrist), let index = point(.indexMCP), let little = point(.littleMCP) else { return nil }
        wrist = w
        knuckles = CGPoint(x:(index.x+little.x)/2,y:(index.y+little.y)/2)
        palmWidth = hypot((index.x-little.x)*imageSize.width,(index.y-little.y)*imageSize.height)
        guard palmWidth > 3 else { return nil }
        palm = [.wrist,.thumbCMC,.thumbMP,.indexMCP,.middleMCP,.ringMCP,.littleMCP].compactMap(point)
        let names: [[VNHumanHandPoseObservation.JointName]] = [
            [.thumbCMC,.thumbMP,.thumbIP,.thumbTip], [.indexMCP,.indexPIP,.indexDIP,.indexTip],
            [.middleMCP,.middlePIP,.middleDIP,.middleTip], [.ringMCP,.ringPIP,.ringDIP,.ringTip],
            [.littleMCP,.littlePIP,.littleDIP,.littleTip]]
        // Stop at a missing joint instead of drawing across an uncertain finger.
        fingers = names.map { names in
            var line: [CGPoint] = []
            for name in names { guard let p = point(name) else { break }; line.append(p) }
            return line
        }
    }

    func overlaps(_ rect: CGRect, imageSize: CGSize) -> Bool {
        func intersects(_ points: [CGPoint], radius: CGFloat) -> Bool {
            guard !points.isEmpty else { return false }
            let box = CGRect(x:points.map(\.x).min()!,y:points.map(\.y).min()!,
                width:points.map(\.x).max()!-points.map(\.x).min()!,
                height:points.map(\.y).max()!-points.map(\.y).min()!)
                .insetBy(dx:-radius/imageSize.width,dy:-radius/imageSize.height)
            return box.intersects(rect)
        }
        if intersects(palm,radius:palmWidth*0.18) { return true }
        for finger in fingers {
            for index in 1..<max(1,finger.count) {
                if intersects([finger[index-1],finger[index]],radius:palmWidth*0.20) { return true }
            }
        }
        let sleeve = CGPoint(x:wrist.x+(wrist.x-knuckles.x)*0.9,y:wrist.y+(wrist.y-knuckles.y)*0.9)
        return intersects([wrist,sleeve],radius:palmWidth*0.5)
    }

    init(palm: [CGPoint], fingers: [[CGPoint]], wrist: CGPoint, knuckles: CGPoint, palmWidth: CGFloat) {
        self.palm = palm; self.fingers = fingers; self.wrist = wrist; self.knuckles = knuckles; self.palmWidth = palmWidth
    }
}

/// Match hands independently: observing the other hand must not erase the
/// protection for one that is briefly lost behind a sleeve or the face.
struct FaceHandTracker {
    struct Entry { var hand: FaceHandGeometry; var lastSeen: Double }
    private var entries: [Entry] = []
    private var time: Double?
    mutating func update(_ hands: [FaceHandGeometry], at next: Double) -> [(FaceHandGeometry, CGFloat)] {
        if let time, next < time || next-time > 0.25 { entries = [] }
        time = next
        var old = entries, updated: [Entry] = []
        for hand in hands {
            if let index = old.indices.min(by: {
                hypot(old[$0].hand.wrist.x-hand.wrist.x,old[$0].hand.wrist.y-hand.wrist.y) <
                hypot(old[$1].hand.wrist.x-hand.wrist.x,old[$1].hand.wrist.y-hand.wrist.y)
            }), hypot(old[index].hand.wrist.x-hand.wrist.x,old[index].hand.wrist.y-hand.wrist.y) < 0.25 {
                old.remove(at:index)
            }
            updated.append(Entry(hand:hand,lastSeen:next))
        }
        entries = updated + old.filter { next-$0.lastSeen < 0.28 }
        return entries.map { ($0.hand,CGFloat(min(1,max(0,(0.28-(next-$0.lastSeen))/0.16)))) }
    }
}

#if FACE_BEAUTY_PROFILING
/// Benchmark-only wall timings. Core Image graph construction is recorded here;
/// the benchmark separately forces output rendering to measure deferred GPU work.
final class FaceBeautyFrameProfile {
    private var checkpoint = DispatchTime.now().uptimeNanoseconds
    private(set) var stagesMs: [String: Double] = [:]
    let captureImages: Bool
    var images: [String: CIImage] = [:]

    init(captureImages: Bool) { self.captureImages = captureImages }

    func mark(_ stage: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        stagesMs[stage, default: 0] += Double(now - checkpoint) / 1_000_000
        checkpoint = now
    }
}
#endif

/// Shared by live camera, editor playback and export. Work is serialized per
/// stream; capture/writing never waits on this processor. Only one frame is cached.
final class FaceBeautyFilter {
#if FACE_BEAUTY_PROFILING
    private(set) var lastProfile: FaceBeautyFrameProfile?
    var profileImagesEnabled = false
#endif
    private let meshDetector: DenseFaceMeshDetector?
    init(meshEnabled: Bool = true, meshModelURL: URL? = nil, meshComputeUnits: MLComputeUnits = .cpuAndGPU) {
        meshDetector = meshEnabled ? DenseFaceMeshDetector(modelURL:meshModelURL,computeUnits:meshComputeUnits) : nil
    }
    var meshError: String? { meshDetector?.error }
    private let lock = NSLock()
    private var tracker = FaceBeautyTracker()
    private var cachedTime: Double?
    private var cachedAmount = 0.0
    private var cachedMakeup = FaceMakeupSettings()
    private var cachedExtent = CGRect.zero
    private var cachedImage: CIImage?
    private var cachedSource: CIImage?
    private(set) var detectionCount = 0
    private(set) var lastDetectedGeometry: FaceBeautyGeometry?
    private(set) var lastUsedFaceFallback = false
    private(set) var lastDetectedHands: [[CGPoint]] = []
    private var handTracker = FaceHandTracker()
    private var makeupVisibility = FaceMakeupVisibility()
    private var lipVisibility = FaceMakeupVisibility()
    var lastLipVisibility: Double { lipVisibility.amount }
    var lastMakeupVisibility: Double { makeupVisibility.amount }
    private(set) var lastHandMask: CIImage?
    var lastTrackedGeometry: FaceBeautyGeometry? { tracker.geometry }

    static func clamped(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

    func render(_ image: CIImage, at time: Double, amount: Double, makeup: FaceMakeupSettings = .init()) -> CIImage {
#if FACE_BEAUTY_PROFILING
        let profile = FaceBeautyFrameProfile(captureImages: profileImagesEnabled)
#endif
        lock.lock()
        defer { lock.unlock() }
#if FACE_BEAUTY_PROFILING
        profile.mark("lock")
        defer { profile.mark("return"); lastProfile = profile }
#endif
        let amount = Self.clamped(amount)
        let makeup = makeup.clamped
        guard amount > 0 || makeup.amount > 0, time.isFinite, !image.extent.isEmpty, !image.extent.isInfinite else {
            tracker = FaceBeautyTracker(); cachedImage = nil; cachedSource = nil; cachedTime = nil
            lastDetectedGeometry = nil; lastUsedFaceFallback = false; lastDetectedHands = []; handTracker = FaceHandTracker(); makeupVisibility = FaceMakeupVisibility(); lipVisibility = FaceMakeupVisibility(); lastHandMask = nil
            return image
        }
        if cachedSource === image, cachedTime == time, cachedAmount == amount, cachedMakeup == makeup, cachedExtent == image.extent, let cachedImage { return cachedImage }
        let bounds = image.extent
        let scale = min(1, (makeup.amount > 0 ? 960 : 512) / max(bounds.width, bounds.height))
        let normalized = image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let small = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let request = VNDetectFaceLandmarksRequest()
        // The landmark request's implicit detector supplies quantized yaw and
        // no pitch. Revision 3 supplies continuous pose; keep landmark geometry
        // unchanged so this correction does not move the other cosmetics.
        let pose = VNDetectFaceRectanglesRequest()
        pose.revision = VNDetectFaceRectanglesRequestRevision3
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 2
        lastDetectedHands = []
        lastUsedFaceFallback = false
        if cachedExtent != bounds || cachedTime.map({ time < $0 || time-$0 > 0.25 }) == true {
            handTracker = FaceHandTracker(); makeupVisibility = FaceMakeupVisibility(); lipVisibility = FaceMakeupVisibility()
        }
        var detected: FaceBeautyGeometry?
#if FACE_BEAUTY_PROFILING
        profile.mark("prepare")
#endif
        do {
            let handler = VNImageRequestHandler(ciImage:small,options:[:])
            try handler.perform(makeup.amount > 0 ? [request,hands] : [request])
#if FACE_BEAUTY_PROFILING
            profile.mark("vision.faceAndHandBatch")
#endif
            // A single batch lets Vision substitute revision 3 for the landmark
            // request's implicit face detector, changing all feature geometry.
            // Use a separate handler as well: reusing the handler can return
            // its cached revision-2 faces, which have no pitch, for this request.
            if makeup.amount > 0 { try? VNImageRequestHandler(ciImage:small,options:[:]).perform([pose]) }
#if FACE_BEAUTY_PROFILING
            profile.mark("vision.pose")
#endif
            detectionCount += 1
            var observations = request.results ?? []
            if makeup.amount > 0, !observations.contains(where:{ FaceBeautyGeometry(observation:$0,imageSize:small.extent.size) != nil }) {
                // Partial occlusion can defeat the implicit revision-2 detector
                // while revision 3 still observes the face. Re-detect landmarks
                // inside that CURRENT box instead of shutting off all cosmetics
                // or drawing an old face over a moving foreground object.
                let fallback = VNDetectFaceLandmarksRequest()
                fallback.inputFaceObservations = (pose.results ?? []).filter { $0.confidence >= 0.6 }
                if fallback.inputFaceObservations?.isEmpty == false {
                    try? VNImageRequestHandler(ciImage:small,options:[:]).perform([fallback])
                    observations = fallback.results ?? []
                    lastUsedFaceFallback = !observations.isEmpty
                }
            }
#if FACE_BEAUTY_PROFILING
            profile.mark("vision.fallback")
#endif
            let candidates = observations.compactMap { observation -> FaceBeautyGeometry? in
                guard var geometry = FaceBeautyGeometry(observation:observation,imageSize:small.extent.size) else { return nil }
                func overlap(_ p: VNFaceObservation) -> CGFloat {
                    let intersection = p.boundingBox.intersection(geometry.bounds)
                    return intersection.isNull ? 0 : intersection.width*intersection.height
                }
                if let matched = pose.results?.max(by:{ overlap($0) < overlap($1) }), matched.confidence >= 0.6,
                   overlap(matched) > geometry.bounds.width*geometry.bounds.height*0.35 {
                    geometry.pitch = matched.pitch?.doubleValue ?? geometry.pitch
                    geometry.lashYaw = matched.yaw?.doubleValue ?? geometry.lashYaw
                }
                return geometry
            }
            if let previous = tracker.geometry {
                detected = candidates.min {
                    hypot($0.bounds.midX - previous.bounds.midX, $0.bounds.midY - previous.bounds.midY)
                        < hypot($1.bounds.midX - previous.bounds.midX, $1.bounds.midY - previous.bounds.midY)
                }
            } else { detected = candidates.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height } }
        } catch {
            // An unavailable detector must not apply a stale mask.
            tracker = FaceBeautyTracker()
            detected = nil
        }
#if FACE_BEAUTY_PROFILING
        profile.mark("geometry.match")
#endif
        let handPoses = makeup.amount > 0 ? (hands.results ?? []).compactMap {
            FaceHandGeometry(observation:$0,imageSize:small.extent.size)
        } : []
        lastDetectedHands = handPoses.map { $0.palm + $0.fingers.flatMap { $0 } }
        let protectedHands = handTracker.update(handPoses,at:time)
        let handMask = makeup.amount > 0 ? Self.handMask(protectedHands,size:small.extent.size) : nil
#if FACE_BEAUTY_PROFILING
        profile.mark("hand.geometryAndMask")
        if profile.captureImages { profile.images["handMask"] = handMask }
#endif
        if makeup.amount > 0, var geometry = detected,
           let mesh = meshDetector?.detect(small,face:geometry) {
            geometry.mesh = mesh
            geometry.features[0] = mesh.polygon(DenseFaceMesh.eyes[0])
            geometry.features[1] = mesh.polygon(DenseFaceMesh.eyes[1])
            geometry.features[2] = mesh.polygon(DenseFaceMesh.brows[0])
            geometry.features[3] = mesh.polygon(DenseFaceMesh.brows[1])
            // Keep bridge and alar width in the same coordinate model. Mixing
            // the dense bridge with Vision's nose edge could erase one side.
            geometry.features[4] = mesh.polygon([98,97,2,326,327,1])
            geometry.features[5] = mesh.polygon([168,6,197,195,5,4])
            geometry.features[6] = mesh.polygon(DenseFaceMesh.lips)
            geometry.innerLips = mesh.polygon(DenseFaceMesh.innerLips)
            geometry.contour = mesh.polygon(DenseFaceMesh.jaw)
            detected = geometry
        }
#if FACE_BEAUTY_PROFILING
        profile.mark("mesh")
#endif
        let surfaceMask = makeup.amount > 0 ? detected.flatMap { Self.surfaceProtection(small,face:$0) } : nil
        let foregroundMask: CIImage?
        if let surfaceMask, let handMask {
            foregroundMask = surfaceMask.applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:handMask])
        } else { foregroundMask = surfaceMask ?? handMask }
        lastHandMask = handMask
        func fullSize(_ mask: CIImage?) -> CIImage? {
            mask?.transformed(by:CGAffineTransform(scaleX:1/scale,y:1/scale))
                .transformed(by:CGAffineTransform(translationX:bounds.minX,y:bounds.minY)).cropped(to:bounds)
        }
        let cosmeticProtection = fullSize(foregroundMask)
        let fullHandMask = fullSize(handMask)
        let interiorSurface = detected.flatMap { face in
            surfaceMask.flatMap { Self.shapingSurfaceProtection($0,face:face) }
        }
        let shapingMask: CIImage?
        if let interiorSurface, let handMask {
            shapingMask = interiorSurface.applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:handMask])
        } else { shapingMask = interiorSurface ?? handMask }
#if FACE_BEAUTY_PROFILING
        profile.mark("protection.maskPreparation")
        if profile.captureImages {
            profile.images["surfaceMask"] = surfaceMask
            profile.images["shapingMask"] = fullSize(shapingMask)
        }
#endif
        makeupVisibility.update(detected:detected != nil,at:time)
        var effectiveMakeup = makeup
        effectiveMakeup.amount *= makeupVisibility.amount
        // Occlusion is spatial: one finger over a corner must not switch off
        // lipstick across the entire mouth. Only missing mouth geometry gates
        // the whole component; the foreground mask removes covered pixels.
        lipVisibility.update(detected:(detected?.features[6].count ?? 0) >= 3,at:time)
        effectiveMakeup.lips *= lipVisibility.amount
        lastDetectedGeometry = detected
        tracker.update(detected, at: time)
#if FACE_BEAUTY_PROFILING
        profile.mark("geometry.tracking")
#endif
        var result = image
        // Peach includes its own skin finish; Natural can still be used alone.
        // Choose the stronger requested pass rather than smoothing twice.
        let peachSkin = detected == nil ? 0 : effectiveMakeup.amount * makeup.skin
        let skinAmount = max(amount, peachSkin)
        if skinAmount > 0, let geometry = tracker.geometry, tracker.opacity > 0,
           let mask = Self.mask(geometry, protecting: detected, size: small.extent.size), let kernel = Self.kernel {
            let fullMask = mask.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
                .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY)).cropped(to: bounds)
#if FACE_BEAUTY_PROFILING
            if profile.captureImages { profile.images["skinMask"] = fullMask }
#endif
            let radius = max(1, geometry.bounds.width * bounds.width * 0.035)
            result = kernel.apply(extent: bounds, roiCallback: { index, rect in index == 0 ? rect.insetBy(dx: -radius, dy: -radius) : rect },
                                  arguments: [image.clampedToExtent(), fullMask, radius, skinAmount * tracker.opacity, peachSkin]) ?? image
        }
#if FACE_BEAUTY_PROFILING
        profile.mark("skin.maskAndGraph")
        if profile.captureImages { profile.images["skinOutput"] = result }
#endif
        // Cosmetics require a current observation: never leave lashes/lip color
        // floating on the last face position after a missed detection.
        if let geometry = tracker.geometry, detected != nil, effectiveMakeup.amount > 0 {
            result = FaceMakeupRenderer.render(result, face: geometry, current: detected!,
                                               settings: effectiveMakeup, opacity: tracker.opacity, unfiltered: image,
                                               handProtection:fullSize(shapingMask), cosmeticProtection:cosmeticProtection)
        }
#if FACE_BEAUTY_PROFILING
        profile.mark("makeup.drawingAndGraph")
        if profile.captureImages { profile.images["makeupOutput"] = result }
#endif
        // True hands stay in camera space. Hair/clothing color protection is
        // restored BEFORE shaping, otherwise the old jaw edge gets pasted back
        // over the shortened chin and cancels the change in face size.
        if let fullHandMask, result !== image {
            result = image.applyingFilter("CIBlendWithMask",parameters:[
                kCIInputBackgroundImageKey:result,kCIInputMaskImageKey:fullHandMask]).cropped(to:bounds)
        }
#if FACE_BEAUTY_PROFILING
        profile.mark("hand.restoreGraph")
        if profile.captureImages { profile.images["final"] = result }
#endif
        cachedMakeup = makeup
        cachedTime = time; cachedAmount = amount; cachedExtent = bounds; cachedImage = result; cachedSource = image
        return result
    }

    /// Rasterize palms and tapered finger capsules separately. Convex-hulling
    /// fingertips erases visible makeup in the empty spaces between fingers.
    static func handMask(_ hands: [(FaceHandGeometry, CGFloat)], size: CGSize) -> CIImage? {
        guard !hands.isEmpty, let ctx = CGContext(data:nil,width:Int(ceil(size.width)),height:Int(ceil(size.height)),
            bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return nil }
        let extent = CGRect(origin:.zero,size:size)
        ctx.setFillColor(gray:0,alpha:1); ctx.fill(extent)
        ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setBlendMode(.lighten)
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x:p.x*size.width,y:p.y*size.height) }
        for (hand,opacity) in hands {
            ctx.setFillColor(gray:opacity,alpha:1); ctx.setStrokeColor(gray:opacity,alpha:1)
            let palm = hull(hand.palm.map(pixel)), width = hand.palmWidth
            if let first = palm.first {
                ctx.move(to:first); palm.dropFirst().forEach { ctx.addLine(to:$0) }
                ctx.closePath(); ctx.setLineWidth(width*0.26); ctx.drawPath(using:.fillStroke)
            }
            for finger in hand.fingers {
                for i in 1..<max(1,finger.count) {
                    ctx.setLineWidth(width*(i == 1 ? 0.30 : 0.25))
                    ctx.move(to:pixel(finger[i-1])); ctx.addLine(to:pixel(finger[i])); ctx.strokePath()
                }
            }
            let wrist = pixel(hand.wrist), knuckles = pixel(hand.knuckles)
            ctx.setLineWidth(width*0.95)
            ctx.move(to:wrist)
            ctx.addLine(to:CGPoint(x:wrist.x+(wrist.x-knuckles.x)*0.9,y:wrist.y+(wrist.y-knuckles.y)*0.9))
            ctx.strokePath()
        }
        guard let cg = ctx.makeImage() else { return nil }
        let solid = CIImage(cgImage:cg)
        let feather = max(0.7,size.width*0.0015)
        return solid.applyingGaussianBlur(sigma:feather)
            .applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:solid]).cropped(to:extent)
    }

    /// A mesh predicts the face behind hair/fabric; it is not an occlusion mask.
    /// Reject dark strands and cool fabric using source pixels, relative to the
    /// current face's own illumination. Hands still need articulated geometry:
    /// their skin color is not distinguishable from facial skin by this test.
    static func surfaceProtection(_ image: CIImage, face: FaceBeautyGeometry) -> CIImage? {
        guard let kernel = surfaceProtectionKernel, face.features.count >= 7,
              face.features[0].count >= 3, face.features[1].count >= 3 else { return nil }
        let bounds = image.extent
        func center(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x:p.map(\.x).reduce(0,+)/CGFloat(p.count),y:p.map(\.y).reduce(0,+)/CGFloat(p.count))
        }
        let a = center(face.features[0]), b = center(face.features[1])
        let mouth = center(face.features[6])
        let anchors = [CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2),
                       CGPoint(x:a.x,y:a.y*0.6+mouth.y*0.4),
                       CGPoint(x:b.x,y:b.y*0.6+mouth.y*0.4)]
        let vectors = anchors.map { CIVector(x:bounds.minX+$0.x*bounds.width,y:bounds.minY+$0.y*bounds.height) }
        return kernel.apply(extent:bounds,roiCallback:{ _,_ in bounds },
                            arguments:[image,vectors[0],vectors[1],vectors[2]])
    }

    /// Color alone cannot distinguish foreground cloth from the background
    /// just outside the jaw. Only interior surface occlusion should stop a warp;
    /// the face silhouette must be free to move. Hands retain their full mask.
    static func shapingSurfaceProtection(_ surface: CIImage, face: FaceBeautyGeometry) -> CIImage? {
        let extent = surface.extent
        guard face.contour.count >= 5,
              let context = CGContext(data:nil,width:Int(ceil(extent.width)),height:Int(ceil(extent.height)),
                    bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(origin:.zero,size:extent.size))
        context.setFillColor(CGColor(gray:1,alpha:1))
        context.addLines(between:face.contour.map { CGPoint(x:$0.x*extent.width,y:$0.y*extent.height) })
        context.closePath(); context.fillPath()
        guard let cg = context.makeImage() else { return nil }
        let interior = CIImage(cgImage:cg).transformed(by:CGAffineTransform(translationX:extent.minX,y:extent.minY))
            .applyingFilter("CIMorphologyMinimum",parameters:[kCIInputRadiusKey:max(2,face.bounds.width*extent.width*0.10)])
        let black = CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:extent)
        return surface.applyingFilter("CIBlendWithMask",parameters:[
            kCIInputBackgroundImageKey:black,kCIInputMaskImageKey:interior]).cropped(to:extent)
    }

    private static let surfaceProtectionKernel = CIKernel(source: """
    kernel vec4 protectForeground(sampler source, vec2 a, vec2 b, vec2 c) {
        vec3 luma = vec3(0.2126,0.7152,0.0722);
        vec3 pixel = sample(source,samplerCoord(source)).rgb;
        float la = dot(sample(source,samplerTransform(source,a)).rgb,luma);
        float lb = dot(sample(source,samplerTransform(source,b)).rgb,luma);
        float lc = dot(sample(source,samplerTransform(source,c)).rgb,luma);
        float reference = max(0.01,max(la,max(lb,lc)));
        float light = dot(pixel,luma)/reference;
        float value = max(0.015,max(pixel.r,max(pixel.g,pixel.b)));
        float warmth = (pixel.r-pixel.b)/value;
        float skin = smoothstep(0.23,0.52,light) * smoothstep(-0.045,0.045,warmth);
        float protection = 1.0-skin;
        return vec4(protection,protection,protection,1.0);
    }
    """)

    /// Feature interiors remain completely excluded after feathering. Protect
    /// both current and stabilized landmarks so the smoothing cannot lag onto eyes.
    static func mask(_ face: FaceBeautyGeometry, protecting current: FaceBeautyGeometry?, size: CGSize) -> CIImage? {
        let width = Int(ceil(size.width)), height = Int(ceil(size.height))
        guard width > 0, height > 0 else { return nil }
        func context() -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        guard let skin = context(), let exclusion = context() else { return nil }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        for ctx in [skin, exclusion] { ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(extent); ctx.setFillColor(gray: 1, alpha: 1) }
        func scaled(_ points: [CGPoint]) -> [CGPoint] { points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } }
        func path(_ points: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            if let first = points.first { path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath() }
            return path
        }
        let rect = CGRect(x: face.bounds.minX * size.width, y: face.bounds.minY * size.height,
                          width: face.bounds.width * size.width, height: face.bounds.height * size.height)
        // Blend mask shapes continuously across pose changes instead of switching
        // skin coverage on a single quantized yaw observation.
        let frontal = face.shapingVisibility
        skin.setFillColor(gray: 1, alpha: 1)
        skin.addPath(path(Self.hull(scaled(face.contour)))); skin.fillPath()
        skin.setFillColor(gray: frontal, alpha: 1)
        skin.setBlendMode(.lighten)
        skin.fillEllipse(in: rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.06))
        skin.addPath(path(scaled(face.forehead))); skin.fillPath()
        exclusion.setStrokeColor(gray: 1, alpha: 1)
        exclusion.setLineWidth(max(3, rect.width * 0.04)); exclusion.setLineJoin(.round); exclusion.setLineCap(.round)
        for geometry in [face, current].compactMap({ $0 }) {
            for points in geometry.features where !points.isEmpty {
                exclusion.addPath(path(Self.hull(scaled(points)))); exclusion.drawPath(using: .fillStroke)
            }
        }
        guard let skinImage = skin.makeImage(), let featureImage = exclusion.makeImage() else { return nil }
        let feather = max(1, rect.width * 0.02)
        let skinMask = CIImage(cgImage: skinImage).applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: feather])
            .applyingGaussianBlur(sigma: feather).cropped(to: extent)
        let features = CIImage(cgImage: featureImage)
        let protected = features.applyingGaussianBlur(sigma: feather)
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: features])
        return CIImage(color: .black).cropped(to: extent).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: skinMask, kCIInputMaskImageKey: protected
        ]).cropped(to: extent)
    }

    private static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x) }
        func half(_ values: [CGPoint]) -> [CGPoint] {
            var result: [CGPoint] = []
            for point in values {
                while result.count > 1 && cross(result[result.count-2], result[result.count-1], point) <= 0 { result.removeLast() }
                result.append(point)
            }
            return result
        }
        return Array(half(sorted).dropLast()) + Array(half(sorted.reversed()).dropLast())
    }

    // A small bilateral neighborhood softens skin without averaging across tonal
    // edges. The fine-line pass lifts narrow dark valleys, not whole face regions.
    private static let kernel = CIKernel(source: """
    kernel vec4 faceBeauty(sampler source, sampler mask, float radius, float strength, float fineLines) {
        vec2 p = destCoord();
        vec4 original = sample(source, samplerTransform(source, p));
        float amount = sample(mask, samplerTransform(mask, p)).r * strength;
        if (amount < 0.001) return original;
        vec3 sum = vec3(0.0); float weights = 0.0;
        for (int y = -2; y <= 2; y++) {
            for (int x = -2; x <= 2; x++) {
                vec2 offset = vec2(float(x), float(y));
                vec3 color = sample(source, samplerTransform(source, p + offset * radius * 0.5)).rgb;
                vec3 difference = color - original.rgb;
                float weight = exp(-dot(offset, offset) / 5.0 - dot(difference, difference) * 65.0);
                sum += color * weight; weights += weight;
            }
        }
        vec3 soft = sum / weights;
        vec3 luma = vec3(0.2126, 0.7152, 0.0722);
        float center = dot(original.rgb, luma);
        float left = dot(sample(source, samplerTransform(source, p - vec2(radius * 0.4, 0.0))).rgb, luma);
        float right = dot(sample(source, samplerTransform(source, p + vec2(radius * 0.4, 0.0))).rgb, luma);
        float up = dot(sample(source, samplerTransform(source, p + vec2(0.0, radius * 0.4))).rgb, luma);
        float down = dot(sample(source, samplerTransform(source, p - vec2(0.0, radius * 0.4))).rgb, luma);
        float ridge = max(0.0, max(min(left, right), min(up, down)) - center);
        float lift = min(ridge, 0.05 + fineLines * 0.025) * smoothstep(0.005, 0.025, ridge) * (1.0 - smoothstep(0.08, 0.18, ridge)) * (0.35 + fineLines * 0.9);
        return vec4(clamp(mix(original.rgb, soft, amount * 0.95) + lift * amount, 0.0, 1.0), original.a);
    }
    """)
}

/// Independent from Natural; old recordings and fresh installs start with makeup off.
struct FaceMakeupSettings: Codable, Equatable {
    var amount = 0.0
    var lashes = 0.85
    var brows = 0.45
    var blush = 0.65
    var lips = 0.55
    var eyeshadow = 0.5
    var underEyeShadow = 0.7
    var aegyo = 0.8
    var contour = 0.7
    var shortening = 0.3
    var skin = 0.9
    var definition = 0.65

    enum CodingKeys: String, CodingKey { case amount, lashes, brows, blush, lips, eyeshadow, underEyeShadow, aegyo, contour, shortening, skin, definition }
    init(amount: Double = 0) { self.amount = amount }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? amount
        lashes = try c.decodeIfPresent(Double.self, forKey: .lashes) ?? lashes
        brows = try c.decodeIfPresent(Double.self, forKey: .brows) ?? brows
        blush = try c.decodeIfPresent(Double.self, forKey: .blush) ?? blush
        lips = try c.decodeIfPresent(Double.self, forKey: .lips) ?? lips
        eyeshadow = try c.decodeIfPresent(Double.self, forKey: .eyeshadow) ?? eyeshadow
        underEyeShadow = try c.decodeIfPresent(Double.self, forKey: .underEyeShadow) ?? underEyeShadow
        aegyo = try c.decodeIfPresent(Double.self, forKey: .aegyo) ?? aegyo
        contour = try c.decodeIfPresent(Double.self, forKey: .contour) ?? contour
        shortening = try c.decodeIfPresent(Double.self, forKey: .shortening) ?? shortening
        skin = try c.decodeIfPresent(Double.self, forKey: .skin) ?? skin
        definition = try c.decodeIfPresent(Double.self, forKey: .definition) ?? definition
    }

    var values: [Double] { [amount, lashes, brows, blush, lips, eyeshadow, underEyeShadow, aegyo, contour, shortening, skin, definition] }
    var clamped: Self {
        var copy = self
        for key in Self.keys { copy[keyPath: key] = FaceBeautyFilter.clamped(copy[keyPath: key]) }
        return copy
    }
    static let keys: [WritableKeyPath<Self, Double>] = [\.amount, \.lashes, \.brows, \.blush, \.lips, \.eyeshadow, \.underEyeShadow, \.aegyo, \.contour, \.shortening, \.skin, \.definition]
}

/// Procedural, translucent cosmetics preserve the source texture. All drawing is
/// in pixel space so rolls and non-square camera frames keep the correct shape.
enum FaceMakeupRenderer {
    private static func center(_ p: [CGPoint]) -> CGPoint {
        guard !p.isEmpty else { return .zero }
        return CGPoint(x: p.map(\.x).reduce(0,+) / CGFloat(p.count), y: p.map(\.y).reduce(0,+) / CGFloat(p.count))
    }
    private static func add(_ p: CGPoint, _ v: CGPoint, _ n: CGFloat) -> CGPoint { CGPoint(x: p.x + v.x*n, y: p.y + v.y*n) }
    private static func dot(_ p: CGPoint, _ v: CGPoint) -> CGFloat { p.x*v.x + p.y*v.y }
    private static func path(_ points: [CGPoint], closed: Bool = true) -> CGPath {
        let p = CGMutablePath()
        guard let first = points.first else { return p }
        p.move(to: first)
        points.dropFirst().forEach { p.addLine(to: $0) }
        if closed { p.closeSubpath() }
        return p
    }
    /// Interpolate only cosmetic outlines. Protection masks retain the complete
    /// observed polygons so a rounded corner cannot expose an eye or tooth.
    private static func smooth(_ points: [CGPoint], closed: Bool = false) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        func point(_ index: Int) -> CGPoint {
            points[closed ? (index + points.count) % points.count : min(points.count-1, max(0,index))]
        }
        var result: [CGPoint] = []
        for index in 0..<(closed ? points.count : points.count-1) {
            let a = point(index-1), b = point(index), c = point(index+1), d = point(index+2)
            for step in 0..<8 {
                let t = CGFloat(step)/8, t2 = t*t, t3 = t2*t
                func value(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * ((2*b)+(-a+c)*t+(2*a-5*b+4*c-d)*t2+(-a+3*b-3*c+d)*t3)
                }
                result.append(CGPoint(x:value(a.x,b.x,c.x,d.x),y:value(a.y,b.y,c.y,d.y)))
            }
        }
        if !closed { result.append(points.last!) }
        return result
    }

    /// A fixed-density lower-eye curve avoids changing pigment density when a
    /// noisy landmark crosses the lid baseline. Input comes from the tracker,
    /// which already follows current translation/scale/roll without motion lag.
    static func underEyeCurve(_ eye: [CGPoint], right: CGPoint) -> [CGPoint] {
        guard eye.count >= 4 else { return [] }
        let up = CGPoint(x:-right.y,y:right.x)
        let sorted = eye.sorted { dot($0,right) < dot($1,right) }
        let a = sorted.first!, b = sorted.last!
        let width = dot(b,right)-dot(a,right)
        guard width > 0.000001 else { return [] }
        var depth: CGFloat = 0
        for p in eye {
            let t = (dot(p,right)-dot(a,right))/width
            guard t > 0.1, t < 0.9 else { continue }
            let baseline = dot(a,up)*(1-t)+dot(b,up)*t
            depth = max(depth,(baseline-dot(p,up))/(4*t*(1-t)))
        }
        // The skin fold remains visible during a blink; keep a shallow curve
        // instead of collapsing or hiding it with the lashes.
        depth = min(width*0.18,max(width*0.025,depth))
        return (0..<25).map { index in
            let t = CGFloat(index)/24
            let base = CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)
            return add(base,up,-depth*4*t*(1-t))
        }
    }

    /// One tapered ribbon per effect, offset along the local lid normal.
    /// Repeated overlapping gradient stamps used to build a bright/dark stripe.
    static func underEyeBand(_ curve: [CGPoint], distance: CGFloat, thickness: CGFloat,
                             range: ClosedRange<CGFloat> = 0...1) -> [CGPoint] {
        guard curve.count >= 3 else { return [] }
        var upper: [CGPoint] = [], lower: [CGPoint] = []
        for index in curve.indices {
            let t = CGFloat(index)/CGFloat(curve.count-1)
            let taper = pow(max(0,sin(t * .pi)),0.8)
            let sample = (range.lowerBound+(range.upperBound-range.lowerBound)*t)*CGFloat(curve.count-1)
            let k = min(curve.count-2,max(0,Int(sample))), mix = sample-CGFloat(k)
            let p = curve[k], q = curve[k+1]
            let point = CGPoint(x:p.x+(q.x-p.x)*mix,y:p.y+(q.y-p.y)*mix)
            let a = curve[max(0,k-1)], b = curve[min(curve.count-1,k+2)]
            let length = max(0.000001,hypot(b.x-a.x,b.y-a.y))
            let down = CGPoint(x:(b.y-a.y)/length,y:-(b.x-a.x)/length)
            let center = add(point,down,distance*(0.65+0.35*taper))
            upper.append(add(center,down,-thickness*0.5*taper))
            lower.append(add(center,down,thickness*0.5*taper))
        }
        return upper+lower.reversed()
    }

    struct Eyelids {
        var upper: [CGPoint]
        var lower: [CGPoint]
        var right: CGPoint
        var up: CGPoint
        var width: CGFloat
        var opening: CGFloat
    }

    /// Follow the two contour arcs between the corners. Classifying individual
    /// points above/below a baseline can change the lash curve's topology when
    /// a landmark crosses that line during a blink or head turn.
    static func eyelids(_ eye: [CGPoint], right: CGPoint) -> Eyelids? {
        guard eye.count >= 4,
              let first = eye.indices.min(by: { dot(eye[$0],right) < dot(eye[$1],right) }),
              let last = eye.indices.max(by: { dot(eye[$0],right) < dot(eye[$1],right) }), first != last else { return nil }
        let a = eye[first], b = eye[last], width = hypot(b.x-a.x,b.y-a.y)
        guard width > 0.000001 else { return nil }
        let axis = CGPoint(x:(b.x-a.x)/width,y:(b.y-a.y)/width)
        let up = CGPoint(x:-axis.y,y:axis.x)
        func arc(step: Int) -> [CGPoint] {
            var points = [a], index = first
            while index != last {
                index = (index+step+eye.count)%eye.count
                points.append(eye[index])
            }
            return points
        }
        let forward = arc(step:1), backward = arc(step:-1)
        let upper = dot(center(forward),up) >= dot(center(backward),up) ? forward : backward
        let lower = dot(center(forward),up) >= dot(center(backward),up) ? backward : forward
        let heights = eye.map { dot($0,up)-dot(a,up) }
        return Eyelids(upper:smooth(upper),lower:smooth(lower),right:axis,up:up,width:width,
                       opening:((heights.max() ?? 0)-(heights.min() ?? 0))/width)
    }

    struct LashHair {
        var root: CGPoint
        var tip: CGPoint
        var outline: [CGPoint]
        var opacity: CGFloat
    }

    /// Lid crown height changes when the upper lid rotates over the eyeball.
    /// Keep this independent of head pose, and smooth the estimate in the face
    /// tracker. This is deliberately bounded because six eye points cannot
    /// establish a full 3D eyeball or gaze direction.
    static func lidPitch(_ lids: Eyelids) -> CGFloat {
        guard let corner = lids.upper.first, lids.width > 0 else { return 0 }
        let crown = (lids.upper.map { dot($0,lids.up)-dot(corner,lids.up) }.max() ?? 0)/lids.width
        return min(0.65,max(-0.22,(0.24-crown)*7))
    }

    /// Project a lash growing out from the face and curling toward the brow.
    /// Positive Vision pitch is a downward nod: depth then projects downward,
    /// making tips foreshorten and eventually point below their roots. Roll is
    /// supplied by the current eyelid axes, rather than a fixed screen vertical.
    static func projectLash(side: CGFloat, rise: CGFloat, depth: CGFloat, pitch: CGFloat, yaw: CGFloat) -> CGPoint {
        let pitch = min(1.3,max(-1.3,pitch)), yaw = min(1.4,max(-1.4,yaw))
        let horizontal = side*cos(yaw)+depth*sin(yaw)
        let forward = depth*cos(yaw)-side*sin(yaw)
        return CGPoint(x:horizontal,y:rise*cos(pitch)-forward*sin(pitch))
    }

    /// Stable irregular fibers, each curled from its own lid root. A gradual
    /// inner/outer-corner taper avoids a comb edge or an inner-corner hook.
    static func lashHairs(_ lids: Eyelids, outerSign: CGFloat, amount: CGFloat,
                          open: CGFloat, brow: [CGPoint], lower: Bool = false,
                          rasterScale: CGFloat = 1, pitch: CGFloat = 0, yaw: CGFloat = 0,
                          lidPitch: CGFloat = 0, surface: DenseFaceMesh.LashSurface? = nil) -> [LashHair] {
        guard amount > 0, !lower || open > 0 else { return [] }
        let curve = lower ? lids.lower : lids.upper
        guard let first = curve.first, curve.count >= 3 else { return [] }
        let width = lids.width, right = lids.right, up = lids.up
        // Manga mapping: distinct long peaks with two finer companion fibers,
        // plus shorter fill in the gaps. A uniform row reads as a drawn comb.
        struct Fiber {
            var position: CGFloat
            var anchor: CGFloat
            var length: CGFloat
            var thickness: CGFloat
            var opacity: CGFloat
        }
        var fibers: [Fiber] = []
        let peaks: [CGFloat] = lower ? [0.20,0.34,0.49,0.64,0.78,0.89] : [0.16,0.31,0.47,0.63,0.78,0.90]
        for (index,anchor) in peaks.enumerated() {
            let length: CGFloat = lower ? [0.72,0.88,1.0,0.90,0.82,0.68][index] : [0.70,0.90,1.0,1.02,0.98,0.92][index]
            fibers.append(Fiber(position:anchor,anchor:anchor,length:length,thickness:1,opacity:1))
            if !lower {
                for offset: CGFloat in [-0.018,0.020] {
                    fibers.append(Fiber(position:anchor+offset,anchor:anchor,length:length*(offset < 0 ? 0.89 : 0.82),
                                        thickness:0.58,opacity:0.76))
                }
            } else if index%2 == 0 {
                fibers.append(Fiber(position:anchor+0.022,anchor:anchor,length:length*0.66,thickness:0.60,opacity:0.60))
            }
            if !lower, index+1 < peaks.count {
                let between = (anchor+peaks[index+1])*0.5
                fibers.append(Fiber(position:between,anchor:between,length:length*0.58,thickness:0.58,opacity:0.60))
            }
        }
        var hairs: [LashHair] = []
        for fiber in fibers {
            let outward = fiber.position
            let t = outerSign < 0 ? 1-outward : outward
            let target = dot(first,right)+width*t
            guard let k = (1..<curve.count).first(where:{ dot(curve[$0],right) >= target }) else { continue }
            let p = curve[k-1], q = curve[k]
            let mix = min(1,max(0,(target-dot(p,right))/max(0.000001,dot(q,right)-dot(p,right))))
            let root = CGPoint(x:p.x+(q.x-p.x)*mix,y:p.y+(q.y-p.y)*mix)
            let taper = pow(max(0,sin(outward * .pi)),0.35)
            // Upper extensions must project beyond the natural dark lash line.
            // Many tiny fibers just thickened that line without reading as lashes.
            let relativeLength: CGFloat = lower ? 0.115 : 0.39+outward*0.035
            let innerTaper = min(1,(outward+0.04)/0.30)
            let proposed = width*relativeLength*fiber.length*innerTaper*(0.75+amount*0.25)
            let clearance = brow.isEmpty ? width*0.5 : max(0,dot(center(brow),up)-dot(root,up))
            let length = min(proposed,lower ? width*0.12 : clearance*0.82)*(lower ? open : 0.9+0.1*open)
            guard length > width*0.002 else { continue }
            let direction: CGFloat = lower ? -1 : 1
            let fan = outerSign*(lower ? 0.20 : 0.04+outward*outward*0.78)
            let convergence = outerSign*(fiber.anchor-outward)*width*0.45
            let meshFrame = lower ? nil : surface?.frame(at:t)
            func project(_ side: CGFloat, _ rise: CGFloat, _ depth: CGFloat) -> CGPoint {
                if let frame = meshFrame {
                    // Mesh normals carry head pose, but the small mesh can
                    // leave them pointing up even when the lids meet. Rotate
                    // the follicle frame continuously through closure; do not
                    // apply the head pose twice or remove the upper lashes.
                    let normalUp = CGFloat(frame.normal.x)*up.x+CGFloat(frame.normal.y)*up.y
                    let tangentUp = CGFloat(frame.up.x)*up.x+CGFloat(frame.up.y)*up.y
                    let rotation = Float(max(0,1.05-atan2(-normalUp,tangentUp))*(1-open))
                    let growth = frame.normal*cos(rotation)-frame.up*sin(rotation)
                    let curl = frame.up*cos(rotation)+frame.normal*sin(rotation)
                    let delta = frame.right*Float(side*length+convergence*rise)
                        + curl*Float(rise*length) + growth*Float(depth*length)
                    return CGPoint(x:root.x+CGFloat(delta.x),y:root.y+CGFloat(delta.y))
                }
                let offset = projectLash(side:side*length+convergence*rise,rise:rise*direction*length,
                                        depth:depth*length*(lower ? 0.55 : 1),
                                        pitch:pitch+(lower ? 0 : lidPitch+max(0,1.05-pitch-lidPitch)*(1-open)),yaw:yaw)
                return add(add(root,right,offset.x),up,offset.y)
            }
            // At a lifted lid the fiber must leave the upper margin outward,
            // without dipping into the eye and then hooking back up. Lid/head
            // rotation alone turns this forward-growing curve downward.
            var c1 = project(fan*0.03,0.16,0.48)
            var c2 = project(fan*0.25,lower ? 0.72 : 0.40,1.02)
            var tip = project(fan,lower ? 1 : 0.72,lower ? 1.65 : 1.28)
            // Looking up increases apparent curl height; keep it clear of brows.
            let projectedHeight = max(dot(c1,up),dot(c2,up),dot(tip,up))-dot(root,up)
            if !lower, projectedHeight > clearance*0.65, projectedHeight > 0 {
                let fit = clearance*0.65/projectedHeight
                func fitted(_ point: CGPoint) -> CGPoint { CGPoint(x:root.x+(point.x-root.x)*fit,y:root.y+(point.y-root.y)*fit) }
                c1 = fitted(c1); c2 = fitted(c2); tip = fitted(tip)
            }
            var centerline: [CGPoint] = []
            for step in 0...12 {
                let u = CGFloat(step)/12, v = 1-u
                let w0 = v*v*v, w1 = 3*v*v*u, w2 = 3*v*u*u, w3 = u*u*u
                let x = w0*root.x+w1*c1.x+w2*c2.x+w3*tip.x
                let y = w0*root.y+w1*c1.y+w2*c2.y+w3*tip.y
                centerline.append(CGPoint(x:x,y:y))
            }
            var a: [CGPoint] = [], b: [CGPoint] = []
            for step in 0...12 {
                let v = 1-CGFloat(step)/12, point = centerline[step]
                // At live-preview sizes an eye is often only 20–30 px wide.
                // Pure proportional widths made these fibers <0.2 px wide,
                // then the tip gradient removed nearly all remaining coverage.
                // Scale the coverage floor with the render resolution. Otherwise
                // a 1920 px editor frame downsampled to 960 has half-width lashes
                // compared with the live 960 px processor used by regression clips.
                let rootHalfWidth = max((lower ? 0.17 : 0.25)*rasterScale,width*(lower ? 0.003 : 0.0055))*fiber.thickness
                let halfWidth = rootHalfWidth*pow(v,0.72)
                // A projected lash may be horizontal or downward. Its ribbon
                // must stay perpendicular to its own tangent, not the eye axis.
                let p = centerline[max(0,step-1)], q = centerline[min(12,step+1)]
                let tangentLength = hypot(q.x-p.x,q.y-p.y)
                let across = tangentLength > 0.000001 ? CGPoint(x:-(q.y-p.y)/tangentLength,y:(q.x-p.x)/tangentLength) : right
                a.append(add(point,across,-halfWidth)); b.append(add(point,across,halfWidth))
            }
            let opacity = taper*fiber.opacity*(lower ? 0.58 : 0.98)
            hairs.append(LashHair(root:root,tip:tip,outline:a+b.reversed(),opacity:opacity))
        }
        return hairs
    }

    /// Vision appends lateral tip/alar points to noseCrest. They are not a
    /// continuation of the bridge: stroking them makes a hook across the tip.
    static func noseBridge(_ crest: [CGPoint], right: CGPoint) -> [CGPoint] {
        guard let first = crest.first else { return [] }
        let up = CGPoint(x:-right.y,y:right.x)
        var bridge = [first]
        for point in crest.dropFirst() {
            let previous = bridge.last!
            let downward = dot(previous,up)-dot(point,up)
            let sideways = abs(dot(point,right)-dot(previous,right))
            if downward <= 0 || (bridge.count >= 2 && sideways > downward*1.25) { break }
            bridge.append(point)
        }
        return bridge.count >= 2 ? bridge : []
    }

    static func noseSideVisibility(projectedWidth: CGFloat, faceWidth: CGFloat) -> CGFloat {
        let t = min(1,max(0,(projectedWidth/max(1,faceWidth)-0.018)/0.055))
        return t*t*(3-2*t)
    }

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r,g,b,a])!
    }

    static func render(_ image: CIImage, face: FaceBeautyGeometry, current: FaceBeautyGeometry,
                       settings: FaceMakeupSettings, opacity: Double, unfiltered: CIImage? = nil,
                       handProtection: CIImage? = nil, cosmeticProtection: CIImage? = nil) -> CIImage {
        let bounds = image.extent
        let scale = min(1, 1920 / max(bounds.width, bounds.height))
        let size = CGSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))
        let extent = CGRect(origin: .zero, size: size)
        func pixels(_ p: [CGPoint]) -> [CGPoint] { p.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } }
        let features = face.features.map(pixels)
        let actual = current.features.map(pixels)
        guard features.count >= 7, features[0].count >= 3, features[1].count >= 3 else { return image }
        let fw = face.bounds.width * size.width, fh = face.bounds.height * size.height
        guard fw > 24, fh > 32 else { return image }
        let eyeA = center(features[0]), eyeB = center(features[1])
        let distance = hypot(eyeB.x-eyeA.x, eyeB.y-eyeA.y)
        guard distance > fw * 0.08 else { return image }
        let right = CGPoint(x: (eyeB.x-eyeA.x)/distance, y: (eyeB.y-eyeA.y)/distance)
        let up = CGPoint(x: -right.y, y: right.x)
        let strength = CGFloat(settings.amount * opacity)
        func context() -> CGContext? {
            CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        var result = image
        func composite(_ ctx: CGContext, blur: CGFloat = 0, excluding: [[CGPoint]] = [],
                       within: [CGPoint] = [], preserveTexture: CGFloat = 0, lipSupport: Bool = false) {
            guard let cg = ctx.makeImage() else { return }
            var overlay = CIImage(cgImage: cg)
            if blur > 0 { overlay = overlay.applyingGaussianBlur(sigma: blur) }
            if !excluding.isEmpty || !within.isEmpty, let mask = context() {
                mask.setFillColor(CGColor(gray: within.isEmpty ? 1 : 0, alpha: 1)); mask.fill(extent)
                if !within.isEmpty {
                    mask.setFillColor(CGColor(gray: 1, alpha: 1)); mask.addPath(path(within)); mask.fillPath()
                }
                if !within.isEmpty, let boundary = mask.makeImage() {
                    let feathered = CIImage(cgImage:boundary).applyingFilter("CIMorphologyMinimum", parameters:[kCIInputRadiusKey:fw*0.008])
                        .applyingGaussianBlur(sigma:fw*0.012).cropped(to:extent)
                    overlay = overlay.applyingFilter("CIBlendWithMask",parameters:[
                        kCIInputBackgroundImageKey:CIImage.empty(),kCIInputMaskImageKey:feathered])
                    mask.setFillColor(CGColor(gray:1,alpha:1)); mask.fill(extent)
                }
                mask.setFillColor(CGColor(gray: 0, alpha: 1))
                mask.setStrokeColor(CGColor(gray: 0, alpha: 1)); mask.setLineWidth(max(0.75,fw*0.003))
                for points in excluding { mask.addPath(path(points)); mask.drawPath(using: .fillStroke) }
                if let cgMask = mask.makeImage() {
                    overlay = overlay.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: CIImage(cgImage: cgMask)])
                }
            }
            overlay = overlay.cropped(to: extent)
                .transformed(by: CGAffineTransform(scaleX: bounds.width / size.width, y: bounds.height / size.height))
                .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
            if lipSupport, let support = lipSupportKernel {
                let mouth = center(actual[6])
                let refs = [center(actual[0]),center(actual[1])].map {
                    CGPoint(x:$0.x,y:$0.y*0.6+mouth.y*0.4)
                } + [CGPoint(x:(center(actual[0]).x+center(actual[1]).x)/2,
                             y:(center(actual[0]).y+center(actual[1]).y)/2)]
                let anchors = refs.map { CIVector(x:bounds.minX+$0.x*bounds.width/size.width,
                                                  y:bounds.minY+$0.y*bounds.height/size.height) }
                overlay = support.apply(extent:bounds,roiCallback:{ _,_ in bounds },
                    arguments:[unfiltered ?? image,overlay,anchors[0],anchors[1],anchors[2]]) ?? CIImage.empty()
            }
            if lipSupport, let handProtection {
                // Apply after lip-edge feathering so color cannot bleed back
                // onto the finger. Visible lip retains its full local pigment;
                // the final foreground restoration also protects skin/warping.
                overlay = overlay.applyingFilter("CIBlendWithMask",parameters:[
                    kCIInputBackgroundImageKey:CIImage.empty(),
                    kCIInputMaskImageKey:handProtection.applyingFilter("CIColorInvert")]).cropped(to:bounds)
            }
            if preserveTexture > 0, let pigment = pigmentKernel {
                result = pigment.apply(extent: bounds, arguments: [result, overlay, preserveTexture]) ?? result
            } else { result = overlay.composited(over: result).cropped(to: bounds) }
        }
        func diffuse(_ ctx: CGContext, at p: CGPoint, width: CGFloat, height: CGFloat, color c: CGColor) {
            guard width > 0, height > 0,
                  let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [c, c.copy(alpha: c.alpha*0.48)!, c.copy(alpha: 0)!] as CFArray,
                      locations: [0,0.45,1]) else { return }
            ctx.saveGState(); ctx.translateBy(x:p.x,y:p.y); ctx.rotate(by:atan2(right.y,right.x))
            ctx.scaleBy(x:width/2,y:height/2)
            ctx.drawRadialGradient(gradient,startCenter:.zero,startRadius:0,endCenter:.zero,endRadius:1,options:[])
            ctx.restoreGState()
        }
        func stroke(_ ctx: CGContext, points: [CGPoint], width: CGFloat, color c: CGColor) {
            guard points.count > 1 else { return }
            ctx.setStrokeColor(c); ctx.setLineWidth(width); ctx.setLineJoin(.round); ctx.setLineCap(.round)
            ctx.addPath(path(smooth(points), closed: false)); ctx.strokePath()
        }
        // A clipped soft pigment layer: never paint blush or contour into eyes/mouth.
        if let soft = context() {
            let jaw = pixels(face.contour)
            if jaw.count > 5 { soft.addPath(path(jaw)); soft.clip() }
            for i in 0..<2 {
                let eye = features[i]
                guard eye.count >= 4 else { continue }
                let eyeWidth = (eye.map { dot($0, right) }.max()! - eye.map { dot($0, right) }.min()!)
                guard eyeWidth > fw * 0.075 else { continue }
                let side: CGFloat = i == 0 ? -1 : 1
                let cheek = add(add(center(eye), up, -fh*0.19), right, side*fw*0.060)
                diffuse(soft, at: cheek, width: min(fw*0.60, eyeWidth*3.2), height: fh*0.29,
                        color: color(0.94,0.50,0.40,strength*CGFloat(settings.blush)*0.38))
            }
            composite(soft, blur: fw*0.018, excluding: [actual[0],actual[1],actual[6],features[0],features[1],features[6]],
                      within: jaw, preserveTexture: 0.65)
        }
        // Taper the bridge contour before the nose tip and account for projected
        // sidewall width. Symmetric full-length strokes cross the silhouette on
        // a turned face and used to draw a dark hook through the tip landmarks.
        if let contour = context(), settings.contour > 0 {
            let jaw = pixels(face.contour), nose = features[4]
            let bridge = noseBridge(features[5],right:right)
            if bridge.count >= 2, let tip = bridge.last, !nose.isEmpty {
                let curve = smooth(bridge)
                let minimum = nose.map { dot($0,right) }.min()!
                let maximum = nose.map { dot($0,right) }.max()!
                let tipX = dot(tip,right)
                func ribbon(offset: CGFloat, halfWidth: CGFloat, tint: CGColor) {
                    var a: [CGPoint] = [], b: [CGPoint] = []
                    // End above the tip; alpha also goes to zero at both ends.
                    let count = max(2,Int(CGFloat(curve.count)*0.90))
                    for index in 0..<count {
                        let t = CGFloat(index)/CGFloat(count-1)
                        let taper = pow(max(0,sin(t * .pi)),0.8)
                        let point = add(curve[index],right,offset*(0.65+0.35*t))
                        a.append(add(point,right,-halfWidth*taper))
                        b.append(add(point,right,halfWidth*taper))
                    }
                    contour.addPath(path(a+b.reversed()))
                    contour.setFillColor(tint); contour.fillPath()
                }
                for side: CGFloat in [-1,1] {
                    let available = max(0,side < 0 ? tipX-minimum : maximum-tipX)
                    let visibility = noseSideVisibility(projectedWidth:available,faceWidth:fw)
                    let offset = side*min(fw*0.041,available*0.35)
                    let opacity = strength*CGFloat(settings.contour)*0.44*visibility*(0.65+0.35*face.shapingVisibility)
                    ribbon(offset:offset,halfWidth:min(fw*0.018,available*0.24),tint:color(0.32,0.23,0.20,opacity))
                }
                ribbon(offset:0,halfWidth:fw*0.007,tint:color(1,0.86,0.73,strength*CGFloat(settings.contour)*0.12*face.shapingVisibility))
            }
            composite(contour,blur:fw*0.021,excluding:[actual[0],actual[1],actual[6],features[0],features[1],features[6]],
                      within:jaw,preserveTexture:0.30)
        }
        if let contour = context(), settings.contour > 0 {
            let jaw = pixels(face.contour)
            if let chin = jaw.min(by: { dot($0,up) < dot($1,up) }) {
                diffuse(contour, at: add(chin,up,fh*0.065), width: fw*0.48, height: fh*0.13,
                        color: color(0.32,0.23,0.20,strength*CGFloat(settings.contour)*0.24))
            }
            composite(contour, blur:fw*0.012, excluding:[actual[0],actual[1],actual[6],features[0],features[1],features[6]],
                      within:jaw, preserveTexture:0.15)
        }
        // Eyeshadow and aegyo-sal use eyelid curves, not a rectangle under the eye.
        // Clear the real eye interior after feathering through an exclusion mask.
        if let shadow = context(), let fold = context(), let eyeMask = context(), let detail = context() {
            eyeMask.setFillColor(CGColor(gray: 0, alpha: 1)); eyeMask.fill(extent)
            eyeMask.setFillColor(CGColor(gray: 1, alpha: 1))
            // Under-eye pigment is anchored to stabilized skin geometry, not
            // raw eyelid opening. Keep fixed sample count and opacity through
            // blinks; only perspective gradually fades the occluded far eye.
            for i in 0..<2 {
                for polygon in [features[i],actual[i]] {
                    eyeMask.addPath(path(polygon)); eyeMask.fillPath()
                }
                let eye = features[i].sorted { dot($0,right) < dot($1,right) }
                guard let first = eye.first, let last = eye.last else { continue }
                let width = hypot(last.x-first.x,last.y-first.y)
                guard width > 0 else { continue }
                let eyeAxis = CGPoint(x:(last.x-first.x)/width,y:(last.y-first.y)/width)
                let curve = underEyeCurve(eye,right:eyeAxis)
                let visibility = min(1,max(0,(width/fw-0.045)/0.09))
                let fade = visibility*visibility*(3-2*visibility)*(0.75+0.25*face.shapingVisibility)
                // Keep the fold central beneath the eye. Carrying it all the
                // way into the tear duct made a dark U-shaped double outline.
                let span: ClosedRange<CGFloat> = i == 0 ? 0.12...0.80 : 0.20...0.88
                func band(distance: CGFloat, thickness: CGFloat, tint: CGColor) {
                    fold.addPath(path(underEyeBand(curve,distance:width*distance,thickness:width*thickness,range:span)))
                    fold.setFillColor(tint); fold.fillPath()
                }
                band(distance:0.035,thickness:0.09,
                     tint:color(0.35,0.23,0.20,pow(strength,0.65)*CGFloat(settings.underEyeShadow)*0.20*fade))
                band(distance:0.135,thickness:0.070,
                     tint:color(0.46,0.31,0.25,strength*CGFloat(settings.aegyo)*0.22*fade))
                band(distance:0.065,thickness:0.080,
                     tint:color(1,0.86,0.72,strength*CGFloat(settings.aegyo)*0.20*fade))
            }
            let liveA = center(actual[0]), liveB = center(actual[1])
            let liveDistance = max(0.000001,hypot(liveB.x-liveA.x,liveB.y-liveA.y))
            let liveRight = CGPoint(x:(liveB.x-liveA.x)/liveDistance,y:(liveB.y-liveA.y)/liveDistance)
            for i in 0..<2 {
                // Current lids and each eye's own axis keep roots attached during
                // blinks and rolls; only the skin pigment uses tracked geometry.
                let eye = actual[i]
                guard let lids = eyelids(eye,right:liveRight) else { continue }
                let width = lids.width
                let visibility = min(1,max(0,(width/fw-0.045)/0.09))
                let fade = visibility*visibility*(3-2*visibility)
                guard fade > 0 else { continue }
                let opening = min(1,max(0,(lids.opening-0.09)/0.12))
                let open = opening*opening*(3-2*opening)
                let lidColor = color(0.64,0.38,0.30,strength*CGFloat(settings.eyeshadow)*0.28*fade)
                stroke(shadow,points:lids.upper.map { add($0,lids.up,width*0.08) },width:width*0.20,color:lidColor)
                eyeMask.addPath(path(eye)); eyeMask.fillPath()
                guard settings.lashes > 0 else { continue }
                for lower in [false,true] {
                    let opacity = pow(strength,0.65)*CGFloat(settings.lashes)*(lower ? open : 0.85+0.15*open)*fade
                    for hair in lashHairs(lids,outerSign:i == 0 ? -1 : 1,amount:CGFloat(settings.lashes),
                                          open:open,brow:actual[i+2],lower:lower,rasterScale:max(size.width,size.height)/960,
                                          pitch:CGFloat(face.pitch),yaw:CGFloat(face.lashYaw),lidPitch:face.lashLidPitch[i],
                                          surface:current.mesh?.lashSurface(eye:i,size:size)) {
                        detail.saveGState()
                        detail.addPath(path(hair.outline)); detail.clip()
                        let alpha = opacity*hair.opacity
                        if let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),
                            colors:[color(0.10,0.065,0.05,alpha),color(0.10,0.065,0.05,alpha*0.95),
                                    color(0.10,0.065,0.05,alpha*0.50)] as CFArray,locations:[0,0.72,1]) {
                            detail.drawLinearGradient(gradient,start:hair.root,end:hair.tip,
                                options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
                        }
                        detail.restoreGState()
                    }
                }
                // No solid eyeliner stroke: it made a hooked outline and a hard
                // comb-like base, especially around the inner corner in profile.
            }
            if let cg = shadow.makeImage(), let mask = eyeMask.makeImage() {
                let blurred = CIImage(cgImage: cg).applyingGaussianBlur(sigma: max(0.5,fw*0.007))
                let excluded = blurred.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey:
                        CIImage(cgImage: mask).applyingFilter("CIColorInvert")])
                // Keep CI processing on the GPU; composite the excluded shadow directly.
                let overlay = excluded.cropped(to: extent)
                    .transformed(by: CGAffineTransform(scaleX: bounds.width/size.width,y: bounds.height/size.height))
                    .transformed(by: CGAffineTransform(translationX: bounds.minX,y: bounds.minY))
                result = overlay.composited(over: result).cropped(to: bounds)
            }
            // The skin fold has its own feathering and retains source texture;
            // sharing a flat overlay with eyelid shadow made it look painted on.
            composite(fold,blur:max(0.65,fw*0.010),excluding:[actual[0],actual[1],features[0],features[1]],preserveTexture:0.30)
            composite(detail)
        }
        if let browLayer = context(), settings.brows > 0 {
            // Vision returns the brow perimeter, not a hair centerline. Tint its
            // interior and retain the source hairs; outlining it creates a hollow
            // stencil and per-segment hair counts pop as landmarks move.
            for i in 2...3 {
                let brow = features[i]
                guard brow.count >= 3 else { continue }
                browLayer.addPath(path(smooth(brow,closed:true)))
                browLayer.setFillColor(color(0.24,0.16,0.12,strength*CGFloat(settings.brows)*0.28))
                browLayer.fillPath()
            }
            composite(browLayer, blur:max(0.65,fw*0.006), preserveTexture:0.65)
        }
        if let lipLayer = context(), settings.lips > 0 {
            // Mouth motion is independent of the eye-based skin transport.
            // Current outer and inner boundaries must share the same frame.
            let lips = actual[6], c = center(lips)
            let inner = pixels(current.innerLips)
            // Do not tint an open mouth when the detector lacks its inner boundary.
            if inner.count >= 3 {
                let halfWidth = max(1, lips.map { abs(dot($0,right)-dot(c,right)) }.max() ?? 1)
                let expanded = lips.map { p -> CGPoint in
                    let x = abs(dot(p,right)-dot(c,right))/halfWidth
                    // Expand mainly at the center; leave mouth corners in place.
                    return add(p,up,(dot(p,up)-dot(c,up))*0.08*CGFloat(settings.lips)*(1-x*x))
                }
                lipLayer.addPath(path(smooth(expanded,closed:true)))
                lipLayer.setFillColor(color(0.78,0.38,0.32,strength*CGFloat(settings.lips)*0.46)); lipLayer.fillPath()
                // Feather first, then exclude the current and tracked mouth opening.
                // A padded cutout keeps pigment off teeth during speech.
                composite(lipLayer, blur:max(0.8,fw*0.012), excluding:[inner], preserveTexture:0.90, lipSupport:true)
            }
        }
        // Remove pigment/smoothing from hair and fabric before moving the face
        // silhouette. Restoring this broad mask after the warp undoes shaping.
        if let cosmeticProtection, let unfiltered {
            result = unfiltered.applyingFilter("CIBlendWithMask",parameters:[
                kCIInputBackgroundImageKey:result,kCIInputMaskImageKey:cosmeticProtection]).cropped(to:bounds)
        }
        if settings.shortening > 0 || settings.definition > 0, face.shapingVisibility > 0,
           let warp = shorteningKernel, face.contour.count >= 5 {
            // The center three contour landmarks identify the same chin region
            // on every frame; selecting a new minimum can jump between vertices.
            let jaw = pixels(face.contour), middle = jaw.count/2
            let chin = CGPoint(x:(jaw[middle-1].x+2*jaw[middle].x+jaw[middle+1].x)/4,
                               y:(jaw[middle-1].y+2*jaw[middle].y+jaw[middle+1].y)/4)
            let chinFull = CGPoint(x: bounds.minX+chin.x*bounds.width/size.width, y: bounds.minY+chin.y*bounds.height/size.height)
            let width = fw*bounds.width/size.width, height = fh*bounds.height/size.height
            let shift = height*0.028*CGFloat(settings.shortening)*strength*face.shapingVisibility
            let slim = width*0.045*CGFloat(settings.definition)*strength*face.shapingVisibility
            // Restoring raw hand pixels after a warp is too late: the warp can
            // already have copied a second finger/sleeve edge beside the mask.
            // Keep displacement zero around foreground boundaries, then blend
            // back to normal shaping over nearby skin without gating all makeup.
            let protection = shapingProtection(handProtection,extent:bounds,displacement:shift+slim)
            result = warp.apply(extent: bounds, roiCallback: { _,rect in rect.insetBy(dx:-(shift+slim),dy:-(shift+slim)) },
                                arguments: [result.clampedToExtent(),protection,CIVector(cgPoint:chinFull),
                                            CIVector(cgPoint:up),width,height,shift,slim]) ?? result
        }
        return result.cropped(to: bounds)
    }

    static func shapingProtection(_ mask: CIImage?, extent: CGRect, displacement: CGFloat) -> CIImage {
        guard let mask else { return CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:extent) }
        // Hand geometry is detected at 960 px. Build its broad safety margin at
        // that resolution rather than running morphology over a full 4K frame.
        let scale = min(1,960/max(extent.width,extent.height))
        let small = mask.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
            .transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let margin = max(2,displacement*1.5)*scale
        let solid = small.applyingFilter("CIMorphologyMaximum",parameters:[kCIInputRadiusKey:margin])
        return solid.applyingGaussianBlur(sigma:margin*0.65)
            .applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:solid])
            .transformed(by:CGAffineTransform(scaleX:1/scale,y:1/scale))
            .transformed(by:CGAffineTransform(translationX:extent.minX,y:extent.minY)).cropped(to:extent)
    }

    // Landmark detectors can hallucinate a mouth behind a sleeve. Lip pigment
    // requires supporting source chroma as well as geometry. Normalize by light
    // level; reject cool/neutral fabric without using an absolute skin brightness.
    private static let lipSupportKernel = CIKernel(source: """
    kernel vec4 visibleLip(sampler source, sampler overlay, vec2 a, vec2 b, vec2 c) {
        vec3 pixel = sample(source,samplerCoord(source)).rgb;
        vec3 ref = sample(source,samplerTransform(source,a)).rgb;
        vec3 rb = sample(source,samplerTransform(source,b)).rgb;
        vec3 rc = sample(source,samplerTransform(source,c)).rgb;
        vec3 luma = vec3(0.2126,0.7152,0.0722);
        if (dot(rb,luma)>dot(ref,luma)) ref=rb;
        if (dot(rc,luma)>dot(ref,luma)) ref=rc;
        float refLight = max(0.03,max(ref.r,max(ref.g,ref.b)));
        float skinRed = (ref.r-ref.g)/refLight;
        float light = max(0.03, max(pixel.r,max(pixel.g,pixel.b)));
        float redGreen = (pixel.r-pixel.g)/light;
        float redBlue = (pixel.r-pixel.b)/light;
        float support = smoothstep(0.015,0.12,redGreen) * smoothstep(0.0,0.07,redBlue);
        // Skin-toned fingers can escape a blurred hand outline. Require excess
        // lip redness relative to nearby skin; retain only a faint feather on
        // bare skin for overlining, without dropping the whole mouth effect.
        support *= 0.08+0.92*smoothstep(0.0,0.09,redGreen-skinRed);
        return sample(overlay,samplerCoord(overlay)) * support;
    }
    """)

    // Pigment inherits much of the source luminance instead of flattening skin
    // and lip texture to a solid RGB swatch. It does not brighten the whole face.
    private static let pigmentKernel = CIColorKernel(source: """
    kernel vec4 peachPigment(__sample source, __sample overlay, float texture) {
        if (overlay.a < 0.00001) return source;
        vec3 pigment = overlay.rgb / overlay.a;
        vec3 luma = vec3(0.2126, 0.7152, 0.0722);
        float ratio = clamp(dot(source.rgb, luma) / max(0.02, dot(pigment, luma)), 0.15, 3.0);
        vec3 tint = clamp(pigment * mix(1.0, ratio, texture), 0.0, 1.0);
        return vec4(mix(source.rgb, tint, overlay.a), source.a);
    }
    """)

    private static let shorteningKernel = CIKernel(source: """
    kernel vec4 shortenFace(sampler source, sampler protection, vec2 chin, vec2 up, float width, float height, float shift, float slim) {
        vec2 p = destCoord(); vec2 delta = p - chin;
        float x = dot(delta, vec2(up.y, -up.x)) / (width * 0.53);
        float y = dot(delta, up);
        float vertical = y > 0.0 ? 1.0 - smoothstep(0.0, height * 0.30, y)
                                  : 1.0 - smoothstep(0.0, height * 0.22, -y);
        float weight = (1.0 - smoothstep(0.0, 1.0, abs(x))) * vertical;
        float jaw = smoothstep(-height*0.08, height*0.12, y) * (1.0-smoothstep(height*0.18, height*0.48, y));
        float lateral = x * (1.0-smoothstep(0.65, 1.15, abs(x))) * jaw;
        vec2 offset = -up * shift * weight + vec2(up.y,-up.x) * slim * lateral;
        float blocked = max(sample(protection,samplerTransform(protection,p)).r,
                            sample(protection,samplerTransform(protection,p+offset)).r);
        return sample(source,samplerTransform(source,p+offset*(1.0-blocked)));
    }
    """)
}
