import CoreGraphics
import CoreImage
import Foundation

enum MakeupPaint {
    struct Pigment {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        mutating func over(_ red: CGFloat,_ green: CGFloat,_ blue: CGFloat,_ opacity: CGFloat) {
            let alpha=MakeupPaint.clamp(opacity),combined=alpha+a*(1-alpha)
            guard combined > 0 else { return }
            r=(red*alpha+r*a*(1-alpha))/combined
            g=(green*alpha+g*a*(1-alpha))/combined
            b=(blue*alpha+b*a*(1-alpha))/combined
            a=combined
        }
    }
    static func smoothstep(_ low: CGFloat,_ high: CGFloat,_ x: CGFloat) -> CGFloat {
        let t=clamp((x-low)/max(0.00001,high-low));return t*t*(3-2*t)
    }
    static func gaussian(_ x: CGFloat,_ y: CGFloat,_ cx: CGFloat,_ cy: CGFloat,_ sx: CGFloat,_ sy: CGFloat) -> CGFloat {
        let u=(x-cx)/max(0.0001,sx),v=(y-cy)/max(0.0001,sy)
        return exp(-0.5*(u*u+v*v))
    }
    /// Small continuous pigment fields avoid the seams made by separately
    /// clipped vertical strips. Coordinates are local, y-up, like the landmarks.
    /// Supersampling and continuous alpha keep the same field stable in motion.
    static func field(_ ctx: CGContext,box: CGRect,maximum: Int = 384,
                      paint: (CGPoint) -> Pigment) {
        guard box.width > 0,box.height > 0 else { return }
        let scale=min(1.5,CGFloat(maximum)/max(box.width,box.height))
        let width=max(2,Int(ceil(box.width*scale))),height=max(2,Int(ceil(box.height*scale)))
        let layer=LashRendering.context(width,height)
        let pixels=layer.data!.assumingMemoryBound(to:UInt8.self)
        for row in 0..<height {
            let y=box.maxY-(CGFloat(row)+0.5)*box.height/CGFloat(height)
            for column in 0..<width {
                let x=box.minX+(CGFloat(column)+0.5)*box.width/CGFloat(width)
                let color=paint(CGPoint(x:x,y:y)),alpha=clamp(color.a)
                let index=row*layer.bytesPerRow+column*4
                pixels[index]=UInt8(clamp(color.r)*alpha*255)
                pixels[index+1]=UInt8(clamp(color.g)*alpha*255)
                pixels[index+2]=UInt8(clamp(color.b)*alpha*255)
                pixels[index+3]=UInt8(alpha*255)
            }
        }
        if let image=layer.makeImage() {
            ctx.saveGState();ctx.interpolationQuality = .high;ctx.draw(image,in:box);ctx.restoreGState()
        }
    }
    static func clamp(_ x: CGFloat) -> CGFloat { x.isFinite ? min(1,max(0,x)) : 0 }
    static func mix(_ a: CGPoint,_ b: CGPoint,_ t: CGFloat) -> CGPoint { CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t) }
    static func add(_ a: CGPoint,_ v: CGPoint,_ t: CGFloat) -> CGPoint { CGPoint(x:a.x+v.x*t,y:a.y+v.y*t) }
    static func distance(_ a: CGPoint,_ b: CGPoint) -> CGFloat { hypot(a.x-b.x,a.y-b.y) }
    static func mean(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        return CGPoint(x:points.map(\.x).reduce(0,+)/CGFloat(points.count),y:points.map(\.y).reduce(0,+)/CGFloat(points.count))
    }
    static func path(_ points: [CGPoint],closed: Bool = true,smooth: Bool = true) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to:first)
        guard smooth,points.count >= 3 else {
            points.dropFirst().forEach { path.addLine(to:$0) }; if closed { path.closeSubpath() }; return path
        }
        func p(_ i: Int) -> CGPoint { points[closed ? (i+points.count)%points.count : min(points.count-1,max(0,i))] }
        for i in 0..<(closed ? points.count : points.count-1) {
            let a=p(i-1),b=p(i),c=p(i+1),d=p(i+2)
            path.addCurve(to:c,control1:CGPoint(x:b.x+(c.x-a.x)/6,y:b.y+(c.y-a.y)/6),
                          control2:CGPoint(x:c.x-(d.x-b.x)/6,y:c.y-(d.y-b.y)/6))
        }
        if closed { path.closeSubpath() }; return path
    }
    /// Rounded corners remain inside each adjacent control triangle. Sparse
    /// observed lip nodes must never overshoot as an unconstrained cubic spline.
    static func lipPath(_ points: [CGPoint]) -> CGPath {
        let result=CGMutablePath()
        guard points.count >= 3 else { return result }
        result.move(to:mix(points[0],points.last!,0.16))
        for index in points.indices {
            let previous=points[(index+points.count-1)%points.count]
            let current=points[index],next=points[(index+1)%points.count]
            result.addLine(to:mix(current,previous,0.16))
            result.addQuadCurve(to:mix(current,next,0.16),control:current)
        }
        result.closeSubpath();return result
    }
    static func color(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat,_ a: CGFloat) -> CGColor {
        CGColor(red:r,green:g,blue:b,alpha:clamp(a))
    }
    /// Independent clips form a union of exclusions even when detector polygons
    /// overlap. One even-odd path containing overlapping eyes would re-add pixels.
    static func exclude(_ ctx: CGContext,_ polygon: [CGPoint],extent: CGRect,padding: CGFloat = 0) {
        guard polygon.count >= 3 else { return }
        let hole = CGMutablePath(); hole.addRect(extent)
        let outline = path(polygon,smooth:false)
        hole.addPath(outline)
        ctx.addPath(hole); ctx.clip(using:.evenOdd)
        if padding > 0, let expanded = outline.copy(strokingWithWidth:padding*2,lineCap:.round,lineJoin:.round,miterLimit:2) as CGPath? {
            let edge = CGMutablePath(); edge.addRect(extent); edge.addPath(expanded)
            ctx.addPath(edge); ctx.clip(using:.evenOdd)
        }
    }
    static func diffuse(_ ctx: CGContext,_ p: CGPoint,right: CGPoint,width: CGFloat,height: CGFloat,tint: CGColor) {
        guard width > 0.1,height > 0.1,let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),
            colors:[1.0,0.94,0.70,0.38,0.14,0.025,0.0].map { tint.copy(alpha:tint.alpha*$0)! } as CFArray,locations:[0,0.12,0.30,0.50,0.70,0.86,1]) else { return }
        ctx.saveGState(); ctx.translateBy(x:p.x,y:p.y); ctx.rotate(by:atan2(right.y,right.x)); ctx.scaleBy(x:width/2,y:height/2)
        ctx.drawRadialGradient(gradient,startCenter:.zero,startRadius:0,endCenter:.zero,endRadius:1,options:[]); ctx.restoreGState()
    }
    /// Blur a small, bounded pigment image once. Nested opaque strokes used to
    /// leave visible contours inside the cheek and nose at oblique angles.
    static func softStroke(_ ctx: CGContext,_ points: [CGPoint],width: CGFloat,tint: CGColor) {
        guard points.count >= 2,width > 0.1,points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        let padding=max(3,width*2.5)
        let xs=points.map(\.x),ys=points.map(\.y)
        let box=CGRect(x:xs.min()!-padding,y:ys.min()!-padding,
            width:xs.max()!-xs.min()!+padding*2,height:ys.max()!-ys.min()!+padding*2).integral
        let scale=min(1,240/max(box.width,box.height))
        let w=max(2,Int(ceil(box.width*scale))),h=max(2,Int(ceil(box.height*scale)))
        let layer=LashRendering.context(w,h)
        layer.scaleBy(x:scale,y:scale);layer.translateBy(x:-box.minX,y:-box.minY)
        layer.setStrokeColor(tint);layer.setLineWidth(width*0.62)
        layer.setLineCap(.round);layer.setLineJoin(.round)
        layer.addPath(path(points,closed:false));layer.strokePath()
        guard let pigment=layer.makeImage() else { return }
        let input=CIImage(cgImage:pigment)
        let blurred=input.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(0.6,width*scale*0.50)])
        guard let image=LashRendering.ci.createCGImage(blurred,from:input.extent) else { return }
        ctx.draw(image,in:box)
    }
}
