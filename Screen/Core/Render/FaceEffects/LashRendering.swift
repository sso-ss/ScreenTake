import AppKit
import Vision
import CoreImage

struct PhotoGeometry {
    var eyes: [[CGPoint]]
    var brows: [[CGPoint]]
    var yaw: CGFloat
    var pitch: CGFloat
    var trackingOpacity: CGFloat = 1
    var bounds: CGRect = .zero
    var surfaces: [LashSurface] = []
    var meshWeight: CGFloat = 0
    var eyeVisibility: [CGFloat] = [1,1]
    var observedRoll: CGFloat? = nil
    var makeup: MakeupGeometry? = nil
    var eyeModelUsed: [Bool] = [false,false]
    /// Positive Vision yaw exposes the image-left eye. Fade the far lid before
    /// the nose occludes it instead of drawing a guessed eye on the profile.
    static func visibility(yaw: CGFloat) -> [CGFloat] {
        guard yaw.isFinite else { return [1,1] }
        let t = min(1,max(0,(abs(yaw)-55 * .pi/180)/(27 * .pi/180)))
        let far = 1-t*t*(3-2*t)
        return yaw >= 0 ? [1,far] : [far,1]
    }
    var roll: CGFloat {
        if let observedRoll, observedRoll.isFinite { return observedRoll }
        guard eyes.count == 2 else { return 0 }
        func center(_ eye:[CGPoint]) -> CGPoint {
            CGPoint(x:eye.map(\.x).reduce(0,+)/CGFloat(eye.count),y:eye.map(\.y).reduce(0,+)/CGFloat(eye.count))
        }
        if !eyes[0].isEmpty, !eyes[1].isEmpty {
            let a = center(eyes[0]), b = center(eyes[1])
            if hypot(b.x-a.x,b.y-a.y) > 1 { return atan2(b.y-a.y,b.x-a.x) }
        }
        // A profile need not have a second eye. Its observed corner chord can
        // still align the local mesh crop without a fabricated far-eye center.
        for eye in eyes {
            if let lids = LashGeometry.eyelids(eye,right:CGPoint(x:1,y:0)) {
                return atan2(lids.right.y,lids.right.x)
            }
        }
        return 0
    }
}

