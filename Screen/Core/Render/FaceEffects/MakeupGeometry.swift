import Foundation
import CoreGraphics

/// A mouth frame uses a single observed contour. Mesh mouth corners must not
/// supply the scale or angle for independently observed Vision lip boundaries.
struct MakeupLipFrame {
    let center: CGPoint
    let right: CGPoint
    let up: CGPoint
    let width: CGFloat
    let leftCorner: CGPoint
    let rightCorner: CGPoint

    init?(outer: [CGPoint], axis: CGPoint) {
        guard outer.count >= 3, outer.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              axis.x.isFinite, axis.y.isFinite else { return nil }
        let axisLength = hypot(axis.x,axis.y)
        guard axisLength > 0.0001 else { return nil }
        let hint = CGPoint(x:axis.x/axisLength,y:axis.y/axisLength)
        let projections = outer.map { $0.x*hint.x+$0.y*hint.y }
        guard let left = projections.min(),let right = projections.max(),right-left > 1 else { return nil }
        let tolerance = (right-left)*0.018
        func corner(_ target: CGFloat) -> CGPoint {
            let candidates = zip(outer,projections).filter { abs($0.1-target) <= tolerance }.map { $0.0 }
            return CGPoint(x:candidates.map(\.x).reduce(0,+)/CGFloat(candidates.count),
                           y:candidates.map(\.y).reduce(0,+)/CGFloat(candidates.count))
        }
        leftCorner = corner(left); rightCorner = corner(right)
        width = hypot(rightCorner.x-leftCorner.x,rightCorner.y-leftCorner.y)
        guard width > 1, width.isFinite else { return nil }
        self.right = CGPoint(x:(rightCorner.x-leftCorner.x)/width,y:(rightCorner.y-leftCorner.y)/width)
        up = CGPoint(x:-self.right.y,y:self.right.x)
        center = CGPoint(x:(leftCorner.x+rightCorner.x)/2,y:(leftCorner.y+rightCorner.y)/2)
        let local = outer.map { point -> CGPoint in
            let x=point.x-center.x,y=point.y-center.y
            return CGPoint(x:x*self.right.x+y*self.right.y,y:x*up.x+y*up.y)
        }
        let height = local.map(\.y).max()!-local.map(\.y).min()!
        var area: CGFloat = 0
        for index in outer.indices {
            let a=outer[index],b=outer[(index+1)%outer.count]
            area += a.x*b.y-a.y*b.x
        }
        guard height > width*0.015,height < width*1.65,abs(area)/2 > width*width*0.003 else { return nil }
    }
    func local(_ point: CGPoint) -> CGPoint {
        let x=point.x-center.x,y=point.y-center.y
        return CGPoint(x:x*right.x+y*right.y,y:x*up.x+y*up.y)
    }
    func carrying(_ point: CGPoint, from old: Self) -> CGPoint {
        let local=old.local(point),scale=width/old.width
        return CGPoint(x:center.x+scale*(local.x*right.x+local.y*up.x),
                       y:center.y+scale*(local.x*right.y+local.y*up.y))
    }
    /// Near a closed mouth, inner points may collapse to a line. That remains a
    /// valid current opening, while a hole outside the observed lip is rejected.
    func containsOpening(_ inner: [CGPoint],outer: [CGPoint]) -> Bool {
        guard inner.count >= 4,inner.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let path=CGMutablePath();path.addLines(between:outer);path.closeSubpath()
        let tolerance=width*0.025
        func nearBoundary(_ point: CGPoint) -> Bool {
            for index in outer.indices {
                let a=outer[index],b=outer[(index+1)%outer.count]
                let dx=b.x-a.x,dy=b.y-a.y,denominator=dx*dx+dy*dy
                let t=denominator > 0 ? min(1,max(0,((point.x-a.x)*dx+(point.y-a.y)*dy)/denominator)) : 0
                if hypot(point.x-a.x-dx*t,point.y-a.y-dy*t) <= tolerance { return true }
            }
            return false
        }
        return inner.allSatisfy { path.contains($0) || nearBoundary($0) }
    }
}

