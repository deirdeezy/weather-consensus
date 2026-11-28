import Foundation

// Beta fields of the place file (added 28 Nov 2026 without a schema version change): each day's condition,
// today, the hourly forecast, the 3-hour blocks and the verification marker. All unverified: the app shows
// them as a beta and makes no accuracy claim for them. Contract: docs/JSON_SCHEMA.md, "Beta". Every value is
// optional and decoded leniently: a block the app cannot read is dropped without touching the forecast.

/// The six conditions the backend publishes (owner decision, 27 Nov 2026: only the checkable ones).
nonisolated enum WeatherCondition: String, Codable, Sendable, CaseIterable {
    case clear, partly, cloudy, rain, snow, mixed

    /// A raw value from the file; anything else (a value a later backend may add) is nil, shown as no condition.
    init?(raw: String?) {
        guard let raw, let known = WeatherCondition(rawValue: raw) else { return nil }
        self = known
    }

    var isPrecipitation: Bool { self == .rain || self == .snow || self == .mixed }
}

nonisolated struct TodayForecast: Codable, Equatable, Sendable {
    let date: LocalDate?
    let high: Double?
    let low: Double?
    let highFrom: String?
    let lowFrom: String?
    let precipSoFarMM: Double?
    let precipRestMM: Double?
    let precipMM: Double?
    let precipChanceRest: Int?
    let conditionRaw: String?
    let verified: Bool?

    var condition: WeatherCondition? { WeatherCondition(raw: conditionRaw) }

    enum CodingKeys: String, CodingKey {
        case date, high, low
        case highFrom = "high_from"
        case lowFrom = "low_from"
        case precipSoFarMM = "precip_so_far_mm"
        case precipRestMM = "precip_rest_mm"
        case precipMM = "precip_mm"
        case precipChanceRest = "precip_chance_rest"
        case conditionRaw = "condition"
        case verified
    }

    init(date: LocalDate?, high: Double?, low: Double?, highFrom: String? = nil, lowFrom: String? = nil,
         precipSoFarMM: Double? = nil, precipRestMM: Double? = nil, precipMM: Double? = nil,
         precipChanceRest: Int? = nil, condition: WeatherCondition? = nil, verified: Bool? = false) {
        self.date = date
        self.high = high
        self.low = low
        self.highFrom = highFrom
        self.lowFrom = lowFrom
        self.precipSoFarMM = precipSoFarMM
        self.precipRestMM = precipRestMM
        self.precipMM = precipMM
        self.precipChanceRest = precipChanceRest
        self.conditionRaw = condition?.rawValue
        self.verified = verified
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.lenient(LocalDate.self, .date)
        high = c.lenient(Double.self, .high)
        low = c.lenient(Double.self, .low)
        highFrom = c.lenient(String.self, .highFrom)
        lowFrom = c.lenient(String.self, .lowFrom)
        precipSoFarMM = c.lenient(Double.self, .precipSoFarMM)
        precipRestMM = c.lenient(Double.self, .precipRestMM)
        precipMM = c.lenient(Double.self, .precipMM)
        precipChanceRest = c.lenient(Int.self, .precipChanceRest)
        conditionRaw = c.lenient(String.self, .conditionRaw)
        verified = c.lenient(Bool.self, .verified)
    }
}

/// One hour, or one 3-hour block (`hours` 3; `time` is its start).
nonisolated struct ForecastHour: Equatable, Sendable, Identifiable {
    let time: Date
    let hours: Int
    let condition: WeatherCondition?
    let temp: Double?
    let feelsLike: Double?
    let precipChance: Int?
    let precipMM: Double?
    let windKMH: Double?

    var id: Date { time }
}

/// The file's column arrays (`time`, `condition`, `temp`, ...), all as long as `time`.
nonisolated struct ForecastSeries: Codable, Equatable, Sendable {
    let stepH: Int?
    let method: String?
    let verified: Bool?
    let time: [Date]
    let condition: [String?]
    let temp: [Double?]
    let feelsLike: [Double?]
    let precipChance: [Int?]
    let precipMM: [Double?]
    let windKMH: [Double?]

    enum CodingKeys: String, CodingKey {
        case stepH = "step_h"
        case method, verified, time, condition, temp
        case feelsLike = "feels_like"
        case precipChance = "precip_chance"
        case precipMM = "precip_mm"
        case windKMH = "wind_kmh"
    }

    init(stepH: Int, time: [Date], condition: [String?], temp: [Double?], feelsLike: [Double?] = [],
         precipChance: [Int?] = [], precipMM: [Double?] = [], windKMH: [Double?] = []) {
        self.stepH = stepH
        self.method = nil
        self.verified = false
        self.time = time
        self.condition = condition
        self.temp = temp
        self.feelsLike = feelsLike
        self.precipChance = precipChance
        self.precipMM = precipMM
        self.windKMH = windKMH
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stepH = c.lenient(Int.self, .stepH)
        method = c.lenient(String.self, .method)
        verified = c.lenient(Bool.self, .verified)
        time = try c.decode([Date].self, forKey: .time)
        condition = c.lenient([String?].self, .condition) ?? []
        temp = c.lenient([Double?].self, .temp) ?? []
        feelsLike = c.lenient([Double?].self, .feelsLike) ?? []
        precipChance = c.lenient([Int?].self, .precipChance) ?? []
        precipMM = c.lenient([Double?].self, .precipMM) ?? []
        windKMH = c.lenient([Double?].self, .windKMH) ?? []
    }

    /// One entry per time; a column that is short or missing gives nil, never a crash.
    var entries: [ForecastHour] {
        func at<T>(_ column: [T?], _ i: Int) -> T? { i < column.count ? column[i] : nil }
        return time.indices.map { i in
            ForecastHour(time: time[i], hours: stepH ?? 1,
                         condition: WeatherCondition(raw: at(condition, i)),
                         temp: at(temp, i), feelsLike: at(feelsLike, i),
                         precipChance: at(precipChance, i), precipMM: at(precipMM, i),
                         windKMH: at(windKMH, i))
        }
    }
}

nonisolated struct Verification: Codable, Equatable, Sendable {
    let verified: [String]?
    let unverified: [String]?
    let conditionsVerified: [String]?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case verified, unverified
        case conditionsVerified = "conditions_verified"
        case note
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verified = c.lenient([String].self, .verified)
        unverified = c.lenient([String].self, .unverified)
        conditionsVerified = c.lenient([String].self, .conditionsVerified)
        note = c.lenient(String.self, .note)
    }

    /// True only when the backend lists `field` as verified. Missing marker: not verified.
    func isVerified(_ field: String) -> Bool { verified?.contains(field) ?? false }
}

/// `now.condition`: precipitation measured by the station, cloud from the forecast's current hour.
nonisolated struct NowCondition: Codable, Equatable, Sendable {
    let classRaw: String?
    let falling: Bool?
    let phase: String?
    let cloudPct: Int?

    var condition: WeatherCondition? { WeatherCondition(raw: classRaw) }

    enum CodingKeys: String, CodingKey {
        case classRaw = "class"
        case falling, phase
        case cloudPct = "cloud_pct"
    }

    init(condition: WeatherCondition?, falling: Bool? = nil, phase: String? = nil, cloudPct: Int? = nil) {
        classRaw = condition?.rawValue
        self.falling = falling
        self.phase = phase
        self.cloudPct = cloudPct
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        classRaw = c.lenient(String.self, .classRaw)
        falling = c.lenient(Bool.self, .falling)
        phase = c.lenient(String.self, .phase)
        cloudPct = c.lenient(Int.self, .cloudPct)
    }
}