enum LashRendering {
    #if !SCREENTAKE_RUNTIME
    static let meshDetector = LashMeshDetector()
    static let irisDetector = LashIrisDetector()
    private static let meshLock = NSLock()
    #endif
    static let ci = CIContext(options: [.cacheIntermediates: false])
    static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    static func load(_ url: URL) throws -> CGImage {
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw NSError(domain: "LashLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "사진을 열 수 없습니다."])
        }
        let scale = min(1, 1400 / max(source.extent.width, source.extent.height))
        let resized = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ci.createCGImage(resized, from: resized.extent)!
    }
    #if !SCREENTAKE_RUNTIME
    static func detect(_ image: CGImage, inspect: ((String,PhotoGeometry) -> Void)? = nil) throws -> PhotoGeometry? {
        let request = VNDetectFaceLandmarksRequest()
        let pose = VNDetectFaceRectanglesRequest()
        pose.revision = VNDetectFaceRectanglesRequestRevision3
        try VNImageRequestHandler(cgImage: image).perform([request, pose])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let marks = face.landmarks else { return nil }
        let box = face.boundingBox
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.normalizedPoints ?? []).map { p in
                CGPoint(x: (box.minX + CGFloat(p.x) * box.width) * CGFloat(image.width),
                        y: (box.minY + CGFloat(p.y) * box.height) * CGFloat(image.height))
            }
        }
        let matched = pose.results?.max { a, b in
            let x = a.boundingBox.intersection(box), y = b.boundingBox.intersection(box)
            return x.width*x.height < y.width*y.height
        }
        var result = PhotoGeometry(eyes: [points(marks.leftEye), points(marks.rightEye)],
                             brows: [points(marks.leftEyebrow), points(marks.rightEyebrow)],
                             yaw: CGFloat(matched?.yaw?.doubleValue ?? face.yaw?.doubleValue ?? 0),
                             pitch: CGFloat(matched?.pitch?.doubleValue ?? face.pitch?.doubleValue ?? 0))
        result.bounds = CGRect(x: box.minX*CGFloat(image.width),y: box.minY*CGFloat(image.height),
                               width: box.width*CGFloat(image.width),height: box.height*CGFloat(image.height))
        if let roll = matched?.roll?.doubleValue ?? face.roll?.doubleValue, roll.isFinite {
            result.observedRoll = CGFloat(roll)
        }
        result.eyeVisibility = PhotoGeometry.visibility(yaw:result.yaw)
        for index in 0..<2 {
            let eye = result.eyes[index]
            // Preserve independently observed lids until the temporal tracker
            // validates pose. One bad yaw estimate must not erase a good eye.
            guard eye.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  let lids = LashGeometry.eyelids(eye,right:CGPoint(x:1,y:0)),
                  lids.width >= max(2,result.bounds.width*0.012) else {
                result.eyes[index] = []
                result.eyeVisibility[index] = 0
                continue
            }
        }
        guard result.eyes.contains(where:{ !$0.isEmpty }) else { return nil }
        inspect?("vision",result)
        meshLock.lock()
        let mesh = meshDetector.detect(CIImage(cgImage: image),face: result)
        meshLock.unlock()
        result.surfaces = mesh?.surfaces(size: CGSize(width: image.width,height: image.height)) ?? []
        result.meshWeight = result.surfaces.count == 2 ? 1 : 0
        if let mesh {
            result.makeup = MakeupGeometry(mesh:mesh,size:CGSize(width:image.width,height:image.height),
                outerLips:points(marks.outerLips),innerLips:points(marks.innerLips),faceContour:points(marks.faceContour))
            var fusedEyes: [[CGPoint]] = []
            if let inspect {
                var meshOnly=result
                meshOnly.eyes=LashMesh.eyes.map { mesh.polygon($0).map { CGPoint(x:$0.x*CGFloat(image.width),y:$0.y*CGFloat(image.height)) } }
                inspect("mesh",meshOnly)
            }
            for (index,indices) in LashMesh.eyes.enumerated() {
                let points = mesh.polygon(indices).map { CGPoint(x:$0.x*CGFloat(image.width),y:$0.y*CGFloat(image.height)) }
                guard let observed = LashGeometry.eyelids(result.eyes[index],right:CGPoint(x:1,y:0),cornerHints:[points[0],points[8]]),
                      let detailed = LashGeometry.eyelids(points,right:CGPoint(x:1,y:0),cornerHints:[points[0],points[8]]) else {
                    fusedEyes.append([])
                    continue
                }
                fusedEyes.append(LashEyeRefinement.contour(detailed:detailed,observed:observed))
            }
            result.eyes = fusedEyes
        }
        inspect?("fused",result)
        meshLock.lock()
        let eyeRefinements=irisDetector.refine(result.eyes,image:CIImage(cgImage:image))
        meshLock.unlock()
        result.eyeModelUsed=eyeRefinements.map { $0 != nil }
        // The old pixel fitter remains a per-eye fallback for rejected inference.
        let fallback=eyeRefinements.contains(where:{ $0 == nil }) ? LashEyeRefinement.refine(result.eyes,image:image) : result.eyes
        result.eyes=result.eyes.indices.map { eyeRefinements[$0] ?? fallback[$0] }
        inspect?("eye-model",result)
        let margins=LashEyeRefinement.refine(result.eyes.enumerated().map { result.eyeModelUsed[$0.offset] ? $0.element : [] },image:image,upperOnly:true)
        result.eyes=result.eyes.indices.map { result.eyeModelUsed[$0] ? margins[$0] : result.eyes[$0] }
        inspect?("refined",result)
        return result
    }
    #endif
    static func drawHairs(_ hairs: [LashGeometry.LashHair], in context: CGContext, intensity: CGFloat) {
        for hair in hairs {
            guard let first = hair.outline.first else { continue }
            context.saveGState()
            context.beginPath(); context.move(to: first)
            hair.outline.dropFirst().forEach { context.addLine(to: $0) }
            context.closePath(); context.clip()
            let alpha = hair.opacity * intensity
            let colors = [CGColor(red: 0.075, green: 0.045, blue: 0.035, alpha: alpha),
                          CGColor(red: 0.075, green: 0.045, blue: 0.035, alpha: alpha * 0.92),
                          CGColor(red: 0.075, green: 0.045, blue: 0.035, alpha: alpha * 0.40)]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0,0.72,1])!
            context.drawLinearGradient(gradient, start: hair.root, end: hair.tip, options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
            context.restoreGState()
        }
    }
    struct EyeState {
        var aperture: CGFloat
        var open: CGFloat
        var lowerVisibility: CGFloat
    }
    struct EyePass {
        var state: EyeState
        var surface: LashSurface
        var upper: [LashGeometry.LashHair]
        var lower: [LashGeometry.LashHair]
    }
    static func eyeState(lids: LashGeometry.Eyelids,index: Int,pose: LashPose) -> EyeState {
        let frame = pose.frame(eye:index)
        let ratio = min(6,1/max(1.0/6,hypot(CGFloat(frame.right.x),CGFloat(frame.right.y))))
        let projection = LashGeometry.apertureProjection(lids,yaw:pose.yaw,pitch:pose.pitch,
            surface:pose.surface(eye:index,widthRatio:ratio))
        let aperture = lids.opening/projection
        return EyeState(aperture:aperture,open:min(1,max(0,(aperture-0.025)/0.13)),
                        lowerVisibility:min(1,max(0,(aperture-0.025)/0.075)))
    }
    /// All previews infer blinks and project fibers through this path. Mesh
    /// depth contributes physical width; measured head pose owns orientation.
    static func eyePass(lids: LashGeometry.Eyelids,index: Int,brow: [CGPoint],pose: LashPose,
                        options: LashOptions,observedSurface: LashSurface? = nil,
                        meshWeight: CGFloat = 0,rasterScale: CGFloat = 1) -> EyePass {
        let frame = pose.frame(eye:index)
        let poseRatio = min(6,1/max(1.0/6,hypot(CGFloat(frame.right.x),CGFloat(frame.right.y))))
        let mix = observedSurface == nil ? 0 : min(1,max(0,meshWeight))
        let ratio = poseRatio+((observedSurface?.widthRatio ?? poseRatio)-poseRatio)*mix
        let surface = pose.surface(eye:index,widthRatio:ratio)
        // Blink state must not change when a depth estimate drops out. The
        // same observed lids and pose always produce the same curl phase.
        let state = eyeState(lids:lids,index:index,pose:pose)
        let compact=options.makeup.effective.enabled && options.makeup.look == .softPeach && options.style == .wispy
        func hairs(lower: Bool) -> [LashGeometry.LashHair] {
            LashGeometry.lashHairs(lids,outerSign:index == 0 ? -1 : 1,amount:options.intensity,
                open:state.open,brow:brow,lower:lower,rasterScale:rasterScale,pitch:pose.pitch,yaw:pose.yaw,
                style:options.style,lengthScale:lower ? options.lowerLength : options.length,surface:surface,meshWeight:1,
                compactWispy:compact)
        }
        return EyePass(state:state,surface:surface,upper:hairs(lower:false),
                       lower:options.lower ? hairs(lower:true) : [])
    }

    static func photo(_ sourceImage: CGImage, face originalFace: PhotoGeometry?, options: LashOptions, handProtection: HandProtection? = nil) -> CGImage {
        guard let originalFace, !options.showOriginal else { return sourceImage }
        let protection=options.handOcclusion ? handProtection : nil
        let makeup=options.makeup.effective
        let skin=makeup.enabled ? MakeupSkinSmoothing.apply(sourceImage,face:originalFace,amount:makeup.skin,protection:protection) : sourceImage
        let (image,face)=makeup.enabled
            ? MakeupFaceShape.apply(skin,face:originalFace,amount:makeup.faceShape,look:makeup.look,protection:protection)
            : (sourceImage,originalFace)
        let ctx = context(image.width, image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let makeupFace=makeup.enabled && makeup.lips>0
            ? MakeupLipVolume.apply(in:ctx,image:image,face:face,amount:makeup.lipVolume,
                upperOverline:makeup.look == .softPeach ? 1 : 0,protection:protection)
            : face
        MakeupRendering.draw(in:ctx,face:makeupFace,options:makeup)
        // Smudge the final pigment as well as the photographed lip edge.
        // Painting after this pass would recreate a sharp lipstick boundary.
        if makeup.enabled,makeup.look == .softPeach {
            MakeupLipSmudge.apply(in:ctx,face:makeupFace,amount:makeup.lips,blur:makeup.lipBlur)
        }
        for i in 0..<2 {
            let observedVisibility = face.eyeVisibility.count == 2 ? face.eyeVisibility[i] : 1
            let eyeVisibility = min(observedVisibility,PhotoGeometry.visibility(yaw:face.yaw)[i])
            guard eyeVisibility > 0.001 else { continue }
            guard let lids = LashGeometry.eyelids(face.eyes[i], right: CGPoint(x: 1, y: 0)) else { continue }
            let surface = face.surfaces.count == 2 ? face.surfaces[i] : nil
            let pass = eyePass(lids:lids,index:i,brow:face.brows[i],pose:LashPose(yaw:face.yaw,pitch:face.pitch,roll:face.roll),
                options:options,observedSurface:surface,meshWeight:face.meshWeight,
                rasterScale:CGFloat(max(image.width,image.height))/960)
            let alpha = options.intensity * face.trackingOpacity * eyeVisibility
            drawHairs(pass.upper,in:ctx,intensity:alpha)
            drawHairs(pass.lower,in:ctx,intensity:alpha*pass.state.lowerVisibility)
            if options.showTracking {
                for (line,color) in [(lids.upper,CGColor(red:0,green:0.85,blue:1,alpha:0.95)),
                                     (lids.lower,CGColor(red:1,green:0.65,blue:0,alpha:0.95))] {
                    ctx.setStrokeColor(color); ctx.setLineWidth(0.8)
                    ctx.beginPath(); ctx.move(to:line[0]); line.dropFirst().forEach { ctx.addLine(to:$0) }; ctx.strokePath()
                    ctx.setFillColor(color)
                    for point in line.enumerated() where point.offset % 4 == 0 {
                        ctx.fillEllipse(in:CGRect(x:point.element.x-1,y:point.element.y-1,width:2,height:2))
                    }
                }
            }
        }
        #if !SCREENTAKE_RUNTIME
        if options.showFaceTracking { FaceDiagnostics.draw(in:ctx,face:makeupFace) }
        #endif
        let rendered=ctx.makeImage()!
        return protection?.restoring(rendered,source:sourceImage) ?? rendered
    }
    static func cameraDiagram(_ face: PhotoGeometry,options: LashOptions) -> CGImage {
        let pose = LashPose(yaw:face.yaw,pitch:face.pitch,roll:face.roll)
        let apertures: [CGFloat] = (0..<2).map { index in
            guard let lids = LashGeometry.eyelids(face.eyes[index],right:CGPoint(x:1,y:0)) else { return 0 }
            return eyeState(lids:lids,index:index,pose:pose).aperture
        }
        return diagram(options:options,yaw:pose.yaw,pitch:pose.pitch,roll:pose.roll,
            apertures:apertures,eyeVisibility:face.eyeVisibility)
    }
    static func cameraComposite(_ image: CGImage,diagram: CGImage) -> CGImage {
        let ctx = context(image.width,image.height)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        ctx.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        let margin = width*0.015, insetWidth = width*0.25
        let insetHeight = insetWidth*CGFloat(diagram.height)/CGFloat(diagram.width)
        let box = CGRect(x:width-insetWidth-margin,y:margin,width:insetWidth,height:insetHeight)
        ctx.setFillColor(CGColor(gray:0.97,alpha:1))
        ctx.fill(box.insetBy(dx:-5,dy:-5))
        ctx.draw(diagram,in:box)
        return ctx.makeImage()!
    }
    static func diagram(options: LashOptions, yaw: CGFloat = 0, pitch: CGFloat = 0, open: CGFloat = 1, roll: CGFloat = 0,
                        apertures: [CGFloat]? = nil,eyeVisibility: [CGFloat]? = nil) -> CGImage {
        let ctx = context(1000, 520)
        ctx.setFillColor(CGColor(red: 0.96, green: 0.91, blue: 0.86, alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: 1000,height: 520))
        let pose = LashPose(yaw:yaw,pitch:pitch,roll:roll)
        func path(_ points:[CGPoint],fill:CGColor? = nil,stroke:CGColor? = nil,width:CGFloat = 1) {
            guard let first = points.first else { return }
            ctx.beginPath(); ctx.move(to:first); points.dropFirst().forEach { ctx.addLine(to:$0) }
            if let fill { ctx.closePath(); ctx.setFillColor(fill); ctx.fillPath() }
            if let stroke {
                ctx.beginPath(); ctx.move(to:first); points.dropFirst().forEach { ctx.addLine(to:$0) }
                ctx.setStrokeColor(stroke); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.strokePath()
            }
        }
        let line = CGColor(red:0.35,green:0.19,blue:0.14,alpha:0.65)
        let nose: [SIMD3<Double>] = [SIMD3(0,115,20),SIMD3(0,-25,140),SIMD3(-30,-42,65),SIMD3(30,-42,65)]
        path(nose.map { pose.project($0) },stroke:CGColor(red:0.55,green:0.35,blue:0.25,alpha:0.28),width:2)
        let eyes = [0,1].compactMap { index -> LashPose.Eye? in
            if let eyeVisibility, eyeVisibility.count == 2, eyeVisibility[index] <= 0.001 { return nil }
            var opening = open
            if let apertures, apertures.count == 2, let full = pose.eye(index,open:1) {
                let reference = eyeState(lids:full.lids,index:index,pose:pose).aperture
                opening = min(1,max(0,apertures[index]/max(0.001,reference)))
            }
            return pose.eye(index,open:opening)
        }.sorted { $0.depth < $1.depth }
        for eye in eyes {
            ctx.saveGState(); ctx.setAlpha(eye.visibility)
            let lids = eye.lids
            let contour = lids.upper + lids.lower.reversed()
            path(contour,fill:CGColor(red:1,green:0.985,blue:0.96,alpha:1))
            ctx.saveGState()
            ctx.beginPath(); ctx.move(to:contour[0]); contour.dropFirst().forEach { ctx.addLine(to:$0) }; ctx.closePath(); ctx.clip()
            path(eye.iris,fill:CGColor(red:0.36,green:0.31,blue:0.20,alpha:1))
            path(eye.pupil,fill:CGColor(gray:0.035,alpha:1))
            ctx.restoreGState()
            path(lids.upper,stroke:line,width:1.7); path(lids.lower,stroke:line,width:1.7)
            path(eye.brow,stroke:CGColor(red:0.35,green:0.22,blue:0.16,alpha:0.35),width:7)
            if !options.showOriginal {
                let pass = eyePass(lids:lids,index:eye.side < 0 ? 0 : 1,brow:eye.brow,pose:pose,
                    options:options,observedSurface:eye.surface,meshWeight:1)
                drawHairs(pass.upper,in:ctx,intensity:options.intensity)
                drawHairs(pass.lower,in:ctx,intensity:options.intensity*pass.state.lowerVisibility)
            }
            if options.showTracking {
                path(lids.upper,stroke:CGColor(red:0,green:0.85,blue:1,alpha:0.95),width:1.7)
                path(lids.lower,stroke:CGColor(red:1,green:0.65,blue:0,alpha:0.95),width:1.7)
            }
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }
    static func save(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
    static func sheet(_ images: [(String,CGImage)], columns: Int, cell: CGSize) -> CGImage {
        let rows = (images.count + columns - 1)/columns
        let ctx = context(Int(cell.width)*columns, Int(cell.height)*rows)
        ctx.setFillColor(CGColor(gray: 0.98,alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: ctx.width,height: ctx.height))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (index,item) in images.enumerated() {
            let x = CGFloat(index%columns)*cell.width, y = CGFloat(rows-1-index/columns)*cell.height
            let area = CGRect(x: x+12,y: y+12,width: cell.width-24,height: cell.height-48)
            let scale = min(area.width/CGFloat(item.1.width),area.height/CGFloat(item.1.height))
            let w = CGFloat(item.1.width)*scale, h = CGFloat(item.1.height)*scale
            ctx.draw(item.1,in: CGRect(x: area.midX-w/2,y: area.midY-h/2,width: w,height: h))
            (item.0 as NSString).draw(at: CGPoint(x: x+18,y: y+cell.height-30),withAttributes: [.font:NSFont.systemFont(ofSize: 15,weight: .semibold),.foregroundColor:NSColor.darkGray])
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
