import AppKit

@main struct TimelineKeyboardChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        func event(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                isARepeat: false, keyCode: code)!
        }
        precondition(EditorPlaybackShortcut.action(for: event(51)) == .deleteSelection)
        precondition(EditorPlaybackShortcut.action(for: event(117)) == .deleteSelection)
        precondition(EditorPlaybackShortcut.action(for: event(117, modifiers: .function)) == .deleteSelection)
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            precondition(EditorPlaybackShortcut.action(for: event(51, modifiers: modifiers)) == nil)
        }
        let monitor = EditorPlaybackKeyboardMonitor.MonitorView()
        monitor.hasSelection = true
        precondition(monitor.acceptsFirstResponder)
        precondition(monitor.shouldHandle(.deleteSelection, responder: monitor))
        precondition(monitor.shouldHandle(.deleteSelection, responder: NSButton()))
        precondition(!monitor.shouldHandle(.deleteSelection, responder: NSTextView()))
        precondition(!monitor.shouldHandle(.deleteSelection, responder: NSTextField()))
        precondition(!monitor.shouldHandle(.step(direction: 1, seconds: false), responder: NSSlider()))
        monitor.hasSelection = false
        precondition(!monitor.shouldHandle(.deleteSelection, responder: monitor))
        print("PASS: Delete/Forward Delete select the timeline action without stealing modified keys")
        print("PASS: selected strips accept keyboard deletion; text fields, sliders, and empty selections retain their keys")
    }
}
