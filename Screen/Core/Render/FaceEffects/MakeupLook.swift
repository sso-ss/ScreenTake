import Foundation

enum MakeupLook: String, Codable, CaseIterable, Identifiable {
    case roseGlam, softPeach
    var id: String { rawValue }
    var name: String { self == .roseGlam ? "로즈 글램" : "소프트 피치" }
    var detail: String {
        self == .roseGlam ? "로즈 음영 · 핑크 블러시 · 블러 립" : "브라운 눈매·눈썹 · 피치 블러시 · 코랄 로즈 립"
    }
    var defaults: LashOptions {
        var result=LashOptions();result.makeup.enabled=true;result.makeup.look=self
        if self == .softPeach {
            result.style = .wispy;result.intensity=0.72;result.length=0.74;result.lowerLength=0.78
            result.makeup.skin=0.78;result.makeup.faceShape=0.28
            result.makeup.contour=0.42;result.makeup.blush=0.62;result.makeup.eyes=0.80
            result.makeup.brows=0.60
            result.makeup.lips=1;result.makeup.lipBlur=0.78;result.makeup.lipVolume=0.55
        }
        return result
    }
}
