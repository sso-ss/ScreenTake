import Foundation
import CoreGraphics

/// Capture metadata — display bounds, scale factor
struct CaptureMeta: Codable, Equatable {
    var displayID: UInt32?
    var boundsPt: CGRect
    var scaleFactor: CGFloat

    init(
        displayID: UInt32? = nil,
        boundsPt: CGRect = .zero,
        scaleFactor: CGFloat = 2.0
    ) {
        self.displayID = displayID
        self.boundsPt = boundsPt
        self.scaleFactor = scaleFactor
    }

    // MARK: - Computed

    var sizePixel: CGSize {
        CGSize(
            width: boundsPt.width * scaleFactor,
            height: boundsPt.height * scaleFactor
        )
    }

    var sizePt: CGSize {
        CGSize(width: boundsPt.width, height: boundsPt.height)
    }
}
