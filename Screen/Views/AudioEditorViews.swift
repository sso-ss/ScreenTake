import SwiftUI
import AVFoundation

struct EditorAudioPanel: View {
    @Binding var settings: VideoEditSettings
    @Binding var selectedClip: UUID?
    @ObservedObject var recorder: VoiceOverRecorder
    let duration: Double
    let hasOriginalAudio: Bool
    let startRecording: () -> Void
    let importAudio: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Voiceover").font(.headline)
            Text("Place the playhead, then record narration while your video plays.")
                .font(.caption).foregroundStyle(.secondary)
            if recorder.isBusy {
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(recorder.isRecording ? String(format: "Recording  %.1fs", recorder.elapsed) : "Preparing microphone…")
                        .monospacedDigit()
                }
                ProgressView(value: Double(recorder.level)).tint(.red)
                    .accessibilityLabel("Microphone level")
                HStack {
                    Button("Stop & Keep") { recorder.stop() }.disabled(!recorder.isRecording)
                    Button("Cancel") { recorder.cancel() }
                }
            } else {
                Button(action: startRecording) {
                    Label("Record Voiceover", systemImage: "mic.fill")
                }
                .disabled(duration <= 0)
                Button(action: importAudio) { Label("Import Audio…", systemImage: "waveform.badge.plus") }
            }
            Text("Uses your Mac’s default microphone. Preview sound is muted while recording.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = recorder.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 16) {
                if hasOriginalAudio {
                    Divider()
                    volumeControl("Original Audio", enabled: $settings.audioEnabled, volume: $settings.originalAudioVolume)
                }
                if !settings.voiceOvers.isEmpty {
                    Divider()
                    volumeControl("Voiceover", enabled: $settings.voiceOverEnabled, volume: $settings.voiceOverVolume)
                    ForEach(settings.voiceOvers) { clip in
                        HStack {
                            Button {
                                selectedClip = clip.id
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Take \((settings.voiceOvers.firstIndex(where: { $0.id == clip.id }) ?? 0) + 1)")
                                    Text(String(format: "%.1fs – %.1fs", clip.start, clip.end))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(selectedClip == clip.id ? Color.accentColor.opacity(0.18) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain)
                            Button {
                                settings.voiceOvers.removeAll { $0.id == clip.id }
                                if selectedClip == clip.id { selectedClip = nil }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).help("Remove voiceover take")
                                .accessibilityLabel("Remove voiceover take")
                        }
                    }
                    if let id = selectedClip, let index = settings.voiceOvers.firstIndex(where: { $0.id == id }) {
                        clipControls(index)
                    }
                    Text("Drag a take to move it; drag its edges to trim. Voiceovers keep their timeline positions when video clips change.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(recorder.isBusy)
        }
    }

    private func volumeControl(_ title: String, enabled: Binding<Bool>, volume: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: enabled)
            HStack {
                Image(systemName: enabled.wrappedValue ? "speaker.wave.2" : "speaker.slash")
                Slider(value: volume, in: 0...1).accessibilityLabel("\(title) volume")
                Text("\(Int(volume.wrappedValue * 100))%")
                    .font(.system(size: 12)).monospacedDigit().lineLimit(1)
                    .fixedSize().frame(width: 36, alignment: .trailing)
            }.disabled(!enabled.wrappedValue)
        }
    }

    private func clipControls(_ index: Int) -> some View {
        let clip = settings.voiceOvers[index]
        return VStack(alignment: .leading, spacing: 8) {
            Stepper(value: Binding(get: { settings.voiceOvers[index].start }, set: {
                settings.voiceOvers[index].start = min(max(0, duration - 0.05), max(0, $0))
            }), in: 0...max(0, duration - 0.05), step: 0.1) {
                Text(String(format: "Start at %.1fs", clip.start))
            }
            Stepper(value: Binding(get: { settings.voiceOvers[index].sourceStart }, set: {
                let value = min(clip.sourceStart + clip.duration - 0.05, max(0, $0))
                settings.voiceOvers[index].duration += clip.sourceStart - value
                settings.voiceOvers[index].sourceStart = value
            }), in: 0...max(0, clip.sourceStart + clip.duration - 0.05), step: 0.1) {
                Text(String(format: "Trim beginning %.1fs", clip.sourceStart))
            }
            Stepper(value: Binding(get: { settings.voiceOvers[index].duration }, set: {
                settings.voiceOvers[index].duration = max(0.05, min(clip.sourceDuration - clip.sourceStart, $0))
            }), in: 0.05...max(0.05, clip.sourceDuration - clip.sourceStart), step: 0.1) {
                Text(String(format: "Length %.1fs", clip.duration))
            }
        }
        .font(.caption)
    }
}

