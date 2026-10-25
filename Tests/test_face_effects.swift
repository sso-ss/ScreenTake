import AppKit
import CoreImage
@testable import ScreenTake


private struct CheckFailure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String = "Check failed",
                     file: StaticString = #fileID, line: UInt = #line) throws {
    if !condition() { throw CheckFailure(message: "\(file):\(line): \(message)") }
}

@main
struct FaceEffectsChecks {
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent(".build/soft-peach-integration/checks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixturePath = CommandLine.arguments.dropFirst().first ?? "website/assets/camera-presenter.png"
        let source = try LashRendering.load(root.appendingPathComponent(fixturePath))
        let image = CIImage(cgImage: source)
        func raster(_ image: CIImage) -> CGImage { LashRendering.ci.createCGImage(image, from: image.extent)! }
        func bytes(_ image: CGImage) -> [UInt8] {
            let ctx = LashRendering.context(image.width, image.height)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        func difference(_ a: CGImage, _ b: CGImage) -> Int {
            zip(bytes(a), bytes(b)).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        }
        let old = try JSONDecoder().decode(FaceMakeupSettings.self, from: Data("{\"amount\":0.7,\"lashes\":0.65}".utf8))
        try require(old.preset == .peachMakeup && old.lipBlur == 0.78 && old.lashes == 0.65)
        try require(CameraEffectStyle.availableCases == [.natural, .softPeach], "Only Natural and Soft Peach should be offered")
        var retired = VideoEditSettings()
        retired.cameraEffectSelection = .init(style: .peachMakeup, intensity: 0.63)
        retired.faceMakeup = old
        retired.migrateRetiredCameraEffect()
        try require(retired.cameraEffectSelection?.style == .softPeach && retired.faceMakeup?.preset == .softPeach)
        try require(retired.faceMakeup?.amount == old.amount, "Migration must preserve the active intensity")
        try require(retired.faceMakeup?.shortening == old.shortening,"Migration must preserve Shorter face")
        retired.faceMakeup?.amount = 0
        retired.migrateRetiredCameraEffect()
        try require(!retired.cameraEffectsEnabled && retired.resolvedCameraEffectSelection.style == .softPeach,
                    "Migrating an off style must not turn it on")
        var settings = VideoEditSettings()
        let selection = CameraEffectSelection(style: .softPeach, intensity: 0.7)
        settings.setCameraEffect(selection, enabled: true)
        try require(settings.faceMakeup?.preset == .softPeach && settings.faceMakeup?.amount == 0.7)
        settings.faceMakeup!.lipBlur = 0.91; settings.faceMakeup!.lipVolume = 0.63
        settings.setCameraEffect(selection, enabled: false)
        try require(!settings.cameraEffectsEnabled && settings.resolvedCameraEffectSelection == selection)
        settings.setCameraEffect(selection, enabled: true)
        try require(settings.faceMakeup?.lipBlur == 0.91 && settings.faceMakeup?.lipVolume == 0.63)
        let decoded = try JSONDecoder().decode(VideoEditSettings.self, from: JSONEncoder().encode(settings))
        try require(decoded == settings)
        print("PASS: old-project migration, Soft Peach persistence, disabled selection and custom lip controls")

        let filter = FaceBeautyFilter()
        var soft = FaceMakeupSettings.softPeach; soft.amount = 1
        let full = filter.render(image, at: 1, amount: 0, makeup: soft)
        guard let geometry = filter.lastDetectedGeometry else { throw CheckFailure(message: filter.meshError ?? "Native face missing") }
        try require(geometry.mesh?.points.count == 468 && geometry.features[0].count == 64 && geometry.features[1].count == 64)
        try require(!filter.lastUsedFaceFallback && filter.detectionCount == 1)
        try require(filter.render(image, at: 1, amount: 0, makeup: soft) === full)
        var alternate = soft; alternate.lipBlur = 0.3
        _ = filter.render(image, at: 1, amount: 0, makeup: alternate)
        try require(filter.detectionCount == 1, "Changing controls must reuse current geometry")
        _ = filter.render(image, at: 1.0001, amount: 0, makeup: soft)
        try require(filter.lastDetectedGeometry != nil, "Submillisecond source times must still progress")
        _ = filter.render(image, at: 0.25, amount: 0, makeup: soft)
        try require(filter.lastDetectedGeometry != nil, "Backward seek must reacquire")
        let blank = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: image.extent)
        try require(filter.render(blank, at: 0.29, amount: 0, makeup: soft) === blank)
        try require(filter.lastDetectedGeometry == nil && filter.lastHandMask == nil)
        _ = filter.render(image, at: 0.33, amount: 0, makeup: soft)
        try require(filter.lastDetectedGeometry != nil)
        try require(filter.render(image, at: 0.37, amount: 0) === image && filter.lastDetectedGeometry == nil)
        print("PASS: native VIDEO geometry, cache, settings repaint, timestamp rounding, seek, loss/reacquisition and off bypass")

        // Natural must ignore every remembered cosmetic control, including a
        // previously selected Soft Peach preset, and preserve eyes/lip pigment.
        let naturalFilter = FaceBeautyFilter()
        let natural = raster(naturalFilter.render(image, at: 1, amount: 0.8))
        guard let naturalFace = naturalFilter.lastDetectedGeometry else {
            throw CheckFailure(message: "Natural face missing")
        }
        var dormantSoft = FaceMakeupSettings.softPeach
        dormantSoft.amount = 0
        for key in FaceMakeupSettings.keys where key != \.amount { dormantSoft[keyPath: key] = 1 }
        let afterSoft = raster(naturalFilter.render(image, at: 1, amount: 0.8, makeup: dormantSoft))
        try require(difference(natural, afterSoft) == 0, "Natural inherited disabled Soft Peach controls")
        var dormantPeach = FaceMakeupSettings()
        dormantPeach.skin = 0; dormantPeach.lips = 1; dormantPeach.blush = 1
        let afterPeach = raster(naturalFilter.render(image, at: 1, amount: 0.8, makeup: dormantPeach))
        try require(difference(natural, afterPeach) == 0, "Natural inherited disabled Peach controls")
        let inputPixels = bytes(source), naturalPixels = bytes(natural)
        var protectedPixels = 0
        // These samples sit inside the observed eye and mouth interiors. A
        // tinted lip/lash layer or a face warp would change their source pixels.
        for index in [0, 1, 6] {
            let points = naturalFace.features[index]
            let x = Int(points.map(\.x).reduce(0,+) / CGFloat(points.count) * CGFloat(source.width))
            let y = Int(points.map(\.y).reduce(0,+) / CGFloat(points.count) * CGFloat(source.height))
            for row in max(0,y-1)...min(source.height-1,y+1) {
                for column in max(0,x-1)...min(source.width-1,x+1) {
                    let offset = ((source.height - 1 - row) * source.width + column) * 4
                    for channel in 0..<3 {
                        try require(abs(Int(inputPixels[offset+channel])-Int(naturalPixels[offset+channel])) <= 1,
                                    "Natural changed protected eye/lip pigment")
                    }
                    protectedPixels += 1
                }
            }
        }
        try require(difference(source, natural) > 100, "Natural skin pass must still reduce fine lines")
        try require(naturalFace.features[2].count == 10 && naturalFace.features[3].count == 10,
                    "Legacy makeup needs closed brow perimeters")
        print("PASS: Natural ignores remembered cosmetics; \(protectedPixels) eye/lip pixels preserved; closed Peach brow contours")

        var panels: [(String, CGImage)] = [("Original", source)]
        var report: [[String: Any]] = []
        for intensity in [0.3, 1.0] {
            var rendered: [CGImage] = []
            for style in CameraEffectStyle.availableCases {
                let amounts = CameraEffectSelection(style: style, intensity: intensity).amounts(enabled: true, makeup: .init())
                let instance = FaceBeautyFilter()
                let start = CFAbsoluteTimeGetCurrent()
                let result = raster(instance.render(image, at: 1, amount: amounts.natural, makeup: amounts.makeup))
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                try require(instance.lastDetectedGeometry != nil)
                rendered.append(result)
                let name = "\(style.rawValue)-\(Int(intensity * 100))"
                try LashRendering.save(result, to: output.appendingPathComponent(name + ".png"))
                panels.append(("\(style.displayName) \(Int(intensity * 100))%", result))
                report.append(["style": style.rawValue, "intensity": intensity, "coldMS": ms, "differenceFromOriginal": difference(source, result)])
            }
            try require(difference(rendered[0], rendered[1]) > 2000,
                "Natural and Soft Peach must produce distinct pixels at equal intensity")
        }
        try LashRendering.save(LashRendering.sheet(panels, columns: 3, cell: CGSize(width: 332, height: 530)), to: output.appendingPathComponent("styles.png"))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("styles.json"))
        print("PASS: only Natural and Soft Peach are offered, with separate rendering at 30% and 100%")

