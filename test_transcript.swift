import AppKit
import Foundation
import Speech

@main
struct TranscriptTest {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: transcript-test <audio-file>\n", stderr)
            exit(2)
        }

        let delegate = TranscriptAppDelegate(audioPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }

    static func transcribe(audioPath: String) async {
        fputs("Main bundle: \(Bundle.main.bundleURL.path), Speech usage: \(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") ?? "missing")\n", stderr)

        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authorization == .authorized else {
            NSLog("Speech authorization status: %d", authorization.rawValue)
            fputs("Speech recognition authorization: \(authorization.rawValue)\n", stderr)
            exit(1)
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US")),
              recognizer.supportsOnDeviceRecognition else {
            fputs("On-device English recognition is unavailable.\n", stderr)
            exit(1)
        }

        let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: audioPath))
        request.requiresOnDeviceRecognition = true
        do {
            let transcript = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                var completed = false
                _ = recognizer.recognitionTask(with: request) { result, error in
                    guard !completed else { return }
                    if let error {
                        completed = true
                        continuation.resume(throwing: error)
                    } else if let result, result.isFinal {
                        completed = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }
            NSLog("Transcript: %@", transcript)
            print(transcript)
        } catch {
            NSLog("Transcription failed: %@", String(describing: error))
            fputs("Transcription failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

final class TranscriptAppDelegate: NSObject, NSApplicationDelegate {
    let audioPath: String

    init(audioPath: String) {
        self.audioPath = audioPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await TranscriptTest.transcribe(audioPath: audioPath)
            NSApp.terminate(nil)
        }
    }
}