import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: DMGBackground.swift output.png")
}

let canvasSize = NSSize(width: 600, height: 340)
let image = NSImage(size: canvasSize)
image.lockFocus()

NSColor(calibratedRed: 0.97, green: 0.965, blue: 0.98, alpha: 1).setFill()
NSRect(origin: .zero, size: canvasSize).fill()

let centeredParagraph = NSMutableParagraphStyle()
centeredParagraph.alignment = .center

let title = NSAttributedString(
    string: "Install ScreenTake",
    attributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.08, alpha: 1),
        .paragraphStyle: centeredParagraph,
    ]
)
title.draw(in: NSRect(x: 0, y: 270, width: canvasSize.width, height: 34))

let subtitle = NSAttributedString(
    string: "Drag ScreenTake to Applications",
    attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1),
        .paragraphStyle: centeredParagraph,
    ]
)
subtitle.draw(in: NSRect(x: 0, y: 244, width: canvasSize.width, height: 24))

let arrow = NSBezierPath()
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 273, y: 135))
arrow.line(to: NSPoint(x: 327, y: 135))
arrow.move(to: NSPoint(x: 315, y: 147))
arrow.line(to: NSPoint(x: 327, y: 135))
arrow.line(to: NSPoint(x: 315, y: 123))
NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
arrow.stroke()

image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render DMG background")
}

try pngData.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)