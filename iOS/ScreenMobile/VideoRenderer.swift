import AVFoundation
import CoreImage
import UIKit

enum VideoRenderer {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func composition(asset: AVAsset, sourceSize: CGSize, settings: EditSettings,
                            frameRate: Float) -> AVMutableVideoComposition {
        let canvas = settings.format.size(for: sourceSize)
        let bounds = CGRect(origin: .zero, size: canvas)
        let background = backgroundImage(settings.background, bounds: bounds)
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let result = render(request.sourceImage, at: request.compositionTime.seconds,
                                settings: settings, canvas: canvas, background: background)
            request.finish(with: result, context: context)
        }
        composition.renderSize = canvas
        composition.frameDuration = CMTime(value: 1, timescale: Int32(max(1, min(60, frameRate.rounded()))))
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }

    static func render(_ source: CIImage, at time: Double, settings: EditSettings,
                       canvas: CGSize, background: CIImage) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        let normalized = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX,
                                                                 y: -source.extent.minY))
        let rect = settings.videoRect(source: normalized.extent.size, canvas: canvas)
        let zoom = settings.zoom(at: time)
        let scale = rect.width / normalized.extent.width * zoom
        let offsetX = rect.minX - rect.width * (zoom - 1) * settings.focusX
        let offsetY = rect.minY - rect.height * (zoom - 1) * (1 - settings.focusY)
        let video = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .cropped(to: rect)
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": min(rect.width, rect.height) * settings.cornerRadius,
            "inputColor": CIColor.white
        ])!.outputImage!.cropped(to: bounds)
        return video.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ]).cropped(to: bounds)
    }

    static func backgroundImage(_ background: MobileBackground, bounds: CGRect) -> CIImage {
        if let name = background.assetName,
           let image = UIImage(named: name)?.cgImage {
            let source = CIImage(cgImage: image)
            let scale = max(bounds.width / source.extent.width, bounds.height / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return scaled.transformed(by: CGAffineTransform(translationX: (bounds.width - scaled.extent.width) / 2,
                                                            y: (bounds.height - scaled.extent.height) / 2))
                .cropped(to: bounds)
        }
        return CIImage(color: background == .white ? .white : .black).cropped(to: bounds)
    }
}