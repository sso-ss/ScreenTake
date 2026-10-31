// Shared by ScreenTake and the standalone Lash Lab.
// Pose growth frames and observed roots share the same geometry.
import AppKit
import Vision
import CoreImage
import simd

enum LashStyle: String, CaseIterable, Identifiable, Codable {
    case doll, cat, wispy
    var id: String { rawValue }
    var name: String { switch self { case .doll: return "돌아이"; case .cat: return "캣아이"; case .wispy: return "위스피" } }
    var subtitle: String { switch self { case .doll: return "중앙에 길이와 컬을 집중"; case .cat: return "바깥쪽으로 길게 흐르는 팬"; case .wispy: return "가늘고 가벼운 여러 겹의 결" } }
    var upperLengths: [CGFloat] { switch self {
        case .doll: return [0.62,0.88,1.16,1.10,0.84,0.62]
        case .cat: return [0.48,0.66,0.82,1.0,1.18,1.25]
        case .wispy: return [0.68,0.96,0.88,1.10,0.94,0.88]
    } }
    var lowerLengths: [CGFloat] { self == .doll ? [0.62,0.85,1.05,0.96,0.78,0.52] : [0.50,0.65,0.80,0.82,0.88,0.65] }
    var baseLength: CGFloat { self == .wispy ? 0.35 : 0.42 }
    var fanBase: CGFloat { self == .cat ? 0.05 : 0.04 }
    var fanSpread: CGFloat { self == .doll ? 0.38 : self == .cat ? 0.55 : 0.86 }
}
struct LashOptions: Codable {
    var style = LashStyle.doll
    var intensity: CGFloat = 0.90
    var length: CGFloat = 1
    var lowerLength: CGFloat = 1
    var makeup = MakeupOptions()
    var lower = true
    var showOriginal = false
    var showTracking = false
    var showFaceTracking = false
    var handOcclusion = true
}

enum LashGeometry {
    /// The upper fiber starts 30° above the outward skin normal. All 3D and
    /// fallback frames use this same basis; the first control has no extra curl.
    static let follicleTilt: CGFloat = .pi/6

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

