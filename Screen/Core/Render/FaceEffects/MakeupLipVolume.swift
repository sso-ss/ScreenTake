import CoreGraphics
import Foundation

/// Resample the existing lip tissue before pigment. Corners and the mouth
/// opening stay fixed, so volume never paints skin over teeth or leaves two rims.
enum MakeupLipVolume {
    struct Warp {
        struct Section { var low: CGFloat; var high: CGFloat; var innerLow: CGFloat; var innerHigh: CGFloat }
        let frame: MakeupLipFrame
        let sections: [Section]
        let amount: CGFloat
        let upperOverline: CGFloat
        init?(face: PhotoGeometry, amount: CGFloat, upperOverline: CGFloat = 0) {
            guard let g=face.makeup,g.lipsReliable,
                  let f=MakeupLipFrame(outer:g.outerLips,axis:CGPoint(x:cos(face.roll),y:sin(face.roll))),
                  f.containsOpening(g.innerLips,outer:g.outerLips) else { return nil }
            frame=f
            self.upperOverline=MakeupPaint.clamp(upperOverline)
            self.amount=MakeupPaint.clamp(amount)*MakeupPaint.clamp(face.trackingOpacity)*MakeupPaint.clamp(g.opacity)
                * (1-MakeupPaint.smoothstep(0.8,1.4,abs(face.yaw)))
            let outer=g.outerLips.map(f.local),inner=g.innerLips.map(f.local)
            func bounds(_ polygon:[CGPoint],_ x:CGFloat) -> (CGFloat,CGFloat) {
                var ys:[CGFloat]=[]
                for i in polygon.indices {
                    let a=polygon[i],b=polygon[(i+1)%polygon.count]
                    if abs(b.x-a.x)>0.00001,x>=min(a.x,b.x),x<=max(a.x,b.x) {
                        ys.append(a.y+(b.y-a.y)*(x-a.x)/(b.x-a.x))
                    }
                }
                return (ys.min() ?? 0,ys.max() ?? 0)
            }
            let il=inner.map(\.x).min()!,ir=inner.map(\.x).max()!
            sections=(0...192).map { i in
                let x=f.width*(CGFloat(i)/192-0.5)*0.99999
                let a=bounds(outer,x),b=bounds(inner,min(ir-0.00001,max(il+0.00001,x)))
                let middle=min(a.1,max(a.0,(b.0+b.1)/2))
                return Section(low:a.0,high:a.1,innerLow:max(a.0,min(middle,b.0)),innerHigh:min(a.1,max(middle,b.1)))
            }
        }
        func section(_ x:CGFloat) -> Section {
            let t=MakeupPaint.clamp(x/frame.width+0.5)*192,i=min(191,Int(t)),f=t-CGFloat(i)
            let a=sections[i],b=sections[i+1]
            return Section(low:a.low+(b.low-a.low)*f,high:a.high+(b.high-a.high)*f,
                innerLow:a.innerLow+(b.innerLow-a.innerLow)*f,innerHigh:a.innerHigh+(b.innerHigh-a.innerHigh)*f)
        }
        func delta(_ x:CGFloat,depth:CGFloat,upper:Bool) -> CGFloat {
            let taper=pow(max(0,1-pow(2*x/frame.width,2)),1.25)
            let target=frame.width*(upper ? 0.155 : 0.210)
            let increase=max(max(0,depth)*(upper ? 0.40 : 0.45),target-depth)
            let overline=upper ? frame.width*0.035*upperOverline : 0
            return (min(increase,frame.width*(upper ? 0.070 : 0.090))+overline)*amount*taper
        }
        func world(_ p:CGPoint) -> CGPoint {
            CGPoint(x:frame.center.x+p.x*frame.right.x+p.y*frame.up.x,
                    y:frame.center.y+p.x*frame.right.y+p.y*frame.up.y)
        }
        func expanded(_ point:CGPoint) -> CGPoint {
            var p=frame.local(point);let s=section(p.x),upper=p.y>(s.innerHigh+s.innerLow)/2
            let depth=upper ? s.high-s.innerHigh : s.innerLow-s.low
            p.y += (upper ? 1 : -1)*delta(p.x,depth:depth,upper:upper)
            return world(p)
        }
        func source(_ point:CGPoint) -> CGPoint {
            var p=frame.local(point)
            guard abs(p.x)<frame.width*0.5 else { return point }
            let s=section(p.x)
            if p.y>=s.innerLow,p.y<=s.innerHigh { return point }
            let upper=p.y>s.innerHigh,sign:CGFloat=upper ? 1 : -1
            let edge=upper ? s.innerHigh : s.innerLow
            let depth=upper ? s.high-s.innerHigh : s.innerLow-s.low
            let expansion=delta(p.x,depth:depth,upper:upper)
            guard depth>0.001,expansion>0.0001 else { return point }
            let d=(p.y-edge)*sign,target=depth+expansion,support=depth+frame.width*0.22
            let original:CGFloat
            if d<=target { original=d*depth/target }
            else if d<support {
                // Hermite continuation joins the tissue scale to unchanged skin.
                let span=support-target,t=(d-target)/span,t2=t*t,t3=t2*t
                original=(2*t3-3*t2+1)*depth+(t3-2*t2+t)*span*depth/target
                    + (-2*t3+3*t2)*support+(t3-t2)*span
            } else { return point }
            p.y=edge+sign*original
            return world(p)
        }
    }
    static func apply(in ctx:CGContext,image:CGImage,face:PhotoGeometry,amount:CGFloat,upperOverline:CGFloat = 0,protection:HandProtection? = nil) -> PhotoGeometry {
        guard amount>0,let warp=Warp(face:face,amount:amount,upperOverline:upperOverline),warp.amount>0.001,
              var geometry=face.makeup else { return face }
        if let protection,protection.overlaps(center:warp.frame.center,right:warp.frame.right,
            radiusX:warp.frame.width*0.85,radiusY:warp.frame.width*0.65) { return face }
        let mouth=geometry.outerLips,xs=mouth.map(\.x),ys=mouth.map(\.y),padding=warp.frame.width*0.28
        let box=CGRect(x:xs.min()!-padding,y:ys.min()!-padding,
            width:xs.max()!-xs.min()!+padding*2,height:ys.max()!-ys.min()!+padding*2)
            .integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        guard box.width>1,box.height>1 else { return face }
        let width=Int(box.width),height=Int(box.height)
        let original=LashRendering.context(width,height),result=LashRendering.context(width,height)
        original.draw(image,in:CGRect(x:-box.minX,y:-box.minY,width:CGFloat(image.width),height:CGFloat(image.height)))
        let input=original.data!.assumingMemoryBound(to:UInt8.self),output=result.data!.assumingMemoryBound(to:UInt8.self)
        for row in 0..<height {
            for col in 0..<width {
                let dest=CGPoint(x:box.minX+CGFloat(col)+0.5,y:box.maxY-CGFloat(row)-0.5)
                let source=warp.source(dest)
                let x=min(CGFloat(width-1),max(0,source.x-box.minX-0.5))
                let y=min(CGFloat(height-1),max(0,box.maxY-source.y-0.5))
                let ix=min(width-2,Int(x)),iy=min(height-2,Int(y)),dx=x-CGFloat(ix),dy=y-CGFloat(iy)
                for c in 0..<4 {
                    let i=(iy*width+ix)*4+c
                    let a=CGFloat(input[i])*(1-dx)+CGFloat(input[i+4])*dx
                    let b=CGFloat(input[i+width*4])*(1-dx)+CGFloat(input[i+width*4+4])*dx
                    output[(row*width+col)*4+c]=UInt8(min(255,max(0,(a*(1-dy)+b*dy).rounded())))
                }
            }
        }
        guard let patch=result.makeImage() else { return face }
        ctx.draw(patch,in:box)
        geometry.outerLips=mouth.map(warp.expanded)
        var resultFace=face;resultFace.makeup=geometry
        return resultFace
    }
}
