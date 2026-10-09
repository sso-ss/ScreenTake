import AppKit
import SwiftUI

extension View {
    /// Keeps help available to VoiceOver and tracks hover even on disabled controls.
    func hoverHelp(_ text: String?) -> some View {
        modifier(HoverHelpModifier(text: text))
    }

    /// Draws help above scrolling/clipped controls without intercepting their input.
    func hoverHelpContainer() -> some View {
        overlayPreferenceValue(HoverHelpKey.self) { tips in
            GeometryReader { geometry in
                // A specific control's help takes precedence over its containing group.
                if let tip = tips.reversed().min(by: {
                    let lhs = geometry[$0.bounds], rhs = geometry[$1.bounds]
                    return lhs.width * lhs.height < rhs.width * rhs.height
                }) {
                    let bounds = geometry[tip.bounds]
                    HoverHelpBubble(text: tip.text,
                                    point: CGPoint(x: bounds.minX + bounds.width * tip.position.x,
                                                   y: bounds.minY + bounds.height * tip.position.y),
                                    size: geometry.size)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct HoverHelpAnchor {
    let text: String
    let bounds: Anchor<CGRect>
    let position: CGPoint
}

private struct HoverHelpKey: PreferenceKey {
    static var defaultValue: [HoverHelpAnchor] = []
    static func reduce(value: inout [HoverHelpAnchor], nextValue: () -> [HoverHelpAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

private struct HoverHelpModifier: ViewModifier {
    let text: String?
    @State private var hoverPosition: CGPoint?

    func body(content: Content) -> some View {
        content
            .accessibilityHint(Text(text ?? ""))
            .overlay {
                if text != nil {
                    HoverHelpTrackingView(position: $hoverPosition)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .anchorPreference(key: HoverHelpKey.self, value: .bounds) {
                if let text, let hoverPosition, !text.isEmpty {
                    return [HoverHelpAnchor(text: text, bounds: $0, position: hoverPosition)]
                }
                return []
            }
    }
}

private struct HoverHelpBubble: View {
    let text: String
    let point: CGPoint
    let size: CGSize

    var body: some View {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let naturalWidth = (text as NSString).size(withAttributes: [.font: font]).width + 20
        let width = min(280, max(40, size.width - 16), ceil(naturalWidth))
        let textHeight = (text as NSString).boundingRect(
            with: CGSize(width: width - 20, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        ).height
        let height = ceil(textHeight) + 14
        let x = min(size.width - width / 2 - 8, max(width / 2 + 8, point.x + 12 + width / 2))
        let below = point.y + 18
        let y = below + height <= size.height - 8 ? below : max(8, point.y - height - 12)

        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DesignColors.primaryLabel)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: width)
            .background(DesignColors.controlBackground, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DesignColors.inputBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            .position(x: x, y: y + height / 2)
    }
}

private struct HoverHelpTrackingView: NSViewRepresentable {
    @Binding var position: CGPoint?

    func makeNSView(context: Context) -> HoverHelpTrackingArea {
        let view = HoverHelpTrackingArea()
        view.onHover = { position = $0 }
        return view
    }

    func updateNSView(_ view: HoverHelpTrackingArea, context: Context) {
        view.onHover = { position = $0 }
    }

    static func dismantleNSView(_ view: HoverHelpTrackingArea, coordinator: ()) {
        view.cancelHover()
    }
}

/// AppKit tracking areas still receive mouse entry/exit when SwiftUI disables a control.
/// Returning nil from hitTest lets all clicks reach the original control unchanged.
private final class HoverHelpTrackingArea: NSView {
    var onHover: ((CGPoint?) -> Void)?
    private var area: NSTrackingArea?
    private var pending: DispatchWorkItem?
    private var showing = false
    private var position: CGPoint?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        // SwiftUI's unclipped backing views can report a visibleRect larger than bounds.
        // Explicitly intersect them so help belongs only to this control, not the whole panel.
        let area = NSTrackingArea(rect: bounds.intersection(visibleRect),
                                 options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                 owner: self, userInfo: nil)
        self.area = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        position = pointerPosition(for: event)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let position = self.position else { return }
            self.showing = true
            self.onHover?(position)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    override func mouseExited(with event: NSEvent) { cancelHover() }

    override func mouseMoved(with event: NSEvent) {
        position = pointerPosition(for: event)
        if showing { onHover?(position) }
    }

    /// Normalize the pointer to the control; SwiftUI resolves its anchor in the overlay.
    private func pointerPosition(for event: NSEvent) -> CGPoint? {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.intersection(visibleRect).contains(point) else { return nil }
        return CGPoint(x: (point.x - bounds.minX) / bounds.width,
                       y: isFlipped ? (point.y - bounds.minY) / bounds.height
                                    : (bounds.maxY - point.y) / bounds.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelHover() }
    }

    func cancelHover() {
        showing = false
        position = nil
        pending?.cancel()
        pending = nil
        let callback = onHover
        // Removal can occur during SwiftUI's update; publish after that update completes.
        DispatchQueue.main.async { callback?(nil) }
    }

    deinit {
        pending?.cancel()
    }
}
