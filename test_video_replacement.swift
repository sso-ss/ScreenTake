import Foundation

@main
struct VideoReplacementTests {
    static func main() {
        struct Edits: Equatable {
            var trimStart = 0
            var voiceOver = false
        }
        let original = Edits()
        let edited = Edits(trimStart: 2, voiceOver: true)
        var work = VideoReplacementState<Edits>()
        precondition(!work.needsConfirmation(for: original), "Empty editor must not warn")

        work.beginVideo(edits: original, needsDownload: false)
        precondition(!work.needsConfirmation(for: original), "Unchanged imported file is already on disk")
        precondition(work.needsConfirmation(for: edited), "Pending trim and voice-over must be protected")
        precondition(!work.needsConfirmation(for: original), "Reverting all pending edits clears the warning")

        work.markRendered()
        precondition(work.needsConfirmation(for: edited), "Apply Changes is not Download")
        precondition(work.needsConfirmation(for: original), "An undownloaded render must still be protected")
        work.markDownloaded(edits: edited)
        precondition(!work.needsConfirmation(for: edited), "Successful download clears the warning")
        precondition(work.needsConfirmation(for: original), "Edits made after download must be protected")

        work.beginVideo(edits: original, needsDownload: true)
        precondition(work.needsConfirmation(for: original), "New recordings must be protected before download")
        work.markDownloaded(edits: original)
        precondition(!work.needsConfirmation(for: original), "Downloaded recording can be replaced")

        work.beginVideo(edits: original, needsDownload: false)
        precondition(!work.needsConfirmation(for: original), "Replacement starts a fresh saved baseline")
        print("PASS: empty, imported, edited, reverted, rendered, downloaded, and recorded sessions")
    }
}
