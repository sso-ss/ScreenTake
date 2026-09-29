import AppKit

// Run from the repository root. The website SVG is the source of truth.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("website/assets/mark.svg")
let assets = root.appendingPathComponent("Screen/Assets.xcassets")
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
let brandSet = assets.appendingPathComponent("BrandMark.imageset")
let files = FileManager.default

guard let mark = NSImage(contentsOf: source) else {
    fatalError("Could not load \(source.path)")
}

func writeJSON(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

try files.createDirectory(at: iconSet, withIntermediateDirectories: true)
try files.createDirectory(at: brandSet, withIntermediateDirectories: true)
try Data(contentsOf: source).write(to: brandSet.appendingPathComponent("mark.svg"), options: .atomic)
try writeJSON([
    "images": [["filename": "mark.svg", "idiom": "universal"]],
    "info": ["author": "xcode", "version": 1],
    "properties": ["preserves-vector-representation": true]
], to: brandSet.appendingPathComponent("Contents.json"))

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Could not create \(pixels)px drawing context")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        mark.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                  from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode \(filename)")
        }
        try png.write(to: iconSet.appendingPathComponent(filename), options: .atomic)
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
try writeJSON([
    "images": images,
    "info": ["author": "xcode", "version": 1]
], to: iconSet.appendingPathComponent("Contents.json"))
print("Updated the Mac app icon and welcome screen logo from website/assets/mark.svg.")
