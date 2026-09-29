import Foundation
import CoreGraphics
import CoreMedia
import AppKit

/// Records mouse positions, clicks, scrolls, and keyboard events during capture.
final class MouseDataRecorder: @unchecked Sendable {

    // MARK: - Types

    struct MousePosition: Codable {
        let timestamp: TimeInterval
        let x: Double
        let y: Double
        let velocity: Double
    }

    struct ClickEvent: Codable {
        let timestamp: TimeInterval
        let x: Double
        let y: Double
        let button: Int  // 0=left, 1=right, 2=middle
        let isDown: Bool
    }

    struct KeyEvent: Codable {
        let timestamp: TimeInterval
        let keyCode: Int
        let characters: String
        let modifiers: Int
        let isDown: Bool
    }

    struct ScrollEvent: Codable {
        let timestamp: TimeInterval
        let deltaX: Double
        let deltaY: Double
    }

    struct ZoomEvent: Codable {
        let timestamp: TimeInterval
        let x: Double
        let y: Double
        let isZoomIn: Bool
    }

    struct MouseRecording: Codable {
        let positions: [MousePosition]
        let clicks: [ClickEvent]
        let keys: [KeyEvent]
        let scrolls: [ScrollEvent]
        let zoomMarkers: [ZoomEvent]
        let screenBounds: CodableRect
        let scaleFactor: Double
        let sampleInterval: Double

        init(positions: [MousePosition], clicks: [ClickEvent], keys: [KeyEvent],
             scrolls: [ScrollEvent], zoomMarkers: [ZoomEvent],
             screenBounds: CodableRect, scaleFactor: Double, sampleInterval: Double) {
            self.positions = positions
            self.clicks = clicks
            self.keys = keys
            self.scrolls = scrolls
            self.zoomMarkers = zoomMarkers
            self.screenBounds = screenBounds
            self.scaleFactor = scaleFactor
            self.sampleInterval = sampleInterval
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            positions = try container.decode([MousePosition].self, forKey: .positions)
            clicks = try container.decode([ClickEvent].self, forKey: .clicks)
            keys = try container.decode([KeyEvent].self, forKey: .keys)
            scrolls = try container.decode([ScrollEvent].self, forKey: .scrolls)
            zoomMarkers = try container.decodeIfPresent([ZoomEvent].self, forKey: .zoomMarkers) ?? []
            screenBounds = try container.decode(CodableRect.self, forKey: .screenBounds)
            scaleFactor = try container.decode(Double.self, forKey: .scaleFactor)
            sampleInterval = try container.decode(Double.self, forKey: .sampleInterval)
        }
    }

