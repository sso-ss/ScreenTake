import Foundation
import Vision
import CoreImage
import CoreGraphics

// Hand geometry, short dropout tracking and articulated mask copied from
// Screen/Core/Render/FaceBeautyFilter.swift. Face coordinates stay in MediaPipe.
/// Articulated hand geometry leaves gaps between fingers unmasked.
#if !SCREENTAKE_RUNTIME
struct FaceHandGeometry {
    var palm: [CGPoint]
    var fingers: [[CGPoint]]
    var wrist: CGPoint
    var knuckles: CGPoint
    var palmWidth: CGFloat

    init?(observation: VNHumanHandPoseObservation, imageSize: CGSize) {
        guard let joints = try? observation.recognizedPoints(.all) else { return nil }
        func point(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let p = joints[name], p.confidence > 0.2 else { return nil }
            return p.location
        }
        guard let w = point(.wrist), let index = point(.indexMCP), let little = point(.littleMCP) else { return nil }
        wrist = w
        knuckles = CGPoint(x:(index.x+little.x)/2,y:(index.y+little.y)/2)
        palmWidth = hypot((index.x-little.x)*imageSize.width,(index.y-little.y)*imageSize.height)
        guard palmWidth > 3 else { return nil }
        palm = [.wrist,.thumbCMC,.thumbMP,.indexMCP,.middleMCP,.ringMCP,.littleMCP].compactMap(point)
        let names: [[VNHumanHandPoseObservation.JointName]] = [
            [.thumbCMC,.thumbMP,.thumbIP,.thumbTip], [.indexMCP,.indexPIP,.indexDIP,.indexTip],
            [.middleMCP,.middlePIP,.middleDIP,.middleTip], [.ringMCP,.ringPIP,.ringDIP,.ringTip],
            [.littleMCP,.littlePIP,.littleDIP,.littleTip]]
        // Stop at a missing joint instead of drawing across an uncertain finger.
        fingers = names.map { names in
            var line: [CGPoint] = []
            for name in names { guard let p = point(name) else { break }; line.append(p) }
            return line
        }
    }

    func overlaps(_ rect: CGRect, imageSize: CGSize) -> Bool {
        func intersects(_ points: [CGPoint], radius: CGFloat) -> Bool {
            guard !points.isEmpty else { return false }
            let box = CGRect(x:points.map(\.x).min()!,y:points.map(\.y).min()!,
                width:points.map(\.x).max()!-points.map(\.x).min()!,
                height:points.map(\.y).max()!-points.map(\.y).min()!)
                .insetBy(dx:-radius/imageSize.width,dy:-radius/imageSize.height)
            return box.intersects(rect)
        }
        if intersects(palm,radius:palmWidth*0.18) { return true }
        for finger in fingers {
            for index in 1..<max(1,finger.count) {
                if intersects([finger[index-1],finger[index]],radius:palmWidth*0.20) { return true }
            }
        }
        let sleeve = CGPoint(x:wrist.x+(wrist.x-knuckles.x)*0.9,y:wrist.y+(wrist.y-knuckles.y)*0.9)
        return intersects([wrist,sleeve],radius:palmWidth*0.5)
    }

    init(palm: [CGPoint], fingers: [[CGPoint]], wrist: CGPoint, knuckles: CGPoint, palmWidth: CGFloat) {
        self.palm = palm; self.fingers = fingers; self.wrist = wrist; self.knuckles = knuckles; self.palmWidth = palmWidth
    }
}

/// Match hands independently: observing the other hand must not erase the
/// protection for one that is briefly lost behind a sleeve or the face.
struct FaceHandTracker {
    struct Entry { var hand: FaceHandGeometry; var lastSeen: Double }
    private var entries: [Entry] = []
    private var time: Double?
    mutating func update(_ hands: [FaceHandGeometry], at next: Double) -> [(FaceHandGeometry, CGFloat)] {
        if let time, next < time || next-time > 0.25 { entries = [] }
        time = next
        var old = entries, updated: [Entry] = []
        for hand in hands {
            if let index = old.indices.min(by: {
                hypot(old[$0].hand.wrist.x-hand.wrist.x,old[$0].hand.wrist.y-hand.wrist.y) <
                hypot(old[$1].hand.wrist.x-hand.wrist.x,old[$1].hand.wrist.y-hand.wrist.y)
            }), hypot(old[index].hand.wrist.x-hand.wrist.x,old[index].hand.wrist.y-hand.wrist.y) < 0.25 {
                old.remove(at:index)
            }
            updated.append(Entry(hand:hand,lastSeen:next))
        }
        entries = updated + old.filter { next-$0.lastSeen < 0.28 }
        return entries.map { ($0.hand,CGFloat(min(1,max(0,(0.28-(next-$0.lastSeen))/0.16)))) }
    }
}


#endif

