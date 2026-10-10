import AppKit
import CoreImage
import ScreenCaptureKit

@main
struct ZoomQualityTests {
    @MainActor
    static func main() async throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let size = CGSize(width: 256, height: 128)
        let bounds = CGRect(origin: .zero, size: size)
        let bitmap = CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(bounds)
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
        for column in stride(from: 0, to: 256, by: 2) {
            bitmap.fill(CGRect(x: column, y: 0, width: 1, height: 128))
        }
        let image = CIImage(cgImage: bitmap.makeImage()!)
        let transform = CameraTransform(zoom: 2, centerX: 0.5, centerY: 0.5)
        let result = TransformApplicator.apply(transform, to: image, sourceSize: size)
        let basic = image.cropped(to: CGRect(x: 64, y: 32, width: 128, height: 64))
            .transformed(by: CGAffineTransform(translationX: -64, y: -32))
            .transformed(by: CGAffineTransform(scaleX: 2, y: 2))

        func contrast(_ input: CIImage) -> Double {
            let rendered = NSBitmapImageRep(cgImage: context.createCGImage(input, from: bounds)!)
            var total: Double = 0
            for column in 16..<240 {
                let color = rendered.colorAt(x: column, y: 64)!.usingColorSpace(.sRGB)!
                total += abs(Double(color.redComponent) - 0.5)
            }
            return total / 224
        }
        let baseline = contrast(basic)
        let improved = contrast(result)
        print("Fine-line contrast: basic=\(baseline), zoom=\(improved)")
        precondition(abs(improved - baseline) < 0.0001, "Zoom introduced additional resampling")
        precondition(result.extent == bounds)
        for center in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)] {
            let edge = TransformApplicator.apply(.init(zoom: 2, centerX: center.x, centerY: center.y),
                                                to: image, sourceSize: size)
            let rendered = NSBitmapImageRep(cgImage: context.createCGImage(edge, from: bounds)!)
            precondition(rendered.colorAt(x: 0, y: 0)!.alphaComponent > 0.99)
            precondition(rendered.colorAt(x: 255, y: 127)!.alphaComponent > 0.99)
        }
        let renderer = LiveEditFrameRenderer(sourceSize: CGSize(width: 3840, height: 2160),
                                            settings: .init(backgroundEnabled: false, showCursor: false), keyframes: [])
        precondition(renderer.outputSize == CGSize(width: 2560, height: 1440), "Retina preview loses source detail")
        print("PASS: unchanged zoom sampling, opaque boundaries and Retina-resolution preview")
        if CommandLine.arguments.contains("--display") {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            for display in content.displays {
                guard let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                }) else { continue }
                let configuration = CaptureConfiguration.forTarget(.display(display))
                precondition(configuration.scaleFactor == screen.backingScaleFactor)
                precondition(configuration.width == Int(CGFloat(display.width) * screen.backingScaleFactor))
                precondition(configuration.height == Int(CGFloat(display.height) * screen.backingScaleFactor))
                let override = CaptureConfiguration.forTarget(.display(display), scaleFactor: 1)
                precondition(override.width == display.width && override.height == display.height)
                print("PASS: display \(display.displayID) captured at native \(configuration.width)x\(configuration.height), scale \(configuration.scaleFactor)")
            }
            for window in content.windows where window.frame.width > 1 && window.frame.height > 1 {
                let configuration = CaptureConfiguration.forTarget(.window(window))
                precondition(configuration.width >= 2 && configuration.width.isMultiple(of: 2))
                precondition(configuration.height >= 2 && configuration.height.isMultiple(of: 2))
                for display in content.displays where CGDisplayBounds(display.displayID).contains(window.frame) {
                    let expected = CaptureConfiguration.forTarget(.display(display)).scaleFactor
                    precondition(configuration.scaleFactor == expected, "Window uses another display's scale")
                }
            }
            print("PASS: window capture uses its display scale and even encoder dimensions")
        }
    }
}