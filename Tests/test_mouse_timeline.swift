import AppKit
import CoreMedia

@main
struct MouseTimelineTest {
    @MainActor
    static func main() {
        let recorder = MouseDataRecorder()
        precondition(MouseDataRecorder.appKitPosition(from: CGPoint(x: 200, y: 300), primaryDisplayHeight: 1440) == CGPoint(x: 200, y: 1140))
        precondition(MouseDataRecorder.appKitPosition(from: CGPoint(x: -800, y: -200), primaryDisplayHeight: 1440) == CGPoint(x: -800, y: 1640))
        precondition(MouseDataRecorder.appKitPosition(from: CGPoint(x: 3600, y: 1600), primaryDisplayHeight: 1440) == CGPoint(x: 3600, y: -160))
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        func time(_ seconds: Double) -> CMTime {
            CMTime(seconds: seconds, preferredTimescale: 60_000)
        }
        func expect(_ seconds: Double, at hostTime: Double) {
            let actual = recorder.recordingTime(at: time(hostTime))
            precondition(abs(actual - seconds) < 0.0001, "Expected \(seconds), got \(actual)")
        }
        recorder.startRecording(screenBounds: bounds, startTime: time(100))
        expect(0, at: 99)
        expect(2, at: 102)
        recorder.pause(at: time(102))
        recorder.pause(at: time(103))
        expect(2, at: 106)
        recorder.resume(at: time(107))
        recorder.resume(at: time(108))
        expect(3, at: 108)
        recorder.pause(at: time(109))
        recorder.resume(at: time(112))
        expect(5, at: 113)
        _ = recorder.stopRecording()
        recorder.startRecording(screenBounds: bounds, startTime: time(200))
        expect(1, at: 201)
        _ = recorder.stopRecording()
        print("PASS: mouse timestamps share the video origin, exclude pauses, and reset for new recordings")
        recorder.startRecording(screenBounds: bounds)
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.35)
        recorder.pause()
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.15)
        recorder.resume()
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.35)
        let sampled = recorder.stopRecording()
        precondition(sampled.positions.count >= 30, "UI work blocked pointer sampling: only \(sampled.positions.count) samples")
        let gaps = zip(sampled.positions, sampled.positions.dropFirst()).map { $1.timestamp - $0.timestamp }
        precondition(gaps.allSatisfy { $0 > 0 && $0 < 0.05 }, "Sampling stalled or included paused time")
        precondition(sampled.positions.last!.timestamp < 0.75, "Pointer samples included paused time")
        print("PASS: \(sampled.positions.count) pointer samples while main thread blocked, maximum gap \(gaps.max()!)s, pause excluded")
    }
}