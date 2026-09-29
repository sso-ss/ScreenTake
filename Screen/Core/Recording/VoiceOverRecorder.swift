import AVFoundation
import Combine

@MainActor
final class VoiceOverRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isBusy = false
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published var error: String?
    private var recorder: AVAudioRecorder?
    private var player: AVPlayer?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var output: URL?
    private var start: Double = 0
    private var limit: Double = 0
    private var wasMuted = false
    private var wasWaitingForPlayback = true
    private var completion: ((VoiceOverClip) -> Void)?

    func start(player: AVPlayer, duration: Double, completion: @escaping (VoiceOverClip) -> Void) {
        guard !isBusy, duration.isFinite, duration > 0,
              player.currentItem?.status == .readyToPlay else {
            error = "Wait for the video preview to finish loading, then try again."
            return
        }
        let position = player.currentTime().seconds
        guard position.isFinite, position >= 0, duration - position > 0.1 else {
            error = "Move the playhead before the end of the video to record narration."
            return
        }
        player.pause()
        player.currentItem?.forwardPlaybackEndTime = .invalid
        self.player = player
        start = position
        limit = duration - position
        self.completion = completion
        wasMuted = player.isMuted
        wasWaitingForPlayback = player.automaticallyWaitsToMinimizeStalling
        error = nil
        elapsed = 0
        level = 0
        isBusy = true
        task = Task {
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation()
                guard allowed else {
                    throw VoiceOverError.message("Allow Microphone access for ScreenTake in System Settings > Privacy & Security, then try again.")
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenTake-Voiceovers", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("Voiceover-\(UUID().uuidString).m4a")
                output = url
                let recorder = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000
                ])
                self.recorder = recorder
                recorder.delegate = self
                recorder.isMeteringEnabled = true
                guard recorder.prepareToRecord() else { throw VoiceOverError.message("The microphone could not be prepared. Check your input device and try again.") }
                // Preroll before starting either clock; mute playback to avoid recording speaker output.
                player.isMuted = true
                player.automaticallyWaitsToMinimizeStalling = false
                let ready = await withCheckedContinuation { continuation in
                    player.preroll(atRate: 1) { continuation.resume(returning: $0) }
                }
                try Task.checkCancellation()
                guard ready else { throw VoiceOverError.message("The video preview could not start. Try again once it is ready.") }
                let delay = 0.15
                let hostTime = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), EditorAudio.time(delay))
                guard recorder.record(atTime: recorder.deviceCurrentTime + delay, forDuration: limit) else {
                    throw VoiceOverError.message("The microphone could not start recording.")
                }
                player.setRate(1, time: EditorAudio.time(start), atHostTime: hostTime)
                isRecording = true
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                cancel()
            }
        }
    }

    private func tick() {
        guard isRecording, let recorder, let player else { return }
        recorder.updateMeters()
        level = min(1, pow(10, recorder.averagePower(forChannel: 0) / 20))
        elapsed = max(0, min(limit, recorder.currentTime))
        if elapsed >= limit - 0.03 || (elapsed > 0.3 && player.timeControlStatus != .playing) {
            if elapsed < limit - 0.2 { error = "Narration stopped because video playback paused. Your recorded take was kept." }
            stop()
        }
    }

    func stop() {
        guard isRecording, let recorder, let url = output else { cancel(); return }
        let recordedDuration = min(limit, max(elapsed, recorder.currentTime))
        let finish = completion
        let position = start
        cleanUp(deleteOutput: false)
        guard recordedDuration > 0.05 else {
            try? FileManager.default.removeItem(at: url)
            error = "The take was too short. Record a little longer and try again."
            return
        }
        finish?(VoiceOverClip(url: url, start: position, duration: recordedDuration, sourceDuration: recordedDuration))
    }

    func cancel() { cleanUp(deleteOutput: true) }

    private func cleanUp(deleteOutput: Bool) {
        task?.cancel()
        task = nil
        timer?.invalidate()
        timer = nil
        player?.cancelPendingPrerolls()
        player?.pause()
        player?.isMuted = wasMuted
        player?.automaticallyWaitsToMinimizeStalling = wasWaitingForPlayback
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        player = nil
        if deleteOutput, let output { try? FileManager.default.removeItem(at: output) }
        output = nil
        completion = nil
        isBusy = false
        isRecording = false
        level = 0
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            if flag { elapsed = limit; stop() }
            else { error = "The microphone recording failed. Please try again."; cancel() }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.error = error?.localizedDescription ?? "The narration could not be saved."
            cancel()
        }
    }
}

private enum VoiceOverError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