/// Per-stream hand detector. The input and mask belong to the same camera frame.
final class ScreenTakeHandOcclusion {
    private let request=VNDetectHumanHandPoseRequest()
    private var tracker=FaceHandTracker()
    private(set) var detectedCount=0
    private(set) var error:String?
    init() { request.maximumHandCount=2 }
    func reset() { tracker=FaceHandTracker();detectedCount=0;error=nil }
    func detect(_ image:CGImage,at seconds:Double) -> HandProtection? {
        guard seconds.isFinite else { reset();return nil }
        let source=CIImage(cgImage:image),bounds=source.extent
        let scale=min(1,640/max(bounds.width,bounds.height))
        let small=source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        do {
            try VNImageRequestHandler(ciImage:small,options:[:]).perform([request])
            let hands=(request.results ?? []).compactMap { FaceHandGeometry(observation:$0,imageSize:small.extent.size) }
            detectedCount=hands.count;error=nil
            guard let mask=Self.handMask(tracker.update(hands,at:seconds),size:small.extent.size) else { return nil }
            return HandProtection(mask:mask.transformed(by:CGAffineTransform(scaleX:1/scale,y:1/scale)).cropped(to:bounds),size:bounds.size)
        } catch { reset();self.error=String(describing:error);return nil }
    }
    static func handMask(_ hands: [(FaceHandGeometry, CGFloat)], size: CGSize) -> CIImage? {
        guard !hands.isEmpty, let ctx = CGContext(data:nil,width:Int(ceil(size.width)),height:Int(ceil(size.height)),
            bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return nil }
        let extent = CGRect(origin:.zero,size:size)
        ctx.setFillColor(gray:0,alpha:1); ctx.fill(extent)
        ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setBlendMode(.lighten)
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x:p.x*size.width,y:p.y*size.height) }
        for (hand,opacity) in hands {
            ctx.setFillColor(gray:opacity,alpha:1); ctx.setStrokeColor(gray:opacity,alpha:1)
            let palm = hull(hand.palm.map(pixel)), width = hand.palmWidth
            if let first = palm.first {
                ctx.move(to:first); palm.dropFirst().forEach { ctx.addLine(to:$0) }
                ctx.closePath(); ctx.setLineWidth(width*0.26); ctx.drawPath(using:.fillStroke)
            }
            for finger in hand.fingers {
                for i in 1..<max(1,finger.count) {
                    ctx.setLineWidth(width*(i == 1 ? 0.30 : 0.25))
                    ctx.move(to:pixel(finger[i-1])); ctx.addLine(to:pixel(finger[i])); ctx.strokePath()
                }
            }
            let wrist = pixel(hand.wrist), knuckles = pixel(hand.knuckles)
            ctx.setLineWidth(width*0.95)
            ctx.move(to:wrist)
            ctx.addLine(to:CGPoint(x:wrist.x+(wrist.x-knuckles.x)*0.9,y:wrist.y+(wrist.y-knuckles.y)*0.9))
            ctx.strokePath()
        }
        guard let cg = ctx.makeImage() else { return nil }
        let solid = CIImage(cgImage:cg)
        let feather = max(0.7,size.width*0.0015)
        return solid.applyingGaussianBlur(sigma:feather)
            .applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:solid]).cropped(to:extent)
    }

    private static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x) }
        func half(_ values: [CGPoint]) -> [CGPoint] {
            var result: [CGPoint] = []
            for point in values {
                while result.count > 1 && cross(result[result.count-2], result[result.count-1], point) <= 0 { result.removeLast() }
                result.append(point)
            }
            return result
        }
        return Array(half(sorted).dropLast()) + Array(half(sorted.reversed()).dropLast())
    }

}

/// White protects foreground. A small CPU field is read only when hands exist,
/// to skip a local shape warp whose support would touch a finger or sleeve.
/// Disabling those regions keeps pixels and landmarks in the same coordinates.
struct HandProtection {
    let mask:CIImage
    private let width:Int
    private let height:Int
    private let size:CGSize
    private let pixels:[UInt8]
    init?(mask:CIImage,size:CGSize) {
        guard size.width>0,size.height>0 else { return nil }
        self.mask=mask;self.size=size
        let scale=min(1,320/max(size.width,size.height))
        width=max(1,Int(ceil(size.width*scale)));height=max(1,Int(ceil(size.height*scale)))
        guard let cg=LashRendering.ci.createCGImage(mask.transformed(by:CGAffineTransform(scaleX:CGFloat(width)/size.width,y:CGFloat(height)/size.height)),from:CGRect(x:0,y:0,width:width,height:height)) else { return nil }
        let ctx=LashRendering.context(width,height)
        ctx.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
        pixels=Array(UnsafeBufferPointer(start:ctx.data!.assumingMemoryBound(to:UInt8.self),count:ctx.bytesPerRow*height))
    }
    func overlaps(center:CGPoint,right:CGPoint,radiusX:CGFloat,radiusY:CGFloat) -> Bool {
        guard radiusX>0,radiusY>0 else { return false }
        let r=max(radiusX,radiusY)
        let minX=max(0,Int(floor((center.x-r)/size.width*CGFloat(width))))
        let maxX=min(width-1,Int(ceil((center.x+r)/size.width*CGFloat(width))))
        let minY=max(0,Int(floor((center.y-r)/size.height*CGFloat(height))))
        let maxY=min(height-1,Int(ceil((center.y+r)/size.height*CGFloat(height))))
        guard minX<=maxX,minY<=maxY else { return false }
        for y in minY...maxY { for x in minX...maxX {
            guard pixels[((height-1-y)*width+x)*4]>20 else { continue }
            let dx=(CGFloat(x)+0.5)*size.width/CGFloat(width)-center.x
            let dy=(CGFloat(y)+0.5)*size.height/CGFloat(height)-center.y
            let u=(dx*right.x+dy*right.y)/radiusX,v=(-dx*right.y+dy*right.x)/radiusY
            if u*u+v*v<=1 { return true }
        } }
        return false
    }
    func restoring(_ result:CGImage,source:CGImage) -> CGImage {
        let raw=CIImage(cgImage:source),rendered=CIImage(cgImage:result)
        let protected=raw.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:rendered,kCIInputMaskImageKey:mask])
        return LashRendering.ci.createCGImage(protected,from:raw.extent) ?? source
    }
}
