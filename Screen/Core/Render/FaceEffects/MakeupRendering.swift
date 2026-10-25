import CoreGraphics
import Foundation

struct MakeupOptions: Codable {
    var look = MakeupLook.roseGlam
    var enabled = false
    var intensity: CGFloat = 1
    var contour: CGFloat = 0.55
    var blush: CGFloat = 0.65
    var eyes: CGFloat = 0.80
    var brows: CGFloat = 0
    var lips: CGFloat = 0.85
    var lipVolume: CGFloat = 0.85
    var faceShape: CGFloat = 0.85
    var lipBlur: CGFloat = 0.8
    var skin: CGFloat = 0.55

    /// The master scales rendering, leaving each saved control value intact.
    var effective: Self {
        var result=self
        let amount=MakeupPaint.clamp(intensity)
        result.enabled=enabled && amount>0
        result.intensity=1
        result.contour *= amount;result.blush *= amount;result.eyes *= amount
        result.lips *= amount;result.lipVolume *= amount;result.faceShape *= amount
        result.skin *= amount;result.brows *= amount
        return result
    }
}

/// Makeup layers have separate anatomical frames. The observed silhouette bounds
/// skin pigments; current lid and mouth contours own eye and lip placement.
enum MakeupRendering {
    static let oval = [10,338,297,332,284,251,389,356,454,323,361,288,397,365,379,378,400,377,152,148,176,149,150,136,172,58,132,93,234,127,162,21,54,103,67,109]
    static let outerLip = [61,185,40,39,37,0,267,269,270,409,291,375,321,405,314,17,84,181,91,146]
    static let innerLip = [78,191,80,81,82,13,312,311,310,415,308,324,318,402,317,14,87,178,88,95]
    static func path(_ points:[CGPoint],closed:Bool = true,smooth:Bool = true) -> CGPath {
        MakeupPaint.path(points,closed:closed,smooth:smooth)
    }
    static func lipPath(_ points:[CGPoint]) -> CGPath { MakeupPaint.lipPath(points) }
    static func draw(in ctx:CGContext,face:PhotoGeometry,options:MakeupOptions) {
        let options=options.effective
        guard options.enabled,let geometry=face.makeup,geometry.points.count == 468,
              geometry.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        let opacity=MakeupPaint.clamp(face.trackingOpacity)*MakeupPaint.clamp(geometry.opacity)
        guard opacity > 0 else { return }
        let extent=face.bounds.insetBy(dx:-face.bounds.width*2,dy:-face.bounds.width*2)
        let mouth=geometry.outerLips.count >= 3 ? geometry.outerLips : geometry.polygon(outerLip)
        let holes=(0..<2).map { index in
            face.eyes.count > index && face.eyes[index].count >= 3 ? face.eyes[index] : geometry.polygon(LashMesh.eyes[index])
        }+[mouth]
        ctx.saveGState()
        ctx.addPath(geometry.skinCoveragePath);ctx.clip()
        for hole in holes { MakeupPaint.exclude(ctx,hole,extent:extent,padding:face.bounds.width*0.0015) }
        MakeupSkin.draw(in:ctx,face:face,geometry:geometry,contour:MakeupPaint.clamp(options.contour)*opacity,blush:MakeupPaint.clamp(options.blush)*opacity,look:options.look)
        MakeupEyes.draw(in:ctx,face:face,geometry:geometry,amount:MakeupPaint.clamp(options.eyes)*opacity,look:options.look)
        MakeupBrows.draw(in:ctx,face:face,geometry:geometry,amount:MakeupPaint.clamp(options.brows)*opacity,look:options.look)
        ctx.restoreGState()
        MakeupLips.draw(in:ctx,face:face,geometry:geometry,amount:MakeupPaint.clamp(options.lips)*opacity,blur:options.lipBlur,look:options.look)
    }
}