        let tracker = LashFaceLandmarker(video: false)
        guard let face = tracker.detect(source), let g = face.makeup else { throw CheckFailure(message: tracker.error ?? "Fixture detection failed") }

        // Actual source hairs must remain readable, rather than becoming a
        // uniformly painted brow. Test dark hairs and bare gaps independently.
        let browFixture = LashRendering.context(source.width, source.height)
        browFixture.setFillColor(CGColor(red: 0.72, green: 0.60, blue: 0.50, alpha: 1))
        browFixture.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        var browPaths: [CGPath] = []
        for index in 0..<2 {
            let top = g.polygon(MakeupBrows.upper[index]), bottom = g.polygon(MakeupBrows.lower[index])
            browPaths.append(MakeupPaint.path(top + bottom.reversed()))
            let width = MakeupPaint.distance(top[0],top.last!)
            browFixture.setStrokeColor(CGColor(red: 0.22, green: 0.17, blue: 0.14, alpha: 1))
            browFixture.setLineWidth(max(0.8,width*0.008))
            for step in 1..<32 {
                let t = CGFloat(step)/32*4, i = min(3,Int(t)), f = t-CGFloat(i)
                let low = MakeupPaint.mix(bottom[i],bottom[i+1],f)
                let high = MakeupPaint.mix(top[i],top[i+1],f)
                browFixture.move(to: MakeupPaint.mix(low,high,0.12))
                browFixture.addLine(to: MakeupPaint.mix(low,high,0.86))
                browFixture.strokePath()
            }
        }
        let bareBrows = browFixture.makeImage()!
        func powderBrows() -> CGImage {
            let ctx = LashRendering.context(source.width,source.height)
            ctx.draw(bareBrows,in:CGRect(x:0,y:0,width:source.width,height:source.height))
            MakeupBrows.draw(in:ctx,face:face,geometry:g,amount:1,look:.softPeach)
            return ctx.makeImage()!
        }
        let powder = powderBrows(), beforeBrows = bytes(bareBrows), afterBrows = bytes(powder)
        let skinRed = Int(beforeBrows[0])
        try require(difference(powder,powderBrows()) == 0,"Brow texture must not change randomly between frames")
        var hairDelta = 0, hairCount = 0, gapDelta = 0, gapCount = 0
        for row in 0..<source.height { for column in 0..<source.width {
            let p = CGPoint(x:CGFloat(column)+0.5,y:CGFloat(source.height-row)-0.5)
            guard browPaths.contains(where: { $0.contains(p) }) else { continue }
            let i = (row*source.width+column)*4
            let change = abs(Int(beforeBrows[i])-Int(afterBrows[i]))
            // Classify by contrast to the rendered skin: Core Graphics color
            // conversion and subpixel antialiasing lift the thin hair strokes.
            if CGFloat(beforeBrows[i]) < CGFloat(skinRed)*0.80 { hairDelta += change; hairCount += 1 }
            if Int(beforeBrows[i]) >= skinRed-1 { gapDelta += change; gapCount += 1 }
        } }
        try LashRendering.save(bareBrows,to:output.appendingPathComponent("brow-fixture-source.png"))
        try LashRendering.save(powder,to:output.appendingPathComponent("brow-fixture-powder.png"))
        try require(hairCount > 15 && gapCount > 50,"Brow regression must contain real hair and skin gaps (\(hairCount) / \(gapCount), skin=\(skinRed))")
        try require(Double(hairDelta)/Double(hairCount) < 8,"Powder obscured already dark source hairs")
        try require(Double(gapDelta)/Double(gapCount) < 4,"Brow gaps became a solid pigment stencil")
        try require(difference(bareBrows,powder) > 50,"Eyebrow control must still apply subtle powder")
        try LashRendering.save(LashRendering.sheet([("Source hairs",bareBrows),("Soft powder",powder)],columns:2,
            cell:CGSize(width:332,height:230)),to:output.appendingPathComponent("brow-texture.png"))
        print("PASS: soft brows preserve \(hairCount) dark hair pixels and \(gapCount) skin gaps; deterministic between frames")

