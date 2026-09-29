import Foundation
import AVFoundation
import UniformTypeIdentifiers

enum PhoneContentMode: String, CaseIterable, Codable {
    case fit, fill

    var displayName: String { rawValue.capitalized }
}

struct VideoEditSettings: Equatable {
    var ratio: CanvasRatio = .original
    var layout: DeviceLayout = .desktop
    var wallpaper: BackgroundStyle.WallpaperPreset = .sonoma
    var desktopCornerRadius: Double = 0.025
    var backgroundEnabled = true
    var crop = PhoneCrop()
    var phoneMode: PhoneContentMode = .fit
    var showCursor = true
    var cursorShape: CursorShape = .arrow
    var cursorScale: Double = 1
    var zoomEnabled = false
    var zoomLevel: Double = 2
    var zoomSegments: [ZoomSegment]? = nil
    var webcamEnabled = false
    var webcamShape: PiPShape = .circle
    var webcamPosition: PiPPosition = .bottomRight
    var webcamSize: PiPSize = .medium
    var videoOverlayURL: URL?
    var audioEnabled = true
    var voiceOverURL: URL?
    var trim = VideoTrim()
}

struct ZoomSegment: Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var zoom: Double
    var centerX: Double
    var centerY: Double
    var followsCursor = true
}

struct PhoneCrop: Equatable {
    var rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    func dragged(by delta: CGSize, corner: Corner? = nil) -> PhoneCrop {
        let start = normalized
        guard let corner else {
            return PhoneCrop(rect: CGRect(x: min(1 - start.width, max(0, start.minX + delta.width)),
                                          y: min(1 - start.height, max(0, start.minY + delta.height)),
                                          width: start.width, height: start.height))
        }
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let minX = left ? min(start.maxX - 0.02, max(0, start.minX + delta.width)) : start.minX
        let maxX = left ? start.maxX : max(start.minX + 0.02, min(1, start.maxX + delta.width))
        let minY = top ? min(start.maxY - 0.02, max(0, start.minY + delta.height)) : start.minY
        let maxY = top ? start.maxY : max(start.minY + 0.02, min(1, start.maxY + delta.height))
        return PhoneCrop(rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    var normalized: CGRect {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
              rect.width > 0, rect.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let width = min(1, max(0.02, rect.width))
        let height = min(1, max(0.02, rect.height))
        return CGRect(x: min(1 - width, max(0, rect.minX)), y: min(1 - height, max(0, rect.minY)), width: width, height: height)
    }

    func pixelRect(in size: CGSize) -> CGRect {
        let crop = normalized
        return CGRect(x: crop.minX * size.width, y: (1 - crop.maxY) * size.height,
                      width: crop.width * size.width, height: crop.height * size.height)
            .integral.intersection(CGRect(origin: .zero, size: size))
    }
}

enum CanvasRatio: String, CaseIterable, Codable {
    case original, landscape, desktop, square, portrait, vertical

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .landscape: return "16:9 · Widescreen"
        case .desktop: return "16:10 · Desktop"
        case .square: return "1:1 · Square"
        case .portrait: return "4:5 · Portrait"
        case .vertical: return "9:16 · Stories / Reels"
        }
    }

    func size(source: CGSize) -> CGSize {
        switch self {
        case .original: return source
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .desktop: return CGSize(width: 1920, height: 1200)
        case .square: return CGSize(width: 1080, height: 1080)
        case .portrait: return CGSize(width: 1080, height: 1350)
        case .vertical: return CGSize(width: 1080, height: 1920)
        }
    }
}

enum DeviceLayout: String, CaseIterable, Codable {
    case desktop, iPhone, duo, iPhoneDuoClosed, iPhoneDuoUnfolded

    static let allCases: [DeviceLayout] = [.desktop, .iPhone]

    var isPhone: Bool {
        self == .iPhone || self == .iPhoneDuoClosed || self == .iPhoneDuoUnfolded
    }

    var isFoldablePhone: Bool {
        self == .iPhoneDuoClosed || self == .iPhoneDuoUnfolded
    }

    var phoneFrameSize: CGSize {
        switch self {
        case .iPhoneDuoClosed: return CGSize(width: 554, height: 778)
        case .iPhoneDuoUnfolded: return CGSize(width: 1116, height: 798)
        default: return CGSize(width: 414, height: 868)
        }
    }

    var displayName: String {
        switch self {
        case .desktop: return "Desktop"
        case .iPhone: return "iPhone"
        case .duo: return "Duo"
        case .iPhoneDuoClosed: return "Duo Closed"
        case .iPhoneDuoUnfolded: return "Duo Unfolded"
        }
    }

    var symbol: String {
        switch self {
        case .desktop: return "macwindow"
        case .iPhone: return "iphone"
        case .duo: return "rectangle.on.rectangle"
        case .iPhoneDuoClosed: return "rectangle.portrait"
        case .iPhoneDuoUnfolded: return "rectangle"
        }
    }
}

/// Export codec
enum VideoCodec: String, Codable, CaseIterable {
    case h264
    case hevc
    case proRes

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .proRes: return "ProRes 422"
        }
    }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proRes: return .proRes422
        }
    }

    var avFileType: AVFileType {
        switch self {
        case .h264: return .mp4
        case .hevc: return .mov
        case .proRes: return .mov
        }
    }
}

