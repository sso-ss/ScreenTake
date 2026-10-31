import SwiftUI
import AVFoundation

struct PrivacyMaskEditorPanel: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var playback: TimelinePlayback
    @Binding var selectedID: UUID?
    @State private var trackingTask: Task<Void, Never>?
    @State private var trackingTarget: PrivacyMaskTrackingTarget = .automatic
    @State private var trackingStatus: String?
    @State private var trackingError: String?
    @State private var trackingNotice: String?

    init(session: EditorSession, selectedID: Binding<UUID?>) {
        self.session = session
        self.playback = session.playback
        _selectedID = selectedID
    }

    private var masks: [PrivacyMask] { session.draft.privacyMasks ?? [] }
    private var selected: PrivacyMask? { masks.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.featureGap) {
            HStack {
                InspectorTitle(title: "Privacy")
                Spacer()
                Button(action: addMask) { Image(systemName: "plus") }
                    .buttonStyle(CompactActionButtonStyle(iconOnly: true))
                    .accessibilityLabel("Add privacy mask")
                    .disabled(session.editedDuration < 0.05)
            }
            Text("Cover sensitive details before sharing. Drag a mask on the video to move it; set another position later to follow motion.")
                .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            if masks.isEmpty {
                Button(action: addMask) { Label("Add Mask", systemImage: "rectangle.dashed") }
                    .buttonStyle(CompactActionButtonStyle(prominent: true, size: .medium))
                    .accessibilityIdentifier("addPrivacyMask")
            } else {
                ForEach(Array(masks.enumerated()), id: \.element.id) { index, mask in
                    HStack {
                        Button {
                            selectedID = mask.id
                            session.player?.pause()
                            session.player?.seek(to: EditorAudio.time(mask.start), toleranceBefore: .zero, toleranceAfter: .zero)
                        } label: {
                            Text("Mask \(index + 1)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(selectedID == mask.id ? DesignColors.accent : DesignColors.primaryLabel)
                        }.buttonStyle(.plain)
                        Button {
                            session.draft.privacyMasks = masks.filter { $0.id != mask.id }
                            if selectedID == mask.id { selectedID = session.draft.privacyMasks?.first?.id }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove privacy mask")
                    }
                }
                if let selected {
                    Picker("Style", selection: Binding(get: { selected.style }, set: { value in
                        update(selected.id) { $0.style = value }
                    })) {
                        ForEach(PrivacyMaskStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }.pickerStyle(.segmented)
                    HStack {
                        timeField("Start", value: selected.start, range: 0...max(0, session.editedDuration - 0.05)) { value in
                            update(selected.id) { mask in
                                let delta = value - mask.start
                                mask.start = value
                                mask.duration = min(mask.duration, session.editedDuration - value)
                                mask.keyframes = mask.keyframes.map { .init(time: $0.time + delta, rect: $0.rect) }
                            }
                        }
                        timeField("End", value: selected.end, range: (selected.start + 0.05)...max(selected.start + 0.05, session.editedDuration)) { value in
                            update(selected.id) { $0.duration = value - $0.start; $0.keyframes.removeAll { $0.time >= value } }
                        }
                    }
                    if let rect = selected.rect(at: min(max(playback.seconds, selected.start), selected.end - 0.001)) {
                        slider("Width", value: rect.width, range: 0.01...max(0.01, 1 - rect.minX)) { width in
                            update(selected.id) { $0.setRect(CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height), at: playback.seconds) }
                        }
                        slider("Height", value: rect.height, range: 0.01...max(0.01, 1 - rect.minY)) { height in
                            update(selected.id) { $0.setRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height), at: playback.seconds) }
                        }
                    }
                    Text(selected.keyframes.count == 1 ? "Fixed position" : "\(selected.keyframes.count) position points")
                        .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                    Picker("Track", selection: $trackingTarget) {
                        ForEach(PrivacyMaskTrackingTarget.allCases, id: \.self) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    .pickerStyle(.menu)
                    Button {
                        track(selected, target: trackingTarget)
                    } label: {
                        Label(trackingStatus ?? "Track Movement", systemImage: "viewfinder")
                    }
                    .buttonStyle(CompactActionButtonStyle(size: .medium))
                    .disabled(trackingTask != nil || session.videoURL == nil || session.isBusy)
                    .hoverHelp("Follow this area through its selected time range.")
                    .accessibilityIdentifier("trackPrivacyMask")
                    if let trackingError {
                        Text(trackingError).font(Typography.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let trackingNotice {
                        Text(trackingNotice).font(Typography.caption)
                            .foregroundStyle(DesignColors.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { if selectedID == nil { selectedID = masks.first?.id } }
        .onDisappear { trackingTask?.cancel() }
    }

    private func addMask() {
        guard session.editedDuration >= 0.05 else { return }
        let current = playback.seconds.isFinite ? playback.seconds : 0
        let start = min(max(0, current), session.editedDuration - 0.05)
        let mask = PrivacyMask(start: start, duration: min(5, session.editedDuration - start),
                               rect: CGRect(x: 0.38, y: 0.44, width: 0.24, height: 0.12))
        session.draft.privacyMasks = masks + [mask]
        selectedID = mask.id
        session.player?.pause()
    }

    private func update(_ id: UUID, change: (inout PrivacyMask) -> Void) {
        var updated = masks
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        change(&updated[index])
        session.draft.privacyMasks = updated
    }

    private func track(_ mask: PrivacyMask, target: PrivacyMaskTrackingTarget) {
        guard session.videoURL != nil, !session.isBusy else { return }
        trackingError = nil
        trackingNotice = nil
        session.player?.pause()
        trackingStatus = "Preparing video..."
        trackingTask = Task { @MainActor in
            defer { session.isAnalyzing = false; trackingTask = nil; trackingStatus = nil }
            do {
                if session.privacyTrackingURL == nil {
                    try await session.applyChanges(excludingPrivacyMasks: true)
                }
                try Task.checkCancellation()
                guard let url = session.privacyTrackingURL else { throw PrivacyMaskTrackingError.unavailable }
                trackingStatus = "Tracking..."
                session.isAnalyzing = true
                let result = try await Task.detached(priority: .userInitiated) {
                    try await PrivacyMaskTracker.track(videoURL: url, mask: mask, target: target)
                }.value
                guard !Task.isCancelled else { return }
                update(mask.id) {
                    $0.keyframes = result.keyframes
                    $0.duration = result.duration
                }
                if result.endedWhenTargetLeftFrame {
                    trackingNotice = "The selected target left the frame, so this mask ends at \(String(format: "%.1f", mask.start + result.duration))s. Review its coverage before sharing."
                }
            } catch is CancellationError {
            } catch {
                trackingError = error.localizedDescription
            }
        }
    }

    private func timeField(_ title: String, value: Double, range: ClosedRange<Double>, update: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(Typography.caption)
            TextField(title, value: Binding(get: { value }, set: { update(min(range.upperBound, max(range.lowerBound, $0))) }), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, update: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading) {
            Text("\(title) \(Int(value * 100))%").font(Typography.caption)
            Slider(value: Binding(get: { value }, set: update), in: range)
        }
    }
}

struct PrivacyMaskCanvasOverlay: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var playback: TimelinePlayback
    @Binding var selectedID: UUID?
    @State private var dragOrigin: CGRect?
    @State private var dragTime: Double?

    init(session: EditorSession, selectedID: Binding<UUID?>) {
        self.session = session
        self.playback = session.playback
        _selectedID = selectedID
    }

    var body: some View {
        GeometryReader { geometry in
            let canvas = session.draft.outputSize(source: session.sourceVideoSize ?? .zero)
            let viewport = TextCanvasGeometry(bounds: CGRect(origin: .zero, size: geometry.size), canvas: canvas).viewport
            if viewport.width > 0, viewport.height > 0 {
                ForEach(session.draft.privacyMasks ?? []) { mask in
                    if let rect = mask.rect(at: playback.seconds) {
                        let display = CGRect(x: viewport.minX + rect.minX * viewport.width,
                                             y: viewport.minY + rect.minY * viewport.height,
                                             width: rect.width * viewport.width, height: rect.height * viewport.height)
                        Rectangle()
                            .fill(.clear)
                            .overlay(Rectangle().strokeBorder(selectedID == mask.id ? DesignColors.accent : .white, lineWidth: 2))
                            .frame(width: display.width, height: display.height)
                            .position(x: display.midX, y: display.midY)
                            .contentShape(Rectangle())
                            .gesture(drag(mask: mask, viewport: viewport))
                            .accessibilityLabel("Privacy mask")
                            .hoverHelp("Drag to move the privacy mask")
                        if selectedID == mask.id {
                            ForEach(PhoneCrop.Corner.allCases, id: \.self) { corner in
                                let left = corner == .topLeft || corner == .bottomLeft
                                let top = corner == .topLeft || corner == .topRight
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.white)
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(DesignColors.accent, lineWidth: 2))
                                    .frame(width: 12, height: 12)
                                    .padding(6)
                                    .contentShape(Rectangle())
                                    .position(x: left ? display.minX : display.maxX,
                                              y: top ? display.minY : display.maxY)
                                    .gesture(drag(mask: mask, viewport: viewport, corner: corner))
                                    .accessibilityLabel("Resize privacy mask")
                                    .hoverHelp("Drag to resize the privacy mask")
                            }
                        }
                    }
                }
            }
        }
        .onDisappear {
            if dragOrigin != nil { session.endUndoGroup() }
            dragOrigin = nil
            dragTime = nil
        }
    }

    private func drag(mask: PrivacyMask, viewport: CGRect, corner: PhoneCrop.Corner? = nil) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard !session.isBusy || dragOrigin != nil,
                      viewport.width > 0, viewport.height > 0 else { return }
                if dragOrigin == nil {
                    guard let rect = mask.rect(at: playback.seconds) else { return }
                    selectedID = mask.id
                    session.player?.pause()
                    // A click selects the mask without inserting a keyframe.
                    guard abs(value.translation.width) >= 1 || abs(value.translation.height) >= 1 else { return }
                    session.beginUndoGroup()
                    dragOrigin = rect
                    dragTime = playback.seconds
                }
                guard let origin = dragOrigin, let time = dragTime else { return }
                let dx = value.translation.width / viewport.width
                let dy = value.translation.height / viewport.height
                let updated: CGRect
                if let corner {
                    let left = corner == .topLeft || corner == .bottomLeft
                    let top = corner == .topLeft || corner == .topRight
                    let minX = left ? min(origin.maxX - 0.01, max(0, origin.minX + dx)) : origin.minX
                    let maxX = left ? origin.maxX : max(origin.minX + 0.01, min(1, origin.maxX + dx))
                    let minY = top ? min(origin.maxY - 0.01, max(0, origin.minY + dy)) : origin.minY
                    let maxY = top ? origin.maxY : max(origin.minY + 0.01, min(1, origin.maxY + dy))
                    updated = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                } else {
                    updated = CGRect(x: min(1 - origin.width, max(0, origin.minX + dx)),
                                     y: min(1 - origin.height, max(0, origin.minY + dy)),
                                     width: origin.width, height: origin.height)
                }
                var masks = session.draft.privacyMasks ?? []
                guard let index = masks.firstIndex(where: { $0.id == mask.id }) else { return }
                masks[index].setRect(updated, at: time)
                session.draft.privacyMasks = masks
            }
            .onEnded { _ in
                if dragOrigin != nil { session.endUndoGroup() }
                dragOrigin = nil
                dragTime = nil
            }
    }
}
