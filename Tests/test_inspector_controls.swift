import AppKit
import AVFoundation
import CoreImage
import SwiftUI

@main
struct InspectorControlChecks {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-controls-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = VideoEditSettings()
        var makeup = FaceMakeupSettings(); makeup.lips = 0.27; makeup.blush = 0.83
        settings.faceMakeup = makeup
        let peach = CameraEffectSelection(style: .peachMakeup, intensity: 0.72)
        settings.setCameraEffect(peach, enabled: true)
        precondition(settings.faceBeautyAmount == 0 && settings.faceMakeup?.amount == 0.72)
        settings.setCameraEffect(peach, enabled: false)
        precondition(!settings.cameraEffectsEnabled && settings.resolvedCameraEffectSelection == peach)
        settings.setCameraEffect(settings.resolvedCameraEffectSelection, enabled: true)
        precondition(settings.faceMakeup?.amount == 0.72)
        settings.setCameraEffect(.init(style: .natural, intensity: 0.4), enabled: true)
        precondition(settings.faceBeautyAmount == 0.4 && settings.faceMakeup?.amount == 0)
        precondition(settings.faceMakeup?.lips == 0.27 && settings.faceMakeup?.blush == 0.83)
        let encoded = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(VideoEditSettings.self, from: encoded)
        precondition(restored == settings)
        var legacyJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyJSON.removeValue(forKey: "cameraEffectSelection")
        let legacy = try JSONDecoder().decode(VideoEditSettings.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        precondition(legacy.resolvedCameraEffectSelection.style == .natural)
        settings.cameraEffectSelection?.intensity = .nan
        do { try settings.validate(duration: 1); preconditionFailure("Invalid preference accepted") } catch is EditValidationError {}
        print("PASS: exclusive camera styles, remembered intensity, customization, Codable and legacy projects")

        // Standalone checks preserve any preferences belonging to their executable domain.
        let keys = ["captureZoomEnabled", "autoZoomEnabled", "cameraEffectSelection", "faceBeautyAmount", "faceMakeupSettings"]
        let defaults = UserDefaults.standard
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for key in keys { if let value = previous[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let capture = CaptureSettings()
        capture.zoomEnabled = true; capture.autoZoomEnabled = true
        capture.zoomEnabled = false
        precondition(capture.autoZoomEnabled)
        capture.zoomEnabled = true
        precondition(capture.autoZoomEnabled)
        capture.autoZoomEnabled = false
        precondition(capture.zoomEnabled)
        capture.setCameraEffect(peach, enabled: true)
        capture.setCameraEffect(peach, enabled: false)
        precondition(!capture.cameraEffectsEnabled && capture.cameraEffectSelection == peach)
        capture.setCameraEffect(capture.cameraEffectSelection, enabled: true)
        precondition(capture.faceBeautyAmount == 0 && capture.faceMakeup.amount == 0.72)
        print("PASS: independent Zoom / Auto Zoom preferences and capture effect persistence")

        func host<V: View>(_ view: V) -> NSHostingView<V> {
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 300, height: 700)
            host.layoutSubtreeIfNeeded()
            return host
        }
        let collapsed = host(CameraEffectsControls(isOn: .constant(false), selection: .constant(peach), makeup: .constant(makeup)))
        let expanded = host(CameraEffectsControls(isOn: .constant(false), selection: .constant(peach), makeup: .constant(makeup), initiallyExpanded: true))
        precondition(collapsed.fittingSize.height < 60 && expanded.fittingSize.height > 150)
        for dark in [false, true] {
            for (name, enabled, selection, expanded) in [("off-collapsed", false, peach, false),
                ("off-expanded", false, peach, true), ("natural", true, CameraEffectSelection(), true), ("peach", true, peach, true)] {
                let view = CameraEffectsControls(isOn: .constant(enabled), selection: .constant(selection),
                    makeup: .constant(makeup), initiallyExpanded: expanded)
                    .padding(16).frame(width: 300).background(DesignColors.controlBackground)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let hosted = host(view)
                hosted.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosted.frame.size.height = hosted.fittingSize.height
                hosted.layoutSubtreeIfNeeded()
                let bitmap = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds)!
                hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/screentake-camera-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        print("PASS: OFF sections start collapsed; rendered enabled/disabled camera effects in light/dark")

        let source = directory.appendingPathComponent("source.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 480, AVVideoHeightKey: 270])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input); precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, 480, 270, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
            context.render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 480, height: 270)), to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        await writer.finishWriting(); precondition(writer.status == .completed)
        let recording = RecordingState(), navigation = NavigationState()
        recording.configure(captureSettings: capture, navigationState: navigation)
        for (master, automatic, expected) in [(true, true, true), (false, true, false), (true, false, false)] {
            capture.zoomEnabled = master; capture.autoZoomEnabled = automatic
            recording.acceptCompletedRecording(RecordingResult(videoURL: source))
            precondition(recording.initialEdits.zoomEnabled == expected)
            precondition(capture.autoZoomEnabled == automatic)
        }
        print("PASS: recording Zoom master gates automatic zoom without changing Auto Zoom preference")
        let session = EditorSession()
        try await session.openVideo(source)
        var text = TextOverlay(); text.text = "Drag 한글\nText"; text.duration = 1
        text.rotation = 30; text.scale = 1.3; text.uniformScale = false; text.scaleY = 0.8
        session.draft.backgroundEnabled = false
        session.draft.textOverlays = [text]
        await session.waitForPreview()
        let view = TextCanvasSelectionView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.session = session; view.canvasSize = CGSize(width: 480, height: 270); view.time = 0.5
        view.updateLayers([text])
        let geometry = TextCanvasGeometry(bounds: view.bounds, canvas: view.canvasSize)
        precondition(geometry.viewport == CGRect(x: 0, y: 75, width: 800, height: 450))
        let center = geometry.center(of: text)
        precondition(view.text(at: center)?.id == text.id)
        precondition(view.text(at: CGPoint(x: 400, y: 10)) == nil)
        var later = text; later.id = UUID(); later.start = 0.8
        view.updateLayers([text, later]); precondition(view.text(at: center)?.id == text.id)
        later.start = 0; view.updateLayers([text, later]); precondition(view.text(at: center)?.id == later.id)
        view.updateLayers([text])
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let undoCount = session.undoEdits.count
        view.mouseDown(with: event(.leftMouseDown, at: center))
        precondition(session.selectedTextID == text.id)
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: center.x + 80, y: center.y - 45)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: center.x + 160, y: center.y - 90)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: center.x + 160, y: center.y - 90)))
        precondition(abs(session.draft.textOverlays![0].x - 0.7) < 0.000001)
        precondition(abs(session.draft.textOverlays![0].y - 0.3) < 0.000001)
        precondition(session.undoEdits.count == undoCount + 1)
        session.undo(); precondition(session.draft.textOverlays == [text])
        session.redo(); precondition(abs(session.draft.textOverlays![0].x - 0.7) < 0.000001)
        let edge = geometry.position(from: .init(x: 0.5, y: 0.5), translation: .init(width: -10000, height: 10000))
        precondition(edge == CGPoint(x: 0, y: 1))
        view.time = 2; precondition(view.text(at: center) == nil)
        session.close(); window.orderOut(nil)
        print("PASS: real mouse selection/drag, rotated multilines, letterboxing, layer order, timing, bounds and one-step Undo/Redo")
    }
}
