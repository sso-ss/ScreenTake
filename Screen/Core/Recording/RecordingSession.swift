import Foundation

/// Recording session state machine
final class RecordingSession {

    // MARK: - State

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case stopping
        case completed(URL?)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.preparing, .preparing),
                 (.recording, .recording), (.paused, .paused),
                 (.stopping, .stopping):
                return true
            case (.completed(let a), .completed(let b)):
                return a == b
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: - Properties

    let id: UUID
    let target: CaptureTarget
    let outputURL: URL
    private(set) var state: State = .idle
    private(set) var frameCount: Int64 = 0
    private(set) var startDate: Date?

    // MARK: - Init

    init(target: CaptureTarget) {
        self.id = UUID()
        self.target = target

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Screen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        self.outputURL = dir.appendingPathComponent("recording-\(timestamp).mov")
    }

    // MARK: - Transitions

    func transition(to newState: State) {
        state = newState
        if case .recording = newState {
            startDate = Date()
        }
    }

    func incrementFrameCount() {
        frameCount += 1
    }
}
