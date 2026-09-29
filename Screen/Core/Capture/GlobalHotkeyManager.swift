import Foundation
import Carbon
import AppKit

/// Registers and handles global keyboard shortcuts.
///
/// - Cmd+Shift+2: toggle recording (always registered)
/// - Ctrl+Z: toggle zoom (registered during recording, works system-wide)
/// - Ctrl+Space: pause/resume (registered during recording, works system-wide)
/// - Escape: stop recording (registered during recording, works system-wide)
///
/// Carbon hotkeys with modifiers work system-wide without Accessibility permission.
/// A local NSEvent monitor also catches bare Z when the toolbar is focused.
@MainActor
final class GlobalHotkeyManager {

    static let shared = GlobalHotkeyManager()

    // Carbon hotkey refs
    private var eventHandler: EventHandlerRef?
    private var toggleRecordingRef: EventHotKeyRef?
    private var zoomRef: EventHotKeyRef?
    private var pauseRef: EventHotKeyRef?
    private var stopRef: EventHotKeyRef?

    // Local monitor for bare Z when toolbar is focused
    private var localMonitor: Any?

    // Callbacks
    var onToggleRecording: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onToggleZoom: (() -> Void)?

    private init() {}

    // MARK: - Global Carbon Hotkeys

    /// Register the persistent hotkey (Cmd+Shift+2) and install the Carbon event handler.
    func registerHotkeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            let mgr = GlobalHotkeyManager.shared
            switch hotKeyID.id {
            case 1:  // Cmd+Shift+2 → toggle recording
                Task { @MainActor in mgr.onToggleRecording?() }
            case 10: // Ctrl+Z → zoom
                Task { @MainActor in
                    Log.app.info("Ctrl+Z → zoom toggle")
                    mgr.onToggleZoom?()
                }
            case 11: // Ctrl+Space → pause/resume
                Task { @MainActor in mgr.onPauseResume?() }
            case 12: // Escape → stop
                Task { @MainActor in mgr.onStopRecording?() }
            default:
                break
            }

            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        // Cmd+Shift+2  —  always active
        var id1 = EventHotKeyID(signature: OSType(0x5363_524E), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_2),
            UInt32(cmdKey | shiftKey),
            id1,
            GetApplicationEventTarget(),
            0,
            &toggleRecordingRef
        )
    }

    func unregisterHotkeys() {
        if let ref = toggleRecordingRef {
            UnregisterEventHotKey(ref)
            toggleRecordingRef = nil
        }
    }

    // MARK: - Recording Shortcuts

    /// Register recording-specific hotkeys: Ctrl+Z (zoom), Ctrl+Space (pause), Escape (stop).
    /// These use Carbon hotkeys which work system-wide without any special permissions.
    /// Also installs a local monitor so bare Z works when the toolbar is focused.
    func startRecordingKeyMonitor() {
        let sig = OSType(0x5363_524E) // 'ScRN'

        // Ctrl+Z → zoom toggle (system-wide)
        var zoomID = EventHotKeyID(signature: sig, id: 10)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Z),
            UInt32(controlKey),
            zoomID,
            GetApplicationEventTarget(),
            0,
            &zoomRef
        )

        // Ctrl+Space → pause/resume (system-wide)
        var pauseID = EventHotKeyID(signature: sig, id: 11)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey),
            pauseID,
            GetApplicationEventTarget(),
            0,
            &pauseRef
        )

        // Escape → stop (no modifier needed — Escape with 0 modifiers works via Carbon)
        var stopID = EventHotKeyID(signature: sig, id: 12)
        RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            stopID,
            GetApplicationEventTarget(),
            0,
            &stopRef
        )

        // Local monitor: bare Z (no modifier) works when toolbar window is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !event.isARepeat else { return event }

            // Only handle bare keys (no Cmd/Ctrl/Option)
            let modFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasModifiers = !modFlags.subtracting([.capsLock, .numericPad, .function]).isEmpty

            switch event.keyCode {
            case 6 where !hasModifiers:  // bare Z
                Log.app.info("Z key → zoom toggle (toolbar focused)")
                Task { @MainActor in self.onToggleZoom?() }
                return nil
            case 49 where !hasModifiers: // bare Space
                Task { @MainActor in self.onPauseResume?() }
                return nil
            case 53: // Escape (always)
                Task { @MainActor in self.onStopRecording?() }
                return nil
            default:
                return event
            }
        }

        Log.app.info("Recording hotkeys active — Ctrl+Z (zoom), Ctrl+Space (pause), Esc (stop)")
    }

    /// Unregister recording-specific hotkeys.
    func stopRecordingKeyMonitor() {
        if let ref = zoomRef { UnregisterEventHotKey(ref); zoomRef = nil }
        if let ref = pauseRef { UnregisterEventHotKey(ref); pauseRef = nil }
        if let ref = stopRef { UnregisterEventHotKey(ref); stopRef = nil }

        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        Log.app.info("Recording hotkeys deactivated")
    }
}
