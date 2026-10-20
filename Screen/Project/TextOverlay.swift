import Foundation

enum TextLetterCase: String, Codable, CaseIterable {
    case original = "Original", upper = "UPPERCASE", lower = "lowercase", title = "Title Case"
}

enum TextHorizontalAlignment: String, Codable, CaseIterable {
    case left = "Left", center = "Center", right = "Right"
    var icon: String { "text.align" + rawValue.lowercased() }
}

enum TextBackgroundStyle: String, Codable, CaseIterable {
    case block = "Block", lines = "Per Line"
}

enum TextStylePreset: String, CaseIterable {
    case clean = "Clean", title = "Title", caption = "Caption", outline = "Outline", highlight = "Highlight", label = "Label"

    func apply(to text: inout TextOverlay) {
        text.fontName = "System"
        text.bold = false; text.italic = false; text.underline = false
        text.color = "#FFFFFF"; text.strokeEnabled = false; text.strokeWidth = 3
        text.strokeColor = "#171717"; text.backgroundEnabled = false
        text.backgroundColor = "#171717"; text.backgroundOpacity = 0.8
        text.backgroundStyle = .block; text.backgroundRadius = 12
        text.paddingX = 24; text.paddingY = 14
        text.backgroundOffsetX = 0; text.backgroundOffsetY = 0
        switch self {
        case .clean: text.fontSize = 64
        case .title: text.fontSize = 96; text.bold = true
        case .caption:
            text.fontSize = 48; text.backgroundEnabled = true; text.backgroundStyle = .lines
        case .outline:
            text.fontSize = 80; text.bold = true; text.strokeEnabled = true; text.strokeWidth = 5
        case .highlight:
            text.fontSize = 64; text.bold = true; text.color = "#171717"
            text.backgroundEnabled = true; text.backgroundColor = "#F9DF70"; text.backgroundOpacity = 1
        case .label:
            text.fontSize = 48; text.bold = true; text.backgroundEnabled = true
            text.backgroundColor = "#6C5CE7"; text.backgroundOpacity = 1; text.backgroundRadius = 24
        }
    }
}