    struct CodableRect: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(from rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }
    }

    // MARK: - State

    private var isRecording = false
    private var positions: [MousePosition] = []
    private var clicks: [ClickEvent] = []
    private var keys: [KeyEvent] = []
    private var scrolls: [ScrollEvent] = []
    private var zoomMarkers: [ZoomEvent] = []
    private var isZoomedIn = false

    private var screenBounds: CGRect = .zero
    private var scaleFactor: CGFloat = 1.0
    private var sampleInterval: TimeInterval = 1.0 / 60.0
    private var recordingStartTime: TimeInterval = 0
    private var pauseStartTime: TimeInterval?
    private var totalPausedDuration: TimeInterval = 0

    private var sampleTimer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(label: "com.screen.mouse-sampling", qos: .userInteractive)
    private var primaryDisplayHeight: CGFloat = 0
    private var lastPosition: CGPoint = .zero
    private var lastPositionTime: TimeInterval = 0

    private var eventMonitor: Any?
    private var localEventMonitor: Any?

    private let lock = NSLock()

    // MARK: - Recording Control

    func startRecording(screenBounds: CGRect, scaleFactor: CGFloat = 1.0, captureFrameRate: Int = 60,
                        startTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.lock()
        guard !isRecording, sampleTimer == nil else {
            lock.unlock()
            return
        }

        let mouseHz = max(1, min(captureFrameRate, 120))
        self.sampleInterval = 1.0 / Double(mouseHz)
        self.screenBounds = screenBounds
        self.scaleFactor = scaleFactor
        self.positions.removeAll()
        self.clicks.removeAll()
        self.keys.removeAll()
        self.scrolls.removeAll()
        self.zoomMarkers.removeAll()
        self.isZoomedIn = false
        self.recordingStartTime = startTime.seconds
        self.pauseStartTime = nil
        self.totalPausedDuration = 0
        self.primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        self.lastPosition = .zero
        self.lastPositionTime = 0

        isRecording = true
        lock.unlock()
        startSampling()
        startEventMonitoring()

        Log.tracking.info("Mouse recording started: \(String(describing: screenBounds)), scale=\(scaleFactor), \(mouseHz)Hz")
    }

    /// Record a manual zoom toggle at the current cursor position.
    func recordZoomToggle() {
        lock.lock()
        guard isRecording else {
            lock.unlock()
            Log.tracking.warning("recordZoomToggle: not recording, ignoring")
            return
        }

        let timestamp = max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds - recordingStartTime - totalPausedDuration)
        let location = NSEvent.mouseLocation
        let normalizedX = (location.x - screenBounds.origin.x) / screenBounds.width
        let normalizedY = (location.y - screenBounds.origin.y) / screenBounds.height

        isZoomedIn.toggle()
        let zoomIn = isZoomedIn
        zoomMarkers.append(ZoomEvent(
            timestamp: timestamp,
            x: normalizedX,
            y: normalizedY,
            isZoomIn: zoomIn
        ))
        let markerCount = zoomMarkers.count
        lock.unlock()

        Log.tracking.info("Zoom \(zoomIn ? "IN" : "OUT") recorded (#\(markerCount)) at t=\(String(format: "%.2f", timestamp))s pos=(\(String(format: "%.3f", normalizedX)), \(String(format: "%.3f", normalizedY)))")
    }

    func recordingTime(at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> TimeInterval {
        lock.withLock {
            max(0, (pauseStartTime ?? time.seconds) - recordingStartTime - totalPausedDuration)
        }
    }

    func pause(at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }
        pauseStartTime = time.seconds
        isRecording = false
        lock.unlock()
    }

    func resume(at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.lock()
        guard let pauseStartTime else {
            lock.unlock()
            return
        }
        totalPausedDuration += max(0, time.seconds - pauseStartTime)
        self.pauseStartTime = nil
        isRecording = true
        lock.unlock()
    }

    func stopRecording() -> MouseRecording {
        lock.lock()
        isRecording = false
        pauseStartTime = nil
        lock.unlock()
        stopSampling()
        stopEventMonitoring()

        lock.lock()
        let recording = MouseRecording(
            positions: positions,
            clicks: clicks,
            keys: keys,
            scrolls: scrolls,
            zoomMarkers: zoomMarkers,
            screenBounds: CodableRect(from: screenBounds),
            scaleFactor: Double(scaleFactor),
            sampleInterval: sampleInterval
        )
        lock.unlock()

        Log.tracking.info("Mouse recording stopped: \(recording.positions.count) positions, \(recording.clicks.count) clicks, \(recording.keys.count) keys")
        return recording
    }

    // MARK: - Position Sampling

    private func startSampling() {
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        timer.schedule(deadline: .now(), repeating: sampleInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.sampleMousePosition()
        }
        sampleTimer = timer
        timer.resume()
    }

    private func stopSampling() {
        sampleTimer?.cancel()
        sampleTimer = nil
        samplingQueue.sync {}
    }

    private func sampleMousePosition() {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return }

        guard let eventLocation = CGEvent(source: nil)?.location else { return }
        let location = Self.appKitPosition(from: eventLocation, primaryDisplayHeight: primaryDisplayHeight)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let timestamp = max(0, now.seconds - recordingStartTime - totalPausedDuration)

        // Normalize to screen bounds (0-1)
        let normalizedX = (location.x - screenBounds.origin.x) / screenBounds.width
        let normalizedY = (location.y - screenBounds.origin.y) / screenBounds.height

        // Calculate velocity
        let dx = Double(location.x - lastPosition.x)
        let dy = Double(location.y - lastPosition.y)
        let dt = now.seconds - lastPositionTime
        let velocity = lastPositionTime > 0 && dt > 0 ? sqrt(dx * dx + dy * dy) / dt : 0.0

        lastPosition = location
        lastPositionTime = now.seconds

        let pos = MousePosition(
            timestamp: timestamp,
            x: normalizedX,
            y: normalizedY,
            velocity: velocity
        )

        positions.append(pos)
    }

    static func appKitPosition(from location: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: location.x, y: primaryDisplayHeight - location.y)
    }

    // MARK: - Event Monitoring

    private func startEventMonitoring() {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .keyDown, .keyUp,
            .scrollWheel,
        ]

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
            return event
        }
    }

    private func stopEventMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    private func handleEvent(_ event: NSEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return }

        let timestamp = max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds - recordingStartTime - totalPausedDuration)
        let location = NSEvent.mouseLocation
        let normalizedX = (location.x - screenBounds.origin.x) / screenBounds.width
        let normalizedY = (location.y - screenBounds.origin.y) / screenBounds.height

        switch event.type {
        case .leftMouseDown:
            clicks.append(ClickEvent(timestamp: timestamp, x: normalizedX, y: normalizedY, button: 0, isDown: true))
        case .leftMouseUp:
            clicks.append(ClickEvent(timestamp: timestamp, x: normalizedX, y: normalizedY, button: 0, isDown: false))
        case .rightMouseDown:
            clicks.append(ClickEvent(timestamp: timestamp, x: normalizedX, y: normalizedY, button: 1, isDown: true))
        case .rightMouseUp:
            clicks.append(ClickEvent(timestamp: timestamp, x: normalizedX, y: normalizedY, button: 1, isDown: false))
        case .keyDown:
            keys.append(KeyEvent(
                timestamp: timestamp,
                keyCode: Int(event.keyCode),
                characters: event.charactersIgnoringModifiers ?? "",
                modifiers: Int(event.modifierFlags.rawValue),
                isDown: true
            ))
        case .keyUp:
            keys.append(KeyEvent(
                timestamp: timestamp,
                keyCode: Int(event.keyCode),
                characters: event.charactersIgnoringModifiers ?? "",
                modifiers: Int(event.modifierFlags.rawValue),
                isDown: false
            ))
        case .scrollWheel:
            scrolls.append(ScrollEvent(
                timestamp: timestamp,
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY
            ))
        default:
            break
        }
    }

    // MARK: - Save

    static func save(_ recording: MouseRecording, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(recording)
        try data.write(to: url)
        Log.tracking.info("Mouse data saved: \(url.lastPathComponent) (\(data.count) bytes)")
    }
}
