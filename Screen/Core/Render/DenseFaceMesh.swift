import Foundation
import CoreML
import CoreImage
import simd

/// Monocular relative depth: X/Y are normalized upright image coordinates;
/// Z uses image-width units and points away from the camera. Not metric depth.
struct DenseFaceMesh {
    var points: [SIMD3<Float>]
    var confidence: Double
    static let eyes = [
        [33,246,161,160,159,158,157,173,133,155,154,153,145,144,163,7],
        [362,398,384,385,386,387,388,466,263,249,390,373,374,380,381,382]
    ]
    static let upperEyes = [[33,246,161,160,159,158,157,173,133], [362,398,384,385,386,387,388,466,263]]
    static let brows = [[70,63,105,66,107,55,65,52,53,46], [336,296,334,293,300,276,283,282,295,285]]
    static let lips = [61,185,40,39,37,0,267,269,270,409,291,375,321,405,314,17,84,181,91,146]
    static let innerLips = [78,191,80,81,82,13,312,311,310,415,308,324,318,402,317,14,87,178,88,95]
    static let jaw = [234,93,132,58,172,136,150,149,176,148,152,377,400,378,379,365,397,288,361,323,454]
    static let oval = [10,338,297,332,284,251,389,356,454,323,361,288,397,365,379,378,400,377,152,148,176,149,150,136,172,58,132,93,234,127,162,21,54,103,67,109]
    static let triangles: [[Int]] = {
        guard let url = Bundle.main.url(forResource:"triangles",withExtension:"json") ?? Bundle.main.url(forResource:"triangles",withExtension:"json",subdirectory:"FaceMesh"),
              let data = try? Data(contentsOf:url), let faces = try? JSONDecoder().decode([[Int]].self,from:data),
              faces.allSatisfy({ $0.count == 3 && $0.allSatisfy({ (0..<468).contains($0) }) }) else { return [] }
        return faces
    }()
    func polygon(_ indices: [Int]) -> [CGPoint] { indices.map { CGPoint(x:CGFloat(points[$0].x),y:CGFloat(points[$0].y)) } }
    func pixel(_ index: Int, size: CGSize) -> SIMD3<Float> {
        points[index] * SIMD3(Float(size.width),Float(size.height),Float(size.width))
    }
    /// The small network can contract the lower face under occlusion while
    /// retaining a high presence score. Fit its projection to independently
    /// observed mouth/chin anchors; preserve the inferred relative depth and
    /// smoothly carry neighboring vertices so the surface stays connected.
    func fitted(to face: FaceBeautyGeometry) -> Self {
        guard points.count == 468, face.features[6].count >= 3, face.contour.count >= 5 else { return self }
        let size = face.imageSize
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x:p.x*size.width,y:p.y*size.height) }
        func box(_ p: [CGPoint]) -> CGRect {
            CGRect(x:p.map(\.x).min()!,y:p.map(\.y).min()!,
                   width:p.map(\.x).max()!-p.map(\.x).min()!,height:p.map(\.y).max()!-p.map(\.y).min()!)
        }
        let observed = box(face.features[6].map(pixel)), predicted = box(polygon(Self.lips).map(pixel))
        let fw = face.bounds.width*size.width
        let dx = observed.midX-predicted.midX, dy = observed.midY-predicted.midY
        guard predicted.width > 2, predicted.height > 1,
              hypot(dx,dy) < fw*0.18 else { return self }
        let sx = min(1.25,max(0.8,observed.width/predicted.width))
        let sy = min(1.4,max(0.7,observed.height/predicted.height))
        let mouthBottom = min(observed.minY,predicted.minY)
        let originalChin = pixel(polygon([152])[0])
        // Use the stable center of the contour, not whichever lateral point
        // happens to have the lowest image-space Y during a roll.
        let middle = face.contour.count/2
        func center(_ points: [CGPoint]) -> CGPoint {
            let points = points.map(pixel)
            return CGPoint(x:points.map(\.x).reduce(0,+)/CGFloat(points.count),
                           y:points.map(\.y).reduce(0,+)/CGFloat(points.count))
        }
        let eyeA = center(face.features[0]), eyeB = center(face.features[1])
        let eyeLength = max(1,hypot(eyeB.x-eyeA.x,eyeB.y-eyeA.y))
        let up = CGPoint(x:-(eyeB.y-eyeA.y)/eyeLength,y:(eyeB.x-eyeA.x)/eyeLength)
        let observedChin = pixel(face.contour[middle])
        // A small, face-relative allowance for the lower chin surface. Keep it
        // tied to face roll and scale; never search outward for a neck shadow.
        let chin = CGPoint(x:observedChin.x-up.x*fw*0.015,y:observedChin.y-up.y*fw*0.015)
        let chinDX = min(fw*0.10,max(-fw*0.10,chin.x-originalChin.x))
        let chinDY = min(fw*0.15,max(-fw*0.15,chin.y-originalChin.y))
        var result = self
        for i in points.indices {
            let p = pixel(polygon([i])[0])
            let x = (p.x-predicted.midX)/max(1,predicted.width*0.85)
            let y = (p.y-predicted.midY)/max(1,predicted.height*0.9)
            let t = min(1,max(0,(1.55-hypot(x,y))/0.55))
            let mouthWeight = t*t*(3-2*t)
            let lower = min(1,max(0,(mouthBottom-p.y)/max(1,mouthBottom-originalChin.y)))
            let chinWeight = lower*lower*(3-2*lower)
            let mx = dx+(p.x-predicted.midX)*(sx-1)
            let my = dy+(p.y-predicted.midY)*(sy-1)
            result.points[i].x += Float((mx*mouthWeight+chinDX*chinWeight)/size.width)
            result.points[i].y += Float((my*mouthWeight+chinDY*chinWeight)/size.height)
        }
        // The small mesh crop can put a whole lateral jaw arc inside the cheek.
        // Fit the complete side curves to the current sparse contour, not only
        // the temple endpoints. Preserve the separately fitted center chin.
        let contour = face.contour.map(pixel)
        for j in Self.jaw.indices {
            let fromChin = abs(j-Self.jaw.count/2)
            guard fromChin > 0 else { continue }
            let i = Self.jaw[j], p = pixel(result.polygon([i])[0])
            var closest = p, distance = CGFloat.infinity
            for pair in zip(contour,contour.dropFirst()) {
                let dx = pair.1.x-pair.0.x, dy = pair.1.y-pair.0.y
                let t = min(1,max(0,((p.x-pair.0.x)*dx+(p.y-pair.0.y)*dy)/max(0.001,dx*dx+dy*dy)))
                let q = CGPoint(x:pair.0.x+t*dx,y:pair.0.y+t*dy)
                let d = hypot(q.x-p.x,q.y-p.y)
                if d < distance { closest = q; distance = d }
            }
            guard distance < fw*0.08 else { continue }
            let weight = min(1,CGFloat(fromChin)/2)
            result.points[i].x += Float((closest.x-p.x)*weight/size.width)
            result.points[i].y += Float((closest.y-p.y)*weight/size.height)
        }
        // This small mesh can retain an open-eye prior during a real blink.
        // Fit both lid arcs to the independently observed closing eye. Keep
        // vertex identity and relative depth, and blend continuously so an
        // opening eye does not switch between two different landmark sets.
        let eyeAxis = CGPoint(x:(eyeB.x-eyeA.x)/eyeLength,y:(eyeB.y-eyeA.y)/eyeLength)
        for eye in 0..<2 {
            guard let observed = FaceMakeupRenderer.eyelids(face.features[eye].map(pixel),right:eyeAxis),
                  let predicted = FaceMakeupRenderer.eyelids(result.polygon(Self.eyes[eye]).map(pixel),right:eyeAxis),
                  let origin = predicted.upper.first else { continue }
            let closing = min(1,max(0,(0.24-observed.opening)/0.14))
            let weight = closing*closing*(3-2*closing)
            guard weight > 0 else { continue }
            let upper = Set(Self.upperEyes[eye])
            for index in Self.eyes[eye] {
                let p = pixel(result.polygon([index])[0])
                let t = min(1,max(0,((p.x-origin.x)*predicted.right.x+(p.y-origin.y)*predicted.right.y)/predicted.width))
                let arc = upper.contains(index) ? observed.upper : observed.lower
                let start = arc[0]
                let target = t*observed.width
                func along(_ p: CGPoint) -> CGFloat { (p.x-start.x)*observed.right.x+(p.y-start.y)*observed.right.y }
                let k = (1..<arc.count).first { along(arc[$0]) >= target } ?? arc.count-1
                let a = arc[k-1], b = arc[k]
                let mix = min(1,max(0,(target-along(a))/max(0.001,along(b)-along(a))))
                let q = CGPoint(x:a.x+(b.x-a.x)*mix,y:a.y+(b.y-a.y)*mix)
                guard hypot(q.x-p.x,q.y-p.y) < fw*0.10 else { continue }
                result.points[index].x += Float((q.x-p.x)*weight/size.width)
                result.points[index].y += Float((q.y-p.y)*weight/size.height)
            }
        }
        return result
    }
    struct LashSurface {
        var roots: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        func frame(at fraction: CGFloat) -> (normal: SIMD3<Float>, up: SIMD3<Float>, right: SIMD3<Float>) {
            let origin = simd_dot(roots[0],right), width = simd_dot(roots.last!,right)-origin
            let target = origin+Float(fraction)*width
            let i = (1..<roots.count).first { simd_dot(roots[$0],right) >= target } ?? roots.count-1
            let a = simd_dot(roots[i-1],right), b = simd_dot(roots[i],right)
            let t = min(1,max(0,(target-a)/max(0.001,b-a)))
            var n = simd_normalize(normals[i-1]*(1-t)+normals[i]*t)
            if !n.x.isFinite { n = SIMD3(0,0,-1) }
            // Keep the curl tangent to the eyelid surface, toward the forehead.
            var u = simd_normalize(simd_cross(n,right))
            if simd_dot(u,up) < 0 { u = -u }
            // The follicle emerges slightly toward the brow, rather than
            // perpendicular to the sloping eyelid skin. Preserve the 3D basis
            // and its pose while applying this small attachment offset.
            let angle: Float = 0.12
            let growth = n*cos(angle)+u*sin(angle)
            u = u*cos(angle)-n*sin(angle)
            n = growth
            return (n,u,right)
        }
    }
    func lashSurface(eye: Int, size: CGSize) -> LashSurface? {
        guard points.count == 468, !Self.triangles.isEmpty else { return nil }
        let indices = Self.upperEyes[eye]
        let roots = indices.map { pixel($0,size:size) }
        let right = simd_normalize(roots.last!-roots[0])
        let up = simd_normalize(pixel(10,size:size)-pixel(152,size:size))
        var normals = [SIMD3<Float>](repeating:.zero,count:468)
        for face in Self.triangles {
            let a = pixel(face[0],size:size), b = pixel(face[1],size:size), c = pixel(face[2],size:size)
            var n = simd_cross(b-a,c-a)
            if n.z > 0 { n = -n }
            for i in face { normals[i] += n }
        }
        return LashSurface(roots:roots,normals:indices.map { simd_normalize(normals[$0]) },right:right,up:up)
    }
}

