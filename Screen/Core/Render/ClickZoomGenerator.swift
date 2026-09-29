import Foundation
import AVFoundation
import os

/// Generates camera keyframes by zooming to click locations.
///
/// Follow-up clicks extend the active zoom and retarget from the current camera
/// state. The camera returns to the full frame only after the user goes idle.
enum ClickZoomGenerator {

    struct Settings {
        /// Zoom level at click location (1.5 = 1.5× magnification).
        var zoomLevel: CGFloat = 2.0
        /// Duration of the zoom-in ramp (seconds).
        var zoomInDuration: TimeInterval = 0.6
        /// Duration to hold the zoomed view after the last click (seconds).
        var holdDuration: TimeInterval = 2.0
        /// Duration of the zoom-out ramp (seconds).
        var zoomOutDuration: TimeInterval = 0.8
        /// Minimum time between nearby retargets to prevent rapid fire.
        var minimumInterval: TimeInterval = 0.3
        /// Idle gap after which a new zoom may anticipate the next click.
        var idleThreshold: TimeInterval = 3.0
        /// Max normalized distance (0-1) for suppressing rapid nearby retargets.
        var mergeDistance: CGFloat = 0.35
        /// Duration to pan between clicks during an active zoom (seconds).
        var panDuration: TimeInterval = 0.4
    }

    /// Generate camera keyframes from mouse recording data.
    ///
    /// - Parameters:
    ///   - mouseDataURL: URL to the .mouse.json file.
    ///   - sourceVideoURL: URL of the source video (used to detect padding).
    ///   - settings: Zoom timing and level settings.
    /// - Returns: Array of camera keyframes for the FrameEvaluator.
    static func generate(
        from mouseDataURL: URL,
        sourceVideoURL: URL? = nil,
        settings: Settings = Settings(),
        segments: [ZoomSegment]? = nil
    ) async throws -> [CameraKeyframe] {
        let data = try Data(contentsOf: mouseDataURL)
        let recording = try JSONDecoder().decode(
            MouseDataRecorder.MouseRecording.self, from: data
        )

        // Detect padding by comparing video dimensions to recorded screen bounds
        var paddingRatio: CGFloat = 0
        if let videoURL = sourceVideoURL {
            paddingRatio = await detectPaddingRatio(videoURL: videoURL, recording: recording)
        }

        if let segments {
            return generate(segments: segments, positions: recording.positions,
                            paddingRatio: paddingRatio, zoomLevel: settings.zoomLevel)
        }
        return generate(from: recording, paddingRatio: paddingRatio, settings: settings)
    }

    /// Detect the padding ratio for window recordings by comparing video size to capture bounds.
    static func detectPaddingRatio(videoURL: URL, recording: MouseDataRecorder.MouseRecording) async -> CGFloat {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else {
            return 0
        }

        let captureWidth = recording.screenBounds.width * recording.scaleFactor
        let videoWidth = Double(size.width)

        // If video is wider than capture area, there's padding (window recording)
        guard videoWidth > captureWidth + 1 else { return 0 }

        // paddingRatio = fraction of the video frame that is padding on each side
        let ratio = (videoWidth - captureWidth) / (2.0 * videoWidth)
        Log.generator.info("Detected window padding: video=\(videoWidth), capture=\(captureWidth), padRatio=\(ratio)")
        return CGFloat(ratio)
    }

    /// Generate camera keyframes from a mouse recording.
    static func generate(
        from recording: MouseDataRecorder.MouseRecording,
        paddingRatio: CGFloat = 0,
        settings: Settings = Settings()
    ) -> [CameraKeyframe] {
        // Remap factor: mouse coords are 0-1 within capture area,
        // but the video frame may have padding around it (window recordings).
        let contentScale = 1.0 - 2.0 * paddingRatio

        // If manual zoom markers exist, use those exclusively
        let keyframes: [CameraKeyframe]
        if !recording.zoomMarkers.isEmpty {
            keyframes = generateFromManualZoom(
                markers: recording.zoomMarkers,
                positions: recording.positions,
                paddingRatio: paddingRatio,
                contentScale: contentScale,
                settings: settings
            )
        } else {
            keyframes = generateFromClicks(
                recording: recording,
                paddingRatio: paddingRatio,
                contentScale: contentScale,
                settings: settings
            )
        }

        return followingPointer(
            in: keyframes, positions: recording.positions,
            paddingRatio: paddingRatio, contentScale: contentScale
        )
    }

