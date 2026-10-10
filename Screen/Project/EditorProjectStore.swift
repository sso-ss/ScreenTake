import Foundation

/// URLs are absolute while in memory and package-relative only in project.json.
struct EditorProject: Codable {
    var version = 2
    var id: UUID
    var revision: Int
    var name: String
    var source: URL
    var audio: URL?
    var mouse: URL?
    var settings: VideoEditSettings
}

enum EditorProjectStore {
    struct SaveResult {
        let project: EditorProject
        let mediaMappings: [URL: URL]
    }

    static func save(_ project: EditorProject, to destination: URL,
                     retaining edits: [VideoEditSettings] = []) async throws -> SaveResult {
        guard destination.isFileURL, destination.pathExtension.lowercased() == ScreenProject.packageExtension else {
            throw ProjectError.invalidDestination
        }
        return try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() } }
            let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                           appropriateFor: destination, create: true)
            defer { try? manager.removeItem(at: staging) }
            let bundle = staging.appendingPathComponent("Project.\(ScreenProject.packageExtension)", isDirectory: true)
            try manager.createDirectory(at: bundle.appendingPathComponent("media"), withIntermediateDirectories: true)
            var paths: [URL: URL] = [:]
            func embed(_ source: URL) throws -> URL {
                try Task.checkCancellation()
                guard source.isFileURL, manager.fileExists(atPath: source.path) else {
                    throw ProjectError.missingMedia(source.lastPathComponent)
                }
                let key = source.standardizedFileURL
                if let path = paths[key] { return path }
                let ext = source.pathExtension.filter { $0.isLetter || $0.isNumber }
                let path = "media/\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
                let relative = URL(string: path)!
                try manager.copyItem(at: source, to: bundle.appendingPathComponent(path))
                paths[key] = relative
                return relative
            }
            var saved = project
            saved.source = try embed(project.source)
            saved.audio = try project.audio.map(embed)
            saved.mouse = try project.mouse.map(embed)
            saved.settings.phoneVideoURL = try project.settings.phoneVideoURL.map(embed)
            saved.settings.videoOverlayURL = try project.settings.videoOverlayURL.map(embed)
            for index in saved.settings.voiceOvers.indices {
                saved.settings.voiceOvers[index].url = try embed(project.settings.voiceOvers[index].url)
            }
            // Live undo history may still refer to a removed take. Keep those assets
            // until the session is closed, even though only the current draft is saved.
            for settings in edits {
                if let url = settings.phoneVideoURL { _ = try embed(url) }
                if let url = settings.videoOverlayURL { _ = try embed(url) }
                for clip in settings.voiceOvers { _ = try embed(clip.url) }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: bundle.appendingPathComponent("project.json"), options: .atomic)
            try Task.checkCancellation()
            if manager.fileExists(atPath: destination.path) {
                // Only replace a project bundle, never an unrelated folder.
                guard manager.fileExists(atPath: destination.appendingPathComponent("project.json").path) else {
                    throw ProjectError.invalidDestination
                }
                _ = try manager.replaceItemAt(destination, withItemAt: bundle)
            } else {
                try manager.moveItem(at: bundle, to: destination)
            }
            let mappings = paths.mapValues { destination.appendingPathComponent($0.relativeString) }
            saved.source = destination.appendingPathComponent(saved.source.relativeString)
            saved.audio = saved.audio.map { destination.appendingPathComponent($0.relativeString) }
            saved.mouse = saved.mouse.map { destination.appendingPathComponent($0.relativeString) }
            saved.settings.phoneVideoURL = saved.settings.phoneVideoURL.map { destination.appendingPathComponent($0.relativeString) }
            saved.settings.videoOverlayURL = saved.settings.videoOverlayURL.map { destination.appendingPathComponent($0.relativeString) }
            for index in saved.settings.voiceOvers.indices {
                saved.settings.voiceOvers[index].url = destination.appendingPathComponent(saved.settings.voiceOvers[index].url.relativeString)
            }
            return SaveResult(project: saved, mediaMappings: mappings)
        }.value
    }

    static func load(from package: URL) async throws -> EditorProject {
        try await Task.detached(priority: .userInitiated) {
            guard package.isFileURL else { throw ProjectError.invalidDestination }
            let data = try Data(contentsOf: package.appendingPathComponent("project.json"))
            struct Header: Decodable { let version: Int }
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == 2 else { throw ProjectError.unsupportedVersion(header.version) }
            var project = try decoder.decode(EditorProject.self, from: data)
            guard project.revision >= 0, !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectError.invalidManifest
            }
            let root = package.standardizedFileURL.resolvingSymlinksInPath()
            func resolve(_ relative: URL) throws -> URL {
                let path = relative.relativeString
                guard relative.scheme == nil, !path.hasPrefix("/"), !path.contains("%"),
                      path.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }),
                      path.hasPrefix("media/") else { throw ProjectError.invalidManifest }
                let result = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                guard result.path.hasPrefix(root.path + "/media/") else { throw ProjectError.invalidManifest }
                guard FileManager.default.fileExists(atPath: result.path) else { throw ProjectError.missingMedia(path) }
                return result
            }
            project.source = try resolve(project.source)
            project.audio = try project.audio.map(resolve)
            project.mouse = try project.mouse.map(resolve)
            project.settings.phoneVideoURL = try project.settings.phoneVideoURL.map(resolve)
            project.settings.videoOverlayURL = try project.settings.videoOverlayURL.map(resolve)
            for index in project.settings.voiceOvers.indices {
                project.settings.voiceOvers[index].url = try resolve(project.settings.voiceOvers[index].url)
            }
            try Task.checkCancellation()
            return project
        }.value
    }

    enum ProjectError: LocalizedError {
        case invalidDestination, invalidManifest, missingMedia(String), unsupportedVersion(Int)
        var errorDescription: String? {
            switch self {
            case .invalidDestination: return "Choose a ScreenTake project (.\(ScreenProject.packageExtension)) destination."
            case .invalidManifest: return "This project contains invalid settings or media paths."
            case .missingMedia(let path): return "Project media is missing: \(path). Restore it from a backup and reopen the project."
            case .unsupportedVersion(let version): return "Project format \(version) is not supported by this version of ScreenTake."
            }
        }
    }
}
