import Foundation
import os

/// Centralized logging using Apple's unified logging system.
///
/// Usage:
///   Log.recording.info("Recording started")
///   Log.capture.error("Failed to stop: \(error)")
///   Log.tracking.debug("Mouse sample: \(position)")
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.screen.Screen"

    /// Recording lifecycle (start, stop, pause, resume)
    static let recording = Logger(subsystem: subsystem, category: "recording")

    /// Screen capture (ScreenCaptureKit interactions)
    static let capture = Logger(subsystem: subsystem, category: "capture")

    /// Mouse, click, keyboard, scroll tracking
    static let tracking = Logger(subsystem: subsystem, category: "tracking")

    /// Export engine and rendering pipeline
    static let export = Logger(subsystem: subsystem, category: "export")

    /// Smart generation pipeline
    static let generator = Logger(subsystem: subsystem, category: "generator")

    /// Project system (save, load, package)
    static let project = Logger(subsystem: subsystem, category: "project")

    /// UI and general app events
    static let app = Logger(subsystem: subsystem, category: "app")

    /// Permissions
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