    static func generate(
        segments: [ZoomSegment],
        positions: [MouseDataRecorder.MousePosition] = [],
        paddingRatio: CGFloat = 0,
        zoomLevel: CGFloat = 2
    ) -> [CameraKeyframe] {
        let contentScale = 1 - 2 * paddingRatio
        var keyframes = [CameraKeyframe(time: 0, transform: .identity, easing: .linear)]
        for segment in segments.sorted(by: { $0.start < $1.start }) where segment.start.isFinite && segment.end.isFinite && segment.centerX.isFinite && segment.centerY.isFinite && segment.end > segment.start && zoomLevel > 1 {
            let start = max(0, segment.start)
            let end = max(start + 0.1, segment.end)
            let target = CameraTransform(
                zoom: min(4, max(1.1, zoomLevel)),
                centerX: paddingRatio + CGFloat(min(1, max(0, segment.centerX))) * contentScale,
                centerY: paddingRatio + CGFloat(1 - min(1, max(0, segment.centerY))) * contentScale
            ).clamped()
            appendClickTransition(to: &keyframes, at: start, target: target, duration: min(0.6, (end - start) / 3))
            keyframes.append(CameraKeyframe(time: end, transform: target, easing: .linear))
            appendClickTransition(to: &keyframes, at: end, target: .identity, duration: 0.6)
        }
        keyframes = deduplicateByTime(keyframes)
        guard !positions.isEmpty else { return keyframes }
        // Fixed-focus segments remain fixed; pointer following only applies to opted-in intervals.
        let followed = followingPointer(in: keyframes, positions: positions, paddingRatio: paddingRatio, contentScale: contentScale)
        let fixed = FrameEvaluator(keyframes: keyframes)
        let ordered = segments.sorted { $0.start < $1.start }
        let fixedIntervals = ordered.indices.compactMap { index -> (Double, Double)? in
            let segment = ordered[index]
            guard !segment.followsCursor else { return nil }
            let nextStart = index + 1 < ordered.count ? ordered[index + 1].start : .infinity
            return (segment.start, min(segment.end + 0.6, nextStart))
        }
        return followed.map { frame in
            guard !fixedIntervals.contains(where: { frame.time >= $0.0 && frame.time <= $0.1 }) else {
                return CameraKeyframe(time: frame.time, transform: fixed.evaluate(at: frame.time), easing: .linear)
            }
            return frame
        }
    }

    static func editableSegments(from recording: MouseDataRecorder.MouseRecording,
                                 duration: Double, zoomLevel: Double) -> [ZoomSegment] {
        if !recording.zoomMarkers.isEmpty {
            var result: [ZoomSegment] = []
            for marker in recording.zoomMarkers.sorted(by: { $0.timestamp < $1.timestamp }) {
                if marker.isZoomIn {
                    if let last = result.indices.last, result[last].end >= marker.timestamp {
                        result[last].end = max(result[last].start + 0.1, marker.timestamp)
                    }
                    result.append(ZoomSegment(start: max(0, marker.timestamp), end: duration,
                                              zoom: zoomLevel, centerX: marker.x, centerY: marker.y))
                } else if let last = result.indices.last {
                    result[last].end = min(duration, max(result[last].start + 0.1, marker.timestamp))
                }
            }
            return result.filter { $0.end > $0.start && $0.start < duration }
        }
        var result: [ZoomSegment] = []
        for click in recording.clicks.filter({ $0.button == 0 && $0.isDown && (0...1).contains($0.x) && (0...1).contains($0.y) })
            .sorted(by: { $0.timestamp < $1.timestamp }) where click.timestamp < duration {
            let time = max(0, click.timestamp)
            if let last = result.indices.last, time <= result[last].end {
                let distance = hypot(result[last].centerX - click.x, result[last].centerY - click.y)
                let deadZone = min(0.35, 0.3 / max(1, zoomLevel))
                if distance <= deadZone {
                    result[last].end = min(duration, max(result[last].end, time + 2))
                    continue
                }
                result[last].end = max(result[last].start + 0.1, time)
            }
            result.append(ZoomSegment(start: time, end: min(duration, time + 2), zoom: zoomLevel,
                                      centerX: click.x, centerY: click.y))
        }
        return result.filter { $0.end > $0.start }
    }

