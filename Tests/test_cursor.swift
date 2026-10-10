import AppKit

@main
struct CursorTests {
    static func main() {
        for shape in CursorShape.allCases {
            let small = CursorImageProvider.cgImage(width: 24, screenScale: 1, shape: shape)!
            let large = CursorImageProvider.cgImage(width: 48, screenScale: 1, shape: shape)!
            precondition(small.width == 24 && large.width == 48)
            let hotspot = CursorImageProvider.hotspot(shape: shape, imageSize: CGSize(width: small.width, height: small.height))
            precondition(hotspot.x >= 0 && hotspot.x < CGFloat(small.width))
            precondition(hotspot.y >= 0 && hotspot.y < CGFloat(small.height))
            precondition(CursorImageProvider.nsImage(width: 24, shape: shape) != nil)
            print("PASS: \(shape.displayName) raster, scale, and hotspot")
        }
        precondition(CursorImageProvider.hotspot(shape: .circle, imageSize: CGSize(width: 24, height: 24)) == CGPoint(x: 12, y: 12))
        let circle = CursorImageProvider.cgImage(width: 24, screenScale: 1, shape: .circle)!
        let center = circle.dataProvider!.data!
        let bytes = CFDataGetBytePtr(center)!
        let centerOffset = (12 * circle.bytesPerRow) + (12 * 4)
        let centerAlpha = bytes[centerOffset + 3]
        precondition(centerAlpha > 50 && centerAlpha < 180, "Circle center must remain strongly frosted but translucent, alpha=\(centerAlpha)")
        precondition(bytes[centerOffset] > 0 && bytes[centerOffset + 1] > 0 && bytes[centerOffset + 2] > 0,
                 "Circle center must not be black")
        print("PASS: Circle uses a translucent glass center")
        precondition(CursorImageProvider.cgImage(width: .infinity) == nil)
        precondition(CursorImageProvider.cgImage(width: -1) == nil)
        precondition(CursorImageProvider.cgImage(width: 10000) == nil)
    }
}