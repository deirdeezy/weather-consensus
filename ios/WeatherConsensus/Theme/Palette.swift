import SwiftUI

/// An sRGB colour as hex, so the same value can drive SwiftUI and the contrast checks in tests.
nonisolated struct RGB: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// Straight line between two colours in sRGB, as a gradient draws it.
    func mixed(with other: RGB, _ amount: Double) -> RGB {
        RGB(red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount)
    }

    /// `self` at `alpha` opacity laid over `background`.
    func over(_ background: RGB, alpha: Double) -> RGB {
        background.mixed(with: self, alpha)
    }

    /// WCAG 2.x relative luminance.
    var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG 2.x contrast ratio, 1 to 21.
    func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Colours from the design canvas (v8).
nonisolated enum Palette {
    // Cards
    static let card = RGB(0x18386B)          // navy card
    static let cardInner = RGB(0x10294F)     // inset panels, ring badge
    static let rowOpen = RGB(0x1E4378)       // expanded day row
    static let detail = RGB(0x22497F)        // detail panel inside an open row
    static let ink = RGB(0x0F2A52)           // navy text on light skies
    static let white = RGB(0xFFFFFF)
    static let textSecondary = RGB(0xC3D3EA) // labels on navy
    static let textBody = RGB(0xDCE7F6)      // body copy on navy
    static let link = RGB(0x8CC8FF)          // links, chance of precipitation
    static let rain = RGB(0x8CC8FF)
    /// Consensus tab hero panel: canvas rgba(9,26,54,0.5) over the navy card.
    static let heroPanel = RGB(0x091A36).over(card, alpha: 0.5)

    // Certainty tiers (canvas dot colours)
    static let tierHigh = RGB(0x3DD68C)
    static let tierMedium = RGB(0xFFC531)
    static let tierLow = RGB(0xFF8A5B)

    /// Tier names written in the tier colour. Low uses a lighter orange so the word keeps 4.5:1
    /// on an open (lighter navy) row; the canvas orange stays for the ring and dots (graphics need 3:1).
    static let tierLowText = RGB(0xFFA07A)

    static func tierText(_ tier: CertaintyTier?) -> RGB {
        tier == .low ? tierLowText : self.tier(tier)
    }

    /// Tier pill in the opened day (canvas breakdown sheet): light fill, dark ink.
    static func tierPill(_ tier: CertaintyTier?) -> (fill: RGB, ink: RGB) {
        switch tier {
        case .high: (RGB(0xE3F6EC), RGB(0x155F39))
        case .medium: (RGB(0xFFF3CC), RGB(0x6B4A00))
        case .low: (RGB(0xFFE8DC), RGB(0x8A3510))
        case nil: (RGB(0xEEF3FA), ink)
        }
    }

    static func tier(_ tier: CertaintyTier?) -> RGB {
        switch tier {
        case .high: tierHigh
        case .medium: tierMedium
        case .low: tierLow
        case nil: textSecondary
        }
    }

    /// Source bar colours, chosen by source `id` (docs/JSON_SCHEMA.md). Colours follow the canvas.
    static let sourceColors: [String: RGB] = [
        "gem_seamless": RGB(0xFF5A5F),          // Environment Canada
        "ecmwf_ifs": RGB(0x4C8DFF),
        "ukmo_seamless": RGB(0x3DD68C),
        "icon_seamless": RGB(0xFFC531),
        "ecmwf_aifs025_single": RGB(0x9B7BFF),
        "gfs_seamless": RGB(0x2EC4B6),
        "jma_seamless": RGB(0xFF8AC8),
        "cma_grapes_global": RGB(0xFF9F45),
        "meteofrance_seamless": RGB(0x8FA3BF),
        "normal": RGB(0xB8C4D4),
        // Ensembles: stored and scored, no weight yet (CLAUDE.md). Colours ready for when they join.
        "ecmwf_ifs025_ensemble": RGB(0x9CC2FF),
        "ncep_gefs05": RGB(0x8FE3D9),
        "gem_global_ensemble": RGB(0xFFA3A6),
    ]

    /// Extra colours for a source id the app does not know yet; picked by a stable hash of the id.
    private static let spare: [RGB] = [RGB(0xE7A6FF), RGB(0xA6E36F), RGB(0xFFD08A), RGB(0x7FD3FF)]

    static func source(_ id: String) -> RGB {
        if let known = sourceColors[id] { return known }
        let hash = id.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return spare[Int(hash % UInt32(spare.count))]
    }
}

extension Color {
    init(_ rgb: RGB) { self = rgb.color }
}
