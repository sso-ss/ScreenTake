import CoreGraphics
import Foundation

/// Color and wet reflections follow the measured lip tissue continuously.
/// Nothing is tiled in vertical strips, and the outer border fades into skin.
enum MakeupLips {
    private typealias Paint = MakeupPaint
    private struct Section {
        var low: CGFloat
        var high: CGFloat
        var innerLow: CGFloat
        var innerHigh: CGFloat
    }
    private static func rounded(_ points: [CGPoint]) -> [CGPoint] {
        var result:[CGPoint]=[]
        for i in points.indices {
            let control=points[i]
            let a=Paint.mix(control,points[(i+points.count-1)%points.count],0.18)
            let b=Paint.mix(control,points[(i+1)%points.count],0.18)
            for j in 0...8 {
                let t=CGFloat(j)/8,s=1-t
                result.append(CGPoint(x:s*s*a.x+2*s*t*control.x+t*t*b.x,
                                      y:s*s*a.y+2*s*t*control.y+t*t*b.y))
            }
        }
        return result
    }
    private static func bounds(_ polygon: [CGPoint],at x: CGFloat) -> (CGFloat,CGFloat)? {
        var low=CGFloat.greatestFiniteMagnitude,high = -CGFloat.greatestFiniteMagnitude
        for i in polygon.indices {
            let a=polygon[i],b=polygon[(i+1)%polygon.count]
            guard abs(b.x-a.x)>0.00001,x>=min(a.x,b.x),x<=max(a.x,b.x) else { continue }
            let y=a.y+(b.y-a.y)*(x-a.x)/(b.x-a.x)
            low=min(low,y);high=max(high,y)
        }
        return low<=high ? (low,high) : nil
    }
    static func draw(in ctx: CGContext,face: PhotoGeometry,geometry: MakeupGeometry,amount: CGFloat,blur: CGFloat = 0.8,look:MakeupLook = .roseGlam) {
        let strength=Paint.clamp(amount)
        guard strength>0,geometry.lipsReliable,geometry.outerLips.count>=6,geometry.innerLips.count>=4,
              let frame=MakeupLipFrame(outer:geometry.outerLips,axis:CGPoint(x:cos(face.roll),y:sin(face.roll))),
              frame.containsOpening(geometry.innerLips,outer:geometry.outerLips) else { return }
        let w=frame.width
        let outer=rounded(geometry.outerLips.map(frame.local)),inner=geometry.innerLips.map(frame.local)
        let left=outer.map(\.x).min()!,right=outer.map(\.x).max()!
        let innerLeft=inner.map(\.x).min()!,innerRight=inner.map(\.x).max()!
        let bottom=outer.map(\.y).min()!,top=outer.map(\.y).max()!
        let softness=Paint.clamp(blur)
        let peach=look == .softPeach
        let expansion=w*(peach ? 0.016+0.025*softness : 0.014+0.012*softness)*strength
        let feather=max(1.0,w*(peach ? 0.020+0.065*softness : 0.018+0.040*softness))
        // Precompute curve intersections once; interpolate them at every pixel.
        // The continuous coordinate remains identical at any output resolution.
        let count=256
        let sections=(0...count).map { i -> Section in
            let x=left+(right-left)*(0.00001+0.99998*CGFloat(i)/CGFloat(count))
            let surface=bounds(outer,at:x) ?? (0,0)
            let hole=bounds(inner,at:min(innerRight-w*0.00001,max(innerLeft+w*0.00001,x))) ?? (0,0)
            return Section(low:surface.0,high:surface.1,innerLow:hole.0,innerHigh:hole.1)
        }
        func section(_ x: CGFloat) -> Section {
            let t=Paint.clamp((x-left)/(right-left))*CGFloat(count)
            let i=min(count-1,Int(t)),f=t-CGFloat(i),a=sections[i],b=sections[i+1]
            return Section(low:a.low+(b.low-a.low)*f,high:a.high+(b.high-a.high)*f,
                innerLow:a.innerLow+(b.innerLow-a.innerLow)*f,innerHigh:a.innerHigh+(b.innerHigh-a.innerHigh)*f)
        }
        struct Tissue {
            var coverage: CGFloat
            var upper: Bool
            var t: CGFloat
            var x: CGFloat
        }
        func reference(_ v: Tissue) -> Paint.Pigment? {
            (v.upper ? MakeupReference.upperLip : MakeupReference.lowerLip)?.sample(v.x+0.5,v.t)
        }
        func tissue(_ p: CGPoint) -> Tissue? {
            guard p.x>left,p.x<right else { return nil }
            let s=section(p.x),upper=p.y>(s.innerLow+s.innerHigh)/2
            let depth=upper ? s.high-s.innerHigh : s.innerLow-s.low
            guard depth>w*0.002 else { return nil }
            let edge=min(p.x-left,right-p.x)
            let dx=w/CGFloat(count)
            let before=section(p.x-dx),after=section(p.x+dx)
            let slope=(upper ? after.high-before.high : after.low-before.low)/(2*dx)
            // Fade normal to the curved contour, including the cupid's bow.
            let contourDistance=(upper ? s.high-p.y : p.y-s.low)/sqrt(1+slope*slope)
            let extensionAmount=(expansion+(peach && upper ? w*0.015*strength : 0)) *
                pow(max(0,1-pow(abs(p.x)/(w*0.51),2)),0.9)
            let t=upper ? (p.y-s.innerHigh)/depth : (s.innerLow-p.y)/depth
            // Fade across the outer tissue itself, not just a subpixel outline.
            let outerFade=1-(0.65+0.20*softness)*Paint.smoothstep(0.48-0.20*softness,1.08+0.20*softness,t)
            let coverage=Paint.smoothstep(-extensionAmount,feather,contourDistance)*Paint.smoothstep(0,feather,edge)*outerFade
            guard coverage>0.001 else { return nil }
            return Tissue(coverage:coverage,upper:upper,t:Paint.clamp(t),x:p.x/w)
        }
        let box=CGRect(x:left,y:bottom-expansion-feather,width:right-left,height:top-bottom+2*(expansion+feather))
        ctx.saveGState();defer { ctx.restoreGState() }
        ctx.translateBy(x:frame.center.x,y:frame.center.y);ctx.rotate(by:atan2(frame.right.y,frame.right.x))
        Paint.exclude(ctx,inner,extent:box.insetBy(dx:-w,dy:-w))
        ctx.setBlendMode(.color)
        Paint.field(ctx,box:box) { p in
            guard let v=tissue(p) else { return Paint.Pigment() }
            // Muted coral-rose sampled from the supplied soft-lip reference.
            // Only hue/chroma are blended; the camera's tissue texture and
            // luminance remain intact. No reference lighting is stamped on skin.
            let outerTone=Paint.smoothstep(0.25,1,v.t)
            let cornerFade=1-0.22*Paint.smoothstep(0.22,0.49,abs(v.x))
            if look == .softPeach {
                return Paint.Pigment(r:0.79+0.07*outerTone,g:0.40+0.15*outerTone,b:0.43+0.12*outerTone,
                    a:strength*v.coverage*cornerFade*0.82)
            }
            return Paint.Pigment(r:0.88+0.04*outerTone,g:0.49+0.11*outerTone,b:0.52+0.09*outerTone,
                a:strength*v.coverage*cornerFade*0.72)
        }
        ctx.setBlendMode(.multiply)
        Paint.field(ctx,box:box) { p in
            guard let v=tissue(p) else { return Paint.Pigment() }
            let seam=exp(-pow(v.t/0.22,2))
            let center=1-Paint.smoothstep(0.28,0.49,abs(v.x))
            let upperShade:CGFloat=v.upper ? 0.022*(1-v.t) : 0
            if look == .softPeach {
                let innerDepth=0.045+0.20*seam*center+upperShade
                return Paint.Pigment(r:0.63,g:0.38,b:0.39,a:strength*v.coverage*innerDepth)
            }
            // A little depth at the inner seam; no dark outer/corner rim.
            return Paint.Pigment(r:0.64,g:0.37,b:0.39,
                a:strength*v.coverage*(0.020+0.055*seam*center+upperShade))
        }
        ctx.setBlendMode(.normal)
        Paint.field(ctx,box:box) { p in
            guard let v=tissue(p) else { return Paint.Pigment() }
            if look == .softPeach {
                let satin=Paint.gaussian(v.x,v.t,-0.04,v.upper ? 0.68 : 0.48,0.26,v.upper ? 0.16 : 0.22)
                let glint=v.upper ? 0 : Paint.gaussian(v.x,v.t,0.035,0.44,0.035,0.085) +
                    0.55*Paint.gaussian(v.x,v.t,-0.075,0.48,0.023,0.070)
                return Paint.Pigment(r:1,g:0.86,b:0.83,a:strength*v.coverage*(satin*(v.upper ? 0.05 : 0.16)+glint*0.17))
            }
            if let sampled=reference(v) {
                var pigment=Paint.Pigment()
                let luminance=sampled.r*0.2126+sampled.g*0.7152+sampled.b*0.0722
                let glass:CGFloat
                if v.upper {
                    glass=Paint.smoothstep(0.59,0.73,luminance) *
                        Paint.gaussian(v.x,v.t,-0.06,0.67,0.22,0.22)
                } else {
                    glass=Paint.smoothstep(0.47,0.66,luminance) *
                        Paint.gaussian(v.x,v.t,-0.04,0.42,0.32,0.28)
                }
                pigment.over(1,0.91,0.91,strength*v.coverage*glass*(v.upper ? 0.09 : 0.20))
                return pigment
            }
            var pigment=Paint.Pigment(r:0.78,g:0.33,b:0.42,a:strength*v.coverage*0.05)
            if !v.upper {
                let glow=Paint.gaussian(v.x,v.t,-0.015,0.54,0.27,0.25)
                pigment.over(1,0.66,0.72,strength*v.coverage*glow*0.10)
                // Broad curved gloss breaks into a few smaller reflections.
                // These are anchored in tissue space, never frame-random specks.
                let ridge=0.54+0.55*v.x*v.x
                let glass=Paint.gaussian(v.x,v.t,-0.075,ridge,0.19,0.068)
                let glints=Paint.gaussian(v.x,v.t,-0.15,ridge-0.055,0.036,0.085) +
                    Paint.gaussian(v.x,v.t,0.055,ridge+0.005,0.026,0.060) +
                    Paint.gaussian(v.x,v.t,0.15,ridge+0.04,0.014,0.052)
                pigment.over(1,0.96,0.94,strength*v.coverage*min(0.30,0.18*glass+0.22*glints))
            } else {
                let bow=Paint.gaussian(v.x,v.t,-0.075,0.76,0.09,0.075) +
                    Paint.gaussian(v.x,v.t,0.09,0.76,0.065,0.07)
                pigment.over(1,0.91,0.90,strength*v.coverage*bow*0.15)
            }
            return pigment
        }
    }
}
