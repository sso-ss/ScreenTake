import Foundation
import CoreImage
import AppKit

@main
struct CanvasSizeTests {
    static func main() {
        let source = CGSize(width: 1440, height: 900)
        precondition(CanvasRatio.original.size(source: source) == source)
        for ratio in CanvasRatio.allCases {
            let size = ratio.size(source: source)
            precondition(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0)
            precondition(size.width > 0 && size.height > 0)
        }
        precondition(CanvasRatio.portrait.size(source: source) == CGSize(width: 1080, height: 1350))
        precondition(CanvasRatio.vertical.size(source: source) == CGSize(width: 1080, height: 1920))
        let context = CIContext()
        for ratio in CanvasRatio.allCases {
            let size = ratio.size(source: source)
            for layout in DeviceLayout.allCases {
                let compositor = CanvasCompositor(size: size, sourceSize: source, layout: layout, wallpaper: .lagoon)
                for rect in [compositor.geometry.desktop, compositor.geometry.phone].compactMap({ $0 }) {
                    precondition(compositor.bounds.contains(rect))
                    precondition(rect.width > 0 && rect.height > 0)
                }
                if let desktop = compositor.geometry.desktop, let phone = compositor.geometry.phone {
                    precondition(!desktop.intersects(phone))
                }
                let primary = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: source))
                let phone = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 390, height: 844))
                let result = compositor.composite(primary: primary, phone: phone)
                precondition(result.extent == compositor.bounds)
                precondition(context.createCGImage(result, from: result.extent) != nil)
            }
        }
        let canvasSize = CanvasRatio.portrait.size(source: source)
        let primary = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: source))
        let backgroundOnly = CanvasCompositor(size: canvasSize, sourceSize: source, layout: .iPhone, wallpaper: .lagoon)
        let wallpaper = NSBitmapImageRep(cgImage: context.createCGImage(backgroundOnly.composite(primary: primary), from: backgroundOnly.bounds)!)
        for (radius, shouldShowVideo) in [(0.0, true), (0.1, false)] {
            let compositor = CanvasCompositor(size: canvasSize, sourceSize: source, layout: .desktop,
                                              wallpaper: .lagoon, desktopCornerRadius: radius)
            let frame = context.createCGImage(compositor.composite(primary: primary), from: compositor.bounds)!
            let corner = compositor.geometry.desktop!
            let bitmap = NSBitmapImageRep(cgImage: frame)
            for y in [corner.minY + 2, corner.maxY - 2] {
                let x = Int(corner.maxX - 2)
                let row = bitmap.pixelsHigh - 1 - Int(y)
                let pixel = bitmap.colorAt(x: x, y: row)!.usingColorSpace(.sRGB)!
                if shouldShowVideo {
                    precondition(pixel.redComponent > 0.8 && pixel.greenComponent < 0.2,
                                 "Square desktop corner did not show the video")
                } else {
                    let expected = wallpaper.colorAt(x: x, y: row)!.usingColorSpace(.sRGB)!
                    precondition(abs(pixel.redComponent - expected.redComponent) < 0.12 &&
                                 abs(pixel.greenComponent - expected.greenComponent) < 0.12 &&
                                 abs(pixel.blueComponent - expected.blueComponent) < 0.12,
                                 "Rounded desktop corner still shows chrome instead of wallpaper")
                }
            }
        }
        print("PASS: canvas presets preserve original size and produce encoder-safe social dimensions")
        print("PASS: all \(CanvasRatio.allCases.count * DeviceLayout.allCases.count) canvas/device combinations render with contained, non-overlapping frames")
        print("PASS: desktop corner radius aligns video, chrome, and wallpaper at both right corners")
    }
}