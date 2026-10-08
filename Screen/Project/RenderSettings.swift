import Foundation
import AVFoundation
import UniformTypeIdentifiers

enum PhoneContentMode: String, CaseIterable, Codable {
    case fit, fill

    var displayName: String { rawValue.capitalized }
}

struct VideoEditSettings: Equatable, Codable {
    var ratio: CanvasRatio = .original
    var layout: DeviceLayout = .desktop
    var wallpaper: BackgroundStyle.WallpaperPreset = .sonoma
    var desktopCornerRadius: Double = 0.025
    var backgroundEnabled = true
    var crop = PhoneCrop()
    var phoneMode: PhoneContentMode = .fit
    var phoneVideoURL: URL?
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
    var cameraLayout = CameraLayoutSettings()
    /// Layout changes follow camera source time, including moved and trimmed takes.
    var cameraLayoutChanges: [CameraLayoutChange] = []
    var usesFaceTracking: Bool {
        webcamEnabled && (cameraLayout.followFace || cameraLayoutChanges.contains { $0.settings.followFace })
    }
    var videoOverlayURL: URL?
    /// Nil for a camera sidecar synchronized to the original recording.
    var videoOverlayTiming: VideoOverlayTiming?
    var audioEnabled = true
    var originalAudioVolume: Double = 1
    var voiceOverEnabled = true
    var voiceOverVolume: Double = 1
    var voiceOvers: [VoiceOverClip] = []
    var trim = VideoTrim()
    var exportResolution: ExportResolution = .preserveSource

    var usesCanvas: Bool { backgroundEnabled || ratio != .original || layout != .desktop }

    func outputSize(source: CGSize) -> CGSize {
        exportResolution.size(source: source, crop: crop, ratio: ratio, layout: layout,
                              usesCanvas: usesCanvas, phoneMode: phoneMode)
    }
}

enum CameraLayout: String, CaseIterable, Codable {
    case overlay, fullScreen
    var displayName: String { self == .overlay ? "Overlay" : "Full Screen" }
}

enum CameraTransitionMotion: String, CaseIterable, Codable {
    case smooth, linear, easeIn, easeOut

    var displayName: String {
        switch self {
        case .smooth: return "Smooth"
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        }
    }

    func progress(at fraction: Double) -> Double {
        let t = fraction.isFinite ? min(1, max(0, fraction)) : 0
        switch self {
        case .smooth: return t * t * (3 - 2 * t)
        case .linear: return t
        case .easeIn: return t * t
        case .easeOut: return 1 - (1 - t) * (1 - t)
        }
    }
}

struct CameraLayoutSettings: Equatable, Codable {
    var layout: CameraLayout = .overlay
    var zoom: Double = 1
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var followFace: Bool = false
    var smoothTransition: Bool = false
    var transitionDuration: Double = CameraLayoutTransition.duration
    var transitionMotion: CameraTransitionMotion = .smooth

    private enum CodingKeys: String, CodingKey {
        case layout, zoom, centerX, centerY, followFace, smoothTransition, transitionDuration, transitionMotion
    }

    init(layout: CameraLayout = .overlay, zoom: Double = 1, centerX: Double = 0.5,
         centerY: Double = 0.5, followFace: Bool = false, smoothTransition: Bool = false,
         transitionDuration: Double = CameraLayoutTransition.duration, transitionMotion: CameraTransitionMotion = .smooth) {
        self.layout = layout
        self.zoom = zoom
        self.centerX = centerX
        self.centerY = centerY
        self.followFace = followFace
        self.smoothTransition = smoothTransition
        self.transitionDuration = transitionDuration
        self.transitionMotion = transitionMotion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layout = try values.decodeIfPresent(CameraLayout.self, forKey: .layout) ?? .overlay
        zoom = try values.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        centerX = try values.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try values.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5
        followFace = try values.decodeIfPresent(Bool.self, forKey: .followFace) ?? false
        smoothTransition = try values.decodeIfPresent(Bool.self, forKey: .smoothTransition) ?? false
        transitionDuration = try values.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? CameraLayoutTransition.duration
        transitionMotion = try values.decodeIfPresent(CameraTransitionMotion.self, forKey: .transitionMotion) ?? .smooth
    }

    var clampedTransitionDuration: Double {
        transitionDuration.isFinite ? min(2, max(0.1, transitionDuration)) : CameraLayoutTransition.duration
    }

    /// Ignore transition options and framing fields that the current layout
    /// does not use. Changing timing alone must never animate identical views.
    func hasDifferentFraming(from previous: Self) -> Bool {
        if layout != previous.layout || followFace != previous.followFace { return true }
        guard layout == .fullScreen else { return false }
        func zoomValue(_ value: Double) -> Double { value.isFinite ? min(3, max(1, value)) : 1 }
        func centerValue(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.5 }
        if zoomValue(zoom) != zoomValue(previous.zoom) { return true }
        return !followFace && (centerValue(centerX) != centerValue(previous.centerX)
                              || centerValue(centerY) != centerValue(previous.centerY))
    }