/// One small crop per frame, entirely on-device. Vision supplies a current ROI;
/// Core ML predicts 468 XYZ vertices. A missing/low-confidence mesh is rejected.
final class DenseFaceMeshDetector {
    private let model: MLModel?
    private let context = CIContext(options:[.cacheIntermediates:false])
    private var buffer: CVPixelBuffer?
    private(set) var error: String?
    init(modelURL: URL? = nil, computeUnits: MLComputeUnits = .cpuAndGPU) {
        let config = MLModelConfiguration(); config.computeUnits = computeUnits
        do {
            guard let url = modelURL ?? Bundle.main.url(forResource:"FaceMesh",withExtension:"mlmodelc") else {
                model = nil; error = "FaceMesh model resource is missing"; return
            }
            model = try MLModel(contentsOf:url,configuration:config)
        } catch { model = nil; self.error = String(describing:error) }
        CVPixelBufferCreate(nil,192,192,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&buffer)
    }
    func detect(_ image: CIImage, face: FaceBeautyGeometry) -> DenseFaceMesh? {
        guard let model, let buffer else { return nil }
        let size = image.extent.size
        let box = CGRect(x:face.bounds.minX*size.width,y:face.bounds.minY*size.height,
                         width:face.bounds.width*size.width,height:face.bounds.height*size.height)
        // Vision's square face box includes forehead/chin. Expand for the mesh
        // network's training crop and align the eye line to avoid roll distortion.
        let side = max(box.width,box.height)*1.45
        let center = CGPoint(x:box.midX,y:box.midY+box.height*0.04)
        func mean(_ eye: [CGPoint]) -> CGPoint {
            CGPoint(x:eye.map(\.x).reduce(0,+)/CGFloat(eye.count)*size.width,
                    y:eye.map(\.y).reduce(0,+)/CGFloat(eye.count)*size.height)
        }
        let a = mean(face.features[0]), b = mean(face.features[1])
        let angle = atan2(b.y-a.y,b.x-a.x), c = cos(angle), s = sin(angle), k = 192/side
        let transform = CGAffineTransform(a:c*k,b:-s*k,c:s*k,d:c*k,
            tx:96-k*(c*center.x+s*center.y),ty:96-k*(-s*center.x+c*center.y))
        context.render(image.clampedToExtent().transformed(by:transform),to:buffer,
                       bounds:CGRect(x:0,y:0,width:192,height:192),colorSpace:CGColorSpaceCreateDeviceRGB())
        do {
            let prediction = try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["input_image":MLFeatureValue(pixelBuffer:buffer)]))
            guard let array = prediction.featureValue(for:"points_confidence")?.multiArrayValue,array.count == 1405 else { return nil }
            let confidence = 1/(1+exp(-array[1404].doubleValue))
            guard confidence >= 0.80 else { return nil }
            let inverse = transform.inverted()
            var points: [SIMD3<Float>] = []
            for i in 0..<468 {
                let p = CGPoint(x:array[i*3].doubleValue,y:192-array[i*3+1].doubleValue).applying(inverse)
                let z = array[i*3+2].floatValue*Float(side/192/size.width)
                guard p.x.isFinite,p.y.isFinite,z.isFinite else { return nil }
                points.append(SIMD3(Float(p.x/size.width),Float(p.y/size.height),z))
            }
            let mesh = DenseFaceMesh(points:points,confidence:confidence)
            // A high presence score alone is not enough under occlusion. Reject
            // a mesh whose eye centers leave the independently observed eyes.
            for eye in 0..<2 {
                let observed = mean(face.features[eye]), predicted = mean(mesh.polygon(DenseFaceMesh.eyes[eye]))
                guard hypot(observed.x-predicted.x,observed.y-predicted.y) < box.width*0.18 else { return nil }
            }
            error = nil
            return mesh.fitted(to:face)
        } catch { self.error = String(describing:error); return nil }
    }
}
