import AppKit

// Run from the repository root after tools/render_brand_assets.cjs.
// PNG masters preserve SVG overlap shadows that CoreSVG does not render.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let symbolSource = root.appendingPathComponent("website/assets/mark.png")
let iconSource = root.appendingPathComponent("website/assets/app-icon.png")
let assets = root.appendingPathComponent("Screen/Assets.xcassets")
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
let brandSet = assets.appendingPathComponent("BrandMark.imageset")
let files = FileManager.default

guard let mark = NSImage(contentsOf: symbolSource),
      let icon = NSImage(contentsOf: iconSource) else {
    fatalError("Missing brand PNG masters. Run tools/render_brand_assets.cjs first.")
}

func writeJSON(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
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
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(url.lastPathComponent)")
    }
    try png.write(to: url, options: .atomic)
}

try files.createDirectory(at: iconSet, withIntermediateDirectories: true)
try files.createDirectory(at: brandSet, withIntermediateDirectories: true)
var brandImages: [[String: String]] = []
for scale in [1, 2, 3] {
    let filename = "mark\(scale == 1 ? "" : "@\(scale)x").png"
    try writePNG(mark, pixels: 128 * scale, to: brandSet.appendingPathComponent(filename))
    brandImages.append(["filename": filename, "idiom": "universal", "scale": "\(scale)x"])
}
try writeJSON([
    "images": brandImages,
    "info": ["author": "xcode", "version": 1]
], to: brandSet.appendingPathComponent("Contents.json"))
let oldSVG = brandSet.appendingPathComponent("mark.svg")
if files.fileExists(atPath: oldSVG.path) { try files.removeItem(at: oldSVG) }

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try writePNG(icon, pixels: pixels, to: iconSet.appendingPathComponent(filename))
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
try writeJSON([
    "images": images,
    "info": ["author": "xcode", "version": 1]
], to: iconSet.appendingPathComponent("Contents.json"))
print("Updated the Mac app icon and native brand images from the rendered website masters.")