    func crop(in source: CGRect, output: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, output.width > 0, output.height > 0 else { return source }
        let scale = max(output.width / source.width, output.height / source.height)
            * CGFloat(zoom.isFinite ? min(3, max(1, zoom)) : 1)
        let size = CGSize(width: output.width / scale, height: output.height / scale)
        let horizontal = CGFloat(centerX.isFinite ? min(1, max(0, centerX)) : 0.5)
        let vertical = CGFloat(centerY.isFinite ? min(1, max(0, centerY)) : 0.5)
        return CGRect(x: source.minX + (source.width - size.width) * horizontal,
                      y: source.minY + (source.height - size.height) * (1 - vertical),
                      width: size.width, height: size.height)
    }
}

struct CameraLayoutChange: Equatable, Codable {
    var start: Double
    var settings: CameraLayoutSettings

    static func settings(at seconds: Double, initial: CameraLayoutSettings,
                         changes: [Self]) -> CameraLayoutSettings {
        changes.filter { $0.start.isFinite && $0.start >= 0 && $0.start <= seconds }
            .max { $0.start < $1.start }?.settings ?? initial
    }

    static func previousSettings(before start: Double, initial: CameraLayoutSettings,
                                 changes: [Self]) -> CameraLayoutSettings {
        changes.filter { $0.start.isFinite && $0.start >= 0 && $0.start < start }
            .max { $0.start < $1.start }?.settings ?? initial
    }

    static func canTransition(into change: Self, initial: CameraLayoutSettings, changes: [Self]) -> Bool {
        guard change.start.isFinite, change.start > 0 else { return false }
        return change.settings.hasDifferentFraming(from: previousSettings(before: change.start, initial: initial, changes: changes))
    }

    /// Resolve in camera source time so seeks, moved takes and exports agree.
    static func transition(at seconds: Double, initial: CameraLayoutSettings,
                           changes: [Self]) -> CameraLayoutTransition? {
        guard seconds.isFinite,
              let change = changes.filter({ $0.start.isFinite && $0.start >= 0 && $0.start <= seconds })
                .max(by: { $0.start < $1.start }), change.settings.smoothTransition,
              canTransition(into: change, initial: initial, changes: changes) else { return nil }
        let previous = previousSettings(before: change.start, initial: initial, changes: changes)
        let next = changes.filter { $0.start.isFinite && $0.start > change.start }.map(\.start).min()
        let duration = min(change.settings.clampedTransitionDuration, next.map { $0 - change.start } ?? .infinity)
        guard duration > 0, seconds < change.start + duration else { return nil }
        let fraction = min(1, max(0, (seconds - change.start) / duration))
        return CameraLayoutTransition(from: previous, to: change.settings,
                                      progress: change.settings.transitionMotion.progress(at: fraction))
    }

    static func split(at outputSeconds: Double, in range: VideoOverlayTimelineRange,
                      initial: CameraLayoutSettings, changes: [Self]) -> Self? {
        guard outputSeconds.isFinite, range.sourceStart.isFinite, range.duration.isFinite,
              outputSeconds >= range.outputStart, outputSeconds < range.outputStart + range.duration else { return nil }
        let sourceTime = range.sourceStart + outputSeconds - range.outputStart
        let boundaries = changes.map(\.start).filter { $0.isFinite && $0 >= 0 }
        let start = max(range.sourceStart, boundaries.filter { $0 <= sourceTime }.max() ?? range.sourceStart)
        let end = min(range.sourceStart + range.duration,
                      boundaries.filter { $0 > sourceTime }.min() ?? range.sourceStart + range.duration)
        guard sourceTime - start >= 1.0 / 30, end - sourceTime >= 1.0 / 30 else { return nil }
        return Self(start: sourceTime, settings: settings(at: sourceTime, initial: initial, changes: changes))
    }
}

struct CameraLayoutTransition {
    static let duration: Double = 0.4
    var from: CameraLayoutSettings
    var to: CameraLayoutSettings
    var progress: Double
}

struct VideoOverlayTiming: Equatable, Codable {
    var start: Double
    var duration: Double
    var sourceStart: Double = 0

    func sampleTime(at outputSeconds: Double) -> CMTime? {
        let seconds = outputSeconds - start
        guard seconds.isFinite, start.isFinite, duration.isFinite, sourceStart.isFinite,
              start >= 0, sourceStart >= 0, seconds >= 0, seconds < duration else { return nil }
        return CMTime(seconds: sourceStart + seconds, preferredTimescale: 60000)
    }

    enum Adjustment { case move, trimStart, trimEnd }