struct AudioWaveformStrip: View {
    let url: URL
    let title: String
    let color: Color
    let muted: Bool
    let duration: Double
    var sourceStart: Double = 0
    var timeline: EditedTimeline?
    @State private var waveform: AudioWaveform?
    @State private var failed = false

    var body: some View {
        Canvas { context, size in
            guard let waveform else { return }
            let count = max(1, Int(size.width / 3))
            var path = Path()
            for index in 0..<count {
                let time = (Double(index) + 0.5) / Double(count) * duration
                let sourceTime = timeline?.sourceTime(at: EditorAudio.time(time)).seconds ?? sourceStart + time
                let amplitude = CGFloat(sqrt(waveform.level(at: sourceTime)))
                let height = max(1, amplitude * 22)
                path.addRoundedRect(in: CGRect(x: CGFloat(index) * 3, y: 29 - height / 2, width: 1.5, height: height),
                                    cornerSize: CGSize(width: 0.75, height: 0.75))
            }
            context.fill(path, with: .color(color.opacity(muted ? 0.35 : 0.85)))
        }
        .background(color.opacity(muted ? 0.05 : 0.12))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                Image(systemName: muted ? "speaker.slash.fill" : "waveform")
                Text(failed ? "\(title) · waveform unavailable" : title)
                    .lineLimit(1)
                if waveform == nil && !failed { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color.opacity(muted ? 0.5 : 1))
            .padding(.horizontal, 6).padding(.top, 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("\(title) waveform\(muted ? ", muted" : "")")
        .task(id: url) {
            waveform = nil
            failed = false
            // The decoder runs off the UI thread and is cancelled when the strip disappears.
            let worker = Task.detached(priority: .utility) { try await AudioWaveform.load(url) }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                waveform = result
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct VoiceOverTimelineClip: View {
    @Binding var clip: VoiceOverClip
    @Binding var selected: UUID?
    let total: Double
    let scale: Double
    let muted: Bool
    let number: Int
    let pause: () -> Void
    @State private var dragOrigin: VoiceOverClip?

    private var visibleDuration: Double { max(0, min(clip.duration, total - clip.start)) }
    var body: some View {
        AudioWaveformStrip(url: clip.url, title: "Take \(number)", color: .purple, muted: muted,
                           duration: visibleDuration, sourceStart: clip.sourceStart)
            .frame(width: max(2, visibleDuration * scale), height: 44)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected == clip.id ? Color.white : Color.purple.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(drag(edge: 0))
            .overlay(alignment: .leading) { handle(edge: -1) }
            .overlay(alignment: .trailing) { handle(edge: 1) }
            .help("Drag to move this voiceover; drag either edge to trim")
            .accessibilityLabel("Voiceover take \(number)")
            .accessibilityValue(String(format: "Starts at %.1f seconds, length %.1f seconds", clip.start, clip.duration))
            .accessibilityAdjustableAction { direction in
                pause(); selected = clip.id
                clip.start = min(max(0, total - 0.05), max(0, clip.start + (direction == .increment ? 0.1 : -0.1)))
            }
    }

    private func handle(edge: Int) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.7)).frame(width: 2, height: 16)
            .frame(width: 8, height: 44).contentShape(Rectangle())
            .gesture(drag(edge: edge))
            .accessibilityLabel(edge < 0 ? "Trim voiceover beginning" : "Trim voiceover end")
            .accessibilityAdjustableAction { direction in
                pause(); selected = clip.id
                adjust(from: clip, delta: direction == .increment ? 0.1 : -0.1, edge: edge)
            }
    }

    private func drag(edge: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = clip; pause(); selected = clip.id }
                guard let origin = dragOrigin else { return }
                guard abs(value.translation.width) > 0.5 else { return }
                adjust(from: origin, delta: value.translation.width / max(0.001, scale), edge: edge)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func adjust(from origin: VoiceOverClip, delta: Double, edge: Int) {
        if edge == 0 {
            clip.start = min(max(0, total - 0.05), max(0, origin.start + delta))
        } else if edge < 0 {
            let shift = min(origin.duration - 0.05, total - origin.start - 0.05,
                            max(-min(origin.start, origin.sourceStart), delta))
            clip.start = origin.start + shift
            clip.sourceStart = origin.sourceStart + shift
            clip.duration = origin.duration - shift
        } else {
            clip.duration = max(0.05, min(origin.sourceDuration - origin.sourceStart, total - origin.start, origin.duration + delta))
        }
    }
}
