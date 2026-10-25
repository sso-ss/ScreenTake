import Foundation
import CoreML
import CoreImage
import simd

struct LashSurface {
    struct Frame {
        var growth: SIMD3<Float>
        var curl: SIMD3<Float>
        var right: SIMD3<Float>
    }
    var frames: [Frame]
    var widthRatio: CGFloat
    func frame(at t: CGFloat) -> Frame {
        let position = min(1,max(0,t))*CGFloat(frames.count-1)
        let i = min(frames.count-2,Int(position)), w = Float(position-CGFloat(i))
        let a = frames[i], b = frames[i+1]
        return Frame(growth: simd_normalize(a.growth*(1-w)+b.growth*w),
                     curl: simd_normalize(a.curl*(1-w)+b.curl*w),
                     right: simd_normalize(a.right*(1-w)+b.right*w))
    }
    func blended(from old: Self,amount: Float) -> Self {
        guard old.frames.count == frames.count else { return self }
        var result = self
        result.widthRatio = old.widthRatio+(widthRatio-old.widthRatio)*CGFloat(amount)
        result.frames = zip(old.frames,frames).map { a,b in
            Frame(growth: simd_normalize(a.growth*(1-amount)+b.growth*amount),
                  curl: simd_normalize(a.curl*(1-amount)+b.curl*amount),
                  right: simd_normalize(a.right*(1-amount)+b.right*amount))
        }
        return result
    }
}

/// Fixed-topology eyelids and relative depth from the local Face Mesh model.
struct LashMesh {
    var points: [SIMD3<Float>]
    static let eyes = [
        [33,246,161,160,159,158,157,173,133,155,154,153,145,144,163,7],
        [362,398,384,385,386,387,388,466,263,249,390,373,374,380,381,382]
    ]
    static let upper = [[33,246,161,160,159,158,157,173,133],[362,398,384,385,386,387,388,466,263]]
    static let triangles: [[Int]] = {
        guard let url = Bundle.main.url(forResource: "triangles",withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let faces = try? JSONDecoder().decode([[Int]].self,from: data) else { return [] }
        return faces.filter { $0.count == 3 && $0.allSatisfy { (0..<468).contains($0) } }
    }()
    func polygon(_ indices: [Int]) -> [CGPoint] { indices.map { CGPoint(x: CGFloat(points[$0].x),y: CGFloat(points[$0].y)) } }
    func surfaces(size: CGSize) -> [LashSurface] {
        guard points.count == 468,!Self.triangles.isEmpty else { return [] }
        let pixel = points.map { $0*SIMD3(Float(size.width),Float(size.height),Float(size.width)) }
        func unit(_ vector: SIMD3<Float>,fallback: SIMD3<Float>) -> SIMD3<Float> {
            let length = simd_length(vector)
            return length.isFinite && length > 0.0001 ? vector/length : fallback
        }
        let up = unit(pixel[10]-pixel[152],fallback:SIMD3(0,1,0))
        let outward = pixel[1]-(pixel[234]+pixel[454]+pixel[10]+pixel[152])/4
        return Self.upper.map { indices in
            let roots = indices.map { pixel[$0] }
            let chord = roots.last!-roots[0], width = max(1,hypot(chord.x,chord.y))
            // The corner chord and face vertical define a stable local plane.
            // Tiny triangles on moving lids can collapse/invert during a blink;
            // deriving normals from those triangles made entire fans flash.
            let right = unit(chord,fallback:SIMD3(1,0,0))
            let fallbackNormal = unit(outward-right*simd_dot(outward,right),fallback:SIMD3(0,0,-1))
            var normal = unit(simd_cross(right,up),fallback:fallbackNormal)
            if simd_dot(normal,outward) < 0 { normal = -normal }
            let curl = unit(up-normal*simd_dot(up,normal),fallback:unit(simd_cross(normal,right),fallback:SIMD3(0,1,0)))
            let angle = Float(LashGeometry.follicleTilt)
            let stable = LashSurface.Frame(growth:normal*cos(angle)+curl*sin(angle),
                curl:curl*cos(angle)-normal*sin(angle),right:right)
            let frames = [LashSurface.Frame](repeating:stable,count:33)
            return LashSurface(frames:frames,widthRatio:CGFloat(min(6,max(1,simd_length(chord)/width))))
        }
    }
}

#if !SCREENTAKE_RUNTIME
final class LashMeshDetector {
    private let model: MLModel?
    private let context = CIContext(options:[.cacheIntermediates:false])
    private var buffer: CVPixelBuffer?
    private(set) var error: String?
    /// The model was trained on eye-line-aligned crops. Head roll alone is not
    /// that projected line under combined yaw/pitch; using it moved the far eye.
    static func cropAngle(_ face:PhotoGeometry) -> CGFloat {
        guard face.eyes.count==2,
              face.eyes.allSatisfy({ $0.count>=4 && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else { return face.roll }
        // Eyelid centroids move as one eye blinks. The corner midpoints do not
        // depend on how many upper/lower samples happen to be present.
        let centers=face.eyes.map { eye -> CGPoint in
            let axis=CGPoint(x:cos(face.roll),y:sin(face.roll))
            func along(_ p:CGPoint) -> CGFloat { p.x*axis.x+p.y*axis.y }
            let first=eye.min { along($0)<along($1) }!,last=eye.max { along($0)<along($1) }!
            return MakeupPaint.mean([first,last])
        }
        let dx=centers[1].x-centers[0].x,dy=centers[1].y-centers[0].y
        guard hypot(dx,dy)>max(3,face.bounds.width*0.08) else { return face.roll }
        return atan2(dy,dx)
    }
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
    func detect(_ image: CIImage, face: PhotoGeometry) -> LashMesh? {
        guard let model, let buffer, face.eyes.count == 2,
              face.bounds.width > 2, face.bounds.height > 2 else { return nil }
        let observedEyes = face.eyes.indices.filter { index in
            face.eyes[index].count >= 4 && face.eyes[index].allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }
        guard !observedEyes.isEmpty else { return nil }
        let size = image.extent.size
        let box = face.bounds
        // Vision's square face box includes forehead/chin. Expand for the mesh
        // network's training crop and align the eye line to avoid roll distortion.
        let side = max(box.width,box.height)*1.45
        let center = CGPoint(x:box.midX,y:box.midY+box.height*0.04)
        func mean(_ eye: [CGPoint]) -> CGPoint {
            CGPoint(x:eye.map(\.x).reduce(0,+)/CGFloat(eye.count),
                    y:eye.map(\.y).reduce(0,+)/CGFloat(eye.count))
        }
        let angle = Self.cropAngle(face), c = cos(angle), s = sin(angle), k = 192/side
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
            let mesh = LashMesh(points:points)
            // A high presence score alone is not enough under occlusion. Reject
            // a mesh whose eye centers leave the independently observed eyes.
            for eye in observedEyes {
                let observed = mean(face.eyes[eye]), predicted = mean(mesh.polygon(LashMesh.eyes[eye]).map { CGPoint(x:$0.x*size.width,y:$0.y*size.height) })
                guard hypot(observed.x-predicted.x,observed.y-predicted.y) < box.width*0.18 else { return nil }
            }
            error = nil
            return mesh
        } catch { self.error = String(describing:error); return nil }
    }
}

#endif