/// Fixed-topology, pixel-space anchors from the local 468-point model. Vision's
/// independent lip loops keep lipstick out of an opening mouth even when the
/// smaller mesh model misses that expression.
struct MakeupGeometry {
    var points: [CGPoint]
    /// Relative camera depth in pixels; smaller values are closer.
    var depths: [CGFloat] = []
    var outerLips: [CGPoint] = []
    var innerLips: [CGPoint] = []
    /// Independent visible jaw/cheek silhouette; the low-resolution mesh can
    /// place its canonical jaw inside the cheek during a profile turn.
    var faceContour: [CGPoint] = []
    /// Surface coverage is different from an independently observed skin edge.
    var usesProjectedMeshSurface = false
    var opacity: CGFloat = 1
    var lipsReliable = true

    static let outerLipIndices = [61,146,91,181,84,17,314,405,321,375,291,409,270,269,267,0,37,39,40,185]
    static let innerLipIndices = [78,95,88,178,87,14,317,402,318,324,308,415,310,311,312,13,82,81,80,191]
    static let faceIndices = [10,338,297,332,284,251,389,356,454,323,361,288,397,365,379,378,400,377,152,148,176,149,150,136,172,58,132,93,234,127,162,21,54,103,67,109]

    func polygon(_ indices: [Int]) -> [CGPoint] {
        guard indices.allSatisfy({ points.indices.contains($0) }) else { return [] }
        return indices.map { points[$0] }
    }
    init?(mesh: LashMesh, size: CGSize, outerLips: [CGPoint], innerLips: [CGPoint], faceContour: [CGPoint] = []) {
        guard mesh.points.count == 468, size.width > 0, size.height > 0 else { return nil }
        points = mesh.points.map { CGPoint(x:CGFloat($0.x)*size.width,y:CGFloat($0.y)*size.height) }
        depths = mesh.points.map { CGFloat($0.z)*size.width }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        self.outerLips = outerLips
        self.innerLips = innerLips
        self.faceContour = faceContour.filter { $0.x.isFinite && $0.y.isFinite }
        let axis = CGPoint(x:points[263].x-points[33].x,y:points[263].y-points[33].y)
        if outerLips.count >= 6,let frame=MakeupLipFrame(outer:outerLips,axis:axis) {
            lipsReliable = frame.containsOpening(innerLips,outer:outerLips)
        } else { lipsReliable = false }
    }
    /// Fixture initializer also permits deterministic geometry/render checks.
    init(points: [CGPoint], outerLips: [CGPoint] = [], innerLips: [CGPoint] = [], opacity: CGFloat = 1, faceContour: [CGPoint] = []) {
        self.points = points; self.outerLips = outerLips; self.innerLips = innerLips; self.opacity = opacity
        self.faceContour = faceContour
    }
    func transformed(_ transform: CGAffineTransform) -> Self {
        var result = self
        result.points = points.map { $0.applying(transform) }
        result.outerLips = outerLips.map { $0.applying(transform) }
        result.innerLips = innerLips.map { $0.applying(transform) }
        result.faceContour = faceContour.map { $0.applying(transform) }
        return result
    }
    var skinOutline: [CGPoint] {
        guard points.count == 468 else { return [] }
        guard faceContour.count >= 7,faceContour.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return polygon(Self.faceIndices)
        }
        let forehead = polygon([21,54,103,67,109,10,338,297,332,284,251])
        func distance(_ a:CGPoint,_ b:CGPoint) -> CGFloat { hypot(a.x-b.x,a.y-b.y) }
        let forward = distance(forehead.last!,faceContour.first!)+distance(forehead.first!,faceContour.last!)
        let reverse = distance(forehead.last!,faceContour.last!)+distance(forehead.first!,faceContour.first!)
        return forehead + (forward <= reverse ? faceContour : Array(faceContour.reversed()))
    }
    var skinCoveragePath: CGPath {
        guard usesProjectedMeshSurface,points.count==468,!LashMesh.triangles.isEmpty else {
            return MakeupPaint.path(skinOutline,smooth:false)
        }
        let path=CGMutablePath()
        // Union of projected triangles, with consistent winding. This covers
        // the nose outside the fixed oval during a turn, without treating
        // an occluded cheek edge as an outer mask boundary.
        for triangle in LashMesh.triangles {
            let a=points[triangle[0]],b=points[triangle[1]],c=points[triangle[2]]
            let area=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
            guard area.isFinite,abs(area)>0.00001 else { continue }
            path.addLines(between:area>0 ? [a,b,c] : [a,c,b]);path.closeSubpath()
        }
        return path
    }
    private static func center(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        return CGPoint(x:points.map(\.x).reduce(0,+)/CGFloat(points.count),y:points.map(\.y).reduce(0,+)/CGFloat(points.count))
    }
    /// Fit head motion from stable anchors, excluding expressive lids and lips.
    /// Local smoothing then damps noise without dragging a mask behind the face.
    func motion(from previous: Self) -> CGAffineTransform? {
        let indices = [1,168,10,33,263]
        guard points.count == 468, previous.points.count == 468 else { return nil }
        let a = previous.polygon(indices), b = polygon(indices)
        let oldCenter = Self.center(a), newCenter = Self.center(b)
        var denominator: CGFloat = 0, real: CGFloat = 0, imaginary: CGFloat = 0
        for (p,q) in zip(a,b) {
            let x = p.x-oldCenter.x, y = p.y-oldCenter.y
            let u = q.x-newCenter.x, v = q.y-newCenter.y
            denominator += x*x+y*y; real += x*u+y*v; imaginary += x*v-y*u
        }
        guard denominator > 1 else { return nil }
        real /= denominator; imaginary /= denominator
        let scale = hypot(real,imaginary)
        guard scale > 0.65, scale < 1.5 else { return nil }
        return CGAffineTransform(a:real,b:imaginary,c:-imaginary,d:real,
            tx:newCenter.x-real*oldCenter.x+imaginary*oldCenter.y,
            ty:newCenter.y-imaginary*oldCenter.x-real*oldCenter.y)
    }
    func blended(from previous: Self, amount: CGFloat, poseChange: CGFloat) -> Self {
        guard let motion = motion(from:previous) else { return self }
        let carried = previous.transformed(motion)
        let alpha = min(1,max(amount,poseChange > 0.10 ? 0.82 : 0))
        func mix(_ a: [CGPoint],_ b: [CGPoint],_ weight: CGFloat) -> [CGPoint] {
            guard a.count == b.count else { return b }
            return zip(a,b).map { CGPoint(x:$0.x+($1.x-$0.x)*weight,y:$0.y+($1.y-$0.y)*weight) }
        }
        var result = self
        result.points = mix(carried.points,points,alpha)
        // Transport the old outer contour in the mouth's own observed frame.
        // Talking can move the mouth without changing the face or its opening.
        // Keep the current inner hole exact so smoothing cannot paint new teeth.
        result.innerLips = innerLips
        let currentAxis = CGPoint(x:points[263].x-points[33].x,y:points[263].y-points[33].y)
        let oldAxis = CGPoint(x:previous.points[263].x-previous.points[33].x,y:previous.points[263].y-previous.points[33].y)
        if let oldFrame=MakeupLipFrame(outer:previous.outerLips,axis:oldAxis),
           let frame=MakeupLipFrame(outer:outerLips,axis:currentAxis) {
            let oldOuter=previous.outerLips.map { frame.carrying($0,from:oldFrame) }
            let oldInner=previous.innerLips.map { frame.carrying($0,from:oldFrame) }
            func extent(_ polygon: [CGPoint]) -> CGSize {
                guard !polygon.isEmpty else { return .zero }
                let local=polygon.map(frame.local)
                return CGSize(width:local.map(\.x).max()!-local.map(\.x).min()!,
                              height:local.map(\.y).max()!-local.map(\.y).min()!)
            }
            let oldOpening=extent(oldInner),newOpening=extent(innerLips)
            let expression = abs(newOpening.height-oldOpening.height) > frame.width*0.025
                || abs(newOpening.width-oldOpening.width) > frame.width*0.035
            let residual = oldOuter.count == outerLips.count
                ? zip(oldOuter,outerLips).map { hypot($0.x-$1.x,$0.y-$1.y) }.max() ?? 0 : frame.width
            let lipAlpha: CGFloat = expression || residual > max(1,frame.width*0.035) ? 1 : max(0.60,alpha)
            result.outerLips = mix(oldOuter,outerLips,lipAlpha)
            result.lipsReliable = lipsReliable && frame.containsOpening(innerLips,outer:result.outerLips)
        } else {
            result.outerLips = outerLips
            result.lipsReliable = false
        }
        // Eye makeup uses current tracked lids separately. Keep mesh lid points
        // responsive too so a blink never leaves shadow inside the eyeball.
        let responsive = Set(LashMesh.eyes.flatMap { $0 } + Self.outerLipIndices + Self.innerLipIndices)
        for index in responsive { result.points[index] = points[index] }
        return result
    }
}

