import CoreImage
import CoreGraphics
import Foundation

/// The same smooth displacement maps both camera pixels and tracked features.
/// Each region fades to identity; the inverse is solved on the GPU per pixel.
enum MakeupFaceShape {
    struct Region {
        var center: CGPoint
        var scaleX: CGFloat
        var scaleY: CGFloat
        var radiusX: CGFloat
        var radiusY: CGFloat
        var tilt: CGFloat = 0
    }
    struct Warp {
        var axis: CGPoint
        var regions: [Region]
        func offset(_ p:CGPoint,_ r:Region) -> CGPoint {
            let dx=p.x-r.center.x,dy=p.y-r.center.y
            let x=dx*axis.x+dy*axis.y,y=dy*axis.x-dx*axis.y
            let radius=hypot(x/r.radiusX,y/r.radiusY)
            let weight=1-MakeupPaint.smoothstep(0.55,1,radius)
            let ox=x*(r.scaleX-1)*weight,oy=(y*(r.scaleY-1)+x*r.tilt)*weight
            return CGPoint(x:ox*axis.x-oy*axis.y,y:ox*axis.y+oy*axis.x)
        }
        func destination(_ source:CGPoint) -> CGPoint {
            regions.reduce(source) { p,r in
                let d=offset(p,r);return CGPoint(x:p.x+d.x,y:p.y+d.y)
            }
        }
        func source(_ destination:CGPoint) -> CGPoint {
            regions.reversed().reduce(destination) { p,r in
                var q=p
                for _ in 0..<8 { let d=offset(q,r);q=CGPoint(x:p.x-d.x,y:p.y-d.y) }
                return q
            }
        }
        func geometry(_ original:PhotoGeometry) -> PhotoGeometry {
            var face=original
            face.eyes=face.eyes.map { $0.map(destination) }
            face.brows=face.brows.map { $0.map(destination) }
            if var g=face.makeup {
                g.points=g.points.map(destination);g.outerLips=g.outerLips.map(destination)
                g.innerLips=g.innerLips.map(destination);g.faceContour=g.faceContour.map(destination)
                face.makeup=g
            }
            return face
        }
    }
    static func warp(face:PhotoGeometry,amount:CGFloat,look:MakeupLook = .roseGlam,protection:HandProtection? = nil) -> Warp? {
        guard let g=face.makeup,g.points.count==468,g.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              face.eyes.count==2,face.bounds.width>20 else { return nil }
        let strength=MakeupPaint.clamp(amount)*MakeupPaint.clamp(face.trackingOpacity)*MakeupPaint.clamp(g.opacity)
            * (1-MakeupPaint.smoothstep(0.60,1.30,abs(face.yaw)))
        guard strength>0.001 else { return nil }
        let axis=CGPoint(x:cos(face.roll),y:sin(face.roll)),fw=face.bounds.width
        let peach=look == .softPeach
        var regions:[Region]=[]
        for i in 0..<2 {
            guard let lid=LashGeometry.eyelids(face.eyes[i],right:axis),lid.width>fw*0.04 else { return nil }
            let center=MakeupPaint.mean(face.eyes[i])
            regions.append(Region(center:center,scaleX:1+(peach ? 0.11 : 0.16)*strength,scaleY:1+(peach ? 0.15 : 0.25)*strength,
                radiusX:lid.width*0.98,radiusY:lid.width*0.75,tilt:(i==0 ? -1 : 1)*(peach ? 0.018 : 0.035)*strength))
        }
        let nose=MakeupPaint.mix(g.points[168],g.points[4],0.67)
        regions.append(Region(center:nose,scaleX:1-(peach ? 0.12 : 0.19)*strength,scaleY:1,
            radiusX:fw*0.21,radiusY:max(fw*0.16,MakeupPaint.distance(g.points[168],g.points[4])*0.94)))
        // Jaw compression flattened the chin and pulled the mouth/neck inward.
        // Keep that entire region at identity; only eyes and nose are shaped.
        if let protection {
            regions.removeAll { protection.overlaps(center:$0.center,right:axis,radiusX:$0.radiusX+2,radiusY:$0.radiusY+2) }
        }
        guard !regions.isEmpty else { return nil }
        return Warp(axis:axis,regions:regions)
    }
    private static let kernel=CIWarpKernel(source:"""
        vec2 displacement(vec2 p, vec4 region, vec4 effect, vec2 axis) {
            vec2 d=p-region.xy;
            vec2 q=vec2(dot(d,axis),dot(d,vec2(-axis.y,axis.x)));
            float weight=1.0-smoothstep(0.55,1.0,length(q/effect.zw));
            vec2 shift=vec2(q.x*(effect.x-1.0),q.y*(effect.y-1.0)+q.x*region.z)*weight;
            return vec2(shift.x*axis.x-shift.y*axis.y,shift.x*axis.y+shift.y*axis.x);
        }
        vec2 undoRegion(vec2 p, vec4 region, vec4 effect, vec2 axis) {
            vec2 q=p;
            for (int i=0;i<8;i++) { q=p-displacement(q,region,effect,axis); }
            return q;
        }
        kernel vec2 referenceShape(vec2 axis, vec4 r0,vec4 e0,vec4 r1,vec4 e1,vec4 r2,vec4 e2) {
            vec2 p=destCoord();
            p=undoRegion(p,r2,e2,axis);
            p=undoRegion(p,r1,e1,axis);p=undoRegion(p,r0,e0,axis);
            return p;
        }
        """)
    static var available: Bool { kernel != nil }
    static func apply(_ image:CGImage,face:PhotoGeometry,amount:CGFloat,look:MakeupLook = .roseGlam,protection:HandProtection? = nil) -> (CGImage,PhotoGeometry) {
        guard let warp=warp(face:face,amount:amount,look:look,protection:protection),let kernel else { return (image,face) }
        var arguments:[Any]=[CIVector(x:warp.axis.x,y:warp.axis.y)]
        // The kernel has three region slots. Missing, protected regions are identity.
        var regions=warp.regions
        while regions.count<3 { regions.append(Region(center:.zero,scaleX:1,scaleY:1,radiusX:1,radiusY:1)) }
        for r in regions {
            arguments.append(CIVector(x:r.center.x,y:r.center.y,z:r.tilt,w:0))
            arguments.append(CIVector(x:r.scaleX,y:r.scaleY,z:r.radiusX,w:r.radiusY))
        }
        let input=CIImage(cgImage:image),padding=face.bounds.width*0.20
        guard let transformed=kernel.apply(extent:input.extent,
            roiCallback:{ _,rect in rect.insetBy(dx:-padding,dy:-padding) },image:input,arguments:arguments),
            let output=LashRendering.ci.createCGImage(transformed,from:input.extent) else { return (image,face) }
        return (output,warp.geometry(face))
    }
}
