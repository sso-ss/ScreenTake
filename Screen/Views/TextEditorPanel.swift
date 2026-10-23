import SwiftUI
import AppKit

struct TextEditorPanel: View {
    @ObservedObject var session: EditorSession
    private static let fonts = NSFontManager.shared.availableFontFamilies.sorted()
    private var overlays: [TextOverlay] { session.draft.textOverlays ?? [] }
    private var selected: TextOverlay? { overlays.first { $0.id == session.selectedTextID } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.featureGap) {
            HStack {
                InspectorTitle(title: "Text")
                Spacer()
                if !overlays.isEmpty {
                    Button(action: addText) { Image(systemName: "plus") }
                        .buttonStyle(CompactActionButtonStyle(iconOnly: true))
                        .accessibilityLabel("Add Text").help("Add another text layer")
                }
            }
            if overlays.isEmpty {
                emptyState
            } else {
                layerPicker
                if let selected {
                    editor(selected).id(selected.id)
                } else {
                    Text("Select a text layer to edit.")
                        .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                }
            }
        }
        .foregroundStyle(DesignColors.primaryLabel)
        .tint(DesignColors.accent)
        .onAppear {
            if selected == nil, let first = overlays.first { select(first) }
        }
        .onChange(of: overlays.map(\.id)) { ids in
            if !ids.contains(session.selectedTextID ?? UUID()) { session.selectedTextID = ids.first }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "textformat").font(.system(size: 28, weight: .medium))
                .foregroundStyle(DesignColors.accent)
            Text("Make your message stand out")
                .font(Typography.body).multilineTextAlignment(.center)
            Text(session.videoURL == nil ? "Open or record a video to add titles, captions, and labels."
                 : "Add a title, caption, or label to your video.")
                .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(action: addText) { Label("Add Text", systemImage: "plus") }
                .buttonStyle(CompactActionButtonStyle(prominent: true, size: .medium))
                .disabled(session.videoURL == nil || session.editedDuration < 0.05)
                .accessibilityIdentifier("addTextOverlay")
        }
        .padding(Spacing.xl).frame(maxWidth: .infinity)
        .background(DesignColors.inputBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: CornerRadius.lg))
    }

    private var layerPicker: some View {
        VStack(spacing: Spacing.md) {
            ForEach(overlays) { text in
                HStack(spacing: Spacing.md) {
                    Button {
                        select(text)
                    } label: {
                        HStack(spacing: Spacing.md) {
                            Image(systemName: "textformat").foregroundStyle(DesignColors.accent)
                            Text(text.text.isEmpty ? "Empty text" : text.text)
                                .font(Typography.caption).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(Spacing.md)
                        .background(session.selectedTextID == text.id ? DesignColors.accent.opacity(0.12) : DesignColors.inputBackground,
                                    in: RoundedRectangle(cornerRadius: CornerRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: CornerRadius.md)
                            .strokeBorder(session.selectedTextID == text.id ? DesignColors.accent : .clear))
                    }.buttonStyle(.plain)
                    Button {
                        session.draft.textOverlays = overlays.filter { $0.id != text.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(DesignColors.secondaryLabel)
                        .accessibilityLabel("Remove text layer")
                }
            }
        }
    }

    private func editor(_ text: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: Spacing.featureGap) {
            TextEditor(text: binding(\.text, fallback: text.text))
                .font(Typography.body).scrollContentBackground(.hidden)
                .padding(Spacing.md).frame(height: 88)
                .background(DesignColors.inputBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
                .overlay(RoundedRectangle(cornerRadius: CornerRadius.md).strokeBorder(DesignColors.inputBorder))
                .accessibilityLabel("Text content").accessibilityIdentifier("textOverlayContent")
            timing(text)
            Divider()
            presets
            Divider()
            typography(text)
            Divider()
            InspectorSection(title: "Transform") {
                transform(text)
            }
            Divider()
            slider("Opacity", \.opacity, value: text.opacity, range: 0...1, multiplier: 100, suffix: "%")
            Divider()
            InspectorSection(title: "Stroke", isOn: binding(\.strokeEnabled, fallback: false)) {
                colorControl("Stroke color", \.strokeColor, value: text.strokeColor)
                slider("Thickness", \.strokeWidth, value: text.strokeWidth, range: 0...20)
            }
            Divider()
            InspectorSection(title: "Background", isOn: binding(\.backgroundEnabled, fallback: false)) {
                background(text)
            }
        }
    }

    private func timing(_ text: TextOverlay) -> some View {
        HStack(spacing: Spacing.lg) {
            number("Start", value: Binding(get: { selected?.start ?? text.start }, set: { value in
                update { overlay in overlay.start = min(max(0, session.editedDuration - 0.05), max(0, value)) }
            }), range: 0...max(0, session.editedDuration - 0.05), suffix: "s")
            number("Duration", value: binding(\.duration, fallback: text.duration), range: 0.05...max(0.05, session.editedDuration - text.start), suffix: "s")
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            sectionLabel("Preset Style")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.md), count: 3), spacing: Spacing.md) {
                ForEach(TextStylePreset.allCases, id: \.self) { preset in
                    Button { update { preset.apply(to: &$0) } } label: {
                        VStack(spacing: Spacing.sm) {
                            Text("Aa").font(.system(size: 22, weight: preset == .clean || preset == .caption ? .regular : .bold))
                                .foregroundStyle(preset == .highlight ? Color(hex: "#171717") : preset == .label ? .white : DesignColors.primaryLabel)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(preset == .highlight ? Color(hex: "#F9DF70") : preset == .label ? DesignColors.accent : .clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .shadow(color: preset == .outline ? DesignColors.secondaryLabel : .clear, radius: 1)
                            Text(LocalizedStringKey(preset.rawValue)).font(.system(size: 10)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).frame(height: 62)
                        .background(DesignColors.inputBackground, in: RoundedRectangle(cornerRadius: CornerRadius.lg))
                    }.buttonStyle(.plain).accessibilityLabel("\(preset.rawValue) text preset")
                }
            }
        }
    }

    private func typography(_ text: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: Spacing.featureGap) {
            sectionLabel("Typography")
            Picker("Font", selection: binding(\.fontName, fallback: "System")) {
                Text("System").tag("System")
                ForEach(Self.fonts, id: \.self) { Text(verbatim: $0).tag($0) }
            }.pickerStyle(.menu)
            slider("Font size", \.fontSize, value: text.fontSize, range: 8...240)
            HStack(spacing: Spacing.md) {
                formatButton("bold", label: "Bold", key: \.bold, selected: text.bold)
                formatButton("italic", label: "Italic", key: \.italic, selected: text.italic)
                formatButton("underline", label: "Underline", key: \.underline, selected: text.underline)
                Spacer()
                ColorPicker("Text color", selection: colorBinding(\.color, value: text.color), supportsOpacity: false)
                    .labelsHidden().accessibilityLabel("Text color")
            }
            Picker("Case", selection: binding(\.letterCase, fallback: .original)) {
                ForEach(TextLetterCase.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }.pickerStyle(.menu)
            HStack(spacing: Spacing.lg) {
                number("Character", value: binding(\.characterSpacing, fallback: 0), range: -10...50)
                number("Line", value: binding(\.lineSpacing, fallback: 0), range: 0...100)
            }
            Picker("Alignment", selection: binding(\.alignment, fallback: .center)) {
                ForEach(TextHorizontalAlignment.allCases, id: \.self) { align in
                    Image(systemName: align.icon).tag(align).accessibilityLabel(align.rawValue)
                }
            }.pickerStyle(.segmented)
            slider("Text width", \.boxWidth, value: text.boxWidth, range: 0.1...1, multiplier: 100, suffix: "%")
        }
    }

    private func transform(_ text: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: Spacing.featureGap) {
            slider(text.uniformScale ? "Scale" : "Scale X", \.scale, value: text.scale, range: 0.1...3, multiplier: 100, suffix: "%")
            InspectorToggle(title: "Uniform scale", isOn: Binding(get: { selected?.uniformScale ?? true }, set: { uniform in
                update { if !uniform { $0.scaleY = $0.scale }; $0.uniformScale = uniform }
            }))
            if !text.uniformScale {
                slider("Scale Y", \.scaleY, value: text.scaleY, range: 0.1...3, multiplier: 100, suffix: "%")
            }
            HStack(spacing: Spacing.lg) {
                number("Position X", value: percentBinding(\.x, value: text.x), range: 0...100, suffix: "%")
                number("Position Y", value: percentBinding(\.y, value: text.y), range: 0...100, suffix: "%")
            }
            slider("Rotation", \.rotation, value: text.rotation, range: -180...180, suffix: "°")
            HStack(spacing: Spacing.md) {
                ForEach([0.15, 0.5, 0.85], id: \.self) { y in
                    Button { update { $0.y = y } } label: {
                        Image(systemName: y == 0.15 ? "align.vertical.top" : y == 0.5 ? "align.vertical.center" : "align.vertical.bottom")
                    }.buttonStyle(CompactActionButtonStyle(iconOnly: true))
                        .accessibilityLabel(y == 0.15 ? "Position at top" : y == 0.5 ? "Position at center" : "Position at bottom")
                }
            }
        }
    }

    private func background(_ text: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: Spacing.featureGap) {
            Picker("Background style", selection: binding(\.backgroundStyle, fallback: .block)) {
                ForEach(TextBackgroundStyle.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            colorControl("Background color", \.backgroundColor, value: text.backgroundColor)
            slider("Background opacity", \.backgroundOpacity, value: text.backgroundOpacity, range: 0...1, multiplier: 100, suffix: "%")
            slider("Corner radius", \.backgroundRadius, value: text.backgroundRadius, range: 0...100)
            slider("Height padding", \.paddingY, value: text.paddingY, range: 0...200)
            slider("Width padding", \.paddingX, value: text.paddingX, range: 0...200)
            slider("Y offset", \.backgroundOffsetY, value: text.backgroundOffsetY, range: -200...200)
            slider("X offset", \.backgroundOffsetX, value: text.backgroundOffsetX, range: -200...200)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(DesignColors.secondaryLabel)
    }

    private func formatButton(_ icon: String, label: String, key: WritableKeyPath<TextOverlay, Bool>, selected: Bool) -> some View {
        Button { update { $0[keyPath: key].toggle() } } label: { Image(systemName: icon) }
            .buttonStyle(CompactActionButtonStyle(prominent: selected, iconOnly: true))
            .accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func slider(_ title: String, _ key: WritableKeyPath<TextOverlay, Double>, value: Double,
                        range: ClosedRange<Double>, multiplier: Double = 1, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: Spacing.labelToControl) {
            Text(LocalizedStringKey(title)).font(Typography.body)
            SliderValueControl(selection: binding(key, fallback: value), range: range, label: title,
                               multiplier: multiplier, unit: suffix, decimals: multiplier == 100 ? 0 : 1,
                               onEditingChanged: { editing in
                    if editing { session.beginUndoGroup() } else { session.endUndoGroup() }
                })
        }
    }

    private func number(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(LocalizedStringKey(title)).font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
            HStack(spacing: 3) {
                TextField(title, value: Binding(get: { value.wrappedValue }, set: {
                    if $0.isFinite { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }
                }), format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.plain).accessibilityLabel(title)
                Text(suffix).font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
            }
            .padding(Spacing.md).background(DesignColors.inputBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
        }.frame(maxWidth: .infinity)
    }

    private func colorControl(_ title: String, _ key: WritableKeyPath<TextOverlay, String>, value: String) -> some View {
        ColorPicker(LocalizedStringKey(title), selection: colorBinding(key, value: value), supportsOpacity: false).font(Typography.body)
    }
    private func colorBinding(_ key: WritableKeyPath<TextOverlay, String>, value: String) -> Binding<Color> {
        Binding(get: { Color(hex: selected?[keyPath: key] ?? value) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            update { $0[keyPath: key] = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                                             Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())) }
        })
    }
    private func binding<Value>(_ key: WritableKeyPath<TextOverlay, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { selected?[keyPath: key] ?? fallback }, set: { value in update { $0[keyPath: key] = value } })
    }
    private func percentBinding(_ key: WritableKeyPath<TextOverlay, Double>, value: Double) -> Binding<Double> {
        Binding(get: { (selected?[keyPath: key] ?? value) * 100 }, set: { value in update { $0[keyPath: key] = value / 100 } })
    }
    private func update(_ change: (inout TextOverlay) -> Void) {
        guard let id = session.selectedTextID else { return }
        var texts = overlays
        guard let index = texts.firstIndex(where: { $0.id == id }) else { return }
        change(&texts[index])
        texts[index].text = String(texts[index].text.prefix(10000))
        session.draft.textOverlays = texts
    }
    private func select(_ text: TextOverlay) {
        session.player?.pause()
        session.selectedTextID = text.id
        session.selectedVoiceOverID = nil; session.selectedZoomID = nil
        session.selectedRecordedAudioID = nil; session.selectedSegment = nil; session.isVideoOverlaySelected = false
        session.player?.seek(to: EditorAudio.time(min(text.start, max(0, session.editedDuration - 0.01))), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func addText() {
        guard session.videoURL != nil, session.editedDuration >= 0.05, overlays.count < 100 else { return }
        var text = TextOverlay()
        let playhead = session.player?.currentTime().seconds ?? 0
        text.start = min(max(0, playhead.isFinite ? playhead : 0), max(0, session.editedDuration - 0.05))
        text.duration = min(5, session.editedDuration - text.start)
        session.draft.textOverlays = overlays + [text]
        select(text)
    }
}

/// Hit testing and dragging use the rendered canvas, excluding the player's letterbox margins.
struct TextCanvasGeometry {
    let viewport: CGRect
    let canvas: CGSize

    init(bounds: CGRect, canvas: CGSize) {
        self.canvas = canvas
        guard canvas.width > 0, canvas.height > 0 else { viewport = .zero; return }
        let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        viewport = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
    }

    func center(of text: TextOverlay) -> CGPoint {
        CGPoint(x: viewport.minX + text.x * viewport.width, y: viewport.minY + text.y * viewport.height)
    }

    func displaySize(_ size: CGSize) -> CGSize {
        guard canvas.width > 0 else { return .zero }
        let scale = viewport.width / canvas.width
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func contains(_ point: CGPoint, text: TextOverlay, size: CGSize) -> Bool {
        guard viewport.contains(point) else { return false }
        let center = center(of: text), size = displaySize(size)
        let angle = -text.rotation * .pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        let local = CGPoint(x: dx * cos(angle) - dy * sin(angle), y: dx * sin(angle) + dy * cos(angle))
        return CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            .insetBy(dx: -4, dy: -4).contains(local)
    }

    func position(from origin: CGPoint, translation: CGSize) -> CGPoint {
        guard viewport.width > 0, viewport.height > 0 else { return origin }
        return CGPoint(x: min(1, max(0, origin.x + translation.width / viewport.width)),
                       y: min(1, max(0, origin.y + translation.height / viewport.height)))
    }
}

struct TextCanvasOverlay: NSViewRepresentable {
    @ObservedObject var session: EditorSession
    @ObservedObject private var playback: TimelinePlayback
    let isEnabled: Bool

    init(session: EditorSession, isEnabled: Bool) {
        self.session = session
        self.playback = session.playback
        self.isEnabled = isEnabled
    }

    func makeNSView(context: Context) -> TextCanvasSelectionView { TextCanvasSelectionView() }

    func updateNSView(_ view: TextCanvasSelectionView, context: Context) {
        view.session = session
        view.isEditable = isEnabled
        view.time = playback.seconds
        view.canvasSize = session.draft.outputSize(source: session.sourceVideoSize ?? .zero)
        view.updateLayers(session.draft.textOverlays ?? [])
    }

    static func dismantleNSView(_ view: TextCanvasSelectionView, coordinator: ()) { view.finishDrag() }
}

final class TextCanvasSelectionView: NSView {
    weak var session: EditorSession?
    var isEditable = true
    var time = 0.0
    var canvasSize = CGSize.zero
    private var texts: [TextOverlay] = []
    private var sizes: [UUID: CGSize] = [:]
    private var cachedTexts: [UUID: TextOverlay] = [:]
    private var cachedCanvas = CGSize.zero
    private var drag: (id: UUID, point: CGPoint, position: CGPoint)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var geometry: TextCanvasGeometry { .init(bounds: bounds, canvas: canvasSize) }

    func updateLayers(_ layers: [TextOverlay]) {
        texts = layers
        if cachedCanvas != canvasSize { cachedTexts = [:]; sizes = [:]; cachedCanvas = canvasSize }
        let ids = Set(layers.map(\.id))
        cachedTexts = cachedTexts.filter { ids.contains($0.key) }
        sizes = sizes.filter { ids.contains($0.key) }
        for var text in layers {
            // Position changes do not affect the typesetting or selection size.
            text.x = 0.5; text.y = 0.5
            if cachedTexts[text.id] != text {
                sizes[text.id] = TextOverlayRenderer.selectionSize(for: text, canvas: canvasSize)
                cachedTexts[text.id] = text
            }
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func text(at point: CGPoint) -> TextOverlay? {
        texts.reversed().first { text in
            text.isVisible(at: time) && text.opacity > 0
                && sizes[text.id].map { geometry.contains(point, text: text, size: $0) } == true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditable, !texts.isEmpty, frame.contains(point) else { return nil }
        return self
    }

    override func resetCursorRects() {
        guard isEditable else { return }
        for text in texts where text.isVisible(at: time) && text.opacity > 0 {
            guard let canvasSize = sizes[text.id] else { continue }
            let size = geometry.displaySize(canvasSize), center = geometry.center(of: text)
            let angle = text.rotation * .pi / 180
            let width = abs(size.width * cos(angle)) + abs(size.height * sin(angle))
            let height = abs(size.width * sin(angle)) + abs(size.height * cos(angle))
            let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
                .intersection(geometry.viewport)
            if !rect.isEmpty { addCursorRect(rect, cursor: .openHand) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable, let session else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let text = text(at: point) else { session.selectedTextID = nil; return }
        session.player?.pause()
        session.selectedTextID = text.id
        session.selectedVoiceOverID = nil; session.selectedZoomID = nil
        session.selectedRecordedAudioID = nil; session.selectedSegment = nil; session.isVideoOverlaySelected = false
        window?.makeFirstResponder(self)
        session.beginUndoGroup()
        drag = (text.id, point, CGPoint(x: text.x, y: text.y))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditable, let drag, let session,
              let index = session.draft.textOverlays?.firstIndex(where: { $0.id == drag.id }) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let position = geometry.position(from: drag.position,
                                         translation: CGSize(width: point.x - drag.point.x, height: point.y - drag.point.y))
        var layers = session.draft.textOverlays ?? []
        layers[index].x = position.x; layers[index].y = position.y
        session.draft.textOverlays = layers
        updateLayers(layers)
    }

    override func mouseUp(with event: NSEvent) { finishDrag() }

    func finishDrag() {
        guard drag != nil else { return }
        drag = nil
        session?.endUndoGroup()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isEditable, let selected = session?.selectedTextID,
              let text = texts.first(where: { $0.id == selected }), text.isVisible(at: time),
              let canvasSize = sizes[selected], let context = NSGraphicsContext.current?.cgContext else { return }
        let size = geometry.displaySize(canvasSize), center = geometry.center(of: text)
        context.saveGState()
        context.clip(to: geometry.viewport)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: text.rotation * .pi / 180)
        context.setStrokeColor(NSColor(DesignColors.accent).cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        context.restoreGState()
    }
}

/// Reuse a text row whenever its previous clip has ended. Layer order in the project stays intact.
struct TextTimelineLayout {
    let rows: [[TextOverlay]]

    init(overlays: [TextOverlay], duration: Double) {
        let ordered = overlays.enumerated().filter { $0.element.start < duration && $0.element.end > 0 }
            .sorted {
                $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
            }
        var rows: [[TextOverlay]] = []
        for (_, text) in ordered {
            if let row = rows.firstIndex(where: { ($0.last?.end ?? 0) <= text.start + 0.000001 }) {
                rows[row].append(text)
            } else {
                rows.append([text])
            }
        }
        self.rows = rows
    }

    var height: Double { Double(rows.count) * TimelineMetrics.textRowHeight }
}

/// One shared text track uses extra rows only for clips that overlap in time.
struct TextTimelineLanes: View {
    @ObservedObject var session: EditorSession
    let layout: TextTimelineLayout
    let width: Double
    let total: Double
    let focus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TimelineMetrics.textRowSpacing) {
            ForEach(layout.rows.indices, id: \.self) { row in
                ZStack(alignment: .leading) {
                    ForEach(layout.rows[row]) { text in
                        TextTimelineClip(text: text, selected: session.selectedTextID == text.id,
                                         scale: width / max(0.001, total), total: total,
                                         select: { select(text) }, commit: { start, duration in
                            var texts = session.draft.textOverlays ?? []
                            guard let index = texts.firstIndex(where: { $0.id == text.id }) else { return }
                            texts[index].start = start; texts[index].duration = duration
                            session.draft.textOverlays = texts
                        }, remove: {
                            session.draft.textOverlays?.removeAll { $0.id == text.id }
                            if session.selectedTextID == text.id { session.selectedTextID = nil }
                        })
                    }
                }
                .frame(width: width, height: TimelineMetrics.textClipHeight, alignment: .leading)
            }
        }
    }

    private func select(_ text: TextOverlay) {
        session.player?.pause()
        session.selectedVoiceOverID = nil; session.selectedZoomID = nil
        session.selectedRecordedAudioID = nil; session.selectedSegment = nil; session.isVideoOverlaySelected = false
        session.selectedTextID = text.id
        focus()
        session.player?.seek(to: EditorAudio.time(min(text.start, max(0, total - 0.01))), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

private struct TextTimelineClip: View {
    let text: TextOverlay
    let selected: Bool
    let scale: Double
    let total: Double
    let select: () -> Void
    let commit: (Double, Double) -> Void
    let remove: () -> Void
    @State private var preview: (start: Double, duration: Double)?

    var body: some View {
        let start = preview?.start ?? text.start
        let duration = min(preview?.duration ?? text.duration, max(0, total - start))
        HStack(spacing: 0) {
            edge(beginning: true)
            HStack(spacing: 4) {
                Image(systemName: "textformat")
                Text(text.text.isEmpty ? "Text" : text.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .medium)).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { gesture in
                    if preview == nil { select() }
                    let start = min(max(0, total - min(text.duration, total)), max(0, text.start + gesture.translation.width / scale))
                    preview = (start, min(text.duration, total))
                }
                .onEnded { _ in
                    if let preview { commit(preview.start, preview.duration) }
                    preview = nil
                })
            edge(beginning: false)
        }
        .frame(width: max(18, duration * scale), height: TimelineMetrics.textClipHeight)
        .foregroundStyle(selected ? Color.white : DesignColors.accent)
        .background(DesignColors.accent.opacity(selected ? 0.85 : 0.18), in: RoundedRectangle(cornerRadius: CornerRadius.sm))
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.sm).strokeBorder(DesignColors.accent.opacity(selected ? 1 : 0.4)))
        .offset(x: min(total, start) * scale)
        .opacity(text.start < total ? 1 : 0.4)
        .contextMenu { Button("Delete Text", role: .destructive, action: remove) }
        .accessibilityLabel("Text: \(text.text)")
    }

    private func edge(beginning: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(selected ? Color.white.opacity(0.7) : DesignColors.accent.opacity(0.4))
            .frame(width: 2, height: 14).frame(width: 8, height: TimelineMetrics.textClipHeight).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { gesture in
                    if preview == nil { select() }
                    let delta = gesture.translation.width / scale
                    let end = min(total, text.end)
                    if beginning {
                        let start = min(max(0, end - 0.05), max(0, text.start + delta))
                        preview = (start, max(0.05, end - start))
                    } else {
                        preview = (text.start, max(0.05, min(total - text.start, text.duration + delta)))
                    }
                }
                .onEnded { _ in
                    if let preview { commit(preview.start, preview.duration) }
                    preview = nil
                })
            .accessibilityLabel(beginning ? "Trim text start" : "Trim text end")
    }
}
