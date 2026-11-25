import Foundation

/// Plain text for values, metric for now (units setting comes with Settings).
/// A missing value is a dash (docs/JSON_SCHEMA.md).
nonisolated enum ValueText {
    static let missing = "–"

    /// "6.3 °C", one decimal as published.
    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return missing }
        return signed(celsius.formatted(.number.precision(.fractionLength(1)))) + " °C"
    }

    /// "6°" or "−2°": whole degrees for the day rows, as on the design canvas.
    static func shortTemperature(_ celsius: Double?) -> String {
        guard let celsius else { return missing }
        let whole = Int(celsius.rounded())
        return signed((whole == 0 ? 0 : whole).formatted()) + "°"
    }

    static func millimetres(_ mm: Double?) -> String {
        guard let mm else { return missing }
        return mm.formatted(.number.precision(.fractionLength(1))) + " mm"
    }

    static func percent(_ value: Int?) -> String {
        guard let value else { return missing }
        return value.formatted() + "%"
    }

    /// Share of the blend, 0 to 1, as a whole percent ("<1%" for tiny shares).
    static func share(_ weight: Double) -> String {
        let percent = weight * 100
        if percent > 0 && percent < 1 { return "<1%" }
        return Int(percent.rounded()).formatted() + "%"
    }

    static func tier(_ tier: CertaintyTier?) -> String {
        switch tier {
        case .high: String(localized: "High", comment: "Certainty tier, 75% and up")
        case .medium: String(localized: "Medium", comment: "Certainty tier, 50 to 74%")
        case .low: String(localized: "Low", comment: "Certainty tier, under 50%")
        case nil: missing
        }
    }

    /// "Wed 25 Nov". Climate days are plain dates, so format in UTC to keep the day fixed.
    static func date(_ date: LocalDate) -> String {
        guard let midnight = date.utcMidnight else { return date.description }
        return midnight.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Wed".
    static func weekday(_ date: LocalDate) -> String {
        guard let midnight = date.utcMidnight else { return date.description }
        return midnight.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated))
    }

    /// "25 Nov".
    static func dayMonth(_ date: LocalDate) -> String {
        guard let midnight = date.utcMidnight else { return date.description }
        return midnight.formatted(Date.FormatStyle(timeZone: .gmt).day().month(.abbreviated))
    }

    /// "Wednesday 25 November", for VoiceOver.
    static func spokenDate(_ date: LocalDate) -> String {
        guard let midnight = date.utcMidnight else { return date.description }
        return midnight.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.wide).day().month(.wide))
    }

    /// Typographic minus for negative numbers ("−2" not "-2").
    private static func signed(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: "\u{2212}")
    }
}

/// Certainty in words and dots, shared by the ring, the dots and VoiceOver.
nonisolated enum CertaintyText {
    /// Filled dots out of 10: Certainty rounded to the nearest 10% (canvas rule).
    static func filledDots(_ certainty: Int?) -> Int {
        guard let certainty else { return 0 }
        return min(10, max(0, Int((Double(certainty) / 10).rounded())))
    }

    /// "Certainty 91%, High".
    static func ringLabel(_ day: PlaceForecast.Day) -> String {
        guard let certainty = day.certainty else {
            return String(localized: "Certainty not available")
        }
        return String(localized: "Certainty \(certainty) percent, \(ValueText.tier(day.certaintyTier)) tier",
                      comment: "VoiceOver label for the Certainty ring")
    }

    /// Shown under an open day: "About 9 of every 10 days like this land within 2 °C of our high."
    static func dotsSentence(_ day: PlaceForecast.Day) -> String {
        guard day.certainty != nil else { return String(localized: "Certainty not available") }
        let filled = filledDots(day.certainty)
        return String(localized: "About \(filled) of every 10 days like this land within 2\u{00A0}°C (3.6\u{00A0}°F) of our high.",
                      comment: "Shown under an open day row")
    }

    /// "9 of 10 dots: about 9 of every 10 days like this land within 2 degrees of our high."
    static func dotsLabel(_ day: PlaceForecast.Day) -> String {
        guard day.certainty != nil else { return String(localized: "Certainty not available") }
        let filled = filledDots(day.certainty)
        return String(localized: "\(filled) of 10 dots: about \(filled) of every 10 days like this land within 2 degrees Celsius of our high",
                      comment: "VoiceOver label for the 10 Certainty dots")
    }
}
