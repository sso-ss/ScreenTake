import Foundation

/// Tracks downloaded work separately from edits rendered by Apply Changes.
struct VideoReplacementState<Edits: Equatable> {
    private var savedEdits: Edits?
    private var needsDownload = false

    mutating func beginVideo(edits: Edits, needsDownload: Bool) {
        savedEdits = edits
        self.needsDownload = needsDownload
    }

    mutating func markRendered() {
        needsDownload = true
    }

    mutating func markDownloaded(edits: Edits) {
        savedEdits = edits
        needsDownload = false
    }

    func needsConfirmation(for edits: Edits) -> Bool {
        guard let savedEdits else { return false }
        return needsDownload || savedEdits != edits
    }
}

enum VideoReplacementAction {
    case importVideo(URL)
    case importProject(URL)
    case record

    var buttonTitle: String {
        switch self {
        case .importVideo: return "Discard & Import"
        case .importProject: return "Discard & Open"
        case .record: return "Discard & Record"
        }
    }

    var message: String {
        let action: String
        switch self {
        case .importVideo: action = "importing another video"
        case .importProject: action = "opening another project"
        case .record: action = "starting a new recording"
        }
        return "Unsaved work in this editing session will be lost. Save your project, or apply your changes and download the video, before \(action) to keep your work."
    }
}
