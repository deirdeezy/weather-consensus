import SwiftUI

// Condition words and icons (beta, 28 Nov 2026), from the design canvas `Main.dc.html`: sun, moon, sun and
// cloud, moon and cloud, cloud, rain, snow, rain and snow, in the canvas colours (sun #FFC531, moon #FFE08A,
// cloud #E3ECF7, drops #6FB8FF, flakes white). Drawn with SF Symbols in those colours, not the canvas's own
// paths, so they scale with Dynamic Type and stay crisp. No accuracy claim anywhere: conditions are a beta.

nonisolated enum ConditionText {
    /// The word for a day row and the opened day: "Sunny", "Sun and cloud", "Cloudy", "Rain", "Snow", "Rain and snow".
    static func day(_ c: WeatherCondition) -> String {
        switch c {
        case .clear: String(localized: "Sunny", comment: "Day condition: clear sky")
        case .partly: String(localized: "Sun and cloud", comment: "Day condition: partly cloudy")
        case .cloudy: String(localized: "Cloudy", comment: "Condition: cloudy")
        case .rain: String(localized: "Rain", comment: "Condition: rain")
        case .snow: String(localized: "Snow", comment: "Condition: snow")
        case .mixed: String(localized: "Rain and snow", comment: "Condition: rain and snow mixed")
        }
    }

    /// The word for a moment (now, one hour): at night "Clear" and "Partly cloudy" instead of sun words.
    static func moment(_ c: WeatherCondition, night: Bool) -> String {
        switch c {
        case .clear: night ? String(localized: "Clear", comment: "Condition at night: clear sky") : day(.clear)
        case .partly: night ? String(localized: "Partly cloudy", comment: "Condition at night: partly cloudy") : day(.partly)
        default: day(c)
        }
    }

    /// Precipitation falling now, measured: "Raining", "Snowing", "Rain and snow".
    static func now(_ c: WeatherCondition, night: Bool) -> String {
        switch c {
        case .rain: String(localized: "Raining", comment: "Now: rain is falling at the station")
        case .snow: String(localized: "Snowing", comment: "Now: snow is falling at the station")
        default: moment(c, night: night)
        }
    }
}

/// Day or night at the place, from the sun (SolarTimes): night before sunrise and after sunset.
nonisolated enum Daylight {
    static func isNight(_ date: Date, place: PlaceForecast.Place) -> Bool {
        let zone = place.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let sun = SolarTimes(date: date, latitude: place.lat, longitude: place.lon, timeZone: zone)
        switch sun.kind {
        case .alwaysUp: return false
        case .alwaysDown: return true
        case let .normal(sunrise, sunset): return date < sunrise || date >= sunset
        }
    }
}

struct ConditionIcon: View {
    let condition: WeatherCondition?
    var night = false
    var size: CGFloat = 30

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    static let sun = RGB(0xFFC531)
    static let moon = RGB(0xFFE08A)
    static let cloud = RGB(0xE3ECF7)
    static let drop = RGB(0x6FB8FF)

    var body: some View {
        Group {
            if let condition {
                symbol(condition)
                    .font(.system(size: size * 0.82 * scale))
                    .frame(width: size * scale, height: size * scale)
            } else {
                Color.clear.frame(width: size * scale, height: size * scale)
            }
        }
        .accessibilityHidden(true) // the row or tile names the condition in its own label
    }

    @ViewBuilder
    private func symbol(_ c: WeatherCondition) -> some View {
        switch c {
        case .clear:
            if night {
                Image(systemName: "moon.fill").foregroundStyle(Color(Self.moon))
            } else {
                Image(systemName: "sun.max.fill").foregroundStyle(Color(Self.sun))
            }
        case .partly:
            Image(systemName: night ? "cloud.moon.fill" : "cloud.sun.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color(Self.cloud), Color(night ? Self.moon : Self.sun))
        case .cloudy:
            Image(systemName: "cloud.fill").foregroundStyle(Color(Self.cloud))
        case .rain:
            Image(systemName: "cloud.rain.fill").symbolRenderingMode(.palette)
                .foregroundStyle(Color(Self.cloud), Color(Self.drop))
        case .snow:
            Image(systemName: "cloud.snow.fill").symbolRenderingMode(.palette)
                .foregroundStyle(Color(Self.cloud), .white)
        case .mixed:
            Image(systemName: "cloud.sleet.fill").symbolRenderingMode(.palette)
                .foregroundStyle(Color(Self.cloud), Color(Self.drop))
        }
    }
}

/// The small "Beta" pill on the beta parts: says they are new, makes no claim about accuracy.
struct BetaPill: View {
    var body: some View {
        Text("Beta", comment: "Pill on parts of the app that are new and not yet checked")
            .font(.inter(11, .extraBold, relativeTo: .caption2))
            .tracking(0.4)
            .foregroundStyle(Color(Palette.cardInner))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(Palette.textSecondary)))
    }
}
