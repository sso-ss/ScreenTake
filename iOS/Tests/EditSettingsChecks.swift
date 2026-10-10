import Foundation

@main
struct EditSettingsChecks {
    static func main() {
        var settings = EditSettings()
        settings.trimEnd = 10
        settings.trimStart = 20
        settings.constrain(to: 10)
        precondition(abs(settings.trimmedDuration - 0.1) < 0.0001)
        settings.trimStart = -2
        settings.trimEnd = 30
        settings.constrain(to: 10)
        precondition(settings.trimStart == 0 && settings.trimEnd == 10)
        settings.constrain(to: 0.04)
        precondition(settings.trimmedDuration == 0.04)
        settings = EditSettings()
        settings.zoomEnabled = true
        settings.zoomStart = 2
        settings.zoomEnd = 4
        precondition(settings.zoom(at: 1) == 1)
        precondition(settings.zoom(at: 2) == 1)
        precondition(settings.zoom(at: 3) == settings.zoomAmount)
        precondition(settings.zoom(at: 4) == 1)
        precondition(settings.zoom(at: 2.1) > 1 && settings.zoom(at: 2.1) < settings.zoomAmount)
        precondition(abs(settings.zoom(at: 2.1) - settings.zoom(at: 3.9)) < 0.0001)
        let source = CGSize(width: 1179, height: 2556)
        let original = CanvasFormat.original.size(for: source)
        precondition(original.height == 1920 && Int(original.width) % 2 == 0)
        for format in CanvasFormat.allCases {
            let canvas = format.size(for: source)
            let rect = settings.videoRect(source: source, canvas: canvas)
            precondition(rect.minX >= 0 && rect.minY >= 0)
            precondition(rect.maxX <= canvas.width && rect.maxY <= canvas.height)
            precondition(abs(rect.width / rect.height - source.width / source.height) < 0.0001)
        }
        let data = try! JSONEncoder().encode(settings)
        precondition(try! JSONDecoder().decode(EditSettings.self, from: data) == settings)
        print("PASS: trim bounds, short clips, zoom easing, aspect ratios, framing, settings round trip")
    }
}