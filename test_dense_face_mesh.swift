import AppKit
import CoreImage
import simd

@main struct MeshChecks {
 static func main() throws {
  setbuf(stdout,nil)
  let url=URL(fileURLWithPath:CommandLine.arguments.count>1 ? CommandLine.arguments[1] : "website/assets/camera-presenter.png")
  let original=CIImage(contentsOf:url)!, scale=min(1,960/max(original.extent.width,original.extent.height))
  let image=original.transformed(by:CGAffineTransform(scaleX:scale,y:scale)), context=CIContext()
  let filter=FaceBeautyFilter(), settings=FaceMakeupSettings(amount:1)
  func pixels(_ im: CIImage) -> [UInt8] {
   var p=[UInt8](repeating:0,count:Int(im.extent.width)*Int(im.extent.height)*4)
   context.render(im,toBitmap:&p,rowBytes:Int(im.extent.width)*4,bounds:im.extent,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB());return p
  }
  let output=filter.render(image,at:0,amount:0,makeup:settings)
  guard let face=filter.lastDetectedGeometry,let mesh=face.mesh else { fatalError("Dense model did not run: \(filter.meshError ?? "no detected mesh")") }
  precondition(mesh.points.count==468 && DenseFaceMesh.triangles.count==898)
  precondition(mesh.points.allSatisfy{$0.x.isFinite && $0.y.isFinite && $0.z.isFinite})
  let depth=mesh.points.map(\.z);precondition(depth.max()!-depth.min()!>0.01,"Mesh must carry predicted depth, not copied 2D points")
  precondition(face.features[0].count==16 && face.features[1].count==16 && face.innerLips.count==20)
  let sparseFilter=FaceBeautyFilter(meshEnabled:false)
  _=sparseFilter.render(image,at:0,amount:0,makeup:settings)
  let observed=sparseFilter.lastDetectedGeometry!
  let chin=observed.contour[observed.contour.count/2]
  let chinError=hypot((CGFloat(mesh.points[152].x)-chin.x)*image.extent.width,
                      (CGFloat(mesh.points[152].y)-chin.y)*image.extent.height)
  precondition(chinError<observed.bounds.width*image.extent.width*0.021,
               "The chin allowance must stay small and face-relative, never extend toward the neck")
  // Protect actual source hair/fabric at different exposures. Darker facial
  // skin must remain eligible; the threshold is relative to this face's skin.
  var maskFace=observed
  maskFace.features[0]=Array(repeating:CGPoint(x:0.3,y:0.7),count:4)
  maskFace.features[1]=Array(repeating:CGPoint(x:0.7,y:0.7),count:4)
  maskFace.features[6]=Array(repeating:CGPoint(x:0.5,y:0.4),count:4)
  let square=CGRect(x:0,y:0,width:100,height:100)
  for exposure in [0.25,0.6,1.0] {
   let skin=CIImage(color:CIColor(red:0.65*exposure,green:0.39*exposure,blue:0.29*exposure)).cropped(to:square)
   let hair=CIImage(color:CIColor(red:0.04*exposure,green:0.025*exposure,blue:0.018*exposure)).cropped(to:CGRect(x:10,y:20,width:20,height:20))
   let sleeve=CIImage(color:CIColor(red:0.30*exposure,green:0.46*exposure,blue:0.52*exposure)).cropped(to:CGRect(x:70,y:20,width:20,height:20))
   let source=hair.composited(over:sleeve.composited(over:skin))
   let mask=FaceBeautyFilter.surfaceProtection(source,face:maskFace)!
   func value(_ x:Double,_ y:Double)->Int {
    var pixel=[UInt8](repeating:0,count:4)
    context.render(mask,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
    return Int(pixel[0])
   }
   precondition(value(20,30)>250 && value(80,30)>250,"Hair/sleeve must reject cosmetics")
   precondition(value(50,50)<5,"Exposed skin must not be erased by a fixed brightness threshold")
  }
  for eye in 0..<2 {
   let surface=mesh.lashSurface(eye:eye,size:image.extent.size)!
   for t:CGFloat in [0.2,0.5,0.8] {
    let f=surface.frame(at:t)
    precondition(f.normal.z<0 && abs(simd_length(f.normal)-1)<0.001)
    precondition(f.up.x.isFinite && f.up.y.isFinite && f.up.z.isFinite)
   }
  }
  let lids=FaceMakeupRenderer.eyelids([CGPoint(x:0,y:0),CGPoint(x:25,y:18),CGPoint(x:75,y:18),CGPoint(x:100,y:0),CGPoint(x:75,y:-10),CGPoint(x:25,y:-10)],right:CGPoint(x:1,y:0))!
  func surface(_ normal: SIMD3<Float>) -> DenseFaceMesh.LashSurface {
   .init(roots:[SIMD3(0,0,0),SIMD3(100,0,0)],normals:[normal,normal],right:SIMD3(1,0,0),up:SIMD3(0,1,0))
  }
  let forward=FaceMakeupRenderer.lashHairs(lids,outerSign:1,amount:1,open:1,brow:[],surface:surface(SIMD3(0,0,-1)))
  let down=FaceMakeupRenderer.lashHairs(lids,outerSign:1,amount:1,open:1,brow:[],pitch:-1,surface:surface(SIMD3(0,-0.8,-0.6)))
  let redundantPose=FaceMakeupRenderer.lashHairs(lids,outerSign:1,amount:1,open:1,brow:[],pitch:1,yaw:1,lidPitch:1,surface:surface(SIMD3(0,0,-1)))
  for i in forward.indices {
   precondition(down[i].tip.y<down[i].root.y,"3D surface must turn lashes downward despite conflicting 2D pitch")
   precondition(forward[i].tip==redundantPose[i].tip,"Mesh pose must not be applied twice")
  }
  for openness: CGFloat in [0,0.25,0.5,0.75,1] {
   let blink=FaceMakeupRenderer.lashHairs(lids,outerSign:1,amount:1,open:openness,brow:[],surface:surface(SIMD3(0,0,-1)))
   precondition(blink.count==forward.count,"Blink must not remove upper lashes")
   for (hair,opened) in zip(blink,forward) {
    precondition(hair.root==opened.root,"Blink rotation must stay attached to the lid")
    if openness <= 0.25 { precondition(hair.tip.y<hair.root.y,"Closed mesh lashes must turn down even with an upward surface normal") }
   }
  }
  var closedObservation = observed
  for eye in 0..<2 {
   let eyePoints = observed.features[eye].map { CGPoint(x:$0.x*image.extent.width,y:$0.y*image.extent.height) }
   let lid = FaceMakeupRenderer.eyelids(eyePoints,right:CGPoint(x:1,y:0))!
   let corner = lid.upper[0]
   closedObservation.features[eye] = eyePoints.map { p in
    let height = (p.x-corner.x)*lid.up.x+(p.y-corner.y)*lid.up.y
    return CGPoint(x:(p.x-height*lid.up.x*0.96)/image.extent.width,
                   y:(p.y-height*lid.up.y*0.96)/image.extent.height)
   }
  }
  let fittedBlink = mesh.fitted(to:closedObservation)
  for eye in 0..<2 {
   let points = fittedBlink.polygon(DenseFaceMesh.eyes[eye]).map { CGPoint(x:$0.x*image.extent.width,y:$0.y*image.extent.height) }
   let lid = FaceMakeupRenderer.eyelids(points,right:CGPoint(x:1,y:0))!
   precondition(lid.opening<0.09,"Dense mesh must follow an independently observed closed lid")
   let hairs = FaceMakeupRenderer.lashHairs(lid,outerSign:eye == 0 ? -1 : 1,amount:1,open:0,brow:[],surface:fittedBlink.lashSurface(eye:eye,size:image.extent.size))
   precondition(!hairs.isEmpty)
   for hair in hairs {
    let projection = (hair.tip.x-hair.root.x)*lid.up.x+(hair.tip.y-hair.root.y)*lid.up.y
    precondition(projection<0,"Production blink fitting must project upper lashes down")
   }
  }
  let a=pixels(image),b=pixels(output)
  precondition(zip(a,b).reduce(0){$0+abs(Int($1.0)-Int($1.1))}>1000)
  for key in [\FaceMakeupSettings.lashes,\.lips,\.brows,\.aegyo] {
   var isolated=FaceMakeupSettings();for k in FaceMakeupSettings.keys {isolated[keyPath:k]=0};isolated.amount=1;isolated[keyPath:key]=1
   let result=FaceMakeupRenderer.render(image,face:face,current:face,settings:isolated,opacity:1)
   precondition(zip(a,pixels(result)).reduce(0){$0+abs(Int($1.0)-Int($1.1))}>100,"Mesh-attached component disappeared: \(key)")
  }
  // Background outside the face is color-protected for makeup, but it must
  // move into the old jaw silhouette when shortening. Restoring it afterward
  // or dilating it into the chin cancels the geometric effect.
  let canvas=CGContext(data:nil,width:Int(image.extent.width),height:Int(image.extent.height),bitsPerComponent:8,bytesPerRow:0,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  canvas.setFillColor(CGColor(gray:0,alpha:1));canvas.fill(image.extent)
  canvas.setFillColor(CGColor(gray:1,alpha:1))
  canvas.addLines(between:face.contour.map{CGPoint(x:$0.x*image.extent.width,y:$0.y*image.extent.height)})
  canvas.closePath();canvas.fillPath()
  let silhouette=CIImage(cgImage:canvas.makeImage()!)
  let exterior=silhouette.applyingFilter("CIColorInvert")
  let shapeSurface=FaceBeautyFilter.shapingSurfaceProtection(exterior,face:face)!
  let skin=CIImage(color:CIColor(red:0.75,green:0.40,blue:0.25)).cropped(to:image.extent)
  let background=CIImage(color:CIColor(red:0.12,green:0.4,blue:0.65)).cropped(to:image.extent)
  let synthetic=skin.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:background,kCIInputMaskImageKey:silhouette])
  var shape=FaceMakeupSettings();for key in FaceMakeupSettings.keys {shape[keyPath:key]=0}
  shape.amount=1;shape.shortening=1;shape.definition=1
  let reference=FaceMakeupRenderer.render(synthetic,face:face,current:face,settings:shape,opacity:1)
  let corrected=FaceMakeupRenderer.render(synthetic,face:face,current:face,settings:shape,opacity:1,
      unfiltered:synthetic,handProtection:shapeSurface,cosmeticProtection:exterior)
  let rawShape=pixels(synthetic),referencePixels=pixels(reference),correctedPixels=pixels(corrected)
  let referenceChange=zip(rawShape,referencePixels).reduce(0){$0+abs(Int($1.0)-Int($1.1))}
  precondition(referenceChange>1000,"Fixture must actually shorten the face silhouette")
  precondition(zip(correctedPixels,referencePixels).reduce(0){$0+abs(Int($1.0)-Int($1.1))}<referenceChange/20,
      "Background color protection must not suppress the jaw displacement")
  var sideChange=[0,0]
  let chinX=Int(face.contour[face.contour.count/2].x*image.extent.width)
  for y in 0..<Int(image.extent.height) {
   for x in 0..<Int(image.extent.width) {
    let index=(y*Int(image.extent.width)+x)*4
    sideChange[x<chinX ? 0:1] += abs(Int(rawShape[index])-Int(correctedPixels[index]))
   }
  }
  precondition(sideChange.allSatisfy{$0>300},"Both jaw sides must respond to shaping: \(sideChange)")
  // A foreground patch well inside the lower face remains protected.
  let interiorPoint=CGPoint(x:face.bounds.midX*image.extent.width,y:(face.contour[face.contour.count/2].y+face.bounds.height*0.20)*image.extent.height)
  let allWhite=CIImage(color:.white).cropped(to:image.extent)
  let interiorProtection=FaceBeautyFilter.shapingSurfaceProtection(allWhite,face:face)!
  var value=[UInt8](repeating:0,count:4)
  context.render(interiorProtection,toBitmap:&value,rowBytes:4,bounds:CGRect(origin:interiorPoint,size:CGSize(width:1,height:1)),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
  precondition(value[0]>240,"Interior hair/fabric must still block shaping")
  print("PASS: face silhouette can shrink while interior surface occlusion stays protected")
  let blank=CIImage(color:.gray).cropped(to:image.extent)
  precondition(filter.render(blank,at:1.0/30,amount:0,makeup:settings) === blank)
  precondition(filter.lastDetectedGeometry==nil,"Lost detection must not reuse a mesh as current")
  _=filter.render(image,at:0,amount:0,makeup:settings)
  precondition(filter.lastDetectedGeometry?.mesh?.points.count==468)
  precondition(filter.lastLipVisibility==1,"First visible mouth after seek must not wait through stale occlusion recovery")
  print("PASS: 468 XYZ vertices, 898 triangles, chin fit, exposure-relative foreground protection, 3D attachment basis, makeup components, loss and seek")
 }
}
