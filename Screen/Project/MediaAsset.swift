import Foundation
import CoreGraphics

/// Media asset — stores relative paths within the .screenize package
struct MediaAsset: Codable, Equatable {
    var videoRelativePath: String
    var mouseDataRelativePath: String?
    var micAudioRelativePath: String?
    var systemAudioRelativePath: String?
    var webcamVideoRelativePath: String?

    var pixelSize: CGSize
    var frameRate: Double
    var duration: TimeInterval
    var isVariableFrameRate: Bool

    // MARK: - Transient (not encoded)

    private var _packageRootURL: URL?

    var packageRootURL: URL? {
        get { _packageRootURL }
        set { _packageRootURL = newValue }
    }

    // MARK: - Init

    init(
        videoRelativePath: String,
        mouseDataRelativePath: String? = nil,
        micAudioRelativePath: String? = nil,
        systemAudioRelativePath: String? = nil,
        webcamVideoRelativePath: String? = nil,
        packageRootURL: URL? = nil,
        pixelSize: CGSize,
        frameRate: Double,
        duration: TimeInterval,
        isVariableFrameRate: Bool = true
    ) {
        self.videoRelativePath = videoRelativePath
        self.mouseDataRelativePath = mouseDataRelativePath
        self.micAudioRelativePath = micAudioRelativePath
        self.systemAudioRelativePath = systemAudioRelativePath
        self.webcamVideoRelativePath = webcamVideoRelativePath
        self._packageRootURL = packageRootURL
        self.pixelSize = pixelSize
        self.frameRate = frameRate
        self.duration = duration
        self.isVariableFrameRate = isVariableFrameRate
    }

    // MARK: - Resolved URLs

    var videoURL: URL {
        guard let root = packageRootURL else {
            return URL(fileURLWithPath: videoRelativePath)
        }
        return root.appendingPathComponent(videoRelativePath)
    }

    var mouseDataURL: URL? {
        guard let path = mouseDataRelativePath, let root = packageRootURL else { return nil }
        return root.appendingPathComponent(path)
    }

    var micAudioURL: URL? {
        guard let path = micAudioRelativePath, let root = packageRootURL else { return nil }
        return root.appendingPathComponent(path)
    }

    var systemAudioURL: URL? {
        guard let path = systemAudioRelativePath, let root = packageRootURL else { return nil }
        return root.appendingPathComponent(path)
    }

    var webcamVideoURL: URL? {
        guard let path = webcamVideoRelativePath, let root = packageRootURL else { return nil }
        return root.appendingPathComponent(path)
    }

    var systemAudioExists: Bool {
        guard let url = systemAudioURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var micAudioExists: Bool {
        guard let url = micAudioURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Resolve

    mutating func resolveURLs(from packageRoot: URL) {
        self._packageRootURL = packageRoot
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case videoRelativePath = "videoPath"
        case mouseDataRelativePath = "mouseDataPath"
        case micAudioRelativePath = "micAudioPath"
        case systemAudioRelativePath = "systemAudioPath"
        case webcamVideoRelativePath = "webcamVideoPath"
        case pixelSize, frameRate, duration, isVariableFrameRate
    }
}