/// Export quality
enum ExportQuality: String, Codable, CaseIterable {
    case low
    case medium
    case high
    case original

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .original: return "Original"
        }
    }

    func bitRate(for size: CGSize) -> Int {
        let pixels = Int(size.width * size.height)
        switch self {
        case .low: return max(2_000_000, pixels / 200)
        case .medium: return max(5_000_000, pixels / 100)
        case .high: return max(15_000_000, pixels / 40)
        case .original: return max(30_000_000, pixels / 20)
        }
    }
}

/// Output resolution
enum OutputResolution: Codable, Equatable, Hashable {
    case original
    case uhd4k
    case qhd1440
    case fhd1080
    case hd720
    case custom(width: Int, height: Int)

    func size(sourceSize: CGSize) -> CGSize {
        switch self {
        case .original: return sourceSize
        case .uhd4k: return CGSize(width: 3840, height: 2160)
        case .qhd1440: return CGSize(width: 2560, height: 1440)
        case .fhd1080: return CGSize(width: 1920, height: 1080)
        case .hd720: return CGSize(width: 1280, height: 720)
        case .custom(let w, let h): return CGSize(width: w, height: h)
        }
    }

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .uhd4k: return "4K (3840×2160)"
        case .qhd1440: return "1440p (2560×1440)"
        case .fhd1080: return "1080p (1920×1080)"
        case .hd720: return "720p (1280×720)"
        case .custom(let w, let h): return "\(w)×\(h)"
        }
    }
}

/// Output frame rate
enum OutputFrameRate: Codable, Equatable, Hashable {
    case source
    case fixed(Int)

    func value(sourceFrameRate: Double) -> Double {
        switch self {
        case .source: return sourceFrameRate
        case .fixed(let fps): return Double(fps)
        }
    }

    var displayName: String {
        switch self {
        case .source: return "Source"
        case .fixed(let fps): return "\(fps) fps"
        }
    }
}

/// Export format
enum ExportFormat: String, Codable {
    case video
    case gif
}

/// Color space
enum OutputColorSpace: String, Codable {
    case auto
    case sRGB
    case displayP3

    var cgColorSpace: CGColorSpace? {
        switch self {
        case .auto: return nil
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)
        }
    }
}

/// Render settings — codec, quality, resolution, background
enum PiPShape: String, Codable, CaseIterable {
    case circle
    case roundedSquare

    var displayName: String {
        switch self {
        case .circle: return "Circle"
        case .roundedSquare: return "Rounded Square"
        }
    }
}

/// Webcam PiP position on a 3-by-3 grid
enum PiPPosition: String, Codable, CaseIterable {
    case topLeft
    case topCenter
    case topRight
    case middleLeft
    case center
    case middleRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .middleLeft: return "Middle Left"
        case .center: return "Center"
        case .middleRight: return "Middle Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        }
    }

    var horizontalFraction: CGFloat {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft: return 0
        case .topCenter, .center, .bottomCenter: return 0.5
        case .topRight, .middleRight, .bottomRight: return 1
        }
    }

    var verticalFraction: CGFloat {
        switch self {
        case .topLeft, .topCenter, .topRight: return 0
        case .middleLeft, .center, .middleRight: return 0.5
        case .bottomLeft, .bottomCenter, .bottomRight: return 1
        }
    }
}

/// Webcam PiP size relative to output height
enum PiPSize: String, Codable, CaseIterable {
    case small
    case medium
    case large

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Fraction of output height for the PiP diameter
    var fraction: CGFloat {
        switch self {
        case .small: return 0.15
        case .medium: return 0.22
        case .large: return 0.30
        }
    }
}

/// Render settings — codec, quality, resolution, background
struct RenderSettings: Codable, Equatable {
    var codec: VideoCodec = .hevc
    var quality: ExportQuality = .high
    var outputResolution: OutputResolution = .original
    var outputFrameRate: OutputFrameRate = .source
    var exportFormat: ExportFormat = .video
    var outputColorSpace: OutputColorSpace = .auto

    // Background (window mode)
    var backgroundEnabled: Bool = true
    var backgroundColor: CodableColor = CodableColor(hex: "#1c1c1e")
    var backgroundStyle: BackgroundStyle = .solid(CodableColor(hex: "#1c1c1e"))
    var cornerRadius: CGFloat = 12
    var shadowEnabled: Bool = true
    var shadowRadius: CGFloat = 60
    var shadowOpacity: CGFloat = 0.35
    var padding: CGFloat = 40

    // Audio
    var systemAudioVolume: Float = 1.0
    var microphoneAudioVolume: Float = 1.0
    var includeSystemAudio: Bool = true
    var includeMicrophoneAudio: Bool = true

    // Webcam PiP
    var webcamPiPEnabled: Bool = false
    var webcamPiPPosition: PiPPosition = .bottomRight
    var webcamPiPSize: PiPSize = .medium

    // MARK: - Computed

    var exportUTType: UTType {
        switch exportFormat {
        case .video:
            return codec == .h264 ? .mpeg4Movie : .quickTimeMovie
        case .gif:
            return .gif
        }
    }
}
