import CoreGraphics
import Foundation

/// One shade layer per lid, restrained satin and a feathered lash-root liner.
/// All three follow the observed arcs without painting an artificial eye bag.
enum MakeupEyes {
    private typealias Paint = MakeupPaint
    private static func height(_ points: [CGPoint],at x: CGFloat) -> CGFloat {
        if x<=points[0].x { return points[0].y }
        if x>=points.last!.x { return points.last!.y }
        for i in 0..<points.count-1 where x>=points[i].x && x<=points[i+1].x {
            let span=points[i+1].x-points[i].x
            return points[i].y+(points[i+1].y-points[i].y)*(x-points[i].x)/max(0.00001,span)
        }
        return 0
    }
    static func draw(in ctx: CGContext,face: PhotoGeometry,geometry: MakeupGeometry,amount: CGFloat,look:MakeupLook = .roseGlam) {
        guard amount>0,face.eyes.count>=2 else { return }
        let axis=CGPoint(x:cos(face.roll),y:sin(face.roll))
        let poseVisibility=PhotoGeometry.visibility(yaw:face.yaw)
        let peach=look == .softPeach
        for index in 0..<2 {
            guard let lid=LashGeometry.eyelids(face.eyes[index],right:axis),
                  lid.width>max(2,face.bounds.width*0.025),lid.upper.count>=3,lid.lower.count>=3 else { continue }
            let observed=face.eyeVisibility.count==2 ? Paint.clamp(face.eyeVisibility[index]) : 1
            let strength=Paint.clamp(amount)*min(observed,poseVisibility[index])
            guard strength>0.005 else { continue }
            let w=lid.width,up=lid.up,sign:CGFloat=index==0 ? -1 : 1
            let upper=index==0 ? Array(lid.upper.reversed()) : lid.upper
            let lower=index==0 ? Array(lid.lower.reversed()) : lid.lower
            let origin=upper[0],outward=CGPoint(x:lid.right.x*sign,y:lid.right.y*sign)
            func local(_ p: CGPoint) -> CGPoint {
                let dx=p.x-origin.x,dy=p.y-origin.y
                return CGPoint(x:(dx*outward.x+dy*outward.y)/w,y:(dx*up.x+dy*up.y)/w)
            }
            let top=upper.map(local).sorted { $0.x<$1.x },bottom=lower.map(local).sorted { $0.x<$1.x }
            let topSamples=(0...128).map { height(top,at:CGFloat($0)/128) }
            let bottomSamples=(0...128).map { height(bottom,at:CGFloat($0)/128) }
            func h(_ values: [CGFloat],_ x: CGFloat) -> CGFloat {
                let t=Paint.clamp(x)*128,i=min(127,Int(t)),f=t-CGFloat(i)
                return values[i]+(values[i+1]-values[i])*f
            }
            let projection=max(0.50,min(1.65,cos(face.pitch)/max(0.55,cos(face.yaw))))
            let box=CGRect(x:-0.20*w,y:((bottomSamples.min() ?? 0)-0.45*projection)*w,
                width:1.49*w,height:((topSamples.max() ?? 0)-(bottomSamples.min() ?? 0)+0.96*projection)*w)
            ctx.saveGState()
            ctx.concatenate(CGAffineTransform(a:outward.x,b:outward.y,c:up.x,d:up.y,tx:origin.x,ty:origin.y))
            ctx.setBlendMode(.multiply)
            Paint.field(ctx,box:box) { p in
                let x=p.x/w,y=p.y/w,upperY=h(topSamples,x),lowerY=h(bottomSamples,x)
                let above=(y-upperY)/projection,below=(lowerY-y)/projection
                let across=Paint.smoothstep(-0.07,0.14,x)*(1-Paint.smoothstep(0.88,1.18,x))
                var color=Paint.Pigment()
                if above > -0.025 {
                    let reference=MakeupReference.upperShade?.sample((x+0.12)/1.24,above/0.45)
                    let transition=Paint.gaussian(x,above,0.53,0.105,0.44,0.125)*across
                    if peach {
                        if let pigment=MakeupReference.peachUpper?.sample((x+0.18)/1.48,max(0,above)/0.46) {
                            color.over(pigment.r,pigment.g,pigment.b,strength*pigment.a)
                        }
                    } else if let reference {
                        let feather=1-Paint.smoothstep(0.19,0.40,above)
                        color.over(reference.r,reference.g,reference.b,
                            strength*min(0.30,reference.a*0.52)*across*feather)
                    } else {
                        color.over(0.56,0.40,0.42,strength*transition*0.24)
                    }
                }
                if below > 0 {
                    if peach {
                        if let pigment=MakeupReference.peachLower?.sample((x+0.18)/1.48,below/0.30) {
                            color.over(pigment.r,pigment.g,pigment.b,strength*pigment.a)
                        }
                    } else if let reference=MakeupReference.lowerShade?.sample((x+0.12)/1.24,below/0.45) {
                        let feather=1-Paint.smoothstep(0.055,0.23,below)
                        color.over(reference.r,reference.g,reference.b,
                            strength*min(0.12,reference.a*0.24)*across*feather)
                    } else {
                        let rose=Paint.gaussian(x,below,0.58,0.07,0.34,0.065)*across
                        color.over(0.78,0.52,0.55,strength*rose*0.10)
                    }
                }
                // A soft boundary at the roots avoids a second opaque outline
                // beneath the lash renderer. Continue into one short tapered wing.
                let wing=Paint.clamp((x-1)/0.12)
                let linerY=h(topSamples,x)+0.035*projection*wing
                let thickness=(0.004+(peach ? 0.010 : 0.019)*Paint.smoothstep(0.08,0.95,x))*(1-wing)
                let distance=(y-linerY)/projection
                let coverage=Paint.smoothstep(-0.003,0.003,distance) *
                    (1-Paint.smoothstep(max(0,thickness-0.004),thickness+0.005,distance)) *
                    Paint.smoothstep(0.02,0.20,x)*(1-Paint.smoothstep(1.08,1.12,x))
                if peach { color.over(0.27,0.16,0.105,strength*coverage*0.45) }
                else { color.over(0.19,0.12,0.14,strength*coverage*0.72) }
                return color
            }
            ctx.setBlendMode(.normal)
            Paint.field(ctx,box:box) { p in
                let x=p.x/w,y=p.y/w,upperY=h(topSamples,x),lowerY=h(bottomSamples,x)
                let above=(y-upperY)/projection,below=(lowerY-y)/projection
                var color=Paint.Pigment()
                if above > 0 {
                    if peach {
                        let satin=Paint.gaussian(x,above,0.34,0.066,0.25,0.057)
                        color.over(1,0.87,0.73,strength*satin*0.035)
                    } else if let reference=MakeupReference.upperPearl?.sample((x+0.12)/1.24,above/0.45) {
                        color.over(reference.r,reference.g,reference.b,strength*reference.a*0.34)
                    } else {
                        let satin=Paint.gaussian(x,above,0.35,0.064,0.25,0.059)
                        color.over(1,0.86,0.82,strength*satin*0.10)
                    }
                }
                if below > 0 {
                    if peach {
                        let satin=Paint.gaussian(x,below,0.39,0.075,0.23,0.033)
                        color.over(1,0.89,0.76,strength*satin*0.10)
                    } else if let reference=MakeupReference.lowerPearl?.sample((x+0.12)/1.24,below/0.45) {
                        color.over(reference.r,reference.g,reference.b,strength*reference.a*0.30)
                    } else {
                        let pearl=Paint.gaussian(x,below,0.46,0.08,0.22,0.035)
                        color.over(1,0.89,0.83,strength*pearl*0.12)
                    }
                }
                let duct=Paint.gaussian(x,y,-0.008,0.004,0.035,0.043*projection)
                color.over(1,0.88,0.81,strength*duct*0.12)
                let glint=Paint.gaussian(x,y,-0.010,0.007,0.013,0.019*projection)
                color.over(1,0.99,0.95,strength*glint*0.14)
                return color
            }
            ctx.restoreGState()
        }
    }
}
