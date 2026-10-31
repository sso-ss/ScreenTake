import Foundation
import CoreGraphics

/// The reference look is concentrated on the upper cheek and nose. A jaw-wide
/// stroke is particularly unsafe here: the small face mesh can put its nominal
/// jaw through the middle of the visible cheek in a three-quarter view.
enum MakeupSkin {
    private static func unit(_ vector: CGPoint, fallback: CGPoint) -> CGPoint {
        let length = hypot(vector.x,vector.y)
        return length > 0.001 ? CGPoint(x:vector.x/length,y:vector.y/length) : fallback
    }
    private static func visibility(_ face: PhotoGeometry, side: Int) -> CGFloat {
        let far = face.yaw >= 0 ? side == 1 : side == 0
        guard far else { return 1 }
        let t = MakeupPaint.clamp((abs(face.yaw)-0.25)/1.05)
        return 1-t*t*(3-2*t)
    }
    private static func nearest(_ point: CGPoint, on outline: [CGPoint]) -> CGPoint? {
        guard outline.count >= 3 else { return nil }
        var best: CGPoint?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in outline.indices {
            let a=outline[index],b=outline[(index+1)%outline.count]
            let dx=b.x-a.x,dy=b.y-a.y,denominator=dx*dx+dy*dy
            let t=denominator > 0 ? MakeupPaint.clamp(((point.x-a.x)*dx+(point.y-a.y)*dy)/denominator) : 0
            let candidate=CGPoint(x:a.x+t*dx,y:a.y+t*dy)
            let distance=MakeupPaint.distance(point,candidate)
            if distance < bestDistance { best=candidate;bestDistance=distance }
        }
        return best
    }

    static func draw(in ctx: CGContext, face: PhotoGeometry, geometry: MakeupGeometry,
                     contour: CGFloat, blush: CGFloat,look:MakeupLook = .roseGlam) {
        guard geometry.points.count == 468 else { return }
        let p=geometry.points,fw=max(1,face.bounds.width)
        let right=CGPoint(x:cos(face.roll),y:sin(face.roll))
        let up=CGPoint(x:-right.y,y:right.x)
        let shape=geometry.skinOutline
        let observedContour=geometry.faceContour.filter { $0.x.isFinite && $0.y.isFinite }
        // The observed chin owns the lower facial frame whenever it exists.
        // A displaced canonical jaw node must not drag either the outward edge
        // direction or a chin highlight into the middle of the visible cheek.
        let chin=observedContour.count >= 7
            ? observedContour.min { $0.x*up.x+$0.y*up.y < $1.x*up.x+$1.y*up.y }!
            : p[152]
        let center=MakeupPaint.mean([p[168],p[1],chin])
        ctx.saveGState();defer { ctx.restoreGState() }

        if contour > 0 {
            ctx.setBlendMode(.multiply)
            // Only a small field at the actual lateral silhouette. A separate
            // observed boundary must corroborate the mesh anchor before it is
            // used; there is no line drawn down the jaw or across the cheek.
            for side in 0..<2 {
                let lateral=p[side == 0 ? 234 : 454]
                guard geometry.faceContour.count >= 7,
                      let edge=nearest(lateral,on:shape),
                      MakeupPaint.distance(edge,lateral) < fw*0.09 else { continue }
                let amount=contour*visibility(face,side:side)
                let outward=unit(CGPoint(x:edge.x-center.x,y:edge.y-center.y),
                                 fallback:CGPoint(x:side == 0 ? -right.x : right.x,
                                                  y:side == 0 ? -right.y : right.y))
                let field=MakeupPaint.add(edge,outward,fw*0.026)
                MakeupPaint.diffuse(ctx,field,right:right,width:fw*0.13,height:fw*0.26,
                    tint:MakeupPaint.color(0.53,0.45,0.46,amount*0.15))
            }

            // Pigment lives on corresponding nose triangles, including the
            // root and alar planes. The nearest visible surface owns a pixel.
            MakeupNose.draw(in:ctx,geometry:geometry,amount:contour)

        }

        if blush > 0 {
            for side in 0..<2 {
                let amount=blush*visibility(face,side:side)
                guard amount > 0.001,face.eyes.count > side,
                      let lid=LashGeometry.eyelids(face.eyes[side],right:right),
                      lid.width > fw*0.018 else { continue }
                let sign:CGFloat=side == 0 ? -1 : 1
                let outward=CGPoint(x:lid.right.x*sign,y:lid.right.y*sign)
                let lower=MakeupPaint.mean(lid.lower)
                let w=lid.width
                let projection=max(0.60,min(1.55,cos(face.pitch)/max(0.60,cos(face.yaw))))
                ctx.saveGState()
                ctx.concatenate(CGAffineTransform(a:outward.x,b:outward.y,c:lid.up.x,d:lid.up.y,
                    tx:lower.x,ty:lower.y))
                let box=CGRect(x:-w*0.95,y:-w*1.72*projection,width:w*2.35,height:w*1.48*projection)
                for pass in 0..<2 {
                    ctx.setBlendMode(pass == 0 ? .normal : .softLight)
                    MakeupPaint.field(ctx,box:box) { point in
                        let x=point.x/w,y=point.y/(w*projection)
                        // The upper border follows a lifted drape. Color falls
                        // away well before the jaw and remains off the aegyo ridge.
                        let lift=y-0.14*x
                        let main=MakeupPaint.gaussian(x,lift,0.12,-0.94,0.66,0.42)
                        let outer=MakeupPaint.gaussian(x,lift,0.55,-0.84,0.42,0.32)
                        let veil=(main*0.68+outer*0.32) *
                            MakeupPaint.smoothstep(0.28,0.76,-y)
                        let a=amount*(pass == 0 ? 0.24*veil : 0.22*veil)
                        // A peach-rose transition at the inside and a cooler
                        // pink focus outside avoid a single flat pink stamp.
                        let outerTone=MakeupPaint.smoothstep(-0.40,0.35,x)
                        if look == .softPeach {
                            return MakeupPaint.Pigment(r:0.93-0.025*outerTone,
                                g:0.53-0.055*outerTone,b:0.46+0.01*outerTone,a:a*0.86)
                        }
                        return MakeupPaint.Pigment(r:0.87-0.02*outerTone,
                            g:0.42-0.015*outerTone,b:0.50+0.025*outerTone,a:a)
                    }
                }
                ctx.restoreGState()
            }
            ctx.setBlendMode(.normal)
            MakeupPaint.diffuse(ctx,MakeupPaint.mix(p[4],p[1],0.28),right:right,
                width:fw*0.09,height:fw*0.058,
                tint:look == .softPeach ? MakeupPaint.color(0.92,0.53,0.46,blush*0.065) : MakeupPaint.color(0.89,0.43,0.50,blush*0.12))
        }
    }
}
