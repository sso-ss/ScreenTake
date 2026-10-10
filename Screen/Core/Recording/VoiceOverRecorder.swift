import AVFoundation
import Combine

@MainActor
final class VoiceOverRecorder: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var isFinishing = false
    @Published var error: String?
    private var recorder: MicrophoneRecorder?
    private var player: AVPlayer?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var output: URL?
    private var start: Double = 0
    private var limit: Double = 0
    private var wasMuted = false
    private var wasWaitingForPlayback = true
    private var hostStart: CMTime = .zero
    private var keepTake = false
    private var completion: ((VoiceOverClip) -> Void)?

    func start(player: AVPlayer, deviceID: String = "", duration: Double,
               completion: @escaping (VoiceOverClip) -> Void) {
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
        isFinishing = false
        keepTake = false
        let recorder = MicrophoneRecorder()
        self.recorder = recorder
        task = Task {
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation()
                guard allowed else {
                    throw VoiceOverError.message("Allow Microphone access for ScreenTake in System Settings > Privacy & Security, then try again.")
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenTake-Voiceovers", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("Voiceover-\(UUID().uuidString).caf")
                output = url
                let device = try Self.microphone(for: deviceID)
                try await Task.detached(priority: .userInitiated) {
                    try recorder.prepare(device: device, outputURL: url)
                }.value
                try Task.checkCancellation()
                try await recorder.waitUntilReady()
                // Preroll before starting either clock; mute playback to avoid recording speaker output.
                player.isMuted = true
                player.automaticallyWaitsToMinimizeStalling = false
                let ready = await withCheckedContinuation { continuation in
                    player.preroll(atRate: 1) { continuation.resume(returning: $0) }
                }
                try Task.checkCancellation()
                guard ready else { throw VoiceOverError.message("The video preview could not start. Try again once it is ready.") }
                hostStart = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), EditorAudio.time(0.15))
                try recorder.startWriting(to: url, startTime: hostStart)
                player.setRate(1, time: EditorAudio.time(start), atHostTime: hostStart)
                isRecording = true
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
                await Task.detached { recorder.tearDown() }.value
                if let output { try? FileManager.default.removeItem(at: output) }
                reset()
            }
        }
    }

    private func tick() {
        guard isRecording, let recorder, let player else { return }
        level = recorder.inputLevel
        elapsed = max(0, min(limit, CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), hostStart).seconds))
        if elapsed >= limit - 0.03 || (elapsed > 0.3 && player.timeControlStatus != .playing) {
            if elapsed < limit - 0.2 { error = "Narration stopped because video playback paused. Your recorded take was kept." }
            stop()
        }
    }

    func stop() {
        finish(keep: true)
    }

    func cancel() {
        guard isBusy else { return }
        keepTake = false
        if isFinishing { return }
        if isRecording { finish(keep: false) }
        else {
            task?.cancel()
            player?.cancelPendingPrerolls()
            player?.pause()
        }
    }

    private func finish(keep: Bool) {
        guard isRecording, let recorder else { return }
        keepTake = keep
        isFinishing = true
        isRecording = false
        timer?.invalidate()
        timer = nil
        player?.pause()
        task = Task {
            let url = await Task.detached { await recorder.stopRecording() }.value
            var clip: VoiceOverClip?
            if keepTake, url == nil { error = "The voiceover could not be saved. Please try again." }
            if keepTake, let url {
                do {
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration).seconds
                    clip = Self.clip(url: url, start: start, limit: limit,
                                     offset: recorder.startOffset.seconds, duration: duration)
                    if clip == nil { throw VoiceOverError.message("The take was too short. Record a little longer and try again.") }
                } catch { self.error = error.localizedDescription }
            }
            let saved = keepTake ? clip : nil
            let complete = completion
            if saved == nil, let output { try? FileManager.default.removeItem(at: output) }
            reset()
            if let saved { complete?(saved) }
        }
    }

    static func microphone(for deviceID: String) throws -> AVCaptureDevice {
        guard let device = deviceID.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: deviceID),
              device.hasMediaType(.audio), device.isConnected else {
            throw VoiceOverError.message("The selected microphone is unavailable. Choose another microphone and try again.")
        }
        return device
    }

    static func clip(url: URL, start: Double, limit: Double, offset: Double, duration: Double) -> VoiceOverClip? {
        guard start.isFinite, limit.isFinite, offset.isFinite, duration.isFinite else { return nil }
        let offset = max(0, offset)
        let length = min(duration, limit - offset)
        guard length > 0.05 else { return nil }
        return VoiceOverClip(url: url, start: start + offset, duration: length, sourceDuration: duration)
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        player?.cancelPendingPrerolls()
        player?.pause()
        player?.isMuted = wasMuted
        player?.automaticallyWaitsToMinimizeStalling = wasWaitingForPlayback
        recorder = nil
        player = nil
        output = nil
        completion = nil
        task = nil
        isBusy = false
        isRecording = false
        isFinishing = false
        level = 0
    }
}

private enum VoiceOverError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
