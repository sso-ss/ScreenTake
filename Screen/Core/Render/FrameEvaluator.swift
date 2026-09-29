import Foundation
import CoreGraphics

/// Evaluates camera state at any point in time by interpolating between keyframes.
///
/// Given a sorted array of CameraKeyframes, this evaluator performs binary search
/// to find the surrounding keyframes and interpolates using the easing curve.
struct FrameEvaluator {

    /// Sorted keyframes defining the camera animation.
    let keyframes: [CameraKeyframe]

    init(keyframes: [CameraKeyframe]) {
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    /// Evaluate the camera transform at a given time.
    ///
    /// - Before the first keyframe: returns the first keyframe's transform.
    /// - After the last keyframe: returns the last keyframe's transform.
    /// - Between keyframes: interpolates using the left keyframe's easing curve.
    func evaluate(at time: TimeInterval) -> CameraTransform {
        guard !keyframes.isEmpty else { return .identity }
        guard keyframes.count > 1 else { return keyframes[0].transform }

        // Before first keyframe
        if time <= keyframes[0].time {
            return keyframes[0].transform
        }

        // After last keyframe
        if time >= keyframes[keyframes.count - 1].time {
            return keyframes[keyframes.count - 1].transform
        }

        // Binary search for the interval containing `time`
        let index = binarySearch(for: time)
        let left = keyframes[index]
        let right = keyframes[index + 1]

        let span = right.time - left.time
        guard span > 0.001 else { return right.transform }

        let linearProgress = CGFloat((time - left.time) / span)
        let easedProgress = left.easing.evaluate(linearProgress)

        return left.transform.lerp(to: right.transform, t: easedProgress)
    }

    /// Find the index of the keyframe just before or at `time`.
    /// Returns an index such that keyframes[index].time <= time < keyframes[index+1].time.
    private func binarySearch(for time: TimeInterval) -> Int {
        var lo = 0
        var hi = keyframes.count - 2
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if keyframes[mid].time <= time {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }
}
