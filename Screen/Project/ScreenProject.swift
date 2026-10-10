import Foundation
import CoreGraphics

/// Placeholder timeline — future editing data
struct Timeline: Codable {
    var keyframes: [CameraKeyframe] = []

    init() {}
}

/// ScreenTake project file — contains recorded media and timeline editing data
struct ScreenProject: Codable, Identifiable {
    let id: UUID
    var version: Int = 1
    var name: String
    var createdAt: Date
    var modifiedAt: Date

    // Media reference
    var media: MediaAsset
    var captureMeta: CaptureMeta

    // Timeline
    var timeline: Timeline

    // Rendering settings
    var renderSettings: RenderSettings

    init(
        id: UUID = UUID(),
        name: String,
        media: MediaAsset,
        captureMeta: CaptureMeta,
        timeline: Timeline = Timeline(),
        renderSettings: RenderSettings = RenderSettings()
    ) {
        self.id = id
        self.version = 1
        self.name = name
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.media = media
        self.captureMeta = captureMeta
        self.timeline = timeline
        self.renderSettings = renderSettings
    }

    // MARK: - Constants

    static let packageExtension = "screentake"
    // Read packages created before the naming correction; all new saves use
    // ScreenTake's extension, including Save As from one of these packages.
    static let readablePackageExtensions = [packageExtension, "screenize"]

    // MARK: - File Operations

    func encodeToJSON() throws -> Data {
        var project = self
        project.modifiedAt = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(project)
    }

    static func decodeFromJSON(_ data: Data) throws -> ScreenProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScreenProject.self, from: data)
    }

    // MARK: - Computed

    var isWindowMode: Bool {
        captureMeta.displayID == nil
    }
}
