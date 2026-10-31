import AppKit
import AVFoundation
import CoreImage

private struct PlaybackCheckError: Error { let message: String }
private func expectPlayback(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PlaybackCheckError(message: message) }
}

struct FaceEffectPlaybackChecks {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent(".build/soft-peach-integration/playback")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let package = ProcessInfo.processInfo.environment["SCREENTAKE_PLAYBACK_PROJECT"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(".build/soft-peach-integration/User Playback.screentake")
        let project = try await EditorProjectStore.load(from: package)
        guard let camera = project.settings.videoOverlayURL else { throw PlaybackCheckError(message: "Missing camera") }
        let frames = OverlayVideoFrames(url: camera, preciseTiming: true)
        let moment = CMTime(seconds: 5.7, preferredTimescale: 600)
        guard let sample = frames.frame(at: moment) else { throw PlaybackCheckError(message: "Missing sample") }
        let context = CIContext(options: [.cacheIntermediates: false])
        func pixels(_ image: CIImage) -> [UInt8] {
            let scaled = image.transformed(by: CGAffineTransform(scaleX: 320 / image.extent.width, y: 180 / image.extent.height))
            var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
            context.render(scaled, toBitmap: &bytes, rowBytes: 320 * 4, bounds: CGRect(x: 0, y: 0, width: 320, height: 180), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return bytes
        }
        func delta(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a,b).reduce(0) { $0 + abs(Int($1.0)-Int($1.1)) } }
        let session = EditorSession()
        try await session.openVideo(project.source)
        var draft = session.draft
        draft.webcamEnabled = true; draft.videoOverlayURL = camera
        draft.backgroundEnabled = false; draft.showCursor = false; draft.audioEnabled = false
        draft.cameraLayout = .init(layout: .fullScreen)
        session.draft = draft
        await session.waitForPreview()
        let initialItem = session.player!.currentItem!
        var stylePixels: [CameraEffectStyle: [UInt8]] = [:]
        // Same order as switching back from Soft Peach in the real inspector.
        let defaults = UserDefaults.standard
        let keys = ["faceMakeupSettings", "faceBeautyAmount", "cameraEffectSelection"]
        let old = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for key in keys { if let value = old[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let capture = CaptureSettings()
        for intensity in [1.0, 0.3] {
            for style in [CameraEffectStyle.softPeach, .natural] {
                let selection = CameraEffectSelection(style: style, intensity: intensity)
                capture.setCameraEffect(selection, enabled: true)
                var edited = session.draft
                edited.setCameraEffect(selection, enabled: true)
                session.draft = edited
                await session.waitForPreview()
                try expectPlayback(session.player!.currentItem === initialItem, "Style changes must keep the player item")
                try expectPlayback(capture.cameraEffectSelection == selection && session.draft.resolvedCameraEffectSelection == selection, "Capture/editor selection mismatch")
                try expectPlayback(capture.faceMakeup == session.draft.faceMakeup && capture.faceBeautyAmount == session.draft.faceBeautyAmount, "Capture/editor amounts mismatch")
                let generator = AVAssetImageGenerator(asset: initialItem.asset)
                generator.videoComposition = initialItem.videoComposition
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                let rendered = try await generator.image(at: moment).image
                let image = CIImage(cgImage: rendered)
                stylePixels[style] = pixels(image)
                try context.writePNGRepresentation(of: image, to: directory.appendingPathComponent("\(style.rawValue)-\(Int(intensity*100)).png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            for (a,b) in [(CameraEffectStyle.natural, CameraEffectStyle.softPeach)] {
                let difference = delta(stylePixels[a]!,stylePixels[b]!)
                print("Style delta \(Int(intensity*100))% \(a) / \(b): \(difference)")
                try expectPlayback(difference > 200, "Editor styles must render different pixels")
            }
        }
        try context.writePNGRepresentation(of: sample.image, to: directory.appendingPathComponent("original-camera.png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        print("PASS: capture preferences and real editor item switch Natural / Soft Peach without rebuilding the player")
        session.close()
        print("PASS: recorded-camera playback checks")
    }
}
