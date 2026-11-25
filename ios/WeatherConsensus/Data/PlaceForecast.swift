import Foundation

// Swift models for the published place file, schema version 1.
// Contract: docs/JSON_SCHEMA.md and docs/place-v1.schema.json.
// Reader rules followed here:
// - Unknown fields are ignored (synthesized Decodable never rejects extra keys).
// - Every field the schema allows to be null is optional, so a null shows as a dash, never a crash.
// - `tier` is a plain string; `CertaintyTier` works out a fallback from `certainty`.
// - Units are metric (deg C, mm, percent).

/// One published file: the forecast for one place, days 1 to 14.
nonisolated struct PlaceForecast: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let place: Place
    let issuedAt: Date
    let issueDate: LocalDate
    let newestRunAt: Date?
    let freshDataAt: Date?
    let stale: Bool
    let staleAfterHours: Double
    let weightsAsOf: LocalDate?
    let units: Units
    let sources: [Source]
    let days: [Day]
    let credits: [Credit]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case place
        case issuedAt = "issued_at"
        case issueDate = "issue_date"
        case newestRunAt = "newest_run_at"
        case freshDataAt = "fresh_data_at"
        case stale
        case staleAfterHours = "stale_after_hours"
        case weightsAsOf = "weights_as_of"
        case units, sources, days, credits
    }

    nonisolated struct Place: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let lat: Double
        let lon: Double
        let elevationM: Double?
        let timezone: String?
        let truthStation: TruthStation?
        let consensusOnly: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, lat, lon
            case elevationM = "elevation_m"
            case timezone
            case truthStation = "truth_station"
            case consensusOnly = "consensus_only"
        }
    }

    nonisolated struct TruthStation: Codable, Equatable, Sendable {
        let network: String
        let id: String
        let name: String
    }

    nonisolated struct Units: Codable, Equatable, Sendable {
        let temperature: String
        let precipitation: String
        let chance: String
    }

    nonisolated struct Source: Codable, Equatable, Sendable {
        let id: String
        let label: String
    }

    nonisolated struct Day: Codable, Equatable, Sendable, Identifiable {
        /// Lead day, 1 to 14.
        let day: Int
        let date: LocalDate
        /// Consensus high, deg C.
        let high: Double?
        /// Consensus low, deg C.
        let low: Double?
        /// Consensus precipitation amount, mm.
        let precipMM: Double?
        /// Chance of 1 mm or more, percent.
        let precipChance: Int?
        /// Chance the day's high lands within 2 deg C of `high`, percent.
        let certainty: Int?
        /// As published: "High", "Medium" or "Low" today. Other values are allowed.
        let tier: String?
        /// Weights for the high, largest first.
        let weights: [Weight]

        var id: Int { day }

        /// The tier to show: the published one when the app knows it, otherwise worked out from `certainty`.
        var certaintyTier: CertaintyTier? {
            if let tier, let known = CertaintyTier(rawValue: tier) { return known }
            return certainty.map(CertaintyTier.init(certainty:))
        }

        enum CodingKeys: String, CodingKey {
            case day, date, high, low
            case precipMM = "precip_mm"
            case precipChance = "precip_chance"
            case certainty, tier, weights
        }
    }

    nonisolated struct Weight: Codable, Equatable, Sendable {
        let id: String
        let weight: Double
    }

    nonisolated struct Credit: Codable, Equatable, Sendable {
        let text: String
        let licence: String
        let url: String
        let licenceURL: String?

        enum CodingKeys: String, CodingKey {
            case text, licence, url
            case licenceURL = "licence_url"
        }
    }
}

/// Certainty tiers (locked): High 75%+, Medium 50 to 74%, Low under 50%.
nonisolated enum CertaintyTier: String, Codable, Sendable, CaseIterable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    init(certainty: Int) {
        switch certainty {
        case 75...: self = .high
        case 50..<75: self = .medium
        default: self = .low
        }
    }
}

/// A calendar date with no time or time zone, as published (`YYYY-MM-DD`).
/// Dates in the file are ECCC climate days, so they are kept as plain dates.
nonisolated struct LocalDate: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = LocalDate(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected YYYY-MM-DD, got \(text)")
        }
        self = date
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Midnight UTC on this date. Format it with a UTC time zone so the day never shifts.
    var utcMidnight: Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