        var shortened = FaceMakeupSettings.softPeach; shortened.amount = 1
        let lengthFilter = FaceBeautyFilter()
        let normalLength = raster(lengthFilter.render(image,at:2,amount:0,makeup:shortened))
        shortened.shortening = 1
        let shorterLength = raster(lengthFilter.render(image,at:2,amount:0,makeup:shortened))
        try require(difference(normalLength,shorterLength) > 100,"Soft Peach must retain the Shorter face control")
        shortened.amount = 0
        try require(lengthFilter.render(image,at:2,amount:0,makeup:shortened) === image,"Effects off must also disable Shorter face")
        print("PASS: Soft Peach Shorter face control changes output independently and turns off with the effect")

        var timings: [String: Double] = [:]
        for name in ["none", "skin", "shape", "lashes", "contour", "blush", "eyes", "brows", "lips", "volume", "smudge"] {
            var value = MakeupLook.softPeach.defaults
            value.intensity = name == "lashes" ? 0.72 : 0
            value.makeup.skin = name == "skin" ? 0.78 : 0
            value.makeup.faceShape = name == "shape" ? 0.28 : 0
            value.makeup.contour = name == "contour" ? 0.42 : 0
            value.makeup.blush = name == "blush" ? 0.62 : 0
            value.makeup.eyes = name == "eyes" ? 0.8 : 0
            value.makeup.brows = name == "brows" ? 0.6 : 0
            value.makeup.lips = ["lips", "volume", "smudge"].contains(name) ? 1 : 0
            value.makeup.lipVolume = name == "volume" ? 0.55 : 0
            value.makeup.lipBlur = name == "smudge" ? 0.78 : 0
            _ = LashRendering.photo(source, face: face, options: value)
            let start = CFAbsoluteTimeGetCurrent()
            _ = LashRendering.photo(source, face: face, options: value)
            timings[name] = (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        try JSONSerialization.data(withJSONObject: timings, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("render-passes.json"))
        let ctx = LashRendering.context(source.width, source.height)
        let size = CGSize(width: source.width, height: source.height)
        ctx.setFillColor(CGColor(red: 0.74, green: 0.60, blue: 0.54, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(red: 0.49, green: 0.17, blue: 0.23, alpha: 1)); ctx.addPath(MakeupPaint.lipPath(g.outerLips)); ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.addPath(MakeupPaint.path(g.innerLips, smooth: false)); ctx.fillPath()
        let fixture = ctx.makeImage()!
        var options = MakeupLook.softPeach.defaults
        options.intensity = 0; options.makeup.skin = 0; options.makeup.faceShape = 0
        options.makeup.contour = 0; options.makeup.blush = 0; options.makeup.eyes = 0; options.makeup.brows = 0
        options.makeup.lipVolume = 0; options.makeup.lipBlur = 1
        let painted = LashRendering.context(source.width, source.height)
        painted.draw(fixture, in: CGRect(origin: .zero, size: size))
        MakeupRendering.draw(in: painted, face: face, options: options.makeup)
        let sharp = painted.makeImage()!
        MakeupLipSmudge.apply(in: painted, face: face, amount: 1, blur: 1)
        let smudged = painted.makeImage()!
        let pipeline = LashRendering.photo(fixture, face: face, options: options)
        try require(difference(pipeline, smudged) == 0, "The final camera path must apply smudge after pigment")
        try LashRendering.save(sharp, to: output.appendingPathComponent("lip-fixture-sharp.png"))
        try LashRendering.save(smudged, to: output.appendingPathComponent("lip-fixture-smudged.png"))
        let a = bytes(sharp), b = bytes(smudged)
        let outer = MakeupPaint.lipPath(g.outerLips), inner = MakeupPaint.path(g.innerLips, smooth: false)
        let frame = MakeupLipFrame(outer: g.outerLips, axis: CGPoint(x: cos(face.roll), y: sin(face.roll)))!
        let region = outer.boundingBoxOfPath.insetBy(dx: -frame.width * 0.15, dy: -frame.width * 0.15)
        var outsideChanged = 0, insideChanged = 0, mouthPixels = 0
        var invalid = 0
        for row in 0..<source.height { for col in 0..<source.width {
            let index = (row * source.width + col) * 4
            let p = CGPoint(x: CGFloat(col) + 0.5, y: CGFloat(source.height - row) - 0.5)
            if inner.contains(p) || !region.contains(p) {
                if a[index..<index+3] != b[index..<index+3] {
                    invalid += 1
                }
                if inner.contains(p) { mouthPixels += 1 }
            }
            if abs(Int(a[index])-Int(b[index])) > 3 {
                if outer.contains(p) { insideChanged += 1 } else { outsideChanged += 1 }
            }
        } }
        try require(invalid == 0)
        try require(insideChanged > 20 && outsideChanged > 20 && mouthPixels > 0)
        try LashRendering.save(LashRendering.sheet([("Sharp pigment", sharp), ("Final smudge", smudged)], columns: 2, cell: size), to: output.appendingPathComponent("lip-smudge-fixture.png"))
        var lipOnly = MakeupLook.softPeach.defaults
        lipOnly.intensity = 0; lipOnly.makeup.skin = 0; lipOnly.makeup.faceShape = 0
        lipOnly.makeup.contour = 0; lipOnly.makeup.blush = 0; lipOnly.makeup.eyes = 0; lipOnly.makeup.brows = 0
        lipOnly.makeup.lipBlur = 0
        let before = LashRendering.photo(source, face: face, options: lipOnly)
        lipOnly.makeup.lipBlur = 0.78
        let after = LashRendering.photo(source, face: face, options: lipOnly)
        let crop = CGRect(x: region.minX, y: region.minY, width: region.width, height: region.height).integral
        func closeup(_ image: CGImage) -> CGImage {
            let context = LashRendering.context(Int(crop.width * 5), Int(crop.height * 5))
            context.scaleBy(x: 5, y: 5)
            context.draw(image, in: CGRect(x: -crop.minX, y: -crop.minY, width: CGFloat(image.width), height: CGFloat(image.height)))
            return context.makeImage()!
        }
        try LashRendering.save(LashRendering.sheet([("Smudge 0%", closeup(before)), ("Smudge 78%", closeup(after))], columns: 2, cell: CGSize(width: 600, height: 330)), to: output.appendingPathComponent("lip-closeup.png"))
        print("PASS: final-pigment smudge crosses lip border (\(insideChanged) inside / \(outsideChanged) outside); \(mouthPixels) mouth pixels and distant skin preserved")
        print("PASS: all face effect integration checks")
    }
}
