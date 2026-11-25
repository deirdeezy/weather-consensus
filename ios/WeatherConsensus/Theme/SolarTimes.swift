import Foundation

/// Sunrise and sunset for a place and day, from NOAA's "General Solar Position Calculations"
/// (NOAA Global Monitoring Laboratory, https://gml.noaa.gov/grad/solcalc/solareqns.PDF).
/// Accurate to a minute or two at mid latitudes, which is plenty for choosing a sky colour.
nonisolated struct SolarTimes: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The sun rises and sets on this day.
        case normal(sunrise: Date, sunset: Date)
        /// The sun stays up all day (polar summer).
        case alwaysUp
        /// The sun stays down all day (polar winter).
        case alwaysDown
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    /// Sun times on the local calendar day that contains `date` in `timeZone`.
    /// `longitude` is degrees east (west is negative), as in the published file.
    init(date: Date, latitude: Double, longitude: Double, timeZone: TimeZone) {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let utcMidnight = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)),
              let dayOfYear = utc.ordinality(of: .day, in: .year, for: utcMidnight),
              let year = utc.dateInterval(of: .year, for: utcMidnight)
        else {
            kind = .alwaysUp
            return
        }

        // Days in this year (365 or 366). Not `range(of: .day, in: .year)`: that gives day-of-month values.
        let daysInYear = (year.duration / 86_400).rounded()
        // Fractional year (radians) at local solar noon, close enough for the whole day.
        let gamma = 2 * Double.pi / daysInYear * Double(dayOfYear - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)

        let lat = latitude * .pi / 180
        // 90.833 degrees: the sun's upper edge on the horizon, with average refraction.
        let zenith = 90.833 * Double.pi / 180
        let cosHA = cos(zenith) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)
        if cosHA > 1 { kind = .alwaysDown; return }
        if cosHA < -1 { kind = .alwaysUp; return }
        let haDegrees = acos(cosHA) * 180 / .pi

        // Minutes after midnight UTC on this calendar date (may run past 1440 for western places).
        let riseMinutes = 720 - 4 * (longitude + haDegrees) - eqTime
        let setMinutes = 720 - 4 * (longitude - haDegrees) - eqTime
        kind = .normal(sunrise: utcMidnight.addingTimeInterval(riseMinutes * 60),
                       sunset: utcMidnight.addingTimeInterval(setMinutes * 60))
    }
}
