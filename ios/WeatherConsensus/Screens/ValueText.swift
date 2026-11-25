import Foundation

/// Plain text for values. The file is metric; the units setting (deg C or deg F, mm or in) converts here.
/// A missing value is a dash (docs/JSON_SCHEMA.md).
///
/// Units never split from their number: a number and its unit are joined by a non-breaking space
/// (U+00A0, written `\u{00A0}` in source) or by nothing ("91%", "6°"). `UnitSpacingTests` checks every
/// user-facing string in the app and the String Catalog.
nonisolated enum ValueText {
    static let missing = "–"
    /// Non-breaking space, for joining a number to its unit.
    static let nbsp = "\u{00A0}"

    static func fahrenheit(_ celsius: Double) -> Double { celsius * 9 / 5 + 32 }

    /// A deg C value in the chosen unit.
    static func converted(_ celsius: Double, to unit: TemperatureUnit) -> Double {
        unit == .celsius ? celsius : fahrenheit(celsius)
    }

    /// "6.3 °C" or "43.3 °F": one decimal, half away from zero, never "−0.0".
    static func temperature(_ celsius: Double?, in unit: TemperatureUnit = .celsius) -> String {
        guard let celsius else { return missing }
        let tenths = (converted(celsius, to: unit) * 10).rounded() / 10
        let symbol = unit == .celsius ? "°C" : "°F"
        return signed((tenths == 0 ? 0 : tenths).formatted(.number.precision(.fractionLength(1)))) + "\u{00A0}" + symbol
    }

    /// "6°" or "−2°" (or "43°" in deg F): whole degrees for the day rows, as on the design canvas.
    static func shortTemperature(_ celsius: Double?, in unit: TemperatureUnit = .celsius) -> String {
        guard let celsius else { return missing }
        let whole = Int(converted(celsius, to: unit).rounded())
        return signed((whole == 0 ? 0 : whole).formatted()) + "°"
    }

    /// "21.2 mm", one decimal as published (opened row).
    static func millimetres(_ mm: Double?) -> String {
        precipitation(mm, in: .millimetres)
    }

    /// Exact amount (opened row): "21.2 mm", one decimal as published, or "0.83 in", two decimals;
    /// in inches, an amount above 0 that rounds to 0.00 reads "<0.01 in".
    static func precipitation(_ mm: Double?, in unit: RainUnit) -> String {
        guard let mm else { return missing }
        switch unit {
        case .millimetres:
            return mm.formatted(.number.precision(.fractionLength(1))) + "\u{00A0}mm"
        case .inches:
            if mm > 0 && hundredths(mm) == 0 { return "<0.01\u{00A0}in" }
            return inches(mm) + "\u{00A0}in"
        }
    }

    /// Closed day row, as on the canvas: whole millimetres, "<1 mm" above 0 and under 1,
    /// "Dry" only when the file says exactly 0. In inches: two decimals ("0.83 in"),
    /// "<0.01 in" for an amount above 0 that rounds to 0.00 (the inch form of "<1 mm").
    static func rowPrecipitation(_ mm: Double?, in unit: RainUnit = .millimetres) -> String {
        guard let mm else { return missing }
        if mm == 0 { return String(localized: "Dry", comment: "Day row: the forecast precipitation is exactly zero") }
        switch unit {
        case .millimetres:
            if mm < 1 { return "<1\u{00A0}mm" }
            return Int(mm.rounded()).formatted() + "\u{00A0}mm"
        case .inches:
            if hundredths(mm) == 0 { return "<0.01\u{00A0}in" }
            return inches(mm) + "\u{00A0}in"
        }
    }

    /// Millimetres as whole hundredths of an inch, half away from zero.
    private static func hundredths(_ mm: Double) -> Int {
        Int((mm / 25.4 * 100).rounded())
    }

    private static func inches(_ mm: Double) -> String {
        (Double(hundredths(mm)) / 100).formatted(.number.precision(.fractionLength(2)))
    }

    // MARK: Wind and pressure (Now card)

    /// km/h per mph: 1 mile is exactly 1.609344 km.
    static let kmPerMile = 1.609344
    /// kPa per inHg: 1 inch of mercury (at 0 °C) is 3.386389 kPa (NIST SP 811, appendix B.8).
    static let kPaPerInHg = 3.386389

    /// Wind in the chosen unit, whole numbers, half away from zero.
    static func windWhole(_ kmh: Double, in unit: WindUnit) -> Int {
        Int((unit == .kilometresPerHour ? kmh : kmh / kmPerMile).rounded())
    }

    /// "30 km/h" or "19 mph".
    static func wind(_ kmh: Double?, in unit: WindUnit) -> String {
        guard let kmh else { return missing }
        return windNumber(windWhole(kmh, in: unit), in: unit)
    }

    /// A whole wind number with its unit.
    static func windNumber(_ whole: Int, in unit: WindUnit) -> String {
        whole.formatted() + "\u{00A0}" + (unit == .kilometresPerHour ? "km/h" : "mph")
    }

    /// "100.2 kPa" (one decimal, as ECCC shows it) or "29.60 inHg" (two decimals).
    static func pressure(_ kPa: Double?, in unit: PressureUnit) -> String {
        guard let kPa else { return missing }
        switch unit {
        case .kilopascals:
            return kPa.formatted(.number.precision(.fractionLength(1))) + "\u{00A0}kPa"
        case .inchesOfMercury:
            return (kPa / kPaPerInHg).formatted(.number.precision(.fractionLength(2))) + "\u{00A0}inHg"
        }
    }

    private static let compassPoints = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                                        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    /// 16-point compass for a direction in degrees true ("NNE").
    static func compass(_ degrees: Double) -> String {
        compassPoints[compassIndex(degrees)]
    }

    private static func compassIndex(_ degrees: Double) -> Int {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return Int(((d < 0 ? d + 360 : d) / 22.5).rounded()) % 16
    }

    /// "north-northeast", for VoiceOver.
    static func spokenCompass(_ degrees: Double) -> String {
        let names = [String(localized: "north"), String(localized: "north-northeast"), String(localized: "northeast"),
                     String(localized: "east-northeast"), String(localized: "east"), String(localized: "east-southeast"),
                     String(localized: "southeast"), String(localized: "south-southeast"), String(localized: "south"),
                     String(localized: "south-southwest"), String(localized: "southwest"), String(localized: "west-southwest"),
                     String(localized: "west"), String(localized: "west-northwest"), String(localized: "northwest"),
                     String(localized: "north-northwest")]
        return names[compassIndex(degrees)]
    }

    /// Label for the chance of precipitation. The backend's threshold is 1 mm; in inches it reads
    /// "Chance of 0.04 in or more" (1 mm = 0.039 in, to two decimals as every inch amount).
    static func chanceLabel(_ unit: RainUnit) -> String {
        switch unit {
        case .millimetres: String(localized: "Chance of 1\u{00A0}mm+", comment: "Opened day row: chance of precipitation at the backend threshold, in millimetres")
        case .inches: String(localized: "Chance of 0.04\u{00A0}in or more", comment: "Opened day row: chance of precipitation at the backend threshold, in inches")
        }
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

    /// "W": one letter, for the Consensus tab's day-by-day chart.
    static func narrowWeekday(_ date: LocalDate) -> String {
        guard let midnight = date.utcMidnight else { return date.description }
        return midnight.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.narrow))
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
    /// The Certainty band in the chosen unit only (owner decision, step 5b): "2 °C", or "3.6 °F"
    /// (the same band: a 2 deg C difference is 3.6 deg F; Certainty is still worked out in deg C).
    static func band(_ unit: TemperatureUnit) -> String {
        unit == .celsius ? "2\u{00A0}°C" : "3.6\u{00A0}°F"
    }

    /// Weather tab Certainty card: "… The ring is the chance the high lands within 2 °C of our number."
    static func explainer(_ unit: TemperatureUnit) -> String {
        String(localized: "Every day blends several forecast sources, weighted by how well each has done here. The ring is the chance the high lands within \(band(unit)) of our number.",
               comment: "Weather tab, Certainty card. Value: the Certainty band in the chosen unit.")
    }

    /// VoiceOver form of `band`.
    static func spokenBand(_ unit: TemperatureUnit) -> String {
        unit == .celsius
            ? String(localized: "2\u{00A0}degrees Celsius", comment: "VoiceOver: the Certainty band")
            : String(localized: "3.6\u{00A0}degrees Fahrenheit", comment: "VoiceOver: the Certainty band, deg F chosen")
    }

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
    static func dotsSentence(_ day: PlaceForecast.Day, unit: TemperatureUnit = .celsius) -> String {
        guard day.certainty != nil else { return String(localized: "Certainty not available") }
        let filled = filledDots(day.certainty)
        return String(localized: "Out of 10 days like this, about \(filled) land within \(band(unit)) of our forecast high.",
                      comment: "Opened day row, under the 10 dots")
    }

    /// Canvas breakdown text beside the big ring: "Odds that Wednesday's high lands within 2 °C of 6°."
    static func oddsSentence(_ day: PlaceForecast.Day, unit: TemperatureUnit = .celsius) -> String {
        String(localized: "Odds that \(ValueText.fullWeekday(day.date))'s high lands within \(band(unit)) of \(ValueText.shortTemperature(day.high, in: unit)).",
               comment: "Opened day row, beside the big Certainty ring. Values: a weekday name, the Certainty band (2\u{00A0}°C), the forecast high.")
    }

    /// "9 of 10 dots: about 9 of every 10 days like this land within 2 degrees Celsius of our high".
    static func dotsLabel(_ day: PlaceForecast.Day, unit: TemperatureUnit = .celsius) -> String {
        guard day.certainty != nil else { return String(localized: "Certainty not available") }
        let filled = filledDots(day.certainty)
        return String(localized: "\(filled) of 10 dots: about \(filled) of every 10 days like this land within \(spokenBand(unit)) of our high",
                      comment: "VoiceOver label for the 10 Certainty dots")
    }
}
