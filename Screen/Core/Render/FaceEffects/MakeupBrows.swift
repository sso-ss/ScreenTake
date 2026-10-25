import CoreGraphics
import Foundation

/// Feathered powder follows the source hairs. Bare skin receives only a faint
/// veil, while already dark hairs are protected from becoming a solid block.
enum MakeupBrows {
    private typealias Paint = MakeupPaint
    // Both sides run from the inner head to the outer tail in MediaPipe space.
    static let upper = [[107,66,105,63,70],[336,296,334,293,300]]
    static let lower = [[55,65,52,53,46],[285,295,282,283,276]]

    private struct Texture {
        let pixels: [UInt8]
        let box: CGRect
        let width = 128, height = 64

        init(image: CGImage, transform: CGAffineTransform, box: CGRect) {
            self.box = box
            let sample = LashRendering.context(width, height)
            sample.interpolationQuality = .high
            sample.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
            sample.translateBy(x: -box.minX, y: -box.minY)
            sample.concatenate(transform.inverted())
            sample.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            pixels = Array(UnsafeBufferPointer(start: sample.data!.assumingMemoryBound(to: UInt8.self),
                count: width * height * 4))
        }

        func light(_ point: CGPoint) -> CGFloat {
            let x = min(CGFloat(width - 1), max(0, (point.x - box.minX) / box.width * CGFloat(width) - 0.5))
            let y = min(CGFloat(height - 1), max(0, (box.maxY - point.y) / box.height * CGFloat(height) - 0.5))
            let a = Int(x), b = Int(y), fx = x - CGFloat(a), fy = y - CGFloat(b)
            func value(_ x: Int, _ y: Int) -> CGFloat {
                let i = (min(height - 1, y) * width + min(width - 1, x)) * 4
                return (0.2126 * CGFloat(pixels[i]) + 0.7152 * CGFloat(pixels[i + 1]) + 0.0722 * CGFloat(pixels[i + 2])) / 255
            }
            return (value(a,b) * (1-fx) + value(a+1,b) * fx) * (1-fy) +
                (value(a,b+1) * (1-fx) + value(a+1,b+1) * fx) * fy
        }

        func support(at point: CGPoint, low: CGFloat, high: CGFloat, browWidth: CGFloat) -> CGFloat {
            let skin = max(light(CGPoint(x: point.x, y: high + browWidth * 0.035)),
                           light(CGPoint(x: point.x, y: low - browWidth * 0.035)))
            let hair = max(0, (skin - light(point)) / max(0.1, skin))
            let nearby = (light(CGPoint(x: point.x - browWidth * 0.014, y: point.y)) +
                          light(CGPoint(x: point.x + browWidth * 0.014, y: point.y))) * 0.5
            let density = Paint.smoothstep(0.025, 0.20, max(hair, (skin-nearby) / max(0.1, skin)))
            // Support follows existing texture; no frame-random hair pattern.
            return (0.12 + 0.88 * density) * (1 - 0.65 * Paint.smoothstep(0.22, 0.65, hair))
        }
    }

    private static func height(_ points:[CGPoint],at x:CGFloat) -> CGFloat {
        if x<=points[0].x { return points[0].y }
        if x>=points.last!.x { return points.last!.y }
        for i in 0..<points.count-1 where x>=points[i].x && x<=points[i+1].x {
            let a=points[i],b=points[i+1],span=b.x-a.x
            let t=(x-a.x)/max(0.00001,span)
            let previous=points[max(0,i-1)],next=points[min(points.count-1,i+2)]
            let m0=(b.y-previous.y)/max(0.00001,b.x-previous.x)*span
            let m1=(next.y-a.y)/max(0.00001,next.x-a.x)*span
            let y=(2*t*t*t-3*t*t+1)*a.y+(t*t*t-2*t*t+t)*m0 +
                (-2*t*t*t+3*t*t)*b.y+(t*t*t-t*t)*m1
            return min(max(a.y,b.y),max(min(a.y,b.y),y))
        }
        return 0
    }