/// Makeup is more conspicuous than individual hairs when stale. It can bridge
/// a single mesh failure only briefly and only while the observed pose is calm.
struct MakeupTracker {
    private var previous: MakeupGeometry?
    private var previousBounds: CGRect = .zero
    private var previousPose: (CGFloat,CGFloat,CGFloat) = (0,0,0)
    private var lastSeen: Double?
    private var lastTime: Double?

    mutating func update(_ detected: MakeupGeometry?, face: PhotoGeometry?, at time: Double) -> MakeupGeometry? {
        guard time.isFinite else { self = Self(); return nil }
        if let lastTime, time < lastTime || time-lastTime > 0.25 { self = Self() }
        let dt = min(0.1,max(0,time-(lastTime ?? time-1.0/30)))
        lastTime = time
        guard let face else { self.previous = nil; lastSeen = nil; return nil }
        let rollDelta = atan2(sin(face.roll-previousPose.2),cos(face.roll-previousPose.2))
        let poseChange = max(abs(face.yaw-previousPose.0),max(abs(face.pitch-previousPose.1),abs(rollDelta)))
        defer { previousBounds = face.bounds; previousPose = (face.yaw,face.pitch,face.roll) }
        if var detected {
            if let previous, time-(lastSeen ?? time) < 0.12 {
                detected = detected.blended(from:previous,amount:CGFloat(1-exp(-dt/0.055)),poseChange:poseChange)
                detected.opacity = min(1,previous.opacity+CGFloat(dt/0.10))
            } else { detected.opacity = 0.65 }
            previous = detected; lastSeen = time
            return detected
        }
        guard var held = previous, let lastSeen, time-lastSeen <= 0.08, poseChange < 0.10,
              previousBounds.width > 1, face.bounds.width > 1 else {
            previous = nil; return nil
        }
        let scale = face.bounds.width/previousBounds.width
        guard scale > 0.85, scale < 1.18 else { previous = nil; return nil }
        let c = cos(rollDelta)*scale, s = sin(rollDelta)*scale
        let a = CGPoint(x:previousBounds.midX,y:previousBounds.midY), b = CGPoint(x:face.bounds.midX,y:face.bounds.midY)
        held = held.transformed(CGAffineTransform(a:c,b:s,c:-s,d:c,tx:b.x-c*a.x+s*a.y,ty:b.y-s*a.x-c*a.y))
        // A mesh-only gap has no independent current mouth contour. Broad
        // shading may bridge briefly, but lipstick must not cover new teeth.
        held.lipsReliable = false
        held.opacity = max(0,held.opacity-CGFloat(dt/0.10))
        previous = held
        return held
    }
}
