import AppKit
import CoreImage
#if IMPORT_BUILT_APP
@testable import ScreenTake
#endif

@main
struct FaceBeautyChecks {
    static func main() throws {
        setbuf(stdout, nil)
        let context = CIContext(options: [.cacheIntermediates: false])
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent(".build/beauty-checks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let portrait = CIImage(contentsOf: root.appendingPathComponent("website/assets/camera-presenter.png"))!
        let scaled = portrait.transformed(by: CGAffineTransform(scaleX: 2.0/3, y: 2.0/3))
        // Compare the same raster pixels; otherwise CI can choose different
        // downsampling optimizations for a bare transform and a kernel sampler.
        let image = CIImage(cgImage: context.createCGImage(scaled, from: scaled.extent)!)
        let bounds = image.extent
        func bytes(_ image: CIImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: 512*512*4)
            context.render(image, toBitmap: &pixels, rowBytes: 512*4, bounds: bounds, format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            return pixels
        }
        let filter = FaceBeautyFilter(meshEnabled:false)
        precondition(filter.render(image, at: 0, amount: 0) === image)
        precondition(filter.detectionCount == 0)
        let strong = filter.render(image, at: 0, amount: 1)
        let raw = bytes(image), adjusted = bytes(strong)
        guard let geometry = filter.lastDetectedGeometry else { fatalError("No face landmarks detected") }
        let mask = FaceBeautyFilter.mask(geometry, protecting: geometry, size: bounds.size)!
        let maskBytes = bytes(mask)
        var changed = 0, protectedError = 0, skinDifference = 0.0, skinCount = 0
        for index in stride(from: 0, to: raw.count, by: 4) {
            let diff = (0..<3).map { abs(Int(raw[index+$0])-Int(adjusted[index+$0])) }.max()!
            if diff > 1 { changed += 1 }
            if maskBytes[index] == 0 { protectedError = max(protectedError,diff) }
            if maskBytes[index] > 180 { skinDifference += Double(diff); skinCount += 1 }
        }
        print("Pixel checks: changed=\(changed), protectedError=\(protectedError)")
        try context.writePNGRepresentation(of: strong, to: output.appendingPathComponent("strong.png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        try context.writePNGRepresentation(of: mask, to: output.appendingPathComponent("mask.png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        precondition(changed > 500, "High intensity must visibly change skin")
        precondition(protectedError <= 1, "Protected features and background must remain unchanged")
        let weak = FaceBeautyFilter(meshEnabled:false).render(image, at: 0, amount: 0.2)
        let weakBytes = bytes(weak)
        let strongTotal = zip(raw,adjusted).map { abs(Int($0)-Int($1)) }.reduce(0,+)
        let weakTotal = zip(raw,weakBytes).map { abs(Int($0)-Int($1)) }.reduce(0,+)
        precondition(strongTotal > weakTotal*2)
        _ = filter.render(image, at: 0, amount: 1)
        precondition(filter.detectionCount == 1, "Repeated presentation of a camera frame should reuse its result")
        var tracker = FaceBeautyTracker()
        tracker.update(geometry, at: 0)
        precondition(tracker.opacity == 1)
        tracker.update(nil, at: 0.033)
        precondition(tracker.opacity > 0 && tracker.opacity < 1)
        tracker.update(nil, at: 0.11)
        precondition(tracker.opacity == 0 && tracker.geometry == nil)
        tracker.update(geometry, at: 0.14)
        precondition(tracker.opacity > 0 && tracker.opacity < 1)
        tracker.update(geometry, at: 0.01)
        precondition(tracker.opacity == 1, "Seeking starts fresh, including when paused")
        var profile = geometry
        profile.isProfile = true
        profile.features[0] = []
        precondition(FaceBeautyFilter.mask(profile, protecting: profile, size: bounds.size) != nil)
        let blank = CIImage(color: .gray).cropped(to: bounds)
        precondition(FaceBeautyFilter(meshEnabled:false).render(blank, at: 0, amount: 1) === blank)
        precondition(FaceBeautyFilter.clamped(.nan) == 0 && FaceBeautyFilter.clamped(2) == 1)
        print("PASS: off/no face, feature protection, intensity range, duplicate frames, loss/recovery, seeking, partial landmarks")
        print("High intensity: \(changed) changed pixels; mean skin difference \(skinDifference/Double(skinCount)); maximum protected difference \(protectedError)")
        try context.writePNGRepresentation(of: strong, to: output.appendingPathComponent("strong.png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        try context.writePNGRepresentation(of: mask, to: output.appendingPathComponent("mask.png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let moving = FaceBeautyFilter(meshEnabled:false)
        var detected = 0, durations: [Double] = []
        for index in 0..<45 {
            autoreleasepool {
                let shift = sin(Double(index)/12)*35
                let frame = image.transformed(by: CGAffineTransform(translationX: shift,y: 0)).composited(over: blank).cropped(to: bounds)
                let start = Date()
                _ = bytes(moving.render(frame, at: Double(index)/30, amount: 0.75))
                durations.append(Date().timeIntervalSince(start))
                if moving.lastDetectedGeometry != nil { detected += 1 }
            }
        }
        precondition(detected >= 40, "Moving portrait should remain tracked")
        durations.sort()
        print("PASS: actual Vision detection on \(detected)/45 translated frames; median \(Int(durations[22]*1000)) ms, p95 \(Int(durations[42]*1000)) ms including rendering")
    }
}
