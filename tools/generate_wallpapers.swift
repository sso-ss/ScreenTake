import AppKit

struct Glow {
    let color: [Double]
    let centerX: Double
    let centerY: Double
    let radiusX: Double
    let radiusY: Double
    let opacity: Double
}

struct Wallpaper {
    let name: String
    let colors: [[Double]]
}

let wallpapers = [
    Wallpaper(name: "Prism", colors: [[235, 118, 127], [255, 224, 166], [24, 124, 177], [35, 231, 217]]),
    Wallpaper(name: "Lagoon", colors: [[62, 148, 148], [215, 238, 177], [25, 107, 175], [68, 226, 191]]),
    Wallpaper(name: "Ember", colors: [[203, 79, 109], [255, 216, 153], [126, 64, 111], [242, 139, 150]]),
    Wallpaper(name: "Midnight", colors: [[88, 107, 175], [160, 192, 224], [31, 89, 153], [52, 202, 210]])
]
let width = 2560
let height = 1536
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Screen/Assets.xcassets", isDirectory: true)
var rendered: [NSImage] = []

for wallpaper in wallpapers {
    let glows = [
        Glow(color: wallpaper.colors[0], centerX: 0.14, centerY: 0.52, radiusX: 0.24, radiusY: 0.18, opacity: 1.08),
        Glow(color: wallpaper.colors[1], centerX: -0.08, centerY: 0.86, radiusX: 0.22, radiusY: 0.34, opacity: 1.12),
        Glow(color: wallpaper.colors[2], centerX: 1.06, centerY: 0.86, radiusX: 0.32, radiusY: 0.30, opacity: 0.92),
        Glow(color: wallpaper.colors[3], centerX: 0.60, centerY: 1.06, radiusX: 0.35, radiusY: 0.30, opacity: 1.08)
    ]
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: width * 4, bitsPerPixel: 32)!
    let pixels = bitmap.bitmapData!
    for row in 0..<height {
        let vertical = Double(row) / Double(height - 1)
        for column in 0..<width {
            let horizontal = Double(column) / Double(width - 1)
            var color = [18.0, 18.0, 20.0]
            for glow in glows {
                let distanceX = (horizontal - glow.centerX) / glow.radiusX
                let distanceY = (vertical - glow.centerY) / glow.radiusY
                let amount = min(1, exp(-0.5 * (distanceX * distanceX + distanceY * distanceY)) * glow.opacity)
                for channel in 0..<3 {
                    color[channel] += (glow.color[channel] - color[channel]) * amount
                }
            }
            var hash = UInt32(row * width + column) &+ 0x9e3779b9
            hash = (hash ^ (hash >> 16)) &* 0x85ebca6b
            hash = (hash ^ (hash >> 13)) &* 0xc2b2ae35
            hash ^= hash >> 16
            let noise = (Double(hash & 0xffff) / 65535.0 - 0.5) * 16.0
            let offset = row * bitmap.bytesPerRow + column * 4
            for channel in 0..<3 {
                pixels[offset + channel] = UInt8(max(0, min(255, (color[channel] + noise).rounded())))
            }
            pixels[offset + 3] = 255
        }
    }
    let directory = output.appendingPathComponent("Wallpaper\(wallpaper.name).imageset", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("wallpaper.png"))
    let manifest: [String: Any] = [
        "images": [["filename": "wallpaper.png", "idiom": "universal"]],
        "info": ["author": "xcode", "version": 1]
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("Contents.json"))
    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(bitmap)
    rendered.append(image)
    precondition(pixels[0] < 35 && pixels[1] < 35 && pixels[2] < 35, "Top edge must stay dark")
    print("Generated \(wallpaper.name): \(width)x\(height), opaque, dark top verified")
}

let sheet = NSImage(size: NSSize(width: 1280, height: 840))
sheet.lockFocus()
NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 1280, height: 840).fill()
for (index, image) in rendered.enumerated() {
    let originX = CGFloat(index % 2) * 640
    let originY = CGFloat(1 - index / 2) * 420
    image.draw(in: NSRect(x: originX, y: originY + 36, width: 640, height: 384))
    (wallpapers[index].name as NSString).draw(at: NSPoint(x: originX + 16, y: originY + 10),
        withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white])
}
sheet.unlockFocus()
let sheetBitmap = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try sheetBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/screen-wallpapers-preview.png"))