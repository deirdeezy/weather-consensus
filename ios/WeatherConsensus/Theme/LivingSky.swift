import Foundation

/// Time of day for the living sky. Rule from the design canvas: dawn runs from 45 minutes before
/// sunrise to 1 hour after, dusk from 45 minutes before sunset to 1 hour after.
nonisolated enum SkyTime: String, CaseIterable, Sendable {
    case dawn, day, dusk, night

    static func at(_ now: Date, solar: SolarTimes) -> SkyTime {
        switch solar.kind {
        case .alwaysUp: return .day
        case .alwaysDown: return .night
        case let .normal(sunrise, sunset):
            let before: TimeInterval = 45 * 60
            let after: TimeInterval = 60 * 60
            if now >= sunrise - before && now < sunrise + after { return .dawn }
            if now >= sunrise + after && now < sunset - before { return .day }
            if now >= sunset - before && now < sunset + after { return .dusk }
            return .night
        }
    }

    static func at(_ now: Date, place: PlaceForecast.Place) -> SkyTime {
        let zone = place.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        return at(now, solar: SolarTimes(date: now, latitude: place.lat, longitude: place.lon, timeZone: zone))
    }
}

/// Weather for the living sky.
nonisolated enum SkyWeather: String, CaseIterable, Sendable {
    case clear, cloudy, rain, snow, storm, fog

    /// HOOK for the weather-driven sky (docs/BUILD_PLAN.md, Stage 3 step 3).
    /// Schema v1 has no condition field, so this returns nil and the sky follows the time of day only,
    /// with no sun, stars, clouds, rain or snow drawn (they would claim weather we do not know).
    /// When the published file gains a condition field (Stage 4, tested on history first),
    /// map it to a case here; `SkyView` already draws every case.
    static func from(_ forecast: PlaceForecast) -> SkyWeather? {
        nil
    }
}

