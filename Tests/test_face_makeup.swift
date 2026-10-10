import AppKit
import CoreImage
import Vision

@main
// Inputs are test subjects, separate from the user's makeup inspiration photos.
struct MakeupChecks {
    static func main() throws {
        setbuf(stdout, nil)
        let context = CIContext(options: [.cacheIntermediates: false])
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/makeup-checks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inputs = CommandLine.arguments.dropFirst().isEmpty ? ["website/assets/camera-presenter.png"] : Array(CommandLine.arguments.dropFirst())
        func raster(_ image: CIImage) -> CIImage { CIImage(cgImage: context.createCGImage(image, from: image.extent)!) }
        func bytes(_ image: CIImage) -> [UInt8] {
            let width = Int(image.extent.width), height = Int(image.extent.height)
            var pixels = [UInt8](repeating: 0, count: width*height*4)
            context.render(image, toBitmap: &pixels, rowBytes: width*4, bounds: image.extent, format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            return pixels
        }
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a,b).reduce(0) { $0+abs(Int($1.0)-Int($1.1)) } }
        for (index,input) in inputs.enumerated() {
            let source = CIImage(contentsOf: URL(fileURLWithPath: input))!
            let scale = min(1,1200/max(source.extent.width,source.extent.height))
            let image = raster(source.transformed(by: CGAffineTransform(scaleX:scale,y:scale)))
            let filter = FaceBeautyFilter(meshEnabled:false)
            let raw = bytes(image)
            precondition(filter.render(image, at: 0, amount: 0) === image)
            let settings = FaceMakeupSettings(amount: 1)
            let result = filter.render(image, at: 0, amount: 0, makeup: settings)
            guard let face = filter.lastDetectedGeometry else { fatalError("Test face \(index) not detected") }
            // Verify the production detector propagates actual revision-3 pose,
            // not just that synthetic pitch changes the projection helper.
            let poseScale = min(1,960/max(image.extent.width,image.extent.height))
            let poseRequest = VNDetectFaceRectanglesRequest()
            poseRequest.revision = VNDetectFaceRectanglesRequestRevision3
            try VNImageRequestHandler(ciImage:image.transformed(by:CGAffineTransform(scaleX:poseScale,y:poseScale))).perform([poseRequest])
            let expectedPose = poseRequest.results!.max { a,b in
                let x = a.boundingBox.intersection(face.bounds), y = b.boundingBox.intersection(face.bounds)
                return x.width*x.height < y.width*y.height
            }!
            precondition(expectedPose.pitch != nil)
            precondition(abs(face.pitch-expectedPose.pitch!.doubleValue) < 0.0001,"Production pitch must come from the independent pose detector")
            precondition(abs(face.lashYaw-expectedPose.yaw!.doubleValue) < 0.0001,"Production lash yaw must use continuous pose")
            print("Test face \(index): yaw=\(face.yaw), profile=\(face.isProfile), eye points=\(face.features[0].count)/\(face.features[1].count), mouth=\(face.innerLips.count)")
            let adjusted = bytes(result)
            precondition(difference(raw,adjusted)>500, "Makeup must change the image")
            _ = filter.render(image, at: 0, amount: 0, makeup: settings)
            precondition(filter.detectionCount == 1)
            let weak = bytes(FaceBeautyFilter(meshEnabled:false).render(image, at: 0, amount: 0, makeup: FaceMakeupSettings(amount:0.2)))
            precondition(difference(raw,adjusted)>difference(raw,weak)*2)
            let faceRect = CGRect(x:face.bounds.minX*image.extent.width,y:face.bounds.minY*image.extent.height,
                                  width:face.bounds.width*image.extent.width,height:face.bounds.height*image.extent.height)
            let crop = faceRect.insetBy(dx:-faceRect.width*0.22,dy:-faceRect.height*0.18).integral.intersection(image.extent)
            for (name,frame) in [("original",image),("peach",result)] {
                try context.writePNGRepresentation(of:frame.cropped(to:crop),to:directory.appendingPathComponent("\(index)-\(name).png"),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
            }
            for key in FaceMakeupSettings.keys.dropFirst() {
                var isolated = FaceMakeupSettings()
                for zero in FaceMakeupSettings.keys { isolated[keyPath:zero] = 0 }
                isolated.amount = 1; isolated[keyPath:key] = 1
                let rendered = key == \.skin ? FaceBeautyFilter(meshEnabled:false).render(image,at:0,amount:0,makeup:isolated) : FaceMakeupRenderer.render(image,face:face,current:face,settings:isolated,opacity:1)
                let renderedBytes = bytes(rendered)
                let diff = difference(raw,renderedBytes)
                if key != \.shortening && key != \.definition {
                    // Pupil centers, teeth/mouth interior and background must not
                    // receive pigment. The sample has an open smile on purpose.
                    var protected: [CGPoint] = [CGPoint(x:0.05,y:0.05)]
                    for points in [face.features[0],face.features[1],face.innerLips] where !points.isEmpty {
                        let x = points.map(\.x).reduce(0,+)/CGFloat(points.count)
                        let y = points.map(\.y).reduce(0,+)/CGFloat(points.count)
                        protected.append(CGPoint(x:x,y:y))
                    }
                    for point in protected {
                        let x = Int(point.x * image.extent.width), y = Int(image.extent.height)-1-Int(point.y * image.extent.height)
                        let pixel = (y * Int(image.extent.width) + x)*4
                        for channel in 0..<3 {
                            precondition(abs(Int(raw[pixel+channel])-Int(renderedBytes[pixel+channel])) <= 1,
                                         "Pigment leaked into a protected feature: \(key)")
                        }
                    }
                }
                print("  \(key): difference \(diff)")
                if (key != \.shortening && key != \.definition) || face.shapingVisibility > 0 { precondition(diff>0,"Individual control has no effect") }
                else { precondition(diff==0,"Do not shorten a full profile") }
            }
            // Quantized yaw and a profile flag flip must not turn shaping off.
            var turnTracker = FaceBeautyTracker()
            var frontal = face; frontal.yaw = 0; frontal.isProfile = false
            turnTracker.update(frontal,at:0)
            var turned = frontal; turned.yaw = .pi/4; turned.isProfile = true
            turnTracker.update(turned,at:1.0/30)
            precondition(turnTracker.geometry!.yaw > 0 && turnTracker.geometry!.yaw < .pi/4)
            precondition(turnTracker.geometry!.shapingVisibility > 0.95)
            for n in 2...30 { turnTracker.update(turned,at:Double(n)/30) }
            precondition(turnTracker.geometry!.shapingVisibility > 0.5)
            var profile = turned; profile.yaw = .pi/2
            precondition(profile.shapingVisibility == 0)
            var shape = FaceMakeupSettings()
            for key in FaceMakeupSettings.keys { shape[keyPath:key] = 0 }
            shape.amount = 1; shape.shortening = 1; shape.definition = 1
            precondition(difference(raw,bytes(FaceMakeupRenderer.render(image,face:turned,current:turned,settings:shape,opacity:1))) > 0)
            precondition(difference(raw,bytes(FaceMakeupRenderer.render(image,face:profile,current:profile,settings:shape,opacity:1))) == 0)

            // Rigid translation follows immediately; local brow jitter is reduced.
            var motionTracker = FaceBeautyTracker(); motionTracker.update(frontal,at:0)
            var shifted = frontal
            func translated(_ points:[CGPoint]) -> [CGPoint] { points.map { CGPoint(x:$0.x+0.04,y:$0.y+0.025) } }
            shifted.features = shifted.features.map(translated)
            shifted.contour = translated(shifted.contour); shifted.forehead = translated(shifted.forehead)
            shifted.innerLips = translated(shifted.innerLips)
            shifted.bounds = shifted.bounds.offsetBy(dx:0.04,dy:0.025)
            motionTracker.update(shifted,at:1.0/30)
            for i in 2...3 {
                for (a,b) in zip(motionTracker.geometry!.features[i],shifted.features[i]) {
                    precondition(hypot(a.x-b.x,a.y-b.y) < 0.000001,"Brow tint must follow whole-face motion immediately")
                }
            }
            var noiseTracker = FaceBeautyTracker(); noiseTracker.update(frontal,at:0)
            var rawNoise = 0.0, filteredNoise = 0.0
            for n in 1...60 {
                var noisy = frontal
                let noise = CGFloat(n % 2 == 0 ? 0.003 : -0.003)
                for i in 2...3 { noisy.features[i] = frontal.features[i].map { CGPoint(x:$0.x,y:$0.y+noise) } }
                noiseTracker.update(noisy,at:Double(n)/30)
                rawNoise += Double(noise*noise)
                let error = noiseTracker.geometry!.features[2][0].y-frontal.features[2][0].y
                filteredNoise += Double(error*error)
            }
            precondition(filteredNoise < rawNoise*0.15,"Landmark jitter must be suppressed without movement lag")
            print("PASS: continuous shaping through 45-degree turn, profile fade, motion compensation, brow jitter")
            // The lateral nose-tip branches must not be painted as bridge.
            let crest = [CGPoint(x:50,y:100),CGPoint(x:51,y:80),CGPoint(x:52,y:60),CGPoint(x:53,y:40),CGPoint(x:35,y:39),CGPoint(x:60,y:35)]
            precondition(FaceMakeupRenderer.noseBridge(crest,right:CGPoint(x:1,y:0)) == Array(crest.prefix(4)))
            let angle = CGFloat(0.55), axis = CGPoint(x:cos(angle),y:sin(angle))
            func rotate(_ p: CGPoint) -> CGPoint { CGPoint(x:p.x*cos(angle)-p.y*sin(angle),y:p.x*sin(angle)+p.y*cos(angle)) }
            let rotated = FaceMakeupRenderer.noseBridge(crest.map(rotate),right:axis)
            precondition(rotated.count == 4,"Nose-tip rejection must work during head roll")
            precondition(FaceMakeupRenderer.noseSideVisibility(projectedWidth:1,faceWidth:100) == 0)
            precondition(FaceMakeupRenderer.noseSideVisibility(projectedWidth:10,faceWidth:100) == 1)
            // Under-eye bands must follow the eyelid's rotation, with zero-width
            // ends instead of round gradient caps beyond the corners.
            let lid = [CGPoint(x:0,y:0),CGPoint(x:25,y:-6),CGPoint(x:50,y:-8),CGPoint(x:75,y:-6),CGPoint(x:100,y:0)]
            let band = FaceMakeupRenderer.underEyeBand(lid,distance:10,thickness:8)
            let rolledBand = FaceMakeupRenderer.underEyeBand(lid.map(rotate),distance:10,thickness:8)
            for (a,b) in zip(band.map(rotate),rolledBand) {
                precondition(hypot(a.x-b.x,a.y-b.y)<0.000001,"Under-eye offset must follow the local eyelid normal")
            }
            precondition(hypot(band.first!.x-band.last!.x,band.first!.y-band.last!.y)<0.000001)
            let centralBand = FaceMakeupRenderer.underEyeBand(lid,distance:10,thickness:8,range:0.20...0.80)
            precondition(centralBand.allSatisfy { $0.x > 10 && $0.x < 90 },"Aegyo must leave the tear duct and outer corner clear")
            precondition(hypot(centralBand.first!.x-centralBand.last!.x,centralBand.first!.y-centralBand.last!.y)<0.000001)
            print("PASS: nose-tip branch rejection, hidden-side fade, tapered under-eye bands through roll")
            // Closed upper lashes remain attached and turn down; lower lashes fade.
            var closed = face
            for i in 0..<2 {
                let points = closed.features[i].sorted { $0.x < $1.x }
                let a = points.first!, b = points.last!
                closed.features[i] = points.map { p in
                    let t = (p.x-a.x)/max(0.00001,b.x-a.x)
                    return CGPoint(x:p.x,y:a.y+(b.y-a.y)*t)
                }
            }
            var lashes = FaceMakeupSettings()
            for key in FaceMakeupSettings.keys { lashes[keyPath:key] = 0 }
            lashes.amount = 1; lashes.lashes = 1
            precondition(difference(raw,bytes(FaceMakeupRenderer.render(image,face:closed,current:closed,settings:lashes,opacity:1)))>100,"Upper lashes must remain visible on a closed lid")
            // Skin beneath the eye does not disappear when eyelids close.
            // A blink may reshape the fold, but must not gate pigment opacity.
            var aegyo = lashes; aegyo.lashes = 0; aegyo.aegyo = 1
            let openFold = bytes(FaceMakeupRenderer.render(image,face:face,current:face,settings:aegyo,opacity:1))
            let blinkFold = bytes(FaceMakeupRenderer.render(image,face:face,current:closed,settings:aegyo,opacity:1))
            precondition(difference(raw,blinkFold)>100,"Aegyo must remain visible during blinks")
            precondition(difference(openFold,blinkFold)<difference(raw,openFold)/20,"Blink detection must not pulse aegyo opacity")
            // No change in curve density as an interior landmark crosses baseline.
            let testEye = [CGPoint(x:0,y:0),CGPoint(x:25,y:8),CGPoint(x:75,y:8),
                           CGPoint(x:100,y:0),CGPoint(x:75,y:-8),CGPoint(x:25,y:-8)]
            var baselineNoise = testEye; baselineNoise[1].y = -0.001
            let curveA = FaceMakeupRenderer.underEyeCurve(testEye,right:CGPoint(x:1,y:0))
            let curveB = FaceMakeupRenderer.underEyeCurve(baselineNoise,right:CGPoint(x:1,y:0))
            precondition(curveA == curveB,"A baseline crossing must not alter under-eye pigment density")
            print("PASS: aegyo blink opacity and stable curve density")
            // Lashes fan away from the nose, taper at the tip, and keep the same
            // contour arcs during a baseline crossing instead of popping roots.
            let lids = FaceMakeupRenderer.eyelids(testEye,right:CGPoint(x:1,y:0))!
            let noisyLids = FaceMakeupRenderer.eyelids(baselineNoise,right:CGPoint(x:1,y:0))!
            precondition(lids.upper.count == noisyLids.upper.count)
            for side: CGFloat in [-1,1] {
                let hairs = FaceMakeupRenderer.lashHairs(lids,outerSign:side,amount:1,open:1,brow:[])
                let rolledLids = FaceMakeupRenderer.eyelids(testEye.map(rotate),right:axis)!
                let rolledHairs = FaceMakeupRenderer.lashHairs(rolledLids,outerSign:side,amount:1,open:1,brow:[])
                precondition(hairs.count == rolledHairs.count && hairs.count > 9)
                for (hair,rolled) in zip(hairs,rolledHairs) {
                    precondition((hair.tip.x-hair.root.x)*side > 0,"Inner lashes must not point toward the nose")
                    precondition(hair.tip.y > hair.root.y,"Upper lashes must project outside the eye")
                    let expected = rotate(hair.tip)
                    precondition(hypot(expected.x-rolled.tip.x,expected.y-rolled.tip.y)<0.000001)
                    precondition(hair.root.x > 0 && hair.root.x < 100,"Corner taper must leave the tear duct clear")
                    precondition(hair.outline[12] == hair.outline[13],"Lash tip must taper to zero width")
                }
                let closedHairs = FaceMakeupRenderer.lashHairs(lids,outerSign:side,amount:1,open:0,brow:[])
                precondition(closedHairs.count == hairs.count)
                for (opened,closedHair) in zip(hairs,closedHairs) {
                    precondition(opened.root == closedHair.root)
                    precondition(closedHair.tip.y < closedHair.root.y,"Closed upper lashes must point down")
                }
                precondition(FaceMakeupRenderer.lashHairs(lids,outerSign:side,amount:1,open:0,brow:[],lower:true).isEmpty)
            }
            print("PASS: curved lash fan, tapered tips, corner clearance, contour continuity and roll")
            // A downward nod projects a forward-growing upper lash toward the
            // eye; an upward nod exposes more of its curl. Roots must not move.
            let facing = FaceMakeupRenderer.lashHairs(lids,outerSign:1,amount:1,open:1,brow:[])
            let nodDown = FaceMakeupRenderer.lashHairs(lids,outerSign:1,amount:1,open:1,brow:[],pitch:0.65)
            let nodUp = FaceMakeupRenderer.lashHairs(lids,outerSign:1,amount:1,open:1,brow:[],pitch:-0.35)
            let rolledLids = FaceMakeupRenderer.eyelids(testEye.map(rotate),right:axis)!
            let rolledDown = FaceMakeupRenderer.lashHairs(rolledLids,outerSign:1,amount:1,open:1,brow:[],pitch:0.65)
            for n in facing.indices {
                precondition(facing[n].root == nodDown[n].root && facing[n].root == nodUp[n].root)
                precondition(nodDown[n].tip.y < nodDown[n].root.y,"Down-facing upper lashes must not stay screen-up")
                precondition(nodUp[n].tip.y > facing[n].tip.y,"Looking up must reveal more projected curl")
                let expected = rotate(nodDown[n].tip)
                precondition(hypot(expected.x-rolledDown[n].tip.x,expected.y-rolledDown[n].tip.y)<0.000001)
            }
            let horizontal = FaceMakeupRenderer.lashHairs(lids,outerSign:1,amount:1,open:1,brow:[],pitch:atan(0.72/1.28))
            for hair in horizontal {
                let points = hair.outline
                let area = abs(points.indices.reduce(CGFloat(0)) { sum,i in
                    let next = points[(i+1)%points.count]
                    return sum+points[i].x*next.y-next.x*points[i].y
                })/2
                precondition(area > 0.5,"Foreshortened horizontal lashes must retain ribbon coverage")
            }
            let turnedTip = FaceMakeupRenderer.projectLash(side:0,rise:1,depth:1.65,pitch:0,yaw:0.5)
            let oppositeTip = FaceMakeupRenderer.projectLash(side:0,rise:1,depth:1.65,pitch:0,yaw:-0.5)
            precondition(turnedTip.x > 0 && oppositeTip.x < 0)
            // Regression for the raised-eye frame near 7.4 s: upper fibers
            // must leave the margin toward the lid exterior. A negative first
            // control point made a hooked root inside an otherwise open eye.
            for side: CGFloat in [-1,1] {
                let lifted = FaceMakeupRenderer.lashHairs(lids,outerSign:side,amount:0.73,
                    open:1,brow:[],pitch:0.15,yaw:0.27,lidPitch:-0.02)
                for hair in lifted {
                    for n in 1...4 {
                        let middleY = (hair.outline[n].y+hair.outline[25-n].y)/2
                        precondition(middleY >= hair.root.y,"Raised-eye lashes must not hook below their roots")
                    }
                }
            }
            // Head angle alone misses downward gaze. Lower the upper arc while
            // retaining the eye corners and lower lid, with a stationary head.
            let neutralEye = testEye.map { CGPoint(x:$0.x,y:$0.y > 0 ? $0.y*2.5 : $0.y) }
            let neutralLids = FaceMakeupRenderer.eyelids(neutralEye,right:CGPoint(x:1,y:0))!
            let loweredEye = neutralEye.map { CGPoint(x:$0.x,y:$0.y > 0 ? $0.y*0.55 : $0.y) }
            let loweredLids = FaceMakeupRenderer.eyelids(loweredEye,right:CGPoint(x:1,y:0))!
            let loweredAngle = FaceMakeupRenderer.lidPitch(loweredLids)
            precondition(loweredAngle > FaceMakeupRenderer.lidPitch(neutralLids)+0.2)
            let loweredFan = FaceMakeupRenderer.lashHairs(loweredLids,outerSign:1,amount:1,open:1,brow:[],lidPitch:loweredAngle)
            let frozenFan = FaceMakeupRenderer.lashHairs(loweredLids,outerSign:1,amount:1,open:1,brow:[])
            for (down,frozen) in zip(loweredFan,frozenFan) {
                precondition(down.root == frozen.root)
                precondition(down.tip.y < down.root.y,"Lowered eyelids must rotate lashes down even without a head nod")
                precondition(down.tip.y < frozen.tip.y)
            }
            var beforeLid = face, afterLid = face
            beforeLid.lashLidPitch = [0,0]; afterLid.lashLidPitch = [0.6,0.6]
            let stableLid = afterLid.blended(from:beforeLid,amount:0.4,poseAmount:0.4)
            precondition(stableLid.lashLidPitch.allSatisfy { abs($0-0.24)<0.0001 },"Lid direction must not snap with landmark noise")
            print("PASS: up/down pitch projection, yaw direction, attached roots and horizontal ribbon coverage")
            // Nonzero total energy alone missed almost invisible subpixel hairs.
            // At actual preview eye sizes, moderate mascara must darken multiple
            // pixels perceptibly, including at fractional pixel translations.
            let previewSize = CGSize(width:960,height:540)
            let neutral = CIImage(color:CIColor(red:0.70,green:0.70,blue:0.70))
                .cropped(to:CGRect(origin:.zero,size:previewSize))
            let neutralBytes = bytes(neutral)
            var previewLashes = lashes; previewLashes.lashes = 0.73
            for eyeWidth: CGFloat in [20,28,40] {
                for phase: CGFloat in [0,0.25,0.5,0.75] {
                    var previewFace = face
                    previewFace.pitch = 0; previewFace.lashYaw = 0
                    previewFace.lashLidPitch = [0,0]
                    previewFace.bounds = CGRect(x:0.35,y:0.3,width:0.18,height:0.45)
                    for i in 0..<2 {
                        previewFace.features[i] = testEye.map { point in
                            CGPoint(x:(380+CGFloat(i)*75+point.x/100*eyeWidth+phase)/previewSize.width,
                                    y:(300+point.y/100*eyeWidth*2)/previewSize.height)
                        }
                        previewFace.features[i+2] = []
                    }
                    let visible = bytes(FaceMakeupRenderer.render(neutral,face:previewFace,current:previewFace,
                                                                  settings:previewLashes,opacity:1))
                    let darkPixels = stride(from:0,to:visible.count,by:4).filter {
                        Int(neutralBytes[$0])-Int(visible[$0]) >= 12
                    }.count
                    precondition(darkPixels >= 12,"Lashes vanished at preview eye width \(eyeWidth), phase \(phase): \(darkPixels) visible pixels")
                    // Contrast at the roots can pass while the extensions are
                    // still invisible against a real eyelid. Require visible
                    // tips above the entire synthetic upper-lid envelope too.
                    let tipBoundary = Int(previewSize.height)-1-Int(300+eyeWidth*0.24)
                    let extendedPixels = stride(from:0,to:visible.count,by:4).filter {
                        let row = ($0/4)/Int(previewSize.width)
                        return row < tipBoundary && Int(neutralBytes[$0])-Int(visible[$0]) >= 12
                    }.count
                    precondition(extendedPixels >= 6,"Lash contrast must extend above the eyelid: \(eyeWidth), \(phase), \(extendedPixels)")
                    if phase == 0 {
                        let fullResolution = neutral.transformed(by:CGAffineTransform(scaleX:2,y:2))
                        let editorLashes = FaceMakeupRenderer.render(fullResolution,face:previewFace,current:previewFace,
                            settings:previewLashes,opacity:1).transformed(by:CGAffineTransform(scaleX:0.5,y:0.5))
                        let liveEnergy = difference(neutralBytes,visible)
                        let editorEnergy = difference(neutralBytes,bytes(editorLashes))
                        let ratio = Double(editorEnergy)/Double(max(1,liveEnergy))
                        precondition(ratio > 0.80 && ratio < 1.25,"Editor downsampling must retain live lash visibility: \(eyeWidth), ratio \(ratio)")
                    }
                }
            }
            print("PASS: visible lash contrast at 20/28/40 px eye widths and subpixel motion")
            // Current lids move while the skin tracker still holds older geometry.
            // Lash placement must match rendering with fresh geometry throughout.
            var movedEyes = face
            for i in 0..<2 { movedEyes.features[i] = face.features[i].map { CGPoint(x:$0.x,y:$0.y+0.012) } }
            let lagged = FaceMakeupRenderer.render(image,face:face,current:movedEyes,settings:lashes,opacity:1)
            let fresh = FaceMakeupRenderer.render(image,face:movedEyes,current:movedEyes,settings:lashes,opacity:1)
            precondition(difference(bytes(lagged),bytes(fresh)) <= 2,"Lashes must not lag behind the current eyelid")
            // A synthetic foreground region over the lips must restore raw
            // pixels even when makeup and shape warping have already rendered.
            let mouth = face.features[6]
            let center = CGPoint(x:mouth.map(\.x).reduce(0,+)/CGFloat(mouth.count),y:mouth.map(\.y).reduce(0,+)/CGFloat(mouth.count))
            let covering = FaceHandGeometry(palm:mouth,fingers:[],wrist:center,
                knuckles:CGPoint(x:center.x,y:center.y+0.03),palmWidth:face.bounds.width*image.extent.width*0.15)
            let occlusion = FaceBeautyFilter.handMask([(covering,1)],size:image.extent.size)!
            let restored = image.applyingFilter("CIBlendWithMask",parameters:[
                kCIInputBackgroundImageKey:result,kCIInputMaskImageKey:occlusion])
            let restoredBytes = bytes(restored)
            for point in mouth {
                let x=Int(point.x*image.extent.width),y=Int(image.extent.height)-1-Int(point.y*image.extent.height)
                let pixel=(y*Int(image.extent.width)+x)*4
                for channel in 0..<3 {
                    precondition(abs(Int(restoredBytes[pixel+channel])-Int(raw[pixel+channel]))<=1,
                                 "Foreground hand interior must retain raw pixels")
                }
            }
            // A feathered perimeter must contain partial opacity, not a hard cut.
            let maskPixels = bytes(occlusion)
            precondition(stride(from:0,to:maskPixels.count,by:4).contains { maskPixels[$0]>10 && maskPixels[$0]<240 })
            print("PASS: foreground protection after shaping and feathered occlusion boundary")
            // Cover only one part of the lip. The uncovered pigment must stay
            // unchanged, rather than applying a mouth-wide visibility switch.
            var partialLipSettings = lashes; partialLipSettings.lashes = 0; partialLipSettings.lips = 1
            let fullLip = bytes(FaceMakeupRenderer.render(image,face:face,current:face,settings:partialLipSettings,opacity:1))
            let mouthMinX = mouth.map(\.x).min()!, mouthMaxX = mouth.map(\.x).max()!
            let mouthMinY = mouth.map(\.y).min()!, mouthMaxY = mouth.map(\.y).max()!
            let fullBlack = CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:image.extent)
            for fraction: CGFloat in [0.20,0.40,0.60] {
                let coveredRect = CGRect(x:mouthMinX*image.extent.width-4,y:mouthMinY*image.extent.height-8,
                    width:(mouthMaxX-mouthMinX)*image.extent.width*fraction+4,
                    height:(mouthMaxY-mouthMinY)*image.extent.height+16).integral
                let partial = CIImage(color:CIColor(red:1,green:1,blue:1)).cropped(to:coveredRect).composited(over:fullBlack)
                    .applyingGaussianBlur(sigma:1).cropped(to:image.extent)
                let partialPixels = bytes(partial)
                let partialLip = bytes(FaceMakeupRenderer.render(image,face:face,current:face,
                    settings:partialLipSettings,opacity:1,handProtection:partial))
                var visibleEffect = 0, coveredEffect = 0
                for i in stride(from:0,to:raw.count,by:4) {
                    if partialPixels[i] == 0 {
                        for c in 0..<3 {
                            precondition(abs(Int(partialLip[i+c])-Int(fullLip[i+c]))<=1,"Visible lip must retain pigment beside the finger")
                            visibleEffect += abs(Int(partialLip[i+c])-Int(raw[i+c]))
                        }
                    } else if partialPixels[i] == 255 {
                        for c in 0..<3 { coveredEffect = max(coveredEffect,abs(Int(partialLip[i+c])-Int(raw[i+c]))) }
                    }
                }
                precondition(visibleEffect>100,"Partial occlusion must not disable all lipstick")
                precondition(coveredEffect<=1,"Covered lip must not paint the foreground finger")
            }
            print("PASS: partial-lip occlusion retains visible pigment and excludes covered pixels")
            // A sharp finger edge across the lower face must not be copied into
            // neighboring skin by shaping, even outside the final restore mask.
            let frame = image.extent
            let fingerRect = CGRect(x:(face.bounds.midX+face.bounds.width*0.20)*frame.width,
                                    y:(face.bounds.minY-face.bounds.height*0.10)*frame.height,
                                    width:max(3,face.bounds.width*frame.width*0.035),
                                    height:face.bounds.height*frame.height*0.60).integral
            let black = CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:frame)
            let fingerMask = CIImage(color:CIColor(red:1,green:1,blue:1)).cropped(to:fingerRect).composited(over:black)
            let fingerImage = CIImage(color:CIColor(red:0.12,green:0.12,blue:0.12)).cropped(to:fingerRect)
                .composited(over:CIImage(color:CIColor(red:0.65,green:0.65,blue:0.65)).cropped(to:frame))
            let beforeProtection = FaceMakeupRenderer.render(fingerImage,face:frontal,current:frontal,settings:shape,opacity:1)
            let restoredLate = fingerImage.applyingFilter("CIBlendWithMask",parameters:[
                kCIInputBackgroundImageKey:beforeProtection,kCIInputMaskImageKey:fingerMask])
            let protectedShape = FaceMakeupRenderer.render(fingerImage,face:frontal,current:frontal,settings:shape,opacity:1,
                                                          handProtection:fingerMask)
            precondition(difference(bytes(fingerImage),bytes(restoredLate))>100,"Fixture must expose a displaced finger edge")
            precondition(difference(bytes(fingerImage),bytes(protectedShape))<=4,"Shaping must not duplicate a foreground edge")
            print("PASS: hand-aware shaping prevents duplicated finger edges beyond the restore mask")
            // Even plausible (hallucinated) lip landmarks must not paint fabric.
            var lipOnly = aegyo; lipOnly.aegyo = 0; lipOnly.lips = 1
            var noLip = lipOnly; noLip.lips = 0
            for cloth in [CIColor(red:0.48,green:0.58,blue:0.63),CIColor(red:0.65,green:0.65,blue:0.65)] {
                let sleeve = CIImage(color:cloth).cropped(to:image.extent)
                let painted = FaceMakeupRenderer.render(sleeve,face:face,current:face,settings:lipOnly,opacity:1)
                let baseline = FaceMakeupRenderer.render(sleeve,face:face,current:face,settings:noLip,opacity:1)
                precondition(difference(bytes(painted),bytes(baseline)) == 0,"Lip tint must not appear on blue or neutral fabric")
            }
            let spread = FaceHandGeometry(palm:[CGPoint(x:0.34,y:0.2),CGPoint(x:0.66,y:0.2),CGPoint(x:0.66,y:0.4),CGPoint(x:0.34,y:0.4)],
                fingers:[[CGPoint(x:0.34,y:0.4),CGPoint(x:0.28,y:0.85)],[CGPoint(x:0.66,y:0.4),CGPoint(x:0.72,y:0.85)]],
                wrist:CGPoint(x:0.5,y:0.2),knuckles:CGPoint(x:0.5,y:0.4),palmWidth:image.extent.width*0.32)
            let spreadPixels = bytes(FaceBeautyFilter.handMask([(spread,1)],size:image.extent.size)!)
            let gap = ((Int(image.extent.height)-1-Int(image.extent.height*0.72))*Int(image.extent.width)+Int(image.extent.width*0.5))*4
            precondition(spreadPixels[gap] < 5,"Open spaces between fingers must preserve visible face makeup")
            var hands = FaceHandTracker()
            _ = hands.update([spread,covering],at:0)
            precondition(hands.update([spread],at:0.04).count == 2,"Other-hand detection must not clear a missing hand")
            precondition(hands.update([spread],at:0.2).count == 2)
            precondition(hands.update([spread],at:0.32).count == 1)
            var visibility = FaceMakeupVisibility()
            visibility.update(detected:true,at:0)
            for n in 1...12 {
                visibility.update(detected:n % 2 == 0,at:Double(n)/30)
                precondition(visibility.amount == 0,"Intermittent reacquisition must not flash makeup back on")
            }
            var previous = 0.0
            for n in 13...36 {
                visibility.update(detected:true,at:Double(n)/30)
                precondition(visibility.amount >= previous && visibility.amount-previous < 0.15)
                previous = visibility.amount
            }
            precondition(visibility.amount == 1)
            visibility.update(detected:true,at:0)
            precondition(visibility.amount == 1,"Seeking must not retain recovery state")
            print("PASS: sleeve lip rejection, finger gaps, independent hand retention, nonflashing reacquisition")
            let blank = CIImage(color:.gray).cropped(to:image.extent)
            precondition(FaceBeautyFilter(meshEnabled:false).render(blank,at:0,amount:0,makeup:settings) === blank)
            // Loss must not leave a stale cosmetics overlay even for one frame.
            precondition(filter.render(blank,at:1.0/30,amount:0,makeup:settings) === blank)
            var times: [Double] = []; let moving = FaceBeautyFilter(meshEnabled:false); var detections = 0
            for frame in 0..<20 {
                autoreleasepool {
                    let shift = sin(Double(frame)/6)*18
                    let translated = image.transformed(by:CGAffineTransform(translationX:shift,y:0)).composited(over:blank).cropped(to:image.extent)
                    let start = Date()
                    _ = bytes(moving.render(translated,at:Double(frame)/30,amount:0,makeup:settings))
                    times.append(Date().timeIntervalSince(start))
                    if moving.lastDetectedGeometry != nil { detections += 1 }
                }
            }
            precondition(detections>=18)
            times.sort(); print("PASS: components, intensity, blink, off/lost face, cache; motion \(detections)/20, median \(Int(times[10]*1000))ms, p95 \(Int(times[18]*1000))ms")
        }
    }
}
