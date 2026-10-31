import Foundation
import CoreGraphics
import ImageIO

/// Cosmetic-only atlases sampled from the first supplied reference. Eyeballs
/// and facial geometry are never copied. Live lid/lip arcs own the deformation.
enum MakeupReference {
    struct Texture {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        init?(_ name: String) {
            guard let url=Bundle.main.url(forResource:name,withExtension:"png",subdirectory:"ReferenceMakeup"),
                  let source=CGImageSourceCreateWithURL(url as CFURL,nil),
                  let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { return nil }
            width=image.width;height=image.height
            let context=LashRendering.context(width,height)
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            pixels=Array(UnsafeBufferPointer(start:context.data!.assumingMemoryBound(to:UInt8.self),count:width*height*4))
        }
        func sample(_ u: CGFloat,_ v: CGFloat) -> MakeupPaint.Pigment {
            guard u>=0,u<=1,v>=0,v<=1 else { return MakeupPaint.Pigment() }
            let x=u*CGFloat(width-1),y=v*CGFloat(height-1)
            let ix=min(width-2,Int(x)),iy=min(height-2,Int(y)),dx=x-CGFloat(ix),dy=y-CGFloat(iy)
            func component(_ c: Int) -> CGFloat {
                let i=(iy*width+ix)*4+c
                let a=CGFloat(pixels[i])*(1-dx)+CGFloat(pixels[i+4])*dx
                let b=CGFloat(pixels[i+width*4])*(1-dx)+CGFloat(pixels[i+width*4+4])*dx
                return (a*(1-dy)+b*dy)/255
            }
            let alpha=component(3)
            guard alpha>0.0001 else { return MakeupPaint.Pigment() }
            return MakeupPaint.Pigment(r:component(0)/alpha,g:component(1)/alpha,b:component(2)/alpha,a:alpha)
        }
    }
    static let upperShade=Texture("eye-upper-shade")
    static let lowerShade=Texture("eye-lower-shade")
    static let upperPearl=Texture("eye-upper-pearl")
    static let lowerPearl=Texture("eye-lower-pearl")
    static let upperLip=Texture("lip-upper")
    static let lowerLip=Texture("lip-lower")
    static let peachUpper=Texture("peach-eye-upper")
    static let peachLower=Texture("peach-eye-lower")
    static var available: Bool { upperShade != nil && lowerShade != nil && upperLip != nil && lowerLip != nil }
}