/// Colours for one sky. Values are the canvas `Sky` component's table (v8).
nonisolated struct SkyStyle: Equatable, Sendable {
    let time: SkyTime
    /// nil: time of day only (no condition known).
    let weather: SkyWeather?
    /// Gradient stops at the top, at 170 pt and from 640 pt down.
    let top: RGB
    let middle: RGB
    let base: RGB
    let glow: RGB
    let glowOpacity: Double
    /// Glow centre: fraction of the width, and points from the top.
    let glowX: Double
    let glowY: Double

    static let middleStop: Double = 170
    static let baseStop: Double = 640

    init(time: SkyTime, weather: SkyWeather?) {
        self.time = time
        self.weather = weather
        let row = SkyStyle.table[time]![weather ?? .clear]!
        top = row.top
        middle = row.middle
        base = row.base
        glow = row.glow
        glowOpacity = row.glowOpacity
        glowX = row.glowX
        glowY = row.glowY
    }

    // MARK: Header ink (place name and gear sit on the sky)

    /// Header ink: white or navy, whichever keeps the most contrast across the whole top band
    /// (top to middle stop), where the header can sit in portrait or landscape.
    var headerInk: RGB {
        let band = topBand
        let white = band.map { Palette.white.contrast(with: $0) }.min()!
        let navy = band.map { Palette.ink.contrast(with: $0) }.min()!
        return white >= navy ? Palette.white : Palette.ink
    }

    /// Backdrop under the header ink: navy at 50% under white ink, white at 60% under navy ink.
    /// With it, every sky keeps at least 6:1 (checked in `LivingSkyTests`).
    var headerBackdrop: (color: RGB, opacity: Double) {
        headerInk == Palette.white ? (Palette.ink, 0.5) : (Palette.white, 0.6)
    }

    /// Worst-case contrast of the header ink on its backdrop over any colour in the top band.
    var headerContrast: Double {
        let backdrop = headerBackdrop
        return topBand.map { headerInk.contrast(with: backdrop.color.over($0, alpha: backdrop.opacity)) }.min()!
    }

    private var topBand: [RGB] {
        (0...20).map { top.mixed(with: middle, Double($0) / 20) }
    }

    /// The whole gradient, top to base, for checks.
    var allSkyColours: [RGB] {
        (0...20).map { top.mixed(with: middle, Double($0) / 20) } + (0...20).map { middle.mixed(with: base, Double($0) / 20) }
    }

    // MARK: Table

    private struct Row {
        let top: RGB, middle: RGB, base: RGB, glow: RGB
        let glowOpacity: Double, glowX: Double, glowY: Double
        init(_ top: UInt32, _ middle: UInt32, _ base: UInt32, glow: (UInt32, Double), at: (Double, Double)) {
            self.top = RGB(top)
            self.middle = RGB(middle)
            self.base = RGB(base)
            self.glow = RGB(glow.0)
            glowOpacity = glow.1
            glowX = at.0
            glowY = at.1
        }
    }

    private static let table: [SkyTime: [SkyWeather: Row]] = [
        .dawn: [
            .clear: Row(0x7FA6E6, 0xF6BFB0, 0xFFF3EA, glow: (0xFFC48C, 0.85), at: (0.14, 80)),
            .cloudy: Row(0x8899C9, 0xE3C3C8, 0xFBF1EE, glow: (0xFFCDAA, 0.55), at: (0.14, 80)),
            .rain: Row(0x5C8DB9, 0xBFD3DA, 0xF2F5F3, glow: (0xFFBEAA, 0.5), at: (0.14, 80)),
            .snow: Row(0xA0B3E8, 0xEFD2DE, 0xFCF7FB, glow: (0xFFD2BE, 0.6), at: (0.14, 80)),
            .storm: Row(0x4D4B9C, 0xC28CB4, 0xF7EBF0, glow: (0xFFB978, 0.7), at: (0.86, 70)),
            .fog: Row(0xC3C7DD, 0xF1DBD5, 0xFBF6F1, glow: (0xFFE1BE, 0.7), at: (0.5, 60)),
        ],
        .day: [
            .clear: Row(0x58A6F0, 0xA8D2F7, 0xEAF3FC, glow: (0xFFF0B4, 0.8), at: (0.67, 36)),
            .cloudy: Row(0x87A5D6, 0xC2D5EC, 0xEEF3F9, glow: (0xFFFFFF, 0.5), at: (0.67, 36)),
            .rain: Row(0x4E93B8, 0x9DCFD6, 0xE7F4F2, glow: (0xDCFAF5, 0.45), at: (0.67, 36)),
            .snow: Row(0x9AB6EC, 0xD8E3FA, 0xF6F8FF, glow: (0xFFFFFF, 0.7), at: (0.67, 36)),
            .storm: Row(0x4A4A9E, 0x8D7CC9, 0xF0EBFB, glow: (0xFFBE78, 0.65), at: (0.86, 70)),
            .fog: Row(0xB7C5DA, 0xE3E3EC, 0xF8F5F2, glow: (0xFFF5C8, 0.75), at: (0.6, 50)),
        ],
        .dusk: [
            .clear: Row(0x3E4FA6, 0xC27FB0, 0xFFE7D8, glow: (0xFFA56E, 0.85), at: (0.62, 90)),
            .cloudy: Row(0x46538F, 0xA98AB0, 0xF5E8E6, glow: (0xFFAA82, 0.55), at: (0.62, 90)),
            .rain: Row(0x2F5A7A, 0x719FAF, 0xE4F0EF, glow: (0xFFB48C, 0.45), at: (0.62, 90)),
            .snow: Row(0x4F5FA6, 0xBAA7D7, 0xF4F0FB, glow: (0xFFBEAA, 0.55), at: (0.62, 90)),
            .storm: Row(0x2D2A6E, 0x7A5AA6, 0xEEE5F6, glow: (0xFFAA64, 0.7), at: (0.86, 70)),
            .fog: Row(0x6E7396, 0xCFB9C5, 0xF7EFEC, glow: (0xFFBE96, 0.6), at: (0.6, 70)),
        ],
        .night: [
            .clear: Row(0x060E28, 0x11245C, 0x0D193D, glow: (0xAAC3FF, 0.35), at: (0.66, 40)),
            .cloudy: Row(0x0D1633, 0x1F2D57, 0x111C3F, glow: (0x96AAE6, 0.22), at: (0.66, 40)),
            .rain: Row(0x091D31, 0x174458, 0x0C2135, glow: (0x78DCE6, 0.18), at: (0.66, 40)),
            .snow: Row(0x131A44, 0x2B3A7B, 0x10183F, glow: (0xC8D7FF, 0.3), at: (0.66, 40)),
            .storm: Row(0x110C31, 0x2E1F62, 0x110E34, glow: (0xFFA05A, 0.35), at: (0.86, 70)),
            .fog: Row(0x1A2040, 0x353D66, 0x141A38, glow: (0xD2D7F0, 0.22), at: (0.6, 50)),
        ],
    ]
}