    static func draw(in ctx:CGContext,face:PhotoGeometry,geometry:MakeupGeometry,
                     amount:CGFloat,look:MakeupLook = .roseGlam) {
        guard amount>0,geometry.points.count==468 else { return }
        let source = look == .softPeach ? ctx.makeImage() : nil
        let visibility=PhotoGeometry.visibility(yaw:face.yaw)
        for index in 0..<2 {
            let observed=face.eyeVisibility.count==2 ? Paint.clamp(face.eyeVisibility[index]) : 1
            let strength=Paint.clamp(amount)*min(observed,visibility[index])
            guard strength>0.005 else { continue }
            let top=geometry.polygon(upper[index]),bottom=geometry.polygon(lower[index])
            let origin=Paint.mix(top[0],bottom[0],0.5)
            let end=Paint.mix(top.last!,bottom.last!,0.5),w=Paint.distance(origin,end)
            guard w>max(3,face.bounds.width*0.035) else { continue }
            let axis=CGPoint(x:(end.x-origin.x)/w,y:(end.y-origin.y)/w)
            let sign:CGFloat=index==0 ? -1 : 1
            let up=CGPoint(x:-axis.y*sign,y:axis.x*sign)
            func local(_ p:CGPoint) -> CGPoint {
                let dx=p.x-origin.x,dy=p.y-origin.y
                return CGPoint(x:(dx*axis.x+dy*axis.y)/w,y:(dx*up.x+dy*up.y)/w)
            }
            let a=top.map(local).sorted { $0.x<$1.x },b=bottom.map(local).sorted { $0.x<$1.x }
            let samples=(0...128).map { i in
                CGPoint(x:height(b,at:CGFloat(i)/128),y:height(a,at:CGFloat(i)/128))
            }
            let low=(a+b).map(\.y).min()!,high=(a+b).map(\.y).max()!
            guard high-low>0.005 else { continue }
            let transform = CGAffineTransform(a:axis.x,b:axis.y,c:up.x,d:up.y,tx:origin.x,ty:origin.y)
            let texture = source.map { Texture(image: $0, transform: transform,
                box: CGRect(x: 0, y: (low-0.06)*w, width: w, height: (high-low+0.12)*w)) }
            ctx.saveGState()
            ctx.concatenate(transform)
            ctx.setBlendMode(.multiply)
            Paint.field(ctx,box:CGRect(x:0,y:low*w,width:w,height:(high-low)*w)) { p in
                let x=Paint.clamp(p.x/w),t=x*128,i=min(127,Int(t)),f=t-CGFloat(i)
                let section=Paint.mix(samples[i],samples[i+1],f),depth=section.y-section.x
                guard depth>0.004 else { return Paint.Pigment() }
                let v=(p.y/w-section.x)/depth
                // Keep powder toward the hair-bearing center, leaving a soft
                // lower border and a light head. The tail tapers in both axes.
                let peach=look == .softPeach
                let taper=1-(peach ? 0.35 : 0.50)*Paint.smoothstep(0.68,1,x)
                let cross=exp(-0.5*pow((v-(peach ? 0.55 : 0.60))/((peach ? 0.30 : 0.24)*taper),2)) *
                    Paint.smoothstep(0.02,peach ? 0.20 : 0.26,v)*(1-Paint.smoothstep(0.83,1,v))
                let along=Paint.smoothstep(peach ? 0.02 : 0,peach ? 0.30 : 0.24,x)*(1-Paint.smoothstep(peach ? 0.72 : 0.80,1,x))
                let support = texture?.support(at: p, low: section.x*w, high: section.y*w, browWidth: w) ?? 1
                let alpha=strength*cross*along*(peach ? 0.18*support : 0.38)
                return look == .softPeach ? Paint.Pigment(r:0.43,g:0.39,b:0.36,a:alpha) :
                    Paint.Pigment(r:0.36,g:0.30,b:0.32,a:alpha)
            }
            ctx.restoreGState()
        }
    }
}
