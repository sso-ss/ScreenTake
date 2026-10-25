import CoreImage
import CoreGraphics

/// Softens the final lip/skin transition after pigment, within the outer-lip
/// band only. Teeth and the inner seam are excluded from the blur.
enum MakeupLipSmudge {
    static func apply(in ctx:CGContext,face:PhotoGeometry,amount:CGFloat,blur:CGFloat) {
        let softness=MakeupPaint.clamp(blur)
        let strength=MakeupPaint.clamp(amount)*MakeupPaint.clamp(face.trackingOpacity)*MakeupPaint.clamp(face.makeup?.opacity ?? 0)
        guard softness>0,strength>0,let g=face.makeup,g.lipsReliable,
              let frame=MakeupLipFrame(outer:g.outerLips,axis:CGPoint(x:cos(face.roll),y:sin(face.roll))),
              frame.containsOpening(g.innerLips,outer:g.outerLips),let source=ctx.makeImage() else { return }
        let w=frame.width,outline=MakeupPaint.lipPath(g.outerLips)
        let box=outline.boundingBoxOfPath.insetBy(dx:-w*0.13,dy:-w*0.13).integral
            .intersection(CGRect(x:0,y:0,width:source.width,height:source.height))
        guard box.width>2,box.height>2 else { return }
        let maskContext=LashRendering.context(Int(box.width),Int(box.height))
        maskContext.setFillColor(CGColor(gray:0,alpha:1));maskContext.fill(CGRect(origin:.zero,size:box.size))
        maskContext.translateBy(x:-box.minX,y:-box.minY)
        maskContext.setStrokeColor(CGColor(gray:strength*(0.40+0.50*softness),alpha:1))
        maskContext.setLineWidth(w*(0.030+0.085*softness))
        maskContext.setLineJoin(.round);maskContext.setLineCap(.round)
        maskContext.addPath(outline);maskContext.strokePath()
        guard let maskImage=maskContext.makeImage() else { return }
        let input=CIImage(cgImage:source)
        let mask=CIImage(cgImage:maskImage).transformed(by:CGAffineTransform(translationX:box.minX,y:box.minY))
            .applyingGaussianBlur(sigma:max(0.55,w*0.013)).cropped(to:box)
        let blurred=input.clampedToExtent().applyingGaussianBlur(sigma:max(0.60,w*(0.010+0.034*softness)))
        let blended=blurred.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:input,kCIInputMaskImageKey:mask])
        guard let result=LashRendering.ci.createCGImage(blended,from:box) else { return }
        // A nearly closed mouth retraces its polygon at the corners. Clipping
        // an expanded stroke with even-odd winding can leave holes there. A
        // filled grayscale mask takes the union of the seam and its padding.
        guard let protected=CGContext(data:nil,width:Int(box.width),height:Int(box.height),
            bitsPerComponent:8,bytesPerRow:Int(box.width),space:CGColorSpaceCreateDeviceGray(),
            bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return }
        protected.setShouldAntialias(false)
        protected.setFillColor(gray:1,alpha:1);protected.fill(CGRect(origin:.zero,size:box.size))
        protected.translateBy(x:-box.minX,y:-box.minY)
        protected.setFillColor(gray:0,alpha:1);protected.setStrokeColor(gray:0,alpha:1)
        protected.setLineWidth(max(2,w*0.025)*2)
        protected.setLineJoin(.round);protected.setLineCap(.round)
        protected.addPath(MakeupPaint.path(g.innerLips,smooth:false));protected.drawPath(using:.fillStroke)
        guard let mouthMask=protected.makeImage() else { return }
        ctx.saveGState();defer { ctx.restoreGState() }
        ctx.clip(to:box,mask:mouthMask)
        ctx.draw(result,in:box)
    }
}