/// Sizes use a 1080-point canvas height; positions use top-left normalized canvas coordinates.
struct TextOverlay: Identifiable, Equatable, Codable {
    var id = UUID()
    var text = "Your text here"
    var start: Double = 0
    var duration: Double = 5
    var fontName = "System"
    var fontSize: Double = 64
    var bold = false
    var italic = false
    var underline = false
    var letterCase: TextLetterCase = .original
    var color = "#FFFFFF"
    var characterSpacing: Double = 0
    var lineSpacing: Double = 0
    var alignment: TextHorizontalAlignment = .center
    var boxWidth: Double = 0.8
    var scale: Double = 1
    var uniformScale = true
    var scaleY: Double = 1
    var x: Double = 0.5
    var y: Double = 0.5
    var rotation: Double = 0
    var opacity: Double = 1
    var strokeEnabled = false
    var strokeColor = "#171717"
    var strokeWidth: Double = 3
    var backgroundEnabled = false
    var backgroundStyle: TextBackgroundStyle = .block
    var backgroundColor = "#171717"
    var backgroundOpacity: Double = 0.8
    var backgroundRadius: Double = 12
    var paddingX: Double = 24
    var paddingY: Double = 14
    var backgroundOffsetX: Double = 0
    var backgroundOffsetY: Double = 0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, text, start, duration, fontName, fontSize, bold, italic, underline, letterCase, color
        case characterSpacing, lineSpacing, alignment, boxWidth, scale, uniformScale, scaleY, x, y, rotation, opacity
        case strokeEnabled, strokeColor, strokeWidth, backgroundEnabled, backgroundStyle, backgroundColor
        case backgroundOpacity, backgroundRadius, paddingX, paddingY, backgroundOffsetX, backgroundOffsetY
    }

    /// New tool-created layers may omit appearance fields; existing layers round-trip in full.
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        start = try values.decode(Double.self, forKey: .start)
        duration = try values.decode(Double.self, forKey: .duration)
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? bold
        italic = try values.decodeIfPresent(Bool.self, forKey: .italic) ?? italic
        underline = try values.decodeIfPresent(Bool.self, forKey: .underline) ?? underline
        letterCase = try values.decodeIfPresent(TextLetterCase.self, forKey: .letterCase) ?? letterCase
        color = try values.decodeIfPresent(String.self, forKey: .color) ?? color
        characterSpacing = try values.decodeIfPresent(Double.self, forKey: .characterSpacing) ?? characterSpacing
        lineSpacing = try values.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? lineSpacing
        alignment = try values.decodeIfPresent(TextHorizontalAlignment.self, forKey: .alignment) ?? alignment
        boxWidth = try values.decodeIfPresent(Double.self, forKey: .boxWidth) ?? boxWidth
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? scale
        uniformScale = try values.decodeIfPresent(Bool.self, forKey: .uniformScale) ?? uniformScale
        scaleY = try values.decodeIfPresent(Double.self, forKey: .scaleY) ?? scaleY
        x = try values.decodeIfPresent(Double.self, forKey: .x) ?? x
        y = try values.decodeIfPresent(Double.self, forKey: .y) ?? y
        rotation = try values.decodeIfPresent(Double.self, forKey: .rotation) ?? rotation
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        strokeEnabled = try values.decodeIfPresent(Bool.self, forKey: .strokeEnabled) ?? strokeEnabled
        strokeColor = try values.decodeIfPresent(String.self, forKey: .strokeColor) ?? strokeColor
        strokeWidth = try values.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? strokeWidth
        backgroundEnabled = try values.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) ?? backgroundEnabled
        backgroundStyle = try values.decodeIfPresent(TextBackgroundStyle.self, forKey: .backgroundStyle) ?? backgroundStyle
        backgroundColor = try values.decodeIfPresent(String.self, forKey: .backgroundColor) ?? backgroundColor
        backgroundOpacity = try values.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? backgroundOpacity
        backgroundRadius = try values.decodeIfPresent(Double.self, forKey: .backgroundRadius) ?? backgroundRadius
        paddingX = try values.decodeIfPresent(Double.self, forKey: .paddingX) ?? paddingX
        paddingY = try values.decodeIfPresent(Double.self, forKey: .paddingY) ?? paddingY
        backgroundOffsetX = try values.decodeIfPresent(Double.self, forKey: .backgroundOffsetX) ?? backgroundOffsetX
        backgroundOffsetY = try values.decodeIfPresent(Double.self, forKey: .backgroundOffsetY) ?? backgroundOffsetY
    }

    var end: Double { start + duration }
    var displayText: String {
        switch letterCase {
        case .original: return text
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return text.capitalized
        }
    }
    func isVisible(at time: Double) -> Bool { time.isFinite && time >= start && time < end && !text.isEmpty }

    func validate() throws {
        func number(_ value: Double, _ range: ClosedRange<Double>) -> Bool { value.isFinite && range.contains(value) }
        func color(_ value: String) -> Bool {
            value.count == 7 && value.first == "#" && UInt32(value.dropFirst(), radix: 16) != nil
        }
        guard text.count <= 10000, fontName.count <= 200,
              number(start, 0...86400), number(duration, 0.05...86400),
              number(fontSize, 8...240), number(characterSpacing, -10...50), number(lineSpacing, 0...100),
              number(boxWidth, 0.1...1), number(scale, 0.1...3), number(scaleY, 0.1...3),
              number(x, 0...1), number(y, 0...1), number(rotation, -180...180), number(opacity, 0...1),
              number(strokeWidth, 0...20), number(backgroundOpacity, 0...1), number(backgroundRadius, 0...100),
              number(paddingX, 0...200), number(paddingY, 0...200),
              number(backgroundOffsetX, -200...200), number(backgroundOffsetY, -200...200),
              color(self.color), color(strokeColor), color(backgroundColor) else {
            throw EditValidationError.invalid("Invalid text overlay settings.")
        }
    }
}
