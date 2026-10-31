import CoreGraphics
import simd

/// Shared pose for the angle rig and captured faces. Angles are radians in an
/// unmirrored, y-up image: positive pitch looks down, positive yaw turns toward
/// image-right, and positive roll turns counterclockwise. Head-space +z points
/// out of the face; camera-space +z points away from the camera.
struct LashPose {
    private static let eyeWidth = 260.0
    private static let depthBulge = 22.0
    private static let eyeSlant = 0.20
    struct Preset: Identifiable {
        let name: String
        let yaw: CGFloat
        let pitch: CGFloat
        var id: String { name }
    }
    static let presets: [Preset] = [
        .init(name:"정면",yaw:0,pitch:0),
        .init(name:"왼쪽 45°",yaw:-45,pitch:0),
        .init(name:"오른쪽 45°",yaw:45,pitch:0),
        .init(name:"아래 45°",yaw:0,pitch:45),
        .init(name:"왼쪽·아래 45°",yaw:-45,pitch:45),
        .init(name:"오른쪽·아래 45°",yaw:45,pitch:45),
        .init(name:"왼쪽 90°",yaw:-90,pitch:0),
        .init(name:"오른쪽 90°",yaw:90,pitch:0),
        .init(name:"왼쪽 90°·아래 45°",yaw:-90,pitch:45),
        .init(name:"오른쪽 90°·아래 45°",yaw:90,pitch:45)
    ]
    var yaw: CGFloat
    var pitch: CGFloat
    var roll: CGFloat = 0

    func rotated(_ point: SIMD3<Double>) -> SIMD3<Double> {
        let cy = cos(Double(yaw)), sy = sin(Double(yaw))
        let cp = cos(Double(pitch)), sp = sin(Double(pitch))
        let y = point.y*cp-point.z*sp, z = point.z*cp+point.y*sp
        let x = point.x*cy+z*sy, depth = -point.x*sy+z*cy
        let cr = cos(Double(roll)), sr = sin(Double(roll))
        return SIMD3(x*cr-y*sr,x*sr+y*cr,depth)
    }
    func project(_ point: SIMD3<Double>) -> CGPoint {
        let p = rotated(point), scale = 1500/(1500-p.z)
        return CGPoint(x:500+p.x*scale,y:260+p.y*scale)
    }
    private func cameraVector(_ vector: SIMD3<Double>) -> SIMD3<Float> {
        let p = rotated(vector)
        return SIMD3(Float(p.x),Float(p.y),Float(-p.z))
    }
    /// Eye indices remain image-left (0), image-right (1) before preview mirror.
    /// The local normal follows the same depth curve as the rig's eyelid roots.
    /// Captured faces share this curved field; their lids determine the roots
    /// and physical eye width. The center remains the aperture/roll reference.
    func frame(eye index: Int, at t: CGFloat = 0.5) -> LashSurface.Frame {
        let side: Double = index == 0 ? -1 : 1
        let position = Double(min(1,max(0,t)))
        let slope = Self.depthBulge * .pi / Self.eyeWidth * cos(position * .pi)-side*Self.eyeSlant
        let normal = simd_normalize(SIMD3<Double>(-slope,0,1))
        let right = simd_normalize(SIMD3<Double>(1,0,slope))
        let up = SIMD3<Double>(0,1,0), tilt = Double(LashGeometry.follicleTilt)
        return LashSurface.Frame(growth:cameraVector(normal*cos(tilt)+up*sin(tilt)),
            curl:cameraVector(up*cos(tilt)-normal*sin(tilt)),right:cameraVector(right))
    }
    func surface(eye index: Int, widthRatio: CGFloat) -> LashSurface {
        LashSurface(frames:(0...32).map { frame(eye:index,at:CGFloat($0)/32) },widthRatio:widthRatio)
    }
    struct Eye {
        let lids: LashGeometry.Eyelids
        let surface: LashSurface
        let iris: [CGPoint]
        let pupil: [CGPoint]
        let brow: [CGPoint]
        let side: CGFloat
        let depth: Double
        let visibility: CGFloat
    }
    func eye(_ index: Int, open: CGFloat) -> Eye? {
        let side: Double = index == 0 ? -1 : 1
        let center = side*200, width = Self.eyeWidth
        func world(_ t: Double,_ y: Double) -> SIMD3<Double> {
            let x = (t-0.5)*width
            return SIMD3(center+x,45+y,25+Self.depthBulge*sin(t * .pi)-side*x*Self.eyeSlant)
        }
        let normal = simd_normalize(SIMD3<Double>(side*Self.eyeSlant,0,1))
        let centerPoint = rotated(world(0.5,0))
        let view = simd_normalize(SIMD3<Double>(0,0,1500)-centerPoint)
        let facing = simd_dot(rotated(normal),view)
        // Use the skin plane before follicle tilt. Its far side disappears
        // before the projected corner chord reverses; the near eye remains
        // visible in a full profile because its local plane faces outward.
        guard facing.isFinite, facing > 0.005 else { return nil }
        let coverage = min(1,max(0,facing/0.20))
        let visibility = CGFloat(coverage*coverage*(3-2*coverage))
        let upper = (0...32).map { n in
            let t = Double(n)/32
            return project(world(t,55*sin(t * .pi)*Double(open)))
        }
        let lower = (0...32).map { n in
            let t = Double(n)/32
            return project(world(t,-38*sin(t * .pi)*Double(open)))
        }
        guard let lids = LashGeometry.eyelids(upper:upper,lower:lower),
              lids.width.isFinite, lids.width > 1,
              (upper+lower).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let scale = 1500/(1500-centerPoint.z)
        let physicalWidth = width*sqrt(1+Self.eyeSlant*Self.eyeSlant)*scale
        let surface = surface(eye:index,widthRatio:CGFloat(physicalWidth)/lids.width)
        func ellipse(_ radius: Double) -> [CGPoint] {
            (0..<64).map { n in
                let angle = Double(n)/64*2 * .pi
                return project(SIMD3(center+radius*cos(angle),45+radius*sin(angle),57-side*radius*cos(angle)*Self.eyeSlant))
            }
        }
        let brow = (0...16).map { n in
            let t = Double(n)/16
            return project(world(t,108+16*sin(t * .pi)))
        }
        return Eye(lids:lids,surface:surface,iris:ellipse(43),pupil:ellipse(21),brow:brow,
            side:CGFloat(side),depth:centerPoint.z,visibility:visibility)
    }
}
