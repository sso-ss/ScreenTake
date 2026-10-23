import SwiftUI
import AVFoundation

/// Edit the focus on the full canvas, then inspect the rendered result in place.
struct ZoomRegionEditor: View {
    let sourceURL: URL
    let sourceTime: CMTime
    let crop: PhoneCrop
    let layout: DeviceLayout
    let phoneMode: PhoneContentMode
    @Binding var region: ZoomRegion
    let player: AVPlayer
    let showsResult: Bool
    let onTogglePreview: () -> Void
    let onClose: () -> Void
    let onEditingChanged: (Bool) -> Void
    @State private var image: CGImage?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if showsResult {
                    NativeVideoPlayerView(player: player, showsControls: false)
                } else if let image {
                    ZoomRegionSelection(image: image, region: $region,
                                        viewport: ZoomRegion.viewport(sourceSize: CGSize(width: image.width, height: image.height),
                                                                      layout: layout, mode: phoneMode),
                                        onEditingChanged: onEditingChanged)
                } else if let error {
                    Text(LocalizedStringKey(error))
                        .font(Typography.caption)
                        .foregroundStyle(DesignColors.secondaryLabel)
                } else {
                    ProgressView()
                        .localizedAccessibilityLabel("Loading zoom preview")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: Spacing.md) {
                Spacer()
                Button(action: onTogglePreview) {
                    Label(showsResult ? "Select Area" : "Preview Zoom",
                          systemImage: showsResult ? "viewfinder" : "play.rectangle")
                }
                .buttonStyle(CompactActionButtonStyle())
                .accessibilityIdentifier("toggleZoomAreaPreview")
                Button("Done", action: onClose)
                    .buttonStyle(CompactActionButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("applyZoomArea")
            }
            .padding(Spacing.lg)
        }
        .background(DesignColors.previewBackground)
        .tint(DesignColors.accent)
        .onDisappear { onEditingChanged(false) }
        .task(id: sourceTime.seconds) {
            image = nil
            error = nil
            do {
                let asset = AVURLAsset(url: sourceURL)
                let duration = try await asset.load(.duration).seconds
                let seconds = sourceTime.seconds.isFinite ? sourceTime.seconds : 0
                let time = CMTime(seconds: min(max(0, duration - 1.0 / 600), max(0, seconds)), preferredTimescale: 60000)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1200, height: 1200)
                generator.requestedTimeToleranceBefore = .positiveInfinity
                generator.requestedTimeToleranceAfter = .zero
                let frame = try await generator.image(at: time).image
                try Task.checkCancellation()
                let rect = crop.normalized
                image = frame.cropping(to: CGRect(x: rect.minX * CGFloat(frame.width), y: rect.minY * CGFloat(frame.height),
                                                  width: rect.width * CGFloat(frame.width), height: rect.height * CGFloat(frame.height)))
                if image == nil { error = "Could not load this frame. Try another point in the video." }
            } catch is CancellationError {
            } catch {
                self.error = "Could not load this frame. Try another point in the video."
            }
        }
    }

}

/// Shown below Set Zoom Area while the full canvas remains available for editing.
struct ZoomRegionControls: View {
    @Binding var region: ZoomRegion
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                ForEach(Array([("Top", "align.vertical.top", CGFloat(0)),
                               ("Center", "align.vertical.center", CGFloat(0.5)),
                               ("Bottom", "align.vertical.bottom", CGFloat(1))].enumerated()), id: \.offset) { _, preset in
                    Button {
                        region = ZoomRegion(zoom: max(2, region.magnification), center: CGPoint(x: 0.5, y: preset.2))
                    } label: {
                        Image(systemName: preset.1)
                    }
                    .buttonStyle(CompactActionButtonStyle(iconOnly: true))
                    .localizedAccessibilityLabel(preset.0)
                    .hoverHelp(preset.0)
                    .accessibilityIdentifier("zoomArea\(preset.0)")
                }
            }
            HStack(spacing: Spacing.lg) {
                SliderValueControl(selection: Binding(get: { Double(region.magnification) }, set: { value in
                    let area = region.normalized.rect
                    region = ZoomRegion(zoom: value, center: CGPoint(x: area.midX, y: area.midY))
                }), range: 1...8, label: "Area magnification",
                           unit: "×", decimals: 2, onEditingChanged: onEditingChanged)
                .accessibilityIdentifier("zoomAreaMagnification")
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: 340, alignment: .leading)
        .background(DesignColors.controlBackground, in: RoundedRectangle(cornerRadius: CornerRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.lg).stroke(DesignColors.separator))
        .onDisappear { onEditingChanged(false) }
    }
}

struct ZoomRegionSelection: View {
    let image: CGImage
    @Binding var region: ZoomRegion
    var viewport = CGSize(width: 1, height: 1)
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragStart: ZoomRegion?

    var body: some View {
        GeometryReader { geometry in
            let fitted = CanvasGeometry.fit(CGSize(width: image.width, height: image.height),
                                            in: CGRect(origin: .zero, size: geometry.size).insetBy(dx: 10, dy: 10))
            let area = region.visibleRect(in: viewport)
            let selection = CGRect(x: area.minX * fitted.width, y: area.minY * fitted.height,
                                   width: area.width * fitted.width, height: area.height * fitted.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: fitted.width, height: fitted.height)
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: fitted.size))
                    path.addRect(selection)
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle().fill(.clear)
                    .contentShape(Rectangle())
                    .overlay(Rectangle().stroke(.white, lineWidth: 2))
                    .overlay {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .foregroundStyle(.white.opacity(0.8))
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .allowsHitTesting(false)
                    }
                    .frame(width: selection.width, height: selection.height)
                    .position(x: selection.midX, y: selection.midY)
                    .gesture(drag(size: fitted.size))
                    .localizedAccessibilityLabel("Selected zoom area")
                    .accessibilityIdentifier("zoomAreaSelection")
                    .hoverHelp("Drag to reposition the zoom area")
                ForEach(Array(PhoneCrop.Corner.allCases.enumerated()), id: \.offset) { _, corner in
                    let left = corner == .topLeft || corner == .bottomLeft
                    let top = corner == .topLeft || corner == .topRight
                    RoundedRectangle(cornerRadius: 2).fill(.white)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(DesignColors.accent, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .padding(6)
                        .contentShape(Rectangle())
                        .position(x: left ? selection.minX : selection.maxX, y: top ? selection.minY : selection.maxY)
                        .gesture(drag(size: fitted.size, corner: corner))
                        .localizedAccessibilityLabel("\(left ? "Left" : "Right") \(top ? "top" : "bottom") zoom handle")
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .position(x: fitted.midX, y: fitted.midY)
        }
    }

    private func drag(size: CGSize, corner: PhoneCrop.Corner? = nil) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                if dragStart == nil { onEditingChanged(true); dragStart = region }
                let start = dragStart ?? region
                let delta = CGSize(width: value.translation.width / size.width, height: value.translation.height / size.height)
                region = corner.map { start.resized(by: delta, corner: $0, viewport: viewport) } ?? start.moved(by: delta)
            }
            .onEnded { _ in dragStart = nil; onEditingChanged(false) }
    }
}
