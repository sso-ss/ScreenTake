import CoreImage
import CoreGraphics
import Foundation

/// ScreenTake's bilateral skin pass, adapted to the current MediaPipe surface.
/// Runs before shaping/pigment so cosmetic detail is never smoothed a second time.
enum MakeupSkinSmoothing {
    static var available: Bool { kernel != nil }

    static func mask(face: PhotoGeometry, size: CGSize) -> CIImage? {
        guard let geometry=face.makeup,geometry.points.count==468,
              geometry.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              face.bounds.width>1,size.width>0,size.height>0 else { return nil }
        let scale=min(1,640/max(size.width,size.height))
        let width=Int(ceil(size.width*scale)),height=Int(ceil(size.height*scale))
        let extent=CGRect(x:0,y:0,width:width,height:height)
        let skin=LashRendering.context(width,height),features=LashRendering.context(width,height)
        for ctx in [skin,features] {
            ctx.setFillColor(CGColor(gray:0,alpha:1));ctx.fill(extent)
            ctx.scaleBy(x:scale,y:scale);ctx.setFillColor(CGColor(gray:1,alpha:1))
        }
        skin.addPath(geometry.skinCoveragePath);skin.fillPath()
        let brows=[geometry.polygon([70,63,105,66,107,55,65,52,53,46]),
                   geometry.polygon([336,296,334,293,300,276,283,282,295,285])]
        let mouth=geometry.outerLips.count>=3 ? geometry.outerLips : geometry.polygon(MakeupRendering.outerLip)
        let protected=face.eyes+brows+[mouth,geometry.polygon([98,97,2,326,327,1])]
        features.setStrokeColor(CGColor(gray:1,alpha:1))
        features.setLineWidth(max(3,face.bounds.width*0.035))
        features.setLineJoin(.round);features.setLineCap(.round)
        for points in protected where points.count>=3 && points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
            features.addPath(MakeupPaint.path(points,smooth:false));features.drawPath(using:.fillStroke)
        }
        guard let skinImage=skin.makeImage(),let featureImage=features.makeImage() else { return nil }
        let surface=CIImage(cgImage:skinImage),holes=CIImage(cgImage:featureImage)
        let feather=max(1,face.bounds.width*scale*0.014)
        let softened=surface.applyingFilter("CIMorphologyMinimum",parameters:[kCIInputRadiusKey:feather])
            .applyingGaussianBlur(sigma:feather)
            .applyingFilter("CIMinimumCompositing",parameters:[kCIInputBackgroundImageKey:surface])
        let protectedHoles=holes.applyingGaussianBlur(sigma:feather)
            .applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:holes])
        return CIImage(color:.black).cropped(to:extent).applyingFilter("CIBlendWithMask",parameters:[
            kCIInputBackgroundImageKey:softened,kCIInputMaskImageKey:protectedHoles])
            .cropped(to:extent).transformed(by:CGAffineTransform(scaleX:1/scale,y:1/scale))
            .cropped(to:CGRect(origin:.zero,size:size))
    }

    static func apply(_ image: CGImage, face: PhotoGeometry, amount: CGFloat, protection: HandProtection? = nil) -> CGImage {
        let strength=MakeupPaint.clamp(amount)*MakeupPaint.clamp(face.trackingOpacity)*MakeupPaint.clamp(face.makeup?.opacity ?? 0)
        guard strength>0,let kernel,var mask=mask(face:face,size:CGSize(width:image.width,height:image.height)) else { return image }
        let source=CIImage(cgImage:image),bounds=source.extent
        if let protection {
            mask=CIImage(color:.black).cropped(to:bounds).applyingFilter("CIBlendWithMask",parameters:[
                kCIInputBackgroundImageKey:mask,kCIInputMaskImageKey:protection.mask])
        }
        let radius=max(1.5,min(14,face.bounds.width*0.026))
        // Current cheeks provide an illumination reference for dark-strand
        // rejection. This is tonal protection, not semantic hair/hand detection.
        let points=face.makeup!.points
        let anchors=[points[205],points[425],points[151]].map { CIVector(cgPoint:$0) }
        guard let result=kernel.apply(extent:bounds,roiCallback:{ index,rect in
            index==0 ? bounds.insetBy(dx:-radius,dy:-radius) : rect
        },arguments:[source.clampedToExtent(),mask,radius,strength*0.78,anchors[0],anchors[1],anchors[2]]),
              let output=LashRendering.ci.createCGImage(result,from:bounds) else { return image }
        return output
    }

    private static let kernel=CIKernel(source:"""
    kernel vec4 labSkin(sampler source, sampler mask, float radius, float strength, vec2 a, vec2 b, vec2 c) {
        vec2 p=destCoord();
        vec4 original=sample(source,samplerTransform(source,p));
        float amount=sample(mask,samplerTransform(mask,p)).r*strength;
        if (amount<0.001) return original;
        vec3 luma=vec3(0.2126,0.7152,0.0722);
        float reference=max(0.01,max(dot(sample(source,samplerTransform(source,a)).rgb,luma),
            max(dot(sample(source,samplerTransform(source,b)).rgb,luma),dot(sample(source,samplerTransform(source,c)).rgb,luma))));
        amount*=smoothstep(0.20,0.50,dot(original.rgb,luma)/reference);
        vec3 sum=vec3(0.0); float weights=0.0;
        for (int y=-2;y<=2;y++) {
            for (int x=-2;x<=2;x++) {
                vec2 offset=vec2(float(x),float(y));
                vec3 color=sample(source,samplerTransform(source,p+offset*radius*0.5)).rgb;
                vec3 difference=color-original.rgb;
                float weight=exp(-dot(offset,offset)/5.0-dot(difference,difference)*65.0);
                sum+=color*weight;weights+=weight;
            }
        }
        vec3 soft=sum/weights;
        float center=dot(original.rgb,luma);
        float left=dot(sample(source,samplerTransform(source,p-vec2(radius*0.4,0.0))).rgb,luma);
        float right=dot(sample(source,samplerTransform(source,p+vec2(radius*0.4,0.0))).rgb,luma);
        float up=dot(sample(source,samplerTransform(source,p+vec2(0.0,radius*0.4))).rgb,luma);
        float down=dot(sample(source,samplerTransform(source,p-vec2(0.0,radius*0.4))).rgb,luma);
        float ridge=max(0.0,max(min(left,right),min(up,down))-center);
        float lift=min(ridge,0.045)*smoothstep(0.005,0.025,ridge)*(1.0-smoothstep(0.08,0.18,ridge))*0.40;
        return vec4(clamp(mix(original.rgb,soft,amount*0.95)+lift*amount,0.0,1.0),original.a);
    }
    """)
}
