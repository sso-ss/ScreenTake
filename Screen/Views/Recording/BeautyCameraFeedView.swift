import SwiftUI
import AVFoundation
import CoreImage

/// A latest-frame-only preview. Slow detection drops preview frames, never
/// queues work behind the recording writer or retains a backlog of camera data.
struct BeautyCameraFeedView: NSViewRepresentable {
    let recorder: WebcamRecorder
    let amount: Double
    var makeup: FaceMakeupSettings = .init()

    func makeNSView(context: Context) -> BeautyCameraNSView { BeautyCameraNSView() }
    func updateNSView(_ view: BeautyCameraNSView, context: Context) { view.configure(recorder: recorder, amount: amount, makeup: makeup) }
    static func dismantleNSView(_ view: BeautyCameraNSView, coordinator: ()) { view.stop() }
}

final class BeautyCameraNSView: NSView {
    private let imageLayer = CALayer()
    private var renderer: CameraBeautyPreviewRenderer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); imageLayer.frame = bounds
        updatePreviewSize()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updatePreviewSize() }
    private func updatePreviewSize() {
        let scale = window?.backingScaleFactor ?? 2
        renderer?.setDisplayPixelSize(CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }
    func configure(recorder: WebcamRecorder, amount: Double, makeup: FaceMakeupSettings = .init()) {
        if renderer == nil { renderer = CameraBeautyPreviewRenderer(layer: imageLayer) }
        renderer?.configure(recorder: recorder, amount: amount, makeup: makeup)
        updatePreviewSize()
    }
    func stop() { renderer?.stop(); renderer = nil }
}

final class CameraBeautyPreviewRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private weak var recorder: WebcamRecorder?
    private var amount = 0.0
    private var makeup = FaceMakeupSettings()
    private var active = true
    private var displayPixelSize = CGSize(width: 360, height: 360)
    private var pendingImage: CGImage?
    private var displayScheduled = false
    private var timer: DispatchSourceTimer?
    private weak var layer: CALayer?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var filter = FaceBeautyFilter()
    private var lastRecorder: ObjectIdentifier?
    private var lastTime: Double?
    private var lastAmount = -1.0
    private var lastRenderEdge: CGFloat = 0
    private var lastMakeup = FaceMakeupSettings()

    init(layer: CALayer) {
        self.layer = layer
        let queue = DispatchQueue(label: "com.screen.beauty-preview", qos: .userInitiated)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in autoreleasepool { self?.render() } }
        self.timer = timer
        timer.resume()
    }

    func configure(recorder: WebcamRecorder, amount: Double, makeup: FaceMakeupSettings = .init()) {
        lock.withLock { self.recorder = recorder; self.amount = FaceBeautyFilter.clamped(amount); self.makeup = makeup.clamped }
    }
    func setDisplayPixelSize(_ size: CGSize) {
        lock.withLock { displayPixelSize = size }
    }

    /// Keep enough source pixels for aspect-fill and Retina display, with a
    /// 640px floor for facial detail. Large previews retain the existing 960px
    /// budget; the raw recording and offline export are never resized here.
    static func renderLongEdge(source: CGSize, display: CGSize) -> CGFloat {
        guard source.width > 0, source.height > 0 else { return 640 }
        let scale = max(display.width / source.width, display.height / source.height)
        let required = max(source.width, source.height) * scale
        return min(960, max(640, ceil(required / 80) * 80))
    }

    func stop() {
        lock.withLock { active = false; recorder = nil; pendingImage = nil }
        timer?.cancel(); timer = nil
    }
    deinit { timer?.cancel() }

    private func render() {
        let (recorder, amount, makeup, active, displaySize) = lock.withLock { (self.recorder, self.amount, self.makeup, self.active, self.displayPixelSize) }
        guard active, let recorder, let frame = recorder.previewFrame else { return }
        if lastRecorder != ObjectIdentifier(recorder) { filter = FaceBeautyFilter(); lastTime = nil; lastRecorder = ObjectIdentifier(recorder) }
        let raw = CIImage(cvPixelBuffer: frame.buffer)
        let edge = Self.renderLongEdge(source: raw.extent.size, display: displaySize)
        guard lastTime != frame.time || lastAmount != amount || lastMakeup != makeup || lastRenderEdge != edge else { return }
        lastTime = frame.time; lastAmount = amount; lastMakeup = makeup; lastRenderEdge = edge
        let scale = min(1, edge / max(raw.extent.width, raw.extent.height))
        let image = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let result = filter.render(image, at: frame.time, amount: amount, makeup: makeup)
        guard let rendered = context.createCGImage(result, from: result.extent) else { return }
        let schedule = lock.withLock { () -> Bool in
            guard self.active else { return false }
            pendingImage = rendered
            guard !displayScheduled else { return false }
            displayScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let image = self.lock.withLock { () -> CGImage? in
                self.displayScheduled = false
                defer { self.pendingImage = nil }
                return self.active ? self.pendingImage : nil
            }
            guard let image else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.layer?.contents = image
            CATransaction.commit()
        }
    }
}
