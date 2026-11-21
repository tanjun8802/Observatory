import SwiftUI

enum BoardTheme: String, CaseIterable, Codable {
    case evergreen = "Evergreen", midnight = "Midnight", paper = "Paper"

    case console = "Console", coral = "Coral", terrazzo = "Terrazzo", tide = "Tide"

    var scheme: ColorScheme {
        switch self {
        case .paper, .coral, .terrazzo: return .light
        case .evergreen, .midnight, .console, .tide: return .dark
        }
    }

    var palette: BoardPalette {
        switch self {
        case .evergreen:
            return BoardPalette(background: 0x131616, rail: 0x161918, surface: 0x1B1E1D, raised: 0x242826,
                                text: 0xEDF0E6, secondary: 0xA3B0A6, accent: 0xB0E8C4, coral: 0xFDA187)
        case .midnight:
            return BoardPalette(background: 0x121421, rail: 0x191C2D, surface: 0x20253A, raised: 0x303750,
                                text: 0xF0F1FF, secondary: 0xB3BAD3, accent: 0xB9B5FF, coral: 0xF6B384)
        case .console:
            return BoardPalette(background: 0x101316, rail: 0x161A1E, surface: 0x202529, raised: 0x30383E,
                                text: 0xF5F2E9, secondary: 0xB1B8BC, accent: 0xEDC05C, coral: 0xFF9F88,
                                figureFace: .monospaced, corner: 7)
        case .coral:
            return BoardPalette(background: 0xF6E9E3, rail: 0xEBD9D1, surface: 0xFFF9F5, raised: 0xF3E4DC,
                                text: 0x32221F, secondary: 0x70564F, accent: 0xAA4234, coral: 0x8F322B,
                                figureFace: .rounded, corner: 12)
        case .terrazzo:
            return BoardPalette(background: 0xE9E8DF, rail: 0xDCDDD0, surface: 0xF9F9F1, raised: 0xEAEBDD,
                                text: 0x262921, secondary: 0x56604E, accent: 0x85401D, coral: 0x94372F,
                                figureFace: .default, corner: 3)
        case .tide:
            return BoardPalette(background: 0x08232A, rail: 0x0C2D34, surface: 0x123942, raised: 0x214C55,
                                text: 0xEDFCF8, secondary: 0xADCECB, accent: 0x82DBD4, coral: 0xFFB69A,
                                figureFace: .serif, corner: 10)
        case .paper:
            return BoardPalette(background: 0xF8F4EB, rail: 0xECE7DA, surface: 0xFFFCF6, raised: 0xEEE7D9,
                                text: 0x312E29, secondary: 0x686157, accent: 0x21644F, coral: 0x9A442B)
        }
    }
}

struct BoardPalette {
    let background, rail, surface, raised, text, secondary, accent, coral: Color
    let figureFace: Font.Design
    let corner: CGFloat
    var rule: Color { text.opacity(0.16) }

    init(background: Int, rail: Int, surface: Int, raised: Int, text: Int, secondary: Int, accent: Int, coral: Int,
         figureFace: Font.Design = .rounded, corner: CGFloat = 14) {
        self.figureFace = figureFace
        self.corner = corner
        func rgb(_ hex: Int) -> Color {
            Color(red: Double(hex >> 16) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
        }
        self.background = rgb(background)
        self.rail = rgb(rail)
        self.surface = rgb(surface)
        self.raised = rgb(raised)
        self.text = rgb(text)
        self.secondary = rgb(secondary)
        self.accent = rgb(accent)
        self.coral = rgb(coral)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = BoardTheme.evergreen.palette
}

extension EnvironmentValues {
    var boardPalette: BoardPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

struct ThemeChoice: View {
    let theme: BoardTheme

    var body: some View {
        Label {
            Text(theme.rawValue)
        } icon: {
            Image(nsImage: NSImage(size: NSSize(width: 24, height: 14), flipped: false) { bounds in
                let ink = theme.palette
                let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                outline.addClip()
                NSColor(ink.surface).setFill()
                bounds.fill()
                NSColor(ink.accent).setFill()
                CGRect(x: 14, y: 0, width: 10, height: 14).fill()
                NSColor(ink.secondary).setStroke()
                outline.stroke()
                return true
            })
        }
    }
}