    /// Preserve learned upper/lower point correspondence during a blink.
    static func fixedContour(upper:[CGPoint],lower:[CGPoint]) -> [CGPoint]? {
        guard upper.count==9,lower.count==9,(upper+lower).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        func sample(_ line:[CGPoint]) -> [CGPoint] {
            // Keep each learned landmark at the same sample index across
            // frames. Arc-length redistribution changes correspondence during
            // a blink; geometric upper/lower reclassification can swap lids.
            return (0...32).map { n in
                let i=min(7,n/4),t=CGFloat(n-i*4)/4,t2=t*t,t3=t2*t
                let a=line[max(0,i-1)],b=line[i],c=line[i+1],d=line[min(8,i+2)]
                func coordinate(_ a:CGFloat,_ b:CGFloat,_ c:CGFloat,_ d:CGFloat) -> CGFloat {
                    0.5*((2*b)+(-a+c)*t+(2*a-5*b+4*c-d)*t2+(-a+3*b-3*c+d)*t3)
                }
                return CGPoint(x:coordinate(a.x,b.x,c.x,d.x),y:coordinate(a.y,b.y,c.y,d.y))
            }
        }
        var top=sample(upper),bottom=sample(lower)
        guard let lids=eyelids(upper:top,lower:bottom) else { return nil }
        for i in 1..<32 {
            let gap=(top[i].x-bottom[i].x)*lids.up.x+(top[i].y-bottom[i].y)*lids.up.y
            if gap<0 {
                // Closed lids share their meeting point; never exchange labels.
                let midpoint=MakeupPaint.mix(top[i],bottom[i],0.5)
                top[i]=midpoint;bottom[i]=midpoint
            }
        }
        return top+bottom.dropFirst().dropLast().reversed()
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
    static func eyelids(_ eye: [CGPoint], right: CGPoint, cornerHints: [CGPoint] = []) -> Eyelids? {
        // Tracked contours have fixed corners at 0/32. Never rediscover their
        // extrema or spline them again: roll and closed lids can swap extrema.
        if eye.count == 64 {
            return eyelids(upper:Array(eye[0...32]),lower:[eye[0]] + Array(eye[33...].reversed()) + [eye[32]])
        }
        guard eye.count >= 4 else { return nil }
        func nearest(_ hint: CGPoint) -> Int? {
            eye.indices.min { hypot(eye[$0].x-hint.x,eye[$0].y-hint.y) < hypot(eye[$1].x-hint.x,eye[$1].y-hint.y) }
        }
        let hintedFirst = cornerHints.count == 2 ? nearest(cornerHints[0]) : nil
        let hintedLast = cornerHints.count == 2 ? nearest(cornerHints[1]) : nil
        let useHints = hintedFirst != nil && hintedLast != nil && hintedFirst != hintedLast
        guard let first = useHints ? hintedFirst : eye.indices.min(by: { dot(eye[$0],right) < dot(eye[$1],right) }),
              let last = useHints ? hintedLast : eye.indices.max(by: { dot(eye[$0],right) < dot(eye[$1],right) }), first != last else { return nil }
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

    static func eyelids(upper: [CGPoint], lower: [CGPoint]) -> Eyelids? {
        guard upper.count >= 2, lower.count >= 2 else { return nil }
        let a = upper[0], b = upper.last!, width = hypot(b.x-a.x,b.y-a.y)
        guard width > 0.001 else { return nil }
        let right = CGPoint(x:(b.x-a.x)/width,y:(b.y-a.y)/width)
        let up = CGPoint(x:-right.y,y:right.x)
        // Measure paired lid separation, not a polygon's bounding height.
        let opening = zip(upper,lower).map { max(0,dot($0,up)-dot($1,up))/width }.max() ?? 0
        return Eyelids(upper:upper,lower:lower,right:right,up:up,width:width,opening:opening)
    }

    struct LashHair {
        var root: CGPoint
        var rootControl: CGPoint
        var tip: CGPoint
        var outline: [CGPoint]
        var opacity: CGFloat
    }

    static func apertureProjection(_ lids: Eyelids,yaw: CGFloat,pitch: CGFloat,surface: LashSurface? = nil) -> CGFloat {
        if let surface {
            let frame = surface.frame(at:0.5)
            // Undo the follicle tilt to recover the face vertical.
            // Only its component perpendicular to the projected eye chord
            // changes the apparent gap between the two lid curves.
            let vertical = frame.curl*cos(Float(follicleTilt))+frame.growth*sin(Float(follicleTilt))
            let upScale = abs(CGFloat(vertical.x)*lids.up.x+CGFloat(vertical.y)*lids.up.y)
            return min(6,max(0.25,surface.widthRatio*upScale))
        }
        return min(3.5,max(0.25,cos(pitch)/max(0.3,cos(yaw))))
    }

    /// Project a lash growing out from the face and curling toward the brow.
    /// Positive Vision pitch is a downward nod: depth then projects downward,
    /// making tips foreshorten and eventually point below their roots. Roll is
    /// supplied by the current eyelid axes, rather than a fixed screen vertical.
    static func projectLash(side: CGFloat, rise: CGFloat, depth: CGFloat, pitch: CGFloat, yaw: CGFloat) -> CGPoint {
        let pitch = min(1.3,max(-1.3,pitch))
        // Pitch in the head's local frame, then yaw into camera space. Yawing
        // first mixed the left/right fan into height: one closed eye curled up
        // while the other curled down at the same nod angle.
        let vertical = rise*cos(pitch)-depth*sin(pitch)
        let forward = depth*cos(pitch)+rise*sin(pitch)
        return CGPoint(x:side*cos(yaw)+forward*sin(yaw),y:vertical)
    }

    /// Stable irregular fibers, each curled from its own lid root. A gradual
    /// inner/outer-corner taper avoids a comb edge or an inner-corner hook.
    static func lashHairs(_ lids: Eyelids, outerSign: CGFloat, amount: CGFloat,
                          open: CGFloat, brow: [CGPoint], lower: Bool = false,
                          rasterScale: CGFloat = 1, pitch: CGFloat = 0, yaw: CGFloat = 0,
                          style: LashStyle = .doll, lengthScale: CGFloat = 1,
                          surface: LashSurface? = nil, meshWeight: CGFloat = 0,
                          compactWispy: Bool = false) -> [LashHair] {
        guard amount > 0, !lower || open > 0 else { return [] }
        let curve = lower ? lids.lower : lids.upper
        guard curve.count >= 3 else { return [] }
        let width = lids.width, right = lids.right, up = lids.up
        // Reconstruct roll from the observed chord only when no camera-space
        // surface is supplied. Both routes use the same head-space eye plane.
        let eyeIndex = outerSign < 0 ? 0 : 1
        let unrolled = LashPose(yaw:yaw,pitch:pitch).frame(eye:eyeIndex)
        let roll = atan2(right.y,right.x)-atan2(CGFloat(unrolled.right.y),CGFloat(unrolled.right.x))
        let fallbackPose = LashPose(yaw:yaw,pitch:pitch,roll:roll)
        let widthMix = surface == nil ? CGFloat(0) : min(1,max(0,meshWeight))
        let surfaceMix = lower ? 0 : widthMix
        let fallbackRatio = min(6,1/max(1.0/6,hypot(CGFloat(unrolled.right.x),CGFloat(unrolled.right.y))))
        let physicalWidth = width*(fallbackRatio*(1-widthMix)+(surface?.widthRatio ?? 1)*widthMix)
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
            let length: CGFloat = lower ? style.lowerLengths[index] : style.upperLengths[index]
            fibers.append(Fiber(position:anchor,anchor:anchor,length:length,thickness:1,opacity:1))
            if !lower {
                for offset: CGFloat in (style == .wispy ? [-0.032,-0.016,0.020,0.034] : [-0.028,-0.013,0.014,0.030]) {
                    fibers.append(Fiber(position:anchor+offset,anchor:anchor,length:length*(abs(offset) < 0.02 ? 0.94 : 0.80),
                                        thickness:style == .wispy ? 0.42 : 0.58,opacity:style == .wispy ? 0.56 : 0.76))
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
            // Preserve the physical follicle parameter through projection. At
            // full profile a curved lid can double back along screen X.
            let position = min(1,max(0,t))*CGFloat(curve.count-1)
            let k = min(curve.count-1,Int(position)+1)
            let p = curve[k-1], q = curve[k]
            let mix = position-CGFloat(k-1)
            let root = CGPoint(x:p.x+(q.x-p.x)*mix,y:p.y+(q.y-p.y)*mix)
            let taper = pow(max(0,sin(outward * .pi)),0.35)
            // Upper extensions must project beyond the natural dark lash line.
            // Many tiny fibers just thickened that line without reading as lashes.
            let relativeLength: CGFloat = lower ? 0.115 : style.baseLength+outward*0.035
            let innerTaper = min(1,(outward+0.04)/0.30)
            let finishLength:CGFloat=compactWispy && !lower ? 0.72 : 1
            let proposed = physicalWidth*relativeLength*fiber.length*innerTaper*(0.75+amount*0.25)*lengthScale*finishLength
            let clearance = brow.isEmpty ? width*0.5 : max(0,dot(center(brow),up)-dot(root,up))
            let length = min(proposed,lower ? physicalWidth*0.12 : max(clearance*0.82,physicalWidth*0.20))*(lower ? 1 : 0.9+0.1*open)
            guard length > width*0.002 else { continue }
            let fan = outerSign*(lower ? 0.20 : style.fanBase+outward*outward*style.fanSpread)
            let convergence = outerSign*(fiber.anchor-outward)*width*0.45
            let fallbackFrame = fallbackPose.frame(eye:eyeIndex,at:t)
            let frame = surface?.frame(at: t)
            func project(_ side: CGFloat, _ rise: CGFloat, _ depth: CGFloat) -> CGPoint {
                if lower {
                    // Under lashes extend below the lower lid in its own frame.
                    // Pitch may shorten them, but must never turn their forward
                    // depth into an upward curl as it does for upper extensions.
                    let horizontal = (side*length+convergence*rise)*cos(yaw)+depth*length*0.55*sin(yaw)
                    let downward = -rise*length*max(0.35,cos(pitch))
                    return add(add(root,right,horizontal),up,downward)
                }
                func mapped(_ basis: LashSurface.Frame) -> CGPoint {
                    let normalUp = CGFloat(basis.growth.x)*up.x+CGFloat(basis.growth.y)*up.y
                    let curlUp = CGFloat(basis.curl.x)*up.x+CGFloat(basis.curl.y)*up.y
                    let rotation = Float(max(0,1.05-atan2(-normalUp,curlUp))*(1-open))
                    let growth = basis.growth*cos(rotation)-basis.curl*sin(rotation)
                    let curl = basis.curl*cos(rotation)+basis.growth*sin(rotation)
                    let delta = basis.right*Float(side*length+convergence*rise)
                        + curl*Float(rise*length) + growth*Float(depth*length)
                    return CGPoint(x:root.x+CGFloat(delta.x),y:root.y+CGFloat(delta.y))
                }
                let fallback = mapped(fallbackFrame)
                guard let frame, surfaceMix > 0 else { return fallback }
                let mapped = mapped(frame)
                return CGPoint(x: fallback.x+(mapped.x-fallback.x)*surfaceMix,y: fallback.y+(mapped.y-fallback.y)*surfaceMix)
            }
            // At a lifted lid the fiber must leave the upper margin outward,
            // without dipping into the eye and then hooking back up. Lid/head
            // rotation alone turns this forward-growing curve downward.
            // Lower fibers leave the margin forward, then curl down. Keeping
            // depth almost constant at the tip gives a rounded profile rather
            // than a straight diagonal, without turning the tip upward.
            var c1 = project(lower ? fan*0.25 : 0,lower ? 0.12 : 0,lower ? 0.55 : 0.43)
            // Curl controls are expressed in the 30° follicle frame. Retain
            // the existing style silhouettes while setting the root angle.
            var c2 = project(fan*(lower ? 0.95 : 0.25),lower ? 0.55 : 0.0720737,lower ? 1.40 : 0.9006729)
            // Cat shape comes from the outer length progression and a modest
            // side sweep. Its tip still curls toward the brow; a large fan with
            // a flatter curl made the whole front view look peeled outward.
            var tip = project(fan,lower ? 1 : (style == .cat ? 0.65 : 0.5872733),lower ? 1.50 : (style == .cat ? 1.2100771 : 1.2729130))
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
                let rootHalfWidth = max((lower ? 0.22 : 0.25)*rasterScale,width*(lower ? 0.006 : (style == .wispy ? 0.0065 : 0.011)))*fiber.thickness
                let halfWidth = rootHalfWidth*pow(v,0.72)*(compactWispy && !lower ? 1.50 : 1)
                // A projected lash may be horizontal or downward. Its ribbon
                // must stay perpendicular to its own tangent, not the eye axis.
                let p = centerline[max(0,step-1)], q = centerline[min(12,step+1)]
                let tangentLength = hypot(q.x-p.x,q.y-p.y)
                let across = tangentLength > 0.000001 ? CGPoint(x:-(q.y-p.y)/tangentLength,y:(q.x-p.x)/tangentLength) : right
                a.append(add(point,across,-halfWidth)); b.append(add(point,across,halfWidth))
            }
            // Back-facing follicles fade continuously; do not draw extensions
            // through a far eyelid just because a 2D landmark was detected.
            let facing = frame.map { CGFloat(-$0.growth.z) } ?? 1
            let coverage = min(1,max(0,(facing+0.30)/0.40))
            let visibility = 1-surfaceMix+surfaceMix*coverage*coverage*(3-2*coverage)
            let opacity = min(1,visibility*taper*fiber.opacity*(lower ? 0.80 : 0.98)*(style == .wispy ? 0.82 : 1)*(compactWispy && !lower ? 1.28 : 1))
            hairs.append(LashHair(root:root,rootControl:c1,tip:tip,outline:a+b.reversed(),opacity:opacity))
        }
        return hairs
    }

}