    func adjusted(by delta: Double, adjustment: Adjustment, total: Double, sourceDuration: Double) -> Self {
        guard delta.isFinite, total.isFinite, sourceDuration.isFinite,
              total > 0.05, sourceDuration > 0.05 else { return self }
        var result = self
        switch adjustment {
        case .move:
            result.start = min(total - 0.05, max(0, start + delta))
        case .trimStart:
            guard start < total - 0.05 else { return self }
            let shift = min(duration - 0.05, total - start - 0.05,
                            max(-min(start, sourceStart), delta))
            result.start += shift
            result.sourceStart += shift
            result.duration -= shift
        case .trimEnd:
            guard start < total - 0.05 else { return self }
            result.duration = max(0.05, min(sourceDuration - sourceStart, total - start, duration + delta))
        }
        return result
    }
}

/// A camera sidecar follows source clips; a separately attached take follows edited time.
struct VideoOverlayTimelineRange: Equatable {
    let outputStart: Double
    let sourceStart: Double
    let duration: Double

    static func visible(timing: VideoOverlayTiming?, timeline: EditedTimeline, sourceDuration: Double) -> [Self] {
        guard sourceDuration.isFinite, sourceDuration > 0 else { return [] }
        if let timing {
            let length = min(timing.duration, timeline.duration.seconds - timing.start, sourceDuration - timing.sourceStart)
            guard timing.start.isFinite, timing.sourceStart.isFinite,
                  timing.start >= 0, timing.sourceStart >= 0, length > 0 else { return [] }
            return [Self(outputStart: timing.start, sourceStart: timing.sourceStart, duration: length)]
        }
        var outputStart: Double = 0
        return timeline.ranges.compactMap { range in
            defer { outputStart += range.duration.seconds }
            let start = max(0, range.start.seconds)
            let end = min(sourceDuration, range.end.seconds)
            guard end > start else { return nil }
            return Self(outputStart: outputStart + start - range.start.seconds, sourceStart: start, duration: end - start)
        }
    }
}

struct ZoomSegment: Equatable, Identifiable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
    var zoom: Double
    var centerX: Double
    var centerY: Double
    var followsCursor = true
}

struct PhoneCrop: Equatable, Codable {
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

/// Resolution is independent of canvas shape. Preserve source allows room for
/// the background/device frame without reducing the captured content's pixels.
enum ExportResolution: String, CaseIterable, Codable {
    case preserveSource, uhd4k, fhd1080

    var displayName: String {
        switch self {
        case .preserveSource: return "Preserve source"
        case .uhd4k: return "4K"
        case .fhd1080: return "1080p"
        }
    }

    func size(source: CGSize, crop: PhoneCrop = PhoneCrop(), ratio: CanvasRatio = .original,
              layout: DeviceLayout = .desktop, usesCanvas: Bool = false,
              phoneMode: PhoneContentMode = .fit) -> CGSize {
        let content = crop.pixelRect(in: source).size
        let reference = ratio.size(source: usesCanvas ? source : content)
        let scale: CGFloat
        switch self {
        case .preserveSource:
            scale = 1 / Self.contentScale(source: content, output: reference, layout: layout,
                                          usesCanvas: usesCanvas, phoneMode: phoneMode)
        case .uhd4k, .fhd1080:
            if ratio == .original {
                scale = (self == .uhd4k ? 3840 : 1920) / max(reference.width, reference.height)
            } else {
                scale = self == .uhd4k ? 2 : 1
            }
        }
        // Round up so padding and encoder-safe dimensions cannot shrink content.
        return CGSize(width: max(2, ceil((reference.width * scale - 0.000001) / 2) * 2),
                      height: max(2, ceil((reference.height * scale - 0.000001) / 2) * 2))
    }

    static func contentScale(source: CGSize, output: CGSize, layout: DeviceLayout,
                             usesCanvas: Bool, phoneMode: PhoneContentMode) -> CGFloat {
        let rect: CGRect
        if usesCanvas {
            let geometry = CanvasGeometry(size: output, layout: layout, sourceSize: source)
            if let desktop = geometry.desktop {
                rect = desktop
            } else if let phone = geometry.phone {
                rect = CanvasGeometry.phoneContent(phone, layout: layout)
            } else { return 1 }
        } else { rect = CGRect(origin: .zero, size: output) }
        let horizontal = rect.width / max(1, source.width)
        let vertical = rect.height / max(1, source.height)
        return layout.isPhone && phoneMode == .fill ? max(horizontal, vertical) : min(horizontal, vertical)
    }
}

enum VideoEncodingQuality {
    /// HEVC budgets scale with pixels and frame rate; a recording master gets
    /// extra headroom because it will be decoded and encoded again on export.
    static func bitRate(size: CGSize, frameRate: Double, recordingMaster: Bool = false) -> Int {
        let pixels = Double(size.width * size.height)
        let rate = pixels * max(30, frameRate) * (recordingMaster ? 0.16 : 0.12)
        return max(recordingMaster ? 30_000_000 : 20_000_000, Int(rate.rounded(.up)))
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
