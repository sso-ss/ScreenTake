import SwiftUI
import AVFoundation

struct MicrophoneDevicePicker: View {
    @Binding var deviceID: String
    let devices: [AVCaptureDevice]

    var body: some View {
        Picker("Microphone device", selection: $deviceID) {
            Text("Default").tag("")
            ForEach(devices, id: \.uniqueID) { device in
                Text(device.localizedName).tag(device.uniqueID)
            }
            if !deviceID.isEmpty && !devices.contains(where: { $0.uniqueID == deviceID }) {
                Text("Unavailable microphone").tag(deviceID)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityLabel("Microphone device")
    }
}

struct EditorTakeRow: View {
    let title: String
    let start: Double
    let end: Double
    let isSelected: Bool
    let removeLabel: String
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(String(format: "%.1fs – %.1fs", start, end))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            Button(action: remove) { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .help(removeLabel)
                .accessibilityLabel(removeLabel)
        }
    }
}

struct EditorAudioPanel: View {
    @Binding var settings: VideoEditSettings
    @Binding var selectedClip: UUID?
    @ObservedObject var recorder: VoiceOverRecorder
    @Binding var microphoneDeviceID: String
    var microphones: [AVCaptureDevice] = []
    let duration: Double
    let hasOriginalAudio: Bool
    let startRecording: () -> Void
    let importAudio: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            Text("Voiceover")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignColors.primaryLabel)
            VStack(alignment: .leading, spacing: Spacing.featureGap) {
                recordingControls
                audioControls
            }
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            Text("Place the playhead, then record narration while your video plays.")
                .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            if recorder.isBusy {
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(recorder.isRecording ? String(format: "Recording  %.1fs", recorder.elapsed)
                         : (recorder.isFinishing ? "Saving voiceover…" : "Preparing microphone…"))
                        .monospacedDigit()
                }
                ProgressView(value: Double(recorder.level)).tint(.red)
                    .accessibilityLabel("Microphone level")
                HStack {
                    Button("Stop & Keep") { recorder.stop() }
                        .buttonStyle(CompactActionButtonStyle()).disabled(!recorder.isRecording)
                    Button("Cancel") { recorder.cancel() }.buttonStyle(CompactActionButtonStyle())
                }
            } else {
                MicrophoneDevicePicker(deviceID: $microphoneDeviceID, devices: microphones)
                VStack(alignment: .leading, spacing: Spacing.labelToControl) {
                    Button(action: startRecording) {
                        Label("Record Voiceover", systemImage: "mic.fill")
                    }
                    .buttonStyle(CompactActionButtonStyle())
                    .disabled(duration <= 0)
                    Button(action: importAudio) { Label("Import Audio…", systemImage: "waveform.badge.plus") }
                        .buttonStyle(CompactActionButtonStyle())
                }
            }
            Text("Preview sound is muted while recording.")
                .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            if let error = recorder.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: Spacing.featureGap) {
            if hasOriginalAudio {
                Divider()
                volumeControl("Original Audio", enabled: $settings.audioEnabled, volume: $settings.originalAudioVolume)
            }
            if !settings.voiceOvers.isEmpty {
                Divider()
                volumeControl("Voiceover", enabled: $settings.voiceOverEnabled, volume: $settings.voiceOverVolume)
                ForEach(settings.voiceOvers) { clip in
                    EditorTakeRow(title: "Take \((settings.voiceOvers.firstIndex(where: { $0.id == clip.id }) ?? 0) + 1)",
                                  start: clip.start, end: clip.end, isSelected: selectedClip == clip.id,
                                  removeLabel: "Remove voiceover take", select: { selectedClip = clip.id }, remove: {
                        settings.voiceOvers.removeAll { $0.id == clip.id }
                        if selectedClip == clip.id { selectedClip = nil }
                    })
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

/// A separate thumbnail lane for the editor's camera overlay.
struct VideoOverlayFilmstrip: View {
    let url: URL
    @Binding var timing: VideoOverlayTiming?
    let timeline: EditedTimeline
    let width: Double
    let enabled: Bool
    let selected: Bool
    var cameraLayout = CameraLayoutSettings()
    var cameraLayoutChanges: [CameraLayoutChange] = []
    let playhead: Double
    let select: () -> Void
    let remove: () -> Void
    var seek: ((Double) -> Void)? = nil
    @State private var thumbnails: [CGImage] = []
    @State private var sourceDuration: Double = 0
    @State private var thumbnailError = false
    @State private var dragOrigin: VideoOverlayTiming?

    private var total: Double { max(0.001, timeline.duration.seconds) }
    private var scale: Double { width / total }
    private var mediaDuration: Double { sourceDuration > 0 ? sourceDuration : (timing.map { $0.sourceStart + $0.duration } ?? 0) }
    private var ranges: [VideoOverlayTimelineRange] {
        VideoOverlayTimelineRange.visible(timing: timing, timeline: timeline, sourceDuration: mediaDuration).flatMap { range in
            let boundaries = [range.sourceStart] + cameraLayoutChanges.map(\.start).filter {
                $0 > range.sourceStart && $0 < range.sourceStart + range.duration
            }.sorted() + [range.sourceStart + range.duration]
            return zip(boundaries, boundaries.dropFirst()).map { start, end in
                VideoOverlayTimelineRange(outputStart: range.outputStart + start - range.sourceStart,
                                          sourceStart: start, duration: end - start)
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(DesignColors.cameraTrack.opacity(0.05))
            if ranges.isEmpty {
                Button(action: select) {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                        Text(sourceDuration == 0 && !thumbnailError ? "Loading camera…" : "Camera · outside visible timeline")
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .padding(8)
                    .frame(height: 44)
                }.buttonStyle(.plain)
            }
            ForEach(ranges.indices, id: \.self) { index in
                clip(ranges[index])
                    .offset(x: ranges[index].outputStart * scale)
            }
        }
        .frame(width: width, height: 44, alignment: .topLeading)
        .contextMenu {
            if timing != nil {
                Button("Move to Playhead") {
                    select()
                    timing?.start = max(0, min(total - 0.05, playhead))
                }
            }
            Button("Remove Camera Overlay", role: .destructive, action: remove)
        }
        .task(id: url) { await loadThumbnails() }
    }

    private func clip(_ range: VideoOverlayTimelineRange) -> some View {
        let clipWidth = max(2, range.duration * scale)
        let sectionSelected = selected && playhead >= range.outputStart && playhead < range.outputStart + range.duration
        let layout = CameraLayoutChange.settings(at: range.sourceStart, initial: cameraLayout,
                                                changes: cameraLayoutChanges).layout
        return HStack(spacing: 0) {
            ForEach(thumbnails.indices, id: \.self) { index in
                Image(decorative: thumbnails[index], scale: 1)
                    .resizable().scaledToFill()
                    .frame(width: max(1, mediaDuration * scale / Double(max(1, thumbnails.count))), height: 44)
                    .clipped()
            }
        }
        .offset(x: -range.sourceStart * scale)
        .frame(width: clipWidth, height: 44, alignment: .leading)
        .background(DesignColors.inputBackground)
        .clipped()
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                Image(systemName: enabled ? "video.fill" : "eye.slash.fill")
                Text(enabled ? "Camera · \(layout.displayName)" : "Camera · hidden")
                    .lineLimit(1)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
            .padding(3)
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(enabled ? 1 : 0.45)
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(sectionSelected ? Color.white : DesignColors.cameraTrack, lineWidth: sectionSelected ? 2 : 1.5))
        .contentShape(Rectangle())
        .gesture(drag(.move, range: range))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera \(layout.displayName) section")
        .accessibilityValue(String(format: "Starts at %.1f seconds, length %.1f seconds%@", range.outputStart, range.duration, enabled ? "" : ", hidden"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            select()
            seek?(range.outputStart + min(0.01, range.duration / 2))
        }
        .accessibilityAdjustableAction { direction in
            select()
            if let timing { self.timing = timing.adjusted(by: direction == .increment ? 0.1 : -0.1,
                                                         adjustment: .move, total: total, sourceDuration: mediaDuration) }
        }
        .help(timing == nil ? "Camera footage follows the screen recording’s clips. Click to adjust its appearance."
              : "Click to select; drag to move; drag either edge to trim")
        .overlay(alignment: .leading) {
            if timing != nil && selected, range.sourceStart == ranges.first?.sourceStart { handle(.trimStart) }
        }
        .overlay(alignment: .trailing) {
            if timing != nil && selected, range.outputStart == ranges.last?.outputStart { handle(.trimEnd) }
        }
    }

    private func handle(_ adjustment: VideoOverlayTiming.Adjustment) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.9))
            .frame(width: 2, height: 20)
            .frame(width: 10, height: 44).contentShape(Rectangle())
            .gesture(drag(adjustment))
            .accessibilityLabel(adjustment == .trimStart ? "Trim camera beginning" : "Trim camera end")
            .accessibilityAdjustableAction { direction in
                select()
                if let timing { self.timing = timing.adjusted(by: direction == .increment ? 0.1 : -0.1,
                                                             adjustment: adjustment, total: total, sourceDuration: mediaDuration) }
            }
    }

    private func drag(_ adjustment: VideoOverlayTiming.Adjustment, range: VideoOverlayTimelineRange? = nil) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                select()
                if dragOrigin == nil, let range, abs(value.translation.width) < 0.5 {
                    seek?(range.outputStart + min(max(0, value.location.x / scale), max(0, range.duration - 0.001)))
                }
                guard let timing else { return }
                if dragOrigin == nil { dragOrigin = timing }
                guard let origin = dragOrigin, abs(value.translation.width) > 0.5 else { return }
                self.timing = origin.adjusted(by: value.translation.width / max(0.001, scale),
                                               adjustment: adjustment, total: total, sourceDuration: mediaDuration)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    @MainActor
    private func loadThumbnails() async {
        thumbnails = []
        sourceDuration = 0
        thumbnailError = false
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw ExportError.noVideoTrack }
            try Task.checkCancellation()
            sourceDuration = duration
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            var images: [CGImage] = []
            for index in 0..<24 {
                try Task.checkCancellation()
                let time = CMTime(seconds: duration * (Double(index) + 0.5) / 24, preferredTimescale: 60000)
                do {
                    images.append(try await generator.image(at: time).image)
                } catch {
                    // Sparse recordings can have no frame near this thumbnail time.
                    generator.requestedTimeToleranceBefore = .positiveInfinity
                    generator.requestedTimeToleranceAfter = .positiveInfinity
                    images.append(try await generator.image(at: time).image)
                    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
                    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
                }
            }
            try Task.checkCancellation()
            thumbnails = images
        } catch {
            if !Task.isCancelled { thumbnailError = true }
        }
    }
}
