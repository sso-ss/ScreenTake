import Foundation

/// Stages completed media before replacing a destination, leaving the source intact.
enum VideoFileStore {
    static func copy(from source: URL, to destination: URL) async throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        try await Task.detached(priority: .userInitiated) {
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() } }
            let manager = FileManager.default
            let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                            appropriateFor: destination, create: true)
            defer { try? manager.removeItem(at: directory) }
            let stagedFile = directory.appendingPathComponent(destination.lastPathComponent)
            try manager.copyItem(at: source, to: stagedFile)
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: stagedFile)
            } else {
                try manager.moveItem(at: stagedFile, to: destination)
            }
        }.value
    }
}
