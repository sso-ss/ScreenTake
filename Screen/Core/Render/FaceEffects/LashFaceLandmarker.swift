#if arch(arm64)
import CoreGraphics
import Foundation
import simd
import Darwin


/// Load the pinned, signed runtime only where its macOS 14 / arm64 binary is
/// supported. ScreenTake can still launch on its existing macOS 13 baseline.
private final class MediaPipeAPI {
    typealias Message = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    typealias Create = @convention(c) (UnsafePointer<MpFaceLandmarkerOptions>, UnsafeMutablePointer<UnsafeMutableRawPointer?>, Message) -> Int32
    typealias DetectImage = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeRawPointer?, UnsafeMutablePointer<MpFaceLandmarkerResult>, Message) -> Int32
    typealias DetectVideo = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeRawPointer?, Int64, UnsafeMutablePointer<MpFaceLandmarkerResult>, Message) -> Int32
    typealias CloseResult = @convention(c) (UnsafeMutablePointer<MpFaceLandmarkerResult>) -> Void
    typealias Close = @convention(c) (UnsafeMutableRawPointer, Message) -> Int32
    typealias ImageCreate = @convention(c) (Int32, Int32, Int32, UnsafePointer<UInt8>, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>, Message) -> Int32
    typealias ImageFree = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias ErrorFree = @convention(c) (UnsafeMutablePointer<CChar>) -> Void
    let create: Create, detectImage: DetectImage, detectVideo: DetectVideo
    let closeResult: CloseResult, close: Close, imageCreate: ImageCreate
    let imageFree: ImageFree, errorFree: ErrorFree
    // Keep the library loaded for all graph workers until process exit.
    private let library: UnsafeMutableRawPointer
    static let shared: MediaPipeAPI? = MediaPipeAPI()
    private init?() {
        guard #available(macOS 14, *), let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("libmediapipe_source.so"),
              let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = symbol("MpFaceLandmarkerCreate", Create.self),
              let detectImage = symbol("MpFaceLandmarkerDetectImage", DetectImage.self),
              let detectVideo = symbol("MpFaceLandmarkerDetectForVideo", DetectVideo.self),
              let closeResult = symbol("MpFaceLandmarkerCloseResult", CloseResult.self),
              let close = symbol("MpFaceLandmarkerClose", Close.self),
              let imageCreate = symbol("MpImageCreateFromUint8Data", ImageCreate.self),
              let imageFree = symbol("MpImageFree", ImageFree.self),
              let errorFree = symbol("MpErrorFree", ErrorFree.self) else { dlclose(library); return nil }
        self.library = library
        self.create = create; self.detectImage = detectImage; self.detectVideo = detectVideo
        self.closeResult = closeResult; self.close = close; self.imageCreate = imageCreate
        self.imageFree = imageFree; self.errorFree = errorFree
    }
}

/// Official native MediaPipe graph. One instance belongs to one ordered stream.
/// VIDEO mode keeps the graph's ROI tracking and landmark filtering together.
final class LashFaceLandmarker {
    private let api = MediaPipeAPI.shared
    private var handle: UnsafeMutableRawPointer?
    private let video: Bool
    private var lastTimestamp: Int64 = -1
    private(set) var error: String?
    private(set) var landmarks: [[Float]] = []
    private(set) var transformation: [Float] = []