    private static func followingPointer(
        in keyframes: [CameraKeyframe],
        positions: [MouseDataRecorder.MousePosition],
        paddingRatio: CGFloat,
        contentScale: CGFloat
    ) -> [CameraKeyframe] {
        guard !positions.isEmpty, let first = keyframes.first else { return keyframes }
        var result = [first]
        var previousBase = first.transform
        var camera = first.transform
        var previousTime = first.time

        for (left, right) in zip(keyframes, keyframes.dropFirst()) {
            let duration = right.time - left.time
            let isZoomed = max(left.transform.zoom, right.transform.zoom) > 1.0001
            let steps = isZoomed ? max(1, Int(ceil(duration * 60))) : 1
            for step in 1...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                let time = left.time + duration * Double(progress)
                let base = left.transform.lerp(to: right.transform, t: left.easing.evaluate(progress))
                let retention = previousBase.zoom > 1.0001
                    ? min(1, max(0, (base.zoom - 1) / (previousBase.zoom - 1))) : 0
                camera = CameraTransform(
                    zoom: base.zoom,
                    centerX: base.centerX + (camera.centerX - previousBase.centerX) * retention,
                    centerY: base.centerY + (camera.centerY - previousBase.centerY) * retention
                ).clamped()

                if base.zoom > 1.0001,
                   let pointer = interpolatedPosition(at: time, in: positions),
                   pointer.x.isFinite, pointer.y.isFinite,
                   (0...1).contains(pointer.x), (0...1).contains(pointer.y) {
                    let pointerX = paddingRatio + CGFloat(pointer.x) * contentScale
                    let pointerY = paddingRatio + (1 - CGFloat(pointer.y)) * contentScale
                    let halfViewport = 0.5 / base.zoom
                    let deadZone = halfViewport * 0.6
                    let margin = halfViewport * 0.95
                    let smoothing = CGFloat(1 - exp(-8 * max(0, time - previousTime)))
                    func follow(_ center: CGFloat, _ pointer: CGFloat) -> CGFloat {
                        let distance = pointer - center
                        let excess = max(0, abs(distance) - deadZone)
                        let smoothed = center + (distance < 0 ? -1 : 1) * excess * smoothing
                        return max(pointer - margin, min(pointer + margin, smoothed))
                    }
                    camera.centerX = follow(camera.centerX, pointerX)
                    camera.centerY = follow(camera.centerY, pointerY)
                    camera = camera.clamped()
                }

                result.append(CameraKeyframe(time: time, transform: camera, easing: .linear))
                previousBase = base
                previousTime = time
            }
        }
        return result
    }

    // MARK: - Manual Zoom

    private static func generateFromManualZoom(
        markers: [MouseDataRecorder.ZoomEvent],
        positions: [MouseDataRecorder.MousePosition],
        paddingRatio: CGFloat,
        contentScale: CGFloat,
        settings: Settings
    ) -> [CameraKeyframe] {
        var keyframes = [CameraKeyframe(time: 0, transform: .identity, easing: .linear)]
        for marker in markers.sorted(by: { $0.timestamp < $1.timestamp }) {
            let target = marker.isZoomIn ? CameraTransform(
                zoom: settings.zoomLevel,
                centerX: paddingRatio + CGFloat(marker.x) * contentScale,
                centerY: paddingRatio + (1 - CGFloat(marker.y)) * contentScale
            ).clamped() : .identity
            appendClickTransition(
                to: &keyframes, at: max(0, marker.timestamp), target: target,
                duration: marker.isZoomIn ? settings.zoomInDuration : settings.zoomOutDuration
            )
        }
        if let last = keyframes.last, let end = positions.last?.timestamp, end > last.time {
            keyframes.append(CameraKeyframe(time: end, transform: last.transform, easing: .linear))
        }

        keyframes = deduplicateByTime(keyframes)
        Log.generator.info("Generated \(keyframes.count) keyframes from manual zoom")
        return keyframes
    }

    /// Linearly interpolate cursor position at a given time from the positions array.
    private static func interpolatedPosition(
        at time: TimeInterval,
        in positions: [MouseDataRecorder.MousePosition]
    ) -> (x: Double, y: Double)? {
        guard !positions.isEmpty else { return nil }

        // Binary search for the insertion point
        var lo = 0, hi = positions.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if positions[mid].timestamp < time { lo = mid + 1 } else { hi = mid }
        }

        if lo == 0 { return (positions[0].x, positions[0].y) }
        if lo >= positions.count { return (positions.last!.x, positions.last!.y) }

        let a = positions[lo - 1]
        let b = positions[lo]
          guard (0...1).contains(a.x), (0...1).contains(a.y),
              (0...1).contains(b.x), (0...1).contains(b.y) else { return nil }
        let dt = b.timestamp - a.timestamp
        guard dt > 0.0001 else { return (a.x, a.y) }
        let t = (time - a.timestamp) / dt
        return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }

    // MARK: - Click-based Auto Zoom

    private static func generateFromClicks(
        recording: MouseDataRecorder.MouseRecording,
        paddingRatio: CGFloat,
        contentScale: CGFloat,
        settings: Settings
    ) -> [CameraKeyframe] {
        // Filter left-click-down events that are inside the capture area.
        // Clicks outside the bounds (e.g. on another monitor, menubar, dock)
        // have normalized coords outside 0-1 and would zoom to a wrong spot.
        let clicks = recording.clicks.filter {
            $0.button == 0 && $0.isDown
            && $0.x >= 0 && $0.x <= 1
            && $0.y >= 0 && $0.y <= 1
        }.sorted { $0.timestamp < $1.timestamp }
        guard !clicks.isEmpty else {
            Log.generator.info("No in-bounds clicks found — returning identity keyframes")
            return [CameraKeyframe(time: 0, transform: .identity)]
        }

        var keyframes = [CameraKeyframe(time: 0, transform: .identity, easing: .linear)]
        var target = CameraTransform.identity
        var movementEnd: TimeInterval = 0
        var holdEnd: TimeInterval = 0
        var previousClickTime: TimeInterval = -.greatestFiniteMagnitude
        var lastRetargetTime: TimeInterval = -.greatestFiniteMagnitude

        for click in clicks {
            let clickTime = max(0, click.timestamp)
            let clickTarget = CameraTransform(
                zoom: settings.zoomLevel,
                centerX: paddingRatio + CGFloat(click.x) * contentScale,
                centerY: paddingRatio + (1.0 - CGFloat(click.y)) * contentScale
            ).clamped()
            let distance = hypot(clickTarget.centerX - target.centerX, clickTarget.centerY - target.centerY)
            let deadZone = min(settings.mergeDistance, 0.3 / max(1, settings.zoomLevel))
            let retarget = distance > deadZone
                && (clickTime - lastRetargetTime >= settings.minimumInterval || distance > settings.mergeDistance)
            let returningToFullFrame = clickTime >= holdEnd

            if returningToFullFrame || retarget {
                let previousZoomOutEnd = keyframes.last?.time ?? 0
                let anticipate = clickTime >= previousZoomOutEnd
                    && clickTime - previousClickTime >= settings.idleThreshold
                let start = anticipate
                    ? max(previousZoomOutEnd, clickTime - settings.zoomInDuration * 0.3)
                    : clickTime
                let current = FrameEvaluator(keyframes: keyframes).evaluate(at: start)
                if retarget || current.zoom <= 1.0001 {
                    target = clickTarget
                }
                let duration = current.zoom < settings.zoomLevel - 0.0001
                    ? settings.zoomInDuration : settings.panDuration
                appendClickTransition(to: &keyframes, at: start, target: target, duration: duration)
                movementEnd = start + max(0, duration)
                lastRetargetTime = clickTime
            }

            let holdStart = max(clickTime, movementEnd)
            keyframes.removeAll { $0.time > holdStart }
            holdEnd = max(holdStart, clickTime + settings.holdDuration)
            keyframes.append(CameraKeyframe(time: holdEnd, transform: target, easing: .linear))
            appendClickTransition(to: &keyframes, at: holdEnd, target: .identity, duration: settings.zoomOutDuration)
            previousClickTime = clickTime
        }

        keyframes = deduplicateByTime(keyframes)
        Log.generator.info("Generated \(keyframes.count) keyframes from \(clicks.count) clicks")
        return keyframes
    }

    private static func appendClickTransition(
        to keyframes: inout [CameraKeyframe],
        at start: TimeInterval,
        target: CameraTransform,
        duration: TimeInterval
    ) {
        let current = FrameEvaluator(keyframes: keyframes).evaluate(at: start)
        keyframes.removeAll { $0.time >= start }
        guard duration > 0 else {
            keyframes.append(CameraKeyframe(time: start, transform: target, easing: .linear))
            return
        }
        keyframes.append(CameraKeyframe(time: start, transform: current, easing: .linear))
        let steps = max(1, Int(ceil(duration * 60)))
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            keyframes.append(CameraKeyframe(
                time: start + duration * Double(progress),
                transform: current.lerp(to: target, t: EasingCurve.easeInOut.evaluate(progress)),
                easing: .linear
            ))
        }
    }

    /// Remove keyframes at the same time, keeping the last one.
    private static func deduplicateByTime(_ keyframes: [CameraKeyframe]) -> [CameraKeyframe] {
        guard keyframes.count > 1 else { return keyframes }
        var result: [CameraKeyframe] = [keyframes[0]]
        for i in 1..<keyframes.count {
            if abs(keyframes[i].time - result[result.count - 1].time) < 0.001 {
                result[result.count - 1] = keyframes[i]
            } else {
                result.append(keyframes[i])
            }
        }
        return result
    }
}
