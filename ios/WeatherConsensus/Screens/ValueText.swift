import Foundation

/// Plain text for values, metric for now (units setting comes with Settings).
/// A missing value is a dash (docs/JSON_SCHEMA.md).
///
/// Units never split from their number: a number and its unit are joined by a non-breaking space
/// (U+00A0, written `\u{00A0}` in source) or by nothing ("91%", "6°"). `UnitSpacingTests` checks every
/// user-facing string in the app and the String Catalog.
nonisolated enum ValueText {
    static let missing = "–"
    /// Non-breaking space, for joining a number to its unit.
    static let nbsp = "\u{00A0}"

    /// "6.3 °C", one decimal as published.
    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return missing }
        return signed(celsius.formatted(.number.precision(.fractionLength(1)))) + "\u{00A0}°C"
    }

    /// "6°" or "−2°": whole degrees for the day rows, as on the design canvas.
    static func shortTemperature(_ celsius: Double?) -> String {
        guard let celsius else { return missing }
        let whole = Int(celsius.rounded())
        return signed((whole == 0 ? 0 : whole).formatted()) + "°"
    }

    /// "21.2 mm", one decimal as published (opened row).
    static func millimetres(_ mm: Double?) -> String {
        guard let mm else { return missing }
        return mm.formatted(.number.precision(.fractionLength(1))) + "\u{00A0}mm"
    }

    /// Closed day row, as on the canvas: whole millimetres, "<1 mm" above 0 and under 1,
    /// "Dry" only when the file says exactly 0.
    static func rowPrecipitation(_ mm: Double?) -> String {
        guard let mm else { return missing }
        if mm == 0 { return String(localized: "Dry", comment: "Day row: the forecast precipitation is exactly zero") }
        if mm < 1 { return "<1\u{00A0}mm" }
        return Int(mm.rounded()).formatted() + "\u{00A0}mm"
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

    /// "Wednesday".
    static func fullWeekday(_ date: LocalDate) -> String {
        guard let midnight = date.utcMidnight else { return date.description }
        return midnight.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.wide))
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

    /// "Certainty 91 percent, High tier".
    static func ringLabel(_ day: PlaceForecast.Day) -> String {
        guard let certainty = day.certainty else {
            return String(localized: "Certainty not available")
        }
        return String(localized: "Certainty \(certainty) percent, \(ValueText.tier(day.certaintyTier)) tier",
                      comment: "VoiceOver label for the Certainty ring")
    }

    /// Canvas breakdown text under the dots:
    /// "Out of 10 days like this, about 9 land within 2 °C of our forecast high."
    static func dotsSentence(_ day: PlaceForecast.Day) -> String {
        guard day.certainty != nil else { return String(localized: "Certainty not available") }
        let filled = filledDots(day.certainty)
        return String(localized: "Out of 10 days like this, about \(filled) land within 2\u{00A0}°C of our forecast high.",
                      comment: "Opened day row, under the 10 dots")
    }

    /// Canvas breakdown text beside the big ring: "Odds that Wednesday's high lands within 2 °C of 6°."
    static func oddsSentence(_ day: PlaceForecast.Day) -> String {
        String(localized: "Odds that \(ValueText.fullWeekday(day.date))'s high lands within 2\u{00A0}°C of \(ValueText.shortTemperature(day.high)).",
               comment: "Opened day row, beside the big Certainty ring. First value is a weekday name, second the forecast high.")
    }

    /// "9 of 10 dots: about 9 of every 10 days like this land within 2 degrees Celsius of our high".
    static func dotsLabel(_ day: PlaceForecast.Day) -> String {
        guard day.certainty != nil else { return String(localized: "Certainty not available") }
        let filled = filledDots(day.certainty)
        return String(localized: "\(filled) of 10 dots: about \(filled) of every 10 days like this land within 2\u{00A0}degrees Celsius of our high",
                      comment: "VoiceOver label for the 10 Certainty dots")
    }
}