    init(video:Bool) {
        self.video=video
        guard api != nil else { error="MediaPipe runtime unavailable (requires Apple silicon and macOS 14+)"; return }
        guard let path=Bundle.main.path(forResource:"face_landmarker",ofType:"task") else {
            error="MediaPipe model is missing";return
        }
        var options=MpFaceLandmarkerOptions()
        options.base_options.file_descriptor = -1
        options.running_mode = video ? 2 : 1
        options.num_faces=1
        options.min_face_detection_confidence=0.5
        options.min_face_presence_confidence=0.5
        options.min_tracking_confidence=0.5
        options.output_facial_transformation_matrixes=true
        var message:UnsafeMutablePointer<CChar>?
        let status=path.withCString { pointer in
            options.base_options.model_asset_path=pointer
            return api!.create(&options,&handle,&message)
        }
        check(status,message:message)
    }
    deinit {
        if let handle {
            var message:UnsafeMutablePointer<CChar>?
            api!.close(handle,&message)
            if let message { api!.errorFree(message) }
        }
    }
    @discardableResult private func check(_ status:Int32,message:UnsafeMutablePointer<CChar>?) -> Bool {
        defer { if let message { api!.errorFree(message) } }
        if status != 0 { error=message.map { String(cString:$0) } ?? "MediaPipe error \(status)";return false }
        error=nil;return true
    }
    func detect(_ image:CGImage,at seconds:Double = 0) -> PhotoGeometry? {
        landmarks=[];transformation=[]
        guard let handle,seconds.isFinite else { return nil }
        let milliseconds=seconds*1000
        guard milliseconds.isFinite,milliseconds >= 0,milliseconds < Double(Int64.max) else { return nil }
        let timestamp=Int64(milliseconds.rounded(.down))
        if video && timestamp<=lastTimestamp { return nil }
        let width=image.width,height=image.height
        // Bitmap rows are top-to-bottom RGBA. The native API copies the image
        // data; image and landmarks then travel as one frame through rendering.
        var bytes=[UInt8](repeating:0,count:width*height*4)
        var nativeImage:UnsafeMutableRawPointer?,message:UnsafeMutablePointer<CChar>?
        let status=bytes.withUnsafeMutableBytes { data -> Int32 in
            guard let context=CGContext(data:data.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return -1 }
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            return api!.imageCreate(2,Int32(width),Int32(height),data.baseAddress!.assumingMemoryBound(to:UInt8.self),Int32(data.count),&nativeImage,&message)
        }
        guard check(status,message:message),let nativeImage else { return nil }
        defer { api!.imageFree(nativeImage) }
        var result=MpFaceLandmarkerResult();message=nil
        let detection:Int32
        if video {
            lastTimestamp=timestamp
            detection=api!.detectVideo(handle,nativeImage,nil,timestamp,&result,&message)
        } else { detection=api!.detectImage(handle,nativeImage,nil,&result,&message) }
        guard check(detection,message:message) else { return nil }
        defer { api!.closeResult(&result) }
        guard result.face_landmarks_count==1,let landmarks=result.face_landmarks?.pointee,
              landmarks.landmarks_count==478,let points=landmarks.landmarks else { return nil }
        self.landmarks=(0..<478).map { [points[$0].x,points[$0].y,points[$0].z] }
        let mesh=LashMesh(points:(0..<468).map { i in SIMD3(points[i].x,1-points[i].y,points[i].z) })
        guard mesh.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        let size=CGSize(width:width,height:height)
        func polygon(_ indices:[Int]) -> [CGPoint] {
            mesh.polygon(indices).map { CGPoint(x:$0.x*size.width,y:$0.y*size.height) }
        }
        let eyes=LashMesh.eyes.map { indices -> [CGPoint] in
            let p=polygon(indices)
            return LashGeometry.fixedContour(upper:Array(p[0...8]),lower:[p[0]]+Array(p[9...].reversed())+[p[8]]) ?? []
        }
        let brows=[polygon([70,63,105,66,107]),polygon([336,296,334,293,300])]
        var face=PhotoGeometry(eyes:eyes,brows:brows,yaw:0,pitch:0)
        if result.facial_transformation_matrixes_count==1,let matrix=result.facial_transformation_matrixes?.pointee,
           matrix.rows==4,matrix.cols==4,let m=matrix.data {
            transformation=Array(UnsafeBufferPointer(start:m,count:16))
            let pose=Self.pose(transformation)
            face.yaw=pose.yaw;face.pitch=pose.pitch;face.observedRoll=pose.roll
        }
        let outline=polygon(MakeupGeometry.faceIndices),xs=outline.map(\.x),ys=outline.map(\.y)
        face.bounds=CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
        face.eyeVisibility=PhotoGeometry.visibility(yaw:face.yaw)
        face.surfaces=mesh.surfaces(size:size);face.meshWeight=1
        // A fixed anatomical oval includes hidden-side vertices in profile.
        // It is not the separately observed, open jawline expected by the
        // legacy makeup geometry. Use the projected surface for coverage.
        face.makeup=MakeupGeometry(mesh:mesh,size:size,outerLips:polygon(MakeupGeometry.outerLipIndices),
            innerLips:polygon(MakeupGeometry.innerLipIndices))
        face.makeup?.usesProjectedMeshSurface=true
        return face
    }
    /// Match LashPose's Rz(roll) Ry(yaw) Rx(pitch), using column-major data.
    static func pose(_ m:[Float]) -> LashPose {
        guard m.count==16,m.allSatisfy(\.isFinite) else { return LashPose(yaw:0,pitch:0) }
        return LashPose(yaw:CGFloat(atan2(-m[2],hypot(m[0],m[1]))),
            pitch:CGFloat(atan2(m[6],m[10])),roll:CGFloat(atan2(m[1],m[0])))
    }
}

#endif
