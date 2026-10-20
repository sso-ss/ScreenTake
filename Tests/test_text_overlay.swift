import AppKit
import AVFoundation
import CoreImage
import SwiftUI

@main
struct TextOverlayChecks {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("text-overlay-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let size = CGSize(width: 480, height: 270)
        let bounds = CGRect(origin: .zero, size: size)
        let context = CIContext()
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds)
        var text = TextOverlay()
        text.text = "ScreenTake\n한글 Text"
        text.fontSize = 100; text.color = "#FFFF00"
        text.start = 0.3; text.duration = 0.6
        var settings = VideoEditSettings(backgroundEnabled: false, showCursor: false)
        settings.textOverlays = [text]
        try settings.validate(duration: 2)
        let restored = try JSONDecoder().decode(VideoEditSettings.self, from: JSONEncoder().encode(settings))
        precondition(restored == settings)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        old.removeValue(forKey: "textOverlays")
        let legacy = try JSONDecoder().decode(VideoEditSettings.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(legacy.textOverlays == nil)
        let sequential = (0..<100).map { index -> TextOverlay in
            var clip = TextOverlay(); clip.start = Double(index) * 0.1; clip.duration = 0.1
            return clip
        }
        precondition(TextTimelineLayout(overlays: Array(sequential.reversed()), duration: 10).rows.count == 1,
                     "Sequential text clips must reuse one row, including touching decimal time boundaries")
        var stacked = Array(sequential.prefix(4))
        for index in stacked.indices { stacked[index].start = Double(index) * 0.25; stacked[index].duration = 1 }
        let packed = TextTimelineLayout(overlays: stacked, duration: 2)
        precondition(packed.rows.count == 4 && Set(packed.rows.flatMap { $0 }.map(\.id)) == Set(stacked.map(\.id)))
        stacked[3].start = 1.5
        precondition(TextTimelineLayout(overlays: stacked, duration: 3).rows.count == 3,
                     "Moving a clip out of an overlap should reclaim the extra row")
        precondition(TextTimelineLayout(overlays: sequential, duration: 0).rows.isEmpty)
        precondition(TextTimelineLayout(overlays: sequential, duration: 0.5).rows[0].count == 5)
        print("PASS: 100 sequential titles reuse one row; overlaps pack and reclaim rows without changing layer order")
        var invalid = text; invalid.rotation = .nan
        do { try invalid.validate(); preconditionFailure("NaN text settings accepted") } catch is EditValidationError {}
        var duplicate = settings; duplicate.textOverlays = [text, text]
        do { try duplicate.validate(duration: 2); preconditionFailure("Duplicate text IDs accepted") } catch is EditValidationError {}
        print("PASS: text persistence, legacy migration, and invalid settings")

        func pixels(_ image: CIImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 480 * 270 * 4)
            context.render(image, toBitmap: &data, rowBytes: 480 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return data
        }
        func yellowPixels(_ image: CIImage) -> Int {
            let data = pixels(image)
            return stride(from: 0, to: data.count, by: 4).filter { data[$0] > 150 && data[$0 + 1] > 150 && data[$0 + 2] < 120 }.count
        }
        func yellowBounds(_ image: CIImage) -> CGRect {
            let data = pixels(image)
            var result = CGRect.null
            for index in stride(from: 0, to: data.count, by: 4) where data[index] > 150 && data[index + 1] > 150 && data[index + 2] < 120 {
                result = result.union(CGRect(x: index / 4 % 480, y: index / 4 / 480, width: 1, height: 1))
            }
            return result
        }
        let renderer = LiveEditFrameRenderer(sourceSize: size, settings: settings, keyframes: [])
        precondition(yellowPixels(renderer.render(blue, at: 0.1)) == 0)
        let reference = renderer.render(blue, at: 0.5)
        let referenceCount = yellowPixels(reference)
        precondition(referenceCount > 300, "Multiline text should render at the center")
        precondition(yellowPixels(renderer.render(blue, at: 1)) == 0)
        precondition(yellowPixels(renderer.render(blue, at: 1.5, outputTime: 0.5)) == referenceCount,
                     "Text must follow edited time independently of source time")
        try context.writePNGRepresentation(of: reference, to: URL(fileURLWithPath: "/tmp/screentake-text-preview.png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var transparent = text; transparent.opacity = 0
        precondition(yellowPixels(TextOverlayRenderer(overlays: [transparent], size: size).composite(over: blue, at: 0.5)) == 0)
        for preset in TextStylePreset.allCases {
            var layer = text; preset.apply(to: &layer)
            layer.rotation = 15; layer.scale = 1.2; layer.uniformScale = false; layer.scaleY = 0.8
            layer.characterSpacing = 2; layer.lineSpacing = 10; layer.italic = true; layer.underline = true
            try layer.validate()
            let rendered = TextOverlayRenderer(overlays: [layer], size: size).composite(over: blue, at: 0.5)
            precondition(pixels(rendered) != pixels(blue), "Preset \(preset) must render")
        }
        print("PASS: Unicode text, timing, opacity, presets, and independent scale/rotation")

        let source = directory.appendingPathComponent("source.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 480, AVVideoHeightKey: 270])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input); precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, 480, 270, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
            context.render(blue, to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        await writer.finishWriting(); precondition(writer.status == .completed)

        let session = EditorSession()
        try await session.openVideo(source)
        session.draft = settings
        session.undo(); precondition(session.draft.textOverlays == nil)
        session.redo(); precondition(session.draft.textOverlays == [text])
        let package = directory.appendingPathComponent("Text.screentake")
        try await session.saveProject(to: package)
        let saved = try await EditorProjectStore.load(from: package)
        precondition(saved.settings.textOverlays == [text])
        await session.waitForPreview()
        let preview = session.player!.currentItem!
        let previewGenerator = AVAssetImageGenerator(asset: preview.asset)
        previewGenerator.videoComposition = preview.videoComposition
        previewGenerator.requestedTimeToleranceBefore = .zero; previewGenerator.requestedTimeToleranceAfter = .zero
        let previewImage = try previewGenerator.copyCGImage(at: EditorAudio.time(0.5), actualTime: nil)
        precondition(yellowPixels(CIImage(cgImage: previewImage)) > 300)
        let exported = try await session.applyChanges()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for (time, visible) in [(0.1, false), (0.5, true), (1.2, false)] {
            let image = CIImage(cgImage: try generator.copyCGImage(at: EditorAudio.time(time), actualTime: nil))
            let count = yellowPixels(image)
            // Chroma subsampling changes small colored glyph edges; compare coverage and placement.
            precondition(visible ? count > referenceCount / 2 : count == 0,
                         "Preview/export text coverage must agree at \(time): \(count) vs \(referenceCount)")
            if visible {
                let actual = yellowBounds(image), expected = yellowBounds(reference)
                precondition(abs(actual.minX - expected.minX) < 3 && abs(actual.minY - expected.minY) < 3
                             && abs(actual.maxX - expected.maxX) < 3 && abs(actual.maxY - expected.maxY) < 3)
            }
        }
        print("PASS: live preview, actual exported text timing/pixels, Undo/Redo, and portable project save")

        // Reorder the source and leave a gap: overlays must remain in edited time, including black gaps.
        settings.trim.clips = [MediaTimelineClip(start: 0, sourceStart: 1, duration: 0.4),
                               MediaTimelineClip(start: 1, sourceStart: 0, duration: 0.8)]
        text.start = 0.5; text.duration = 0.4; settings.textOverlays = [text]
        session.draft = settings
        await session.waitForPreview()
        let gapPreview = session.player!.currentItem!
        let gapGenerator = AVAssetImageGenerator(asset: gapPreview.asset)
        gapGenerator.videoComposition = gapPreview.videoComposition
        let gapImage = try gapGenerator.copyCGImage(at: EditorAudio.time(0.7), actualTime: nil)
        precondition(yellowPixels(CIImage(cgImage: gapImage)) > 300)
        let gapExport = try await session.applyChanges()
        let gapExportGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: gapExport))
        gapExportGenerator.requestedTimeToleranceBefore = .zero
        gapExportGenerator.requestedTimeToleranceAfter = .zero
        let gapExportImage = try gapExportGenerator.copyCGImage(at: EditorAudio.time(0.7), actualTime: nil)
        precondition(yellowPixels(CIImage(cgImage: gapExportImage)) > 300)
        print("PASS: text remains visible over gaps after reordering, in preview and export")
        session.selectedTextID = text.id
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let host = NSHostingView(rootView: TextEditorPanel(session: session)
                .padding(16).frame(width: 300).background(DesignColors.controlBackground))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 2150)
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/screentake-text-panel-\(name).png"))
        }
        let timelineHost = NSHostingView(rootView: VideoTrimControls(trim: .constant(settings.trim),
            zoomSegments: .constant([ZoomSegment(start: 0, end: 1.5, zoom: 2, centerX: 0.5, centerY: 0.5)]),
            zoomEnabled: true, duration: 2, player: session.player!, source: source, session: session))
        timelineHost.frame = NSRect(x: 0, y: 0, width: 850, height: 240)
        timelineHost.layoutSubtreeIfNeeded()
        let timelineBitmap = timelineHost.bitmapImageRepForCachingDisplay(in: timelineHost.bounds)!
        timelineHost.cacheDisplay(in: timelineHost.bounds, to: timelineBitmap)
        try timelineBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/screentake-text-timeline.png"))
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        var compactHeight = 0.0
        for dark in [false, true] {
            for crowded in [false, true] {
                let layers = (0..<(crowded ? 20 : 12)).map { index -> TextOverlay in
                    var clip = TextOverlay(); clip.text = "Title \(index + 1)"
                    clip.start = crowded ? 0 : Double(index) * 0.12; clip.duration = crowded ? 1.5 : 0.1
                    return clip
                }
                session.draft.textOverlays = layers
                session.selectedTextID = layers.first?.id
                let hosted = NSHostingView(rootView: VideoTrimControls(trim: .constant(settings.trim),
                    zoomSegments: .constant([ZoomSegment(start: 0, end: 1.5, zoom: 2, centerX: 0.5, centerY: 0.5)]),
                    zoomEnabled: true, duration: 2, player: session.player!, source: source, session: session)
                    .frame(width: 850).environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 850, height: 800),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosted
                window.orderBack(nil)
                hosted.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosted.frame = NSRect(x: 0, y: 0, width: 850, height: 800)
                hosted.layoutSubtreeIfNeeded()
                window.setContentSize(CGSize(width: 850, height: hosted.fittingSize.height))
                hosted.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 100_000_000)
                hosted.layoutSubtreeIfNeeded()
                precondition(hosted.frame.height <= 304.1, "Timeline must stop growing when tracks overflow")
                if !crowded { compactHeight = hosted.frame.height }
                let scroll = scrollViews(in: hosted).max(by: { $0.frame.width < $1.frame.width })!
                print("Timeline \(crowded ? "overflow" : "packed"): host=\(hosted.frame), viewport=\(scroll.contentView.bounds), document=\(scroll.documentView!.frame)")
                precondition(scroll.contentView.bounds.height <= TimelineMetrics.maximumTrackHeight + 1)
                if crowded {
                    precondition(hosted.frame.height > compactHeight)
                    let document = scroll.documentView!
                    precondition(document.frame.height > scroll.contentView.bounds.height + 300)
                    scroll.contentView.scroll(to: CGPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    precondition(scroll.contentView.bounds.minY > 300, "Overflowing rows must remain reachable by scrolling")
                }
                let bitmap = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds)!
                hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
                    "/tmp/screentake-text-timeline-\(crowded ? "overflow" : "packed")-\(dark ? "dark" : "light").png"))
                window.orderOut(nil)
            }
        }
        print("PASS: shared text track in light/dark; timeline height stays capped and all overflow rows scroll into view")
        session.close()
        print("PASS: rendered Text panel in light/dark and Text strip below Auto Zoom")
    }
}
