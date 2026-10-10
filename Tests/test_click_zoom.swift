import Foundation

@main
struct ClickZoomTest {
    static func recording(_ clicks: [(Double, Double)]) -> MouseDataRecorder.MouseRecording {
        MouseDataRecorder.MouseRecording(
            positions: [],
            clicks: clicks.map {
                .init(timestamp: $0.0, x: $0.1, y: 0.5, button: 0, isDown: true)
            },
            keys: [], scrolls: [], zoomMarkers: [],
            screenBounds: .init(from: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            scaleFactor: 1, sampleInterval: 1.0 / 60
        )
    }

    static func frames(_ clicks: [(Double, Double)]) -> [CameraKeyframe] {
        let result = ClickZoomGenerator.generate(from: recording(clicks))
        for (left, right) in zip(result, result.dropFirst()) {
            precondition(right.time > left.time, "Animation timestamps must increase")
        }
        return result
    }

    static func expect(_ actual: CGFloat, _ expected: CGFloat, _ label: String) {
        precondition(abs(actual - expected) < 0.0001, "\(label): expected \(expected), got \(actual)")
    }

    static func expectSameHistory(_ clicks: [(Double, Double)]) {
        let previous = FrameEvaluator(keyframes: frames(Array(clicks.dropLast())))
        let updated = FrameEvaluator(keyframes: frames(clicks))
        let interruption = clicks.last!.0
        for time in stride(from: 0.0, through: interruption, by: 0.007) {
            let original = previous.evaluate(at: time)
            let current = updated.evaluate(at: time)
            expect(current.zoom, original.zoom, "A new click must preserve earlier zoom")
            expect(current.centerX, original.centerX, "A new click must preserve earlier pan")
        }
        expect(updated.evaluate(at: interruption).zoom, previous.evaluate(at: interruption).zoom, "No zoom jump at interruption")
        expect(updated.evaluate(at: interruption).centerX, previous.evaluate(at: interruption).centerX, "No pan jump at interruption")
    }

    static func main() {
        let empty = frames([])
        precondition(empty.count == 1 && empty[0].transform == .identity)
        let single = FrameEvaluator(keyframes: frames([(1, 0.4)]))
        expect(single.evaluate(at: 0.82).zoom, 1, "Single click starts unzoomed")
        expect(single.evaluate(at: 1.42).zoom, 2, "Single click zoom duration")
        expect(single.evaluate(at: 3).centerX, 0.4, "Single click hold")
        expect(single.evaluate(at: 3.8).zoom, 1, "Single click zoom out")

        let continuous = FrameEvaluator(keyframes: frames([(1, 0.25), (2, 0.75)]))
        for time in stride(from: 1.42, through: 4.0, by: 0.01) {
            expect(continuous.evaluate(at: time).zoom, 2, "A follow-up click must not restart zoom")
        }

        let doubleClick = FrameEvaluator(keyframes: frames([(1, 0.4), (1.1, 0.6)]))
        expect(doubleClick.evaluate(at: 1.42).centerX, 0.4, "Double click avoids rapid nearby retarget")
        expect(doubleClick.evaluate(at: 3.1).zoom, 2, "Double click extends hold")
        expect(doubleClick.evaluate(at: 3.9).zoom, 1, "Double click final zoom out")

        let nearby = FrameEvaluator(keyframes: frames([(1, 0.4), (2, 0.45)]))
        expect(nearby.evaluate(at: 4).centerX, 0.4, "Nearby click keeps camera still")
        expect(nearby.evaluate(at: 4).zoom, 2, "Nearby click extends hold")

        let quick = FrameEvaluator(keyframes: frames([(1, 0.4), (1.31, 0.6)]))
        expectSameHistory([(1, 0.4), (1.31, 0.6)])
        var previous = quick.evaluate(at: 1.31).centerX
        for time in stride(from: 1.32, through: 3.31, by: 0.01) {
            let current = quick.evaluate(at: time).centerX
            precondition(current >= previous - 0.0001, "Quick clicks reversed the pan")
            previous = current
        }
        expect(quick.evaluate(at: 1.91).centerX, 0.6, "Quick click reaches new target")

        let separate = FrameEvaluator(keyframes: frames([(1, 0.25), (2, 0.75)]))
        let firstOnly = FrameEvaluator(keyframes: frames([(1, 0.25)]))
        precondition(separate.evaluate(at: 1.82) == firstOnly.evaluate(at: 1.82), "New cluster jumps at start")
        for time in stride(from: 2.42, through: 4.0, by: 0.01) {
            expect(separate.evaluate(at: time).centerX, 0.75, "Old cluster must not move the camera")
            expect(separate.evaluate(at: time).zoom, 2, "Old cluster must not zoom out")
        }
        expect(separate.evaluate(at: 4.8).zoom, 1, "Final cluster zoom out")

        let rapidPans = FrameEvaluator(keyframes: frames([(1, 0.3), (1.6, 0.5), (1.91, 0.7)]))
        previous = rapidPans.evaluate(at: 1.42).centerX
        for time in stride(from: 1.43, through: 3.91, by: 0.01) {
            let current = rapidPans.evaluate(at: time).centerX
            precondition(current >= previous - 0.0001, "Overlapping pans reversed direction")
            previous = current
        }
        expectSameHistory([(1, 0.3), (1.6, 0.5), (1.91, 0.7)])

        let alternatingClicks = [(1.0, 0.25), (2.0, 0.75), (2.15, 0.25), (2.28, 0.75)]
        for count in 2...alternatingClicks.count {
            expectSameHistory(Array(alternatingClicks.prefix(count)))
        }
        let alternating = FrameEvaluator(keyframes: frames(alternatingClicks))
        for time in stride(from: 1.42, through: 4.28, by: 0.01) {
            expect(alternating.evaluate(at: time).zoom, 2, "Alternating targets must stay zoomed")
        }
        expect(alternating.evaluate(at: 2.68).centerX, 0.75, "Rapid clicks retain latest distant target")
        expect(alternating.evaluate(at: 5.08).zoom, 1, "Alternating clicks finish with one zoom out")

        expectSameHistory([(1, 0.25), (3.4, 0.75)])
        let interruptedOut = FrameEvaluator(keyframes: frames([(1, 0.25), (3.4, 0.75)]))
        previous = interruptedOut.evaluate(at: 3.4).zoom
        for time in stride(from: 3.41, through: 5.4, by: 0.01) {
            let current = interruptedOut.evaluate(at: time).zoom
            precondition(current >= previous - 0.0001, "New click must cancel unfinished zoom out")
            previous = current
        }
        expect(interruptedOut.evaluate(at: 4).zoom, 2, "Interrupted zoom out returns to full zoom")
        expect(interruptedOut.evaluate(at: 4).centerX, 0.75, "Interrupted zoom out reaches latest target")
        expect(interruptedOut.evaluate(at: 6.2).zoom, 1, "Interrupted zoom out ends after new hold")

        let spaced = FrameEvaluator(keyframes: frames([(1, 0.25), (6, 0.75)]))
        expect(spaced.evaluate(at: 4).zoom, 1, "Separated clusters retain idle time")
        expect(spaced.evaluate(at: 6.42).centerX, 0.75, "Separated cluster target")
        testPointerFollowing()
        testEditableZooms()
        print("PASS: single, double, nearby, rapid, alternating, interrupted, separated, and pointer-following zooms")
    }

    static func testEditableZooms() {
        let blocks = ClickZoomGenerator.editableSegments(from: recording([(1, 0.25), (6, 0.75)]),
                                 duration: 10, zoomLevel: 2)
        precondition(blocks.count == 2, "Separated automatic zooms should produce two editable blocks")
        precondition(blocks[0].start < blocks[0].end && blocks[0].end < blocks[1].start)
        precondition(abs(blocks[1].centerX - 0.75) < 0.001, "Automatic block focus")
        let retargets = ClickZoomGenerator.editableSegments(from: recording([(1, 0.25), (2, 0.75)]),
                                    duration: 6, zoomLevel: 2)
        precondition(retargets.count == 2 && retargets[0].end == retargets[1].start,
                 "Each distant click must remain an editable target")
        let retargetCamera = FrameEvaluator(keyframes: ClickZoomGenerator.generate(segments: retargets))
        expect(retargetCamera.evaluate(at: 1.6).centerX, 0.25, "First edited click target")
        expect(retargetCamera.evaluate(at: 2.6).centerX, 0.75, "Second edited click target")

        let motion = stride(from: 0.0, through: 4.0, by: 1.0 / 60).map { time in
            MouseDataRecorder.MousePosition(timestamp: time, x: time < 2 ? 0.25 : 0.9, y: 0.5, velocity: 0)
        }
        let fixed = ZoomSegment(start: 1, end: 3, zoom: 2, centerX: 0.25, centerY: 0.5, followsCursor: false)
        let fixedCamera = FrameEvaluator(keyframes: ClickZoomGenerator.generate(segments: [fixed], positions: motion))
        expect(fixedCamera.evaluate(at: 1).zoom, 1, "Edited zoom starts at source time")
        expect(fixedCamera.evaluate(at: 1.6).zoom, 2, "Edited zoom reaches selected magnification")
        let globalCamera = FrameEvaluator(keyframes: ClickZoomGenerator.generate(segments: [fixed], zoomLevel: 3))
        expect(globalCamera.evaluate(at: 1.6).zoom, 3, "Global magnification overrides an edited block's saved value")
        expect(fixedCamera.evaluate(at: 2.8).centerX, 0.25, "Manual focus remains fixed")
         let fixedWithoutPointer = FrameEvaluator(keyframes: ClickZoomGenerator.generate(segments: [fixed]))
         expect(fixedCamera.evaluate(at: 3.1).centerX, fixedWithoutPointer.evaluate(at: 3.1).centerX,
             "Manual focus zoom-out must ignore the moving pointer")
        expect(fixedCamera.evaluate(at: 3.8).zoom, 1, "Edited zoom ends")
        var following = fixed
        following.followsCursor = true
        let trackingCamera = FrameEvaluator(keyframes: ClickZoomGenerator.generate(segments: [following], positions: motion))
        precondition(trackingCamera.evaluate(at: 2.8).centerX > 0.35, "Follow Cursor should track movement")
        let removed = ClickZoomGenerator.generate(segments: [], positions: motion)
        precondition(removed.count == 1 && removed[0].transform == .identity, "Removing every block must disable zoom")
    }

    static func testPointerFollowing() {
        func following(_ position: (Double) -> (Double, Double), padding: CGFloat = 0,
                   markers: [MouseDataRecorder.ZoomEvent] = []) -> FrameEvaluator {
            let original = recording([(1, 0.4)])
            let positions = stride(from: 0.0, through: 4.0, by: 1.0 / 60).map { time in
                let point = position(time)
                return MouseDataRecorder.MousePosition(timestamp: time, x: point.0, y: point.1, velocity: 0)
            }
            let recording = MouseDataRecorder.MouseRecording(
                positions: positions, clicks: original.clicks, keys: [], scrolls: [], zoomMarkers: markers,
                screenBounds: original.screenBounds, scaleFactor: 1, sampleInterval: 1.0 / 60
            )
            let keyframes = ClickZoomGenerator.generate(from: recording, paddingRatio: padding)
            for (left, right) in zip(keyframes, keyframes.dropFirst()) {
                precondition(right.time > left.time, "Following timestamps must increase")
            }
            return FrameEvaluator(keyframes: keyframes)
        }
        let baseline = FrameEvaluator(keyframes: frames([(1, 0.4)]))
        let quiet = following { time in (0.4 + sin(time * 20) * 0.01, 0.5) }
        for time in stride(from: 1.42, through: 3.0, by: 0.01) {
            expect(quiet.evaluate(at: time).centerX, 0.4, "Small pointer movements must not shake camera")
        }
        func path(_ time: Double) -> (Double, Double) {
            let progress = min(1, max(0, (time - 1.5) / 1.2))
            return (0.4 + progress * 0.59, 0.5 - progress * 0.49)
        }
        for padding: CGFloat in [0, 0.08] {
            let moving = following(path, padding: padding)
            var previous = moving.evaluate(at: 1.5)
            for time in stride(from: 1.5, through: 3.8, by: 1.0 / 60) {
                let camera = moving.evaluate(at: time)
                let pointer = path(time)
                let pointerX = padding + CGFloat(pointer.0) * (1 - 2 * padding)
                let pointerY = padding + (1 - CGFloat(pointer.1)) * (1 - 2 * padding)
                let halfViewport = 0.5 / camera.zoom
                expect(camera.zoom, baseline.evaluate(at: time).zoom, "Following must preserve zoom timing")
                precondition(abs(pointerX - camera.centerX) <= halfViewport + 0.001, "Pointer escaped horizontal crop")
                precondition(abs(pointerY - camera.centerY) <= halfViewport + 0.001, "Pointer escaped vertical crop")
                expect(camera.centerX, camera.clamped().centerX, "Camera must stay within horizontal screen bounds")
                expect(camera.centerY, camera.clamped().centerY, "Camera must stay within vertical screen bounds")
                precondition(abs(camera.centerX - previous.centerX) < 0.035, "Following pan jumped")
                previous = camera
            }
            precondition(moving.evaluate(at: 2.8).centerX > 0.65, "Camera must follow without another click")
            precondition(moving.evaluate(at: 3.8) == .identity, "Zoom out must restore the full frame")
        }
        let outside = following { time in time < 1.5 ? (0.4, 0.5) : (1.5, -0.4) }
        expect(outside.evaluate(at: 2.5).centerX, 0.4, "Ignore pointer on another monitor")
        let zoomIn = MouseDataRecorder.ZoomEvent(timestamp: 1, x: 0.4, y: 0.5, isZoomIn: true)
        let zoomOut = MouseDataRecorder.ZoomEvent(timestamp: 3, x: 0.99, y: 0.01, isZoomIn: false)
        let manual = following(path, markers: [zoomIn, zoomOut])
        for time in stride(from: 1.6, through: 3.0, by: 1.0 / 60) {
            let camera = manual.evaluate(at: time)
            let pointer = path(time)
            expect(camera.zoom, 2, "Manual follow must keep zoom fixed")
            precondition(abs(pointer.0 - camera.centerX) <= 0.251, "Manual pointer escaped horizontal crop")
            precondition(abs(1 - pointer.1 - camera.centerY) <= 0.251, "Manual pointer escaped vertical crop")
        }
        precondition(manual.evaluate(at: 3.8) == .identity, "Manual zoom restores full frame")
        let openEnded = following(path, markers: [zoomIn])
        expect(openEnded.evaluate(at: 4).zoom, 2, "Unpaired manual zoom stays active")
        precondition(openEnded.evaluate(at: 4).centerX > 0.7, "Unpaired manual zoom follows through recording end")
        let quickToggle = following(path, markers: [zoomIn, .init(timestamp: 1.2, x: 0.4, y: 0.5, isZoomIn: false)])
        expect(quickToggle.evaluate(at: 2).zoom, 1, "Fast manual toggle must finish zoom out")
    }
}