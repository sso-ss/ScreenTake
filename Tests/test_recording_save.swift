import Foundation

enum RecordingSaveTestError: Error {
    case failed(String)
}

@main
struct RecordingSaveTest {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recording-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("temporary.mov")
        let destination = directory.appendingPathComponent("My Recording.mov")
        let content = Data("finished recording".utf8)
        try content.write(to: source)
        let state = RecordingState()
        state.lastRecordingURL = source
        try await state.saveRecording(from: source, to: destination)
        guard try Data(contentsOf: destination) == content,
              try Data(contentsOf: source) == content,
              state.lastRecordingURL == destination else {
            throw RecordingSaveTestError.failed("Save lost source data or failed to update the saved location")
        }
        print("PASS: save copies recording and retains temporary original")

        try Data("older file".utf8).write(to: destination)
        try await state.saveRecording(from: source, to: destination)
        guard try Data(contentsOf: destination) == content else {
            throw RecordingSaveTestError.failed("Confirmed replacement failed")
        }
        print("PASS: confirmed overwrite replaces existing destination")

        try await state.saveRecording(from: source, to: source)
        guard try Data(contentsOf: source) == content else {
            throw RecordingSaveTestError.failed("Saving to source changed the recording")
        }
        print("PASS: saving to original path preserves recording")

        do {
            try await state.saveRecording(from: directory.appendingPathComponent("missing.mov"), to: destination)
            throw RecordingSaveTestError.failed("Missing source did not fail")
        } catch is RecordingSaveTestError {
            throw RecordingSaveTestError.failed("Missing source did not fail")
        } catch {
            guard try Data(contentsOf: destination) == content,
                try Data(contentsOf: source) == content else {
                throw RecordingSaveTestError.failed("Failed save damaged existing files")
            }
        }
        print("PASS: failed save preserves destination and temporary original")
    }
}