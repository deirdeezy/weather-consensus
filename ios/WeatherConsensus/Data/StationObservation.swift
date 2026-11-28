import Foundation

/// The optional top-level `now` block: the latest hourly observation at the place's approved station
/// (ECCC real-time SWOB) and what the station has seen so far in the climate day. Observations, not a
/// forecast. Contract: docs/JSON_SCHEMA.md, "`now` (optional)".
///
/// Read leniently: only `observed_at` is needed. A field that is missing, null or of an unexpected type
/// is nil (shown as a dash), and a `now` block that cannot be read at all is dropped without touching
/// the forecast (`PlaceForecast.init(from:)`).
nonisolated struct StationObservation: Codable, Equatable, Sendable {
    let observedAt: Date
    let fetchedAt: Date?
    let source: String?
    let station: Station?
    /// Air temperature, deg C.
    let temp: Double?
    /// Dew point, deg C.
    let dewPoint: Double?
    /// Relative humidity, percent.
    let humidity: Double?
    /// 2-minute mean wind at 10 m, km/h.
    let windKMH: Double?
    /// Direction the wind blows from, degrees true.
    let windDirDeg: Double?
    /// Highest wind in the last 10 minutes, km/h.
    let gustKMH: Double?
    /// Mean sea level pressure, kPa.
    let pressureKPA: Double?
    /// "rising", "falling" or "steady" today; other values are allowed (shown as nothing).
    let pressureTendency: String?
    let pressureChange3hKPA: Double?
    /// Precipitation in the hour ending at `observedAt`, mm.
    let precip1hMM: Double?
    /// Highest and lowest temperature since `soFarSince`, deg C.
    let highSoFar: Double?
    let lowSoFar: Double?
    /// Precipitation since `soFarSince`, mm. Nil when an hour is missing.
    let precipSoFarMM: Double?
    /// Start of the climate day (06 UTC).
    let soFarSince: Date?
    /// How many hourly records the so-far values cover.
    let soFarHours: Int?
    /// Which record each current value came from (`values_from`, since 26 Nov 2026). nil in older blocks,
    /// where every value is from the hourly record at `observedAt`.
    let valuesFrom: ValuesFrom?
    /// Added 28 Nov 2026: precipitation measured now, cloud from the forecast (Data/BetaForecast.swift).
    var condition: NowCondition? = nil

    /// `values_from`: the minute record's and the newest hourly record's times, and per current value which
    /// one it came from. Readers must accept other source names (docs/JSON_SCHEMA.md).
    nonisolated struct ValuesFrom: Codable, Equatable, Sendable {
        let minuteAt: Date?
        let hourlyAt: Date?
        let temp: String?
        let dewPoint: String?
        let humidity: String?
        let wind: String?
        let gust: String?

        init(minuteAt: Date?, hourlyAt: Date?, temp: String? = nil, dewPoint: String? = nil,
             humidity: String? = nil, wind: String? = nil, gust: String? = nil) {
            self.minuteAt = minuteAt
            self.hourlyAt = hourlyAt
            self.temp = temp
            self.dewPoint = dewPoint
            self.humidity = humidity
            self.wind = wind
            self.gust = gust
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            minuteAt = c.lenient(Date.self, .minuteAt)
            hourlyAt = c.lenient(Date.self, .hourlyAt)
            temp = c.lenient(String.self, .temp)
            dewPoint = c.lenient(String.self, .dewPoint)
            humidity = c.lenient(String.self, .humidity)
            wind = c.lenient(String.self, .wind)
            gust = c.lenient(String.self, .gust)
        }

        enum CodingKeys: String, CodingKey {
            case minuteAt = "minute_at"
            case hourlyAt = "hourly_at"
            case temp
            case dewPoint = "dew_point"
            case humidity, wind, gust
        }
    }

    /// A current value the card shows, and where it came from.
    nonisolated enum CurrentValue: CaseIterable, Sendable {
        case temp, dewPoint, humidity, wind, gust
    }

    private func isShown(_ value: CurrentValue) -> Bool {
        switch value {
        case .temp: temp != nil
        case .dewPoint: dewPoint != nil
        case .humidity: humidity != nil
        case .wind: windKMH != nil
        case .gust: gustKMH != nil
        }
    }

    /// True when the value came from the minute record (and that record's time is known).
    func isFromMinuteRecord(_ value: CurrentValue) -> Bool {
        guard let valuesFrom, valuesFrom.minuteAt != nil else { return false }
        let from: String? = switch value {
        case .temp: valuesFrom.temp
        case .dewPoint: valuesFrom.dewPoint
        case .humidity: valuesFrom.humidity
        case .wind: valuesFrom.wind
        case .gust: valuesFrom.gust
        }
        return from == "minute"
    }

    /// The time of the oldest value on the card: the age the card shows and dims by. `observedAt` is the
    /// newest record used, so when temperature comes from a minute record and pressure from the hourly
    /// record before it, the card must not call everything as new as the temperature.
    var shownAsOf: Date {
        guard let valuesFrom else { return observedAt }
        var times: [Date] = []
        if let minuteAt = valuesFrom.minuteAt, CurrentValue.allCases.contains(where: { isShown($0) && isFromMinuteRecord($0) }) {
            times.append(minuteAt)
        }
        let hourlyShown = CurrentValue.allCases.contains { isShown($0) && !isFromMinuteRecord($0) }
            || pressureKPA != nil || pressureTendency != nil || precip1hMM != nil
            || highSoFar != nil || lowSoFar != nil || precipSoFarMM != nil
        if hourlyShown { times.append(valuesFrom.hourlyAt ?? observedAt) }
        return times.min() ?? observedAt
    }

    /// The values that are newer than `shownAsOf`, and their time: nil when every value is as old as the oldest.
    var newerValues: (values: [CurrentValue], at: Date)? {
        guard let minuteAt = valuesFrom?.minuteAt, minuteAt > shownAsOf else { return nil }
        let values = CurrentValue.allCases.filter { isShown($0) && isFromMinuteRecord($0) }
        return values.isEmpty ? nil : (values, minuteAt)
    }

    nonisolated struct Station: Codable, Equatable, Sendable {
        let network: String?
        let id: String?
        let name: String?
        let distanceKM: Double?

        enum CodingKeys: String, CodingKey {
            case network, id, name
            case distanceKM = "distance_km"
        }

        init(network: String?, id: String?, name: String?, distanceKM: Double?) {
            self.network = network
            self.id = id
            self.name = name
            self.distanceKM = distanceKM
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            network = c.lenient(String.self, .network)
            id = c.lenient(String.self, .id)
            name = c.lenient(String.self, .name)
            distanceKM = c.lenient(Double.self, .distanceKM)
        }
    }

    enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at"
        case fetchedAt = "fetched_at"
        case source, station, temp
        case dewPoint = "dew_point"
        case humidity
        case windKMH = "wind_kmh"
        case windDirDeg = "wind_dir_deg"
        case gustKMH = "gust_kmh"
        case pressureKPA = "pressure_kpa"
        case pressureTendency = "pressure_tendency"
        case pressureChange3hKPA = "pressure_change_3h_kpa"
        case precip1hMM = "precip_1h_mm"
        case highSoFar = "high_so_far"
        case lowSoFar = "low_so_far"
        case precipSoFarMM = "precip_so_far_mm"
        case soFarSince = "so_far_since"
        case soFarHours = "so_far_hours"
        case valuesFrom = "values_from"
        case condition
    }

    init(observedAt: Date, fetchedAt: Date? = nil, source: String? = nil, station: Station? = nil,
         temp: Double? = nil, dewPoint: Double? = nil, humidity: Double? = nil, windKMH: Double? = nil,
         windDirDeg: Double? = nil, gustKMH: Double? = nil, pressureKPA: Double? = nil,
         pressureTendency: String? = nil, pressureChange3hKPA: Double? = nil, precip1hMM: Double? = nil,
         highSoFar: Double? = nil, lowSoFar: Double? = nil, precipSoFarMM: Double? = nil,
         soFarSince: Date? = nil, soFarHours: Int? = nil, valuesFrom: ValuesFrom? = nil,
         condition: NowCondition? = nil) {
        self.observedAt = observedAt
        self.fetchedAt = fetchedAt
        self.source = source
        self.station = station
        self.temp = temp
        self.dewPoint = dewPoint
        self.humidity = humidity
        self.windKMH = windKMH
        self.windDirDeg = windDirDeg
        self.gustKMH = gustKMH
        self.pressureKPA = pressureKPA
        self.pressureTendency = pressureTendency
        self.pressureChange3hKPA = pressureChange3hKPA
        self.precip1hMM = precip1hMM
        self.highSoFar = highSoFar
        self.lowSoFar = lowSoFar
        self.precipSoFarMM = precipSoFarMM
        self.soFarSince = soFarSince
        self.soFarHours = soFarHours
        self.valuesFrom = valuesFrom
        self.condition = condition
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try c.decode(Date.self, forKey: .observedAt)
        fetchedAt = c.lenient(Date.self, .fetchedAt)
        source = c.lenient(String.self, .source)
        station = c.lenient(Station.self, .station)
        temp = c.lenient(Double.self, .temp)
        dewPoint = c.lenient(Double.self, .dewPoint)
        humidity = c.lenient(Double.self, .humidity)
        windKMH = c.lenient(Double.self, .windKMH)
        windDirDeg = c.lenient(Double.self, .windDirDeg)
        gustKMH = c.lenient(Double.self, .gustKMH)
        pressureKPA = c.lenient(Double.self, .pressureKPA)
        pressureTendency = c.lenient(String.self, .pressureTendency)
        pressureChange3hKPA = c.lenient(Double.self, .pressureChange3hKPA)
        precip1hMM = c.lenient(Double.self, .precip1hMM)
        highSoFar = c.lenient(Double.self, .highSoFar)
        lowSoFar = c.lenient(Double.self, .lowSoFar)
        precipSoFarMM = c.lenient(Double.self, .precipSoFarMM)
        soFarSince = c.lenient(Date.self, .soFarSince)
        soFarHours = c.lenient(Int.self, .soFarHours)
        valuesFrom = c.lenient(ValuesFrom.self, .valuesFrom)
        condition = c.lenient(NowCondition.self, .condition)
    }
}

extension KeyedDecodingContainer {
    /// The value, or nil when it is missing, null or not of the expected type.
    nonisolated func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// How old an observation is, and how the card treats it (owner rules, 25 Nov 2026):
/// up to 3 h it is shown as is; over 3 h the values are dimmed; over 12 h they are hidden.
nonisolated struct ObservationAge: Equatable, Sendable {
    static let dimAfter: TimeInterval = 3 * 3600
    static let hideAfter: TimeInterval = 12 * 3600

    /// Seconds since `observed_at`, never negative.
    let seconds: TimeInterval

    init(observedAt: Date, now: Date) {
        seconds = max(0, now.timeIntervalSince(observedAt))
    }

    var minutes: Int { Int(seconds / 60) }
    var hours: Int { Int(seconds / 3600) }

    enum State: Equatable, Sendable { case fresh, dimmed, hidden }

    var state: State {
        if seconds > Self.hideAfter { return .hidden }
        if seconds > Self.dimAfter { return .dimmed }
        return .fresh
    }
}

/// "Feels like": Environment and Climate Change Canada's wind chill and humidex, otherwise the air temperature.
///
/// Formulas, as printed in ECCC's "Technical documentation: Historical Hourly Climate Station Data"
/// (https://www.canada.ca/en/environment-climate-change/services/climate-change/canadian-centre-climate-services/display-download/technical-documentation-hourly-data.html,
/// page dated 2023-05-01, checked 25 Nov 2026):
/// - Wind chill: W = 13.12 + 0.6215 Tair − 11.37 V^0.16 + 0.3965 Tair V^0.16 (Tair deg C, V wind at 10 m in km/h).
/// - Humidex: Humidex = Tair + h, h = 0.5555 (e − 10.0), e = 6.11 exp[5417.7530 (1/273.15 − 1/dewpoint)],
///   dewpoint in kelvins, e in hPa.
///
/// When each is shown, as ECCC shows them in current conditions:
/// - Wind chill: "When temperatures are zero or below and the wind speed is 5 km/h or higher"
///   (https://www.canada.ca/en/services/environment/weather/severeweather/wind-chill-index.html, checked 25 Nov 2026).
///   ECCC's second formula for winds under 5 km/h is for its hourly archive, not current conditions, so it is not used.
/// - Humidex: "if the temperature is currently 20°C or higher and the Humidex is at least one degree higher than
///   the temperature" (https://www.canada.ca/en/services/environment/weather/severeweather/humidex.html, checked 25 Nov 2026).
nonisolated enum FeelsLike: Equatable, Sendable {
    case windChill(Double)
    case humidex(Double)
    case air(Double)

    /// Wind chill shown at or below this air temperature, deg C.
    static let windChillMaxTemp = 0.0
    /// ... and at or above this wind, km/h.
    static let windChillMinWind = 5.0
    /// Humidex shown at or above this air temperature, deg C.
    static let humidexMinTemp = 20.0
    /// ... when it is at least this much above the air temperature.
    static let humidexMinExcess = 1.0

    var value: Double {
        switch self {
        case .windChill(let v), .humidex(let v), .air(let v): v
        }
    }

    static func windChill(temp: Double, windKMH: Double) -> Double {
        let v = pow(windKMH, 0.16)
        return 13.12 + 0.6215 * temp - 11.37 * v + 0.3965 * temp * v
    }

    static func humidex(temp: Double, dewPoint: Double) -> Double {
        let e = 6.11 * exp(5417.7530 * (1 / 273.15 - 1 / (dewPoint + 273.15)))
        return temp + 0.5555 * (e - 10.0)
    }

    /// Nil only when the air temperature is missing.
    static func from(temp: Double?, windKMH: Double?, dewPoint: Double?) -> FeelsLike? {
        guard let temp else { return nil }
        if temp <= windChillMaxTemp, let windKMH, windKMH >= windChillMinWind {
            return .windChill(windChill(temp: temp, windKMH: windKMH))
        }
        if temp >= humidexMinTemp, let dewPoint {
            let h = humidex(temp: temp, dewPoint: dewPoint)
            if h - temp >= humidexMinExcess { return .humidex(h) }
        }
        return .air(temp)
    }
}
