import CoreGraphics
import Foundation
import simd

/// A fixed anatomical pigment map is transported by the current face mesh.
/// The model supplies correspondence, not a replacement face shape. Real image
/// texture stays intact, and camera depth resolves overlapping sides of the nose.
enum MakeupNose {
    static let canonical: [SIMD3<Float>] = {
        guard let url=Bundle.main.url(forResource:"canonical_face_model",withExtension:"obj"),
              let text=try? String(contentsOf:url) else { return [] }
        return text.split(separator:"\n").filter { $0.hasPrefix("v ") }.compactMap { line in
            let values=line.split(separator:" ").dropFirst().compactMap { Float($0) }
            return values.count==3 ? SIMD3(values[0],values[1],values[2]) : nil
        }
    }()
    struct Pigment { var shadow: Float; var light: Float }
    private static let domain=CGRect(x:-4,y:-3,width:8,height:9)
    private static let textureWidth=192,textureHeight=216
    private static func pigment(_ p:CGPoint) -> Pigment {
        // Root 168 to tip 4 is only a coordinate frame: all intermediate bridge
        // and ala vertices deform this map independently in the live image.
        let x=p.x/1.405627,y=(p.y+0.463170)/3.734197
        var shade:CGFloat=0
        for sign:CGFloat in [-1,1] {
            let root=MakeupPaint.gaussian(x,y,sign*0.78,0.96,0.43,0.24)
            let wall=MakeupPaint.gaussian(x,y,sign*0.58,0.46,0.31,0.40)
            let ala=MakeupPaint.gaussian(x,y,sign*0.94,-0.055,0.28,0.16)
            shade += 0.24*root+0.13*wall+0.11*ala
        }
        shade += 0.045*MakeupPaint.gaussian(x,y,0,-0.35,0.48,0.09)
        let light=0.075*MakeupPaint.gaussian(x,y,0,0.57,0.20,0.40)
            + 0.055*MakeupPaint.gaussian(x,y,0,-0.045,0.30,0.13)
        let edge=MakeupPaint.smoothstep(-3,-2.2,p.y)*(1-MakeupPaint.smoothstep(4.7,6,p.y))
            * (1-MakeupPaint.smoothstep(3,4,abs(p.x)))
        return Pigment(shadow:Float(shade*edge),light:Float(light*edge))
    }
    private static let texture: [Pigment] = {
        (0..<textureWidth*textureHeight).map { index in
            pigment(CGPoint(x:domain.minX+CGFloat(index%textureWidth)*domain.width/CGFloat(textureWidth-1),
                y:domain.minY+CGFloat(index/textureWidth)*domain.height/CGFloat(textureHeight-1)))
        }
    }()
    private static func sample(_ x:Float,_ y:Float) -> Pigment {
        let u=(x-Float(domain.minX))/Float(domain.width)*Float(textureWidth-1)
        let v=(y-Float(domain.minY))/Float(domain.height)*Float(textureHeight-1)
        guard u>=0,v>=0,u<Float(textureWidth-1),v<Float(textureHeight-1) else { return Pigment(shadow:0,light:0) }
        let i=Int(u),j=Int(v),tx=u-Float(i),ty=v-Float(j)
        let a=texture[j*textureWidth+i],b=texture[j*textureWidth+i+1]
        let c=texture[(j+1)*textureWidth+i],d=texture[(j+1)*textureWidth+i+1]
        func mix(_ a:Float,_ b:Float,_ c:Float,_ d:Float) -> Float {
            (a+(b-a)*tx)*(1-ty)+(c+(d-c)*tx)*ty
        }
        return Pigment(shadow:mix(a.shadow,b.shadow,c.shadow,d.shadow),light:mix(a.light,b.light,c.light,d.light))
    }
    struct Surface {
        var box: CGRect
        var width: Int
        var height: Int
        var coordinates: [SIMD2<Float>]
    }
    /// Rasterize correspondence once, with a shared depth buffer. Overlapping
    /// triangles cannot double-darken a pixel or paint the hidden nose wall.
    static func surface(points:[CGPoint],depths:[CGFloat],coordinates:[SIMD2<Float>],
                        triangles:[[Int]],box:CGRect,maximum:Int=320) -> Surface? {
        guard points.count==depths.count,points.count==coordinates.count,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),depths.allSatisfy(\.isFinite),
              !box.isEmpty,box.width.isFinite,box.height.isFinite else { return nil }
        let scale=min(1.5,CGFloat(maximum)/max(box.width,box.height))
        let width=max(2,Int(ceil(box.width*scale))),height=max(2,Int(ceil(box.height*scale)))
        let screen=points.map { SIMD2(Float(($0.x-box.minX)*CGFloat(width)/box.width),
                                     Float((box.maxY-$0.y)*CGFloat(height)/box.height)) }
        var z=[Float](repeating:.infinity,count:width*height)
        var uv=[SIMD2<Float>](repeating:SIMD2(.infinity,.infinity),count:width*height)
        for tri in triangles {
            guard tri.count==3,tri.allSatisfy({ points.indices.contains($0) }) else { continue }
            let a=screen[tri[0]],b=screen[tri[1]],c=screen[tri[2]]
            let denominator=(b.y-c.y)*(a.x-c.x)+(c.x-b.x)*(a.y-c.y)
            guard abs(denominator)>0.0001 else { continue }
            let x0=max(0,Int(floor(min(a.x,b.x,c.x)))),x1=min(width-1,Int(ceil(max(a.x,b.x,c.x))))
            let y0=max(0,Int(floor(min(a.y,b.y,c.y)))),y1=min(height-1,Int(ceil(max(a.y,b.y,c.y))))
            guard x0<=x1,y0<=y1 else { continue }
            let za=Float(depths[tri[0]]),zb=Float(depths[tri[1]]),zc=Float(depths[tri[2]])
            for row in y0...y1 { for column in x0...x1 {
                let x=Float(column)+0.5,y=Float(row)+0.5
                let wa=((b.y-c.y)*(x-c.x)+(c.x-b.x)*(y-c.y))/denominator
                let wb=((c.y-a.y)*(x-c.x)+(a.x-c.x)*(y-c.y))/denominator,wc=1-wa-wb
                guard wa>=(-0.00001),wb>=(-0.00001),wc>=(-0.00001) else { continue }
                let depth=za*wa+zb*wb+zc*wc,index=row*width+column
                guard depth<z[index] else { continue }
                z[index]=depth
                uv[index]=coordinates[tri[0]]*wa+coordinates[tri[1]]*wb+coordinates[tri[2]]*wc
            } }
        }
        return Surface(box:box,width:width,height:height,coordinates:uv)
    }
    static func draw(in ctx:CGContext,geometry:MakeupGeometry,amount:CGFloat) {
        guard canonical.count==468,geometry.points.count==468,geometry.depths.count==468,amount>0 else { return }
        let selected=canonical.indices.filter { domain.contains(CGPoint(x:CGFloat(canonical[$0].x),y:CGFloat(canonical[$0].y))) }
        let points=selected.map { geometry.points[$0] },xs=points.map(\.x),ys=points.map(\.y)
        guard let minX=xs.min(),let maxX=xs.max(),let minY=ys.min(),let maxY=ys.max() else { return }
        let box=CGRect(x:minX-2,y:minY-2,width:maxX-minX+4,height:maxY-minY+4)
        guard let map=surface(points:geometry.points,depths:geometry.depths,
            coordinates:canonical.map { SIMD2($0.x,$0.y) },triangles:LashMesh.triangles,box:box) else { return }
        let shadow=LashRendering.context(map.width,map.height),light=LashRendering.context(map.width,map.height)
        let sb=shadow.data!.assumingMemoryBound(to:UInt8.self),lb=light.data!.assumingMemoryBound(to:UInt8.self)
        for i in map.coordinates.indices {
            let uv=map.coordinates[i],color=sample(uv.x,uv.y)
            let sa=min(1,max(0,color.shadow*Float(amount))),la=min(1,max(0,color.light*Float(amount)))
            sb[i*4]=UInt8(0.53*sa*255);sb[i*4+1]=UInt8(0.46*sa*255)
            sb[i*4+2]=UInt8(0.43*sa*255);sb[i*4+3]=UInt8(sa*255)
            lb[i*4]=UInt8(la*255);lb[i*4+1]=UInt8(0.94*la*255)
            lb[i*4+2]=UInt8(0.90*la*255);lb[i*4+3]=UInt8(la*255)
        }
        ctx.saveGState();defer { ctx.restoreGState() }
        ctx.interpolationQuality = .high
        if let image=shadow.makeImage() { ctx.setBlendMode(.multiply);ctx.draw(image,in:box) }
        if let image=light.makeImage() { ctx.setBlendMode(.normal);ctx.draw(image,in:box) }
    }
}
