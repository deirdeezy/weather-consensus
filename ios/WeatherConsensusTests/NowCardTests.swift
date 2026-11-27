import Foundation
import Testing
@testable import WeatherConsensus

private let nbsp = "\u{00A0}"

/// A `now` block with the values of a real observation: Kitimat Forest Ave, 25 Nov 2026 21:00 UTC,
/// as the backend published it from ECCC swob-realtime (docs/JSON_SCHEMA.md example). Real data.
enum NowFixture {
    static let block: [String: Any] = [
        "observed_at": "2026-11-25T21:00:00Z", "fetched_at": "2026-11-25T21:40:21Z",
        "source": "ECCC SWOB real-time (MSC GeoMet swob-realtime)",
        "station": ["network": "ECCC", "id": "1064324", "name": "Kitimat Forest Ave", "distance_km": 2.0],
        "temp": 3.5, "dew_point": 3.5, "humidity": 100, "wind_kmh": 0.5, "wind_dir_deg": 0, "gust_kmh": 2.0,
        "pressure_kpa": 100.22, "pressure_tendency": "rising", "pressure_change_3h_kpa": 0.02, "precip_1h_mm": 0.7,
        "high_so_far": 4.0, "low_so_far": 1.9, "precip_so_far_mm": 8.2, "so_far_since": "2026-11-25T06:00:00Z",
        "so_far_hours": 15,
    ]

    static let observedAt = ISO8601DateFormatter().date(from: "2026-11-25T21:00:00Z")!

    /// The saved real file with `now` set to `block` (or a variation of it).
    static func forecast(now: Any? = block) throws -> PlaceForecast {
        var object = try Fixture.jsonObject()
        object["now"] = now
        return try ForecastDecoder.decode(Fixture.encode(object))
    }

    static func observation(_ changes: [String: Any] = [:]) throws -> StationObservation {
        try #require(try forecast(now: block.merging(changes) { $1 }).now)
    }
}

@Suite("Now block in the file")
struct NowDecodingTests {
    @Test func decodesTheNowBlock() throws {
        let now = try #require(try NowFixture.forecast().now)
        #expect(now.observedAt == NowFixture.observedAt)
        #expect(now.station?.name == "Kitimat Forest Ave")
        #expect(now.station?.distanceKM == 2.0)
        #expect(now.temp == 3.5 && now.dewPoint == 3.5 && now.humidity == 100)
        #expect(now.windKMH == 0.5 && now.windDirDeg == 0 && now.gustKMH == 2.0)
        #expect(now.pressureKPA == 100.22 && now.pressureTendency == "rising")
        #expect(now.precip1hMM == 0.7 && now.precipSoFarMM == 8.2)
        #expect(now.highSoFar == 4.0 && now.lowSoFar == 1.9 && now.soFarHours == 15)
    }

    @Test func placeWithoutAStationHasNoNow() throws {
        #expect(try Fixture.forecast().now == nil)
        #expect(try NowFixture.forecast(now: nil).now == nil)
    }

    /// The reader rule: unknown fields are ignored, at the top, in `now` and in `now.station`.
    @Test func unknownFieldsAreIgnored() throws {
        var block = NowFixture.block
        block["visibility_km"] = 10
        block["station"] = (block["station"] as! [String: Any]).merging(["elevation_m": 106]) { $1 }
        var object = try Fixture.jsonObject()
        object["now"] = block
        object["today"] = ["high": 5]
        object["alerts"] = []
        let forecast = try ForecastDecoder.decode(Fixture.encode(object))
        #expect(forecast.now?.temp == 3.5)
        #expect(forecast.days.count == 14)
    }

    /// A `now` block the app cannot read never costs the forecast.
    @Test func unreadableNowIsDroppedNotFatal() throws {
        for bad: Any in ["warm", 42, [1, 2], ["temp": 3.5], ["observed_at": "yesterday"]] {
            let forecast = try NowFixture.forecast(now: bad)
            #expect(forecast.now == nil)
            #expect(forecast.days.count == 14)
        }
    }

    @Test func oddValuesBecomeDashesNotErrors() throws {
        let now = try NowFixture.observation(["temp": "warm", "humidity": NSNull(), "wind_kmh": [1],
                                              "station": "Kitimat", "pressure_tendency": 3])
        #expect(now.temp == nil && now.humidity == nil && now.windKMH == nil)
        #expect(now.station == nil && now.pressureTendency == nil)
        #expect(now.dewPoint == 3.5)
        #expect(NowText.bigTemperature(now.temp, unit: .celsius) == ValueText.missing)
    }
}

@Suite("Now card")
struct NowCardTests {
    private func age(minutes: Double) -> ObservationAge {
        ObservationAge(observedAt: NowFixture.observedAt, now: NowFixture.observedAt.addingTimeInterval(minutes * 60))
    }

    @Test func freshLabelsCountMinutesThenHours() throws {
        let obs = try NowFixture.observation()
        #expect(NowText.label(obs, age: age(minutes: 0.5)) == ["Observed at Kitimat Forest Ave, just now"])
        #expect(NowText.label(obs, age: age(minutes: 40)) == ["Observed at Kitimat Forest Ave, 40\(nbsp)min ago"])
        #expect(NowText.label(obs, age: age(minutes: 59)) == ["Observed at Kitimat Forest Ave, 59\(nbsp)min ago"])
        #expect(NowText.label(obs, age: age(minutes: 61)) == ["Observed at Kitimat Forest Ave, 1\(nbsp)h ago"])
        #expect(NowText.label(obs, age: age(minutes: 180)) == ["Observed at Kitimat Forest Ave, 3\(nbsp)h ago"])
        // A phone clock a little behind the station: never a negative age.
        #expect(NowText.label(obs, age: age(minutes: -5)) == ["Observed at Kitimat Forest Ave, just now"])
    }

    @Test func overThreeHoursDimsAndOverTwelveHides() throws {
        let obs = try NowFixture.observation()
        #expect(age(minutes: 180).state == .fresh)
        #expect(age(minutes: 181).state == .dimmed)
        #expect(age(minutes: 720).state == .dimmed)
        #expect(age(minutes: 721).state == .hidden)
        #expect(NowText.label(obs, age: age(minutes: 5 * 60 + 10)) ==
                ["Observed at Kitimat Forest Ave", "Last observation 5\(nbsp)h ago"])
        #expect(NowText.label(obs, age: age(minutes: 30 * 60)) ==
                ["Observed at Kitimat Forest Ave", "Last observation 30\(nbsp)h ago"])
    }

    @Test func bigTemperatureIsWholeDegreesInTheChosenUnit() {
        #expect(NowText.bigTemperature(3.5, unit: .celsius) == "4")
        #expect(NowText.bigTemperature(3.5, unit: .fahrenheit) == "38")   // 38.3
        #expect(NowText.bigTemperature(-2.4, unit: .celsius) == "\u{2212}2")
        #expect(NowText.bigTemperature(nil, unit: .celsius) == ValueText.missing)
    }

    @Test func soFarUsesThePhonesClock() throws {
        let obs = try NowFixture.observation()
        let pst = try #require(TimeZone(secondsFromGMT: -8 * 3600))
        let us = NowText.soFar(obs, unit: .celsius, timeZone: pst, locale: Locale(identifier: "en_US"))
        #expect(us == NowText.SoFar(high: "High 4°", low: "Low 2°", since: "So far since 10:00\u{202F}PM",
                                    spoken: "Observed so far since 10:00\u{202F}PM: high 4°, low 2°"))
        let gb = NowText.soFar(obs, unit: .fahrenheit, timeZone: pst, locale: Locale(identifier: "en_GB"))
        #expect(gb?.since == "So far since 22:00")
        #expect(gb?.high == "High 39°" && gb?.low == "Low 35°")
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(NowText.soFar(obs, unit: .celsius, timeZone: tokyo, locale: Locale(identifier: "en_GB"))?.since == "So far since 15:00")
        // No hour of the climate day yet: no so-far row.
        #expect(NowText.soFar(try NowFixture.observation(["high_so_far": NSNull(), "low_so_far": NSNull()]), unit: .celsius) == nil)
    }

    @Test func precipitationLastHourAndSoFar() throws {
        let obs = try NowFixture.observation()
        let pst = try #require(TimeZone(secondsFromGMT: -8 * 3600))
        #expect(ValueText.precipitation(obs.precip1hMM, in: .millimetres) == "0.7\(nbsp)mm")
        #expect(ValueText.precipitation(obs.precip1hMM, in: .inches) == "0.03\(nbsp)in")
        #expect(NowText.precipSoFarNote(obs, unit: .millimetres, timeZone: pst, locale: Locale(identifier: "en_GB")) == "8.2\(nbsp)mm since 22:00")
        #expect(NowText.precipSoFarNote(obs, unit: .inches, timeZone: pst, locale: Locale(identifier: "en_GB")) == "0.32\(nbsp)in since 22:00")
        #expect(NowText.precipSoFarNote(try NowFixture.observation(["precip_so_far_mm": NSNull()]), unit: .millimetres) == nil)
    }

    @Test func windInTheChosenUnitWithCompassAndGusts() throws {
        let breezy = try NowFixture.observation(["wind_kmh": 30.0, "wind_dir_deg": 22, "gust_kmh": 50.0])
        #expect(NowText.windValue(breezy, unit: .kilometresPerHour) == "30\(nbsp)km/h")
        #expect(NowText.windValue(breezy, unit: .milesPerHour) == "19\(nbsp)mph")        // 18.6
        #expect(NowText.windNote(breezy, unit: .kilometresPerHour) == "From NNE · gusts 50")
        #expect(NowText.windNote(breezy, unit: .milesPerHour) == "From NNE · gusts 31")  // 31.1
        #expect(NowText.arrowDegrees(breezy, unit: .kilometresPerHour) == 202)
        #expect(NowText.spokenWind(breezy, unit: .kilometresPerHour) ==
                "Wind, 30\(nbsp)km/h, from the north-northeast, gusts 50\(nbsp)km/h")

        // The real 21:00 observation: 0.5 km/h rounds to 1, gust 2 shows.
        let real = try NowFixture.observation()
        #expect(NowText.windValue(real, unit: .kilometresPerHour) == "1\(nbsp)km/h")
        #expect(NowText.windNote(real, unit: .kilometresPerHour) == "From N · gusts 2")
        // In mph the same wind is calm: no direction, gust still shown.
        #expect(NowText.windValue(real, unit: .milesPerHour) == "Calm")
        #expect(NowText.windNote(real, unit: .milesPerHour) == "Gusts 1")
        #expect(NowText.arrowDegrees(real, unit: .milesPerHour) == nil)

        // A gust no higher than the wind is not shown.
        let steady = try NowFixture.observation(["wind_kmh": 20.0, "gust_kmh": 20.4])
        #expect(NowText.windNote(steady, unit: .kilometresPerHour) == "From N")
    }

    @Test func compassPoints() {
        #expect(ValueText.compass(0) == "N")
        #expect(ValueText.compass(11.2) == "N")
        #expect(ValueText.compass(11.3) == "NNE")
        #expect(ValueText.compass(90) == "E")
        #expect(ValueText.compass(225) == "SW")
        #expect(ValueText.compass(348.7) == "NNW")
        #expect(ValueText.compass(349) == "N")
        #expect(ValueText.compass(360) == "N")
        #expect(ValueText.spokenCompass(315) == "northwest")
    }

    @Test func pressureInTheChosenUnitWithTendency() {
        #expect(ValueText.pressure(100.22, in: .kilopascals) == "100.2\(nbsp)kPa")
        #expect(ValueText.pressure(100.22, in: .inchesOfMercury) == "29.59\(nbsp)inHg")   // 29.5949
        #expect(ValueText.pressure(101.325, in: .inchesOfMercury) == "29.92\(nbsp)inHg")  // standard atmosphere
        #expect(ValueText.pressure(nil, in: .kilopascals) == ValueText.missing)
        #expect(NowText.tendency("rising") == "Rising")
        #expect(NowText.tendency("falling") == "Falling")
        #expect(NowText.tendency("steady") == "Steady")
        #expect(NowText.tendency("wobbly") == nil)
        #expect(NowText.tendency(nil) == nil)
    }

    @Test func humidityAndDewPoint() {
        #expect(NowText.dewNote(3.5, unit: .celsius) == "Dew point 4°")
        #expect(NowText.dewNote(3.5, unit: .fahrenheit) == "Dew point 38°")
        #expect(NowText.dewNote(nil, unit: .celsius) == nil)
    }

    @Test func sunTimesOnThePhonesClock() throws {
        let rise = try #require(ISO8601DateFormatter().date(from: "2026-11-25T16:20:00Z"))
        let set = try #require(ISO8601DateFormatter().date(from: "2026-11-26T00:24:00Z"))
        let pst = try #require(TimeZone(secondsFromGMT: -8 * 3600))
        let lines = NowText.sun(SolarTimes(kind: .normal(sunrise: rise, sunset: set)), timeZone: pst, locale: Locale(identifier: "en_GB"))
        #expect(lines.map(\.text) == ["8:20", "16:24"])
        #expect(lines.map(\.spoken) == ["Sunrise 8:20", "Sunset 16:24"])
        #expect(NowText.sun(SolarTimes(kind: .alwaysDown)).map(\.text) == ["Sun down all day"])
    }

    @Test func everyNowStringKeepsUnitsJoined() throws {
        let obs = try NowFixture.observation(["wind_kmh": 30.0, "gust_kmh": 50.0])
        let all = UnitChoice(temperature: .fahrenheit, rain: .inches, wind: .milesPerHour, pressure: .inchesOfMercury)
        for units in [UnitChoice.metric, all] {
            var strings = NowText.label(obs, age: age(minutes: 40)) + NowText.label(obs, age: age(minutes: 300))
            strings += [NowText.windValue(obs, unit: units.wind), NowText.spokenWind(obs, unit: units.wind),
                        ValueText.pressure(obs.pressureKPA, in: units.pressure), NowText.spokenPrecip(obs, unit: units.rain),
                        NowText.spokenTemperature(obs.temp, unit: units.temperature)]
            strings += [NowText.windNote(obs, unit: units.wind), NowText.precipSoFarNote(obs, unit: units.rain),
                        NowText.dewNote(obs.dewPoint, unit: units.temperature)].compactMap { $0 }
            for text in strings {
                #expect(UnitSpacingTests.offenders(in: text).isEmpty, "\(text)")
                #expect(text.firstMatch(of: /\d[ \t](in|inHg|mph|kPa|km\/h|min|h)\b/) == nil, "\(text)")
            }
        }
    }

    /// Dimmed values (over 3 h old) keep 4.5:1, on the card and on the tiles.
    @Test func dimmedTextKeepsContrast() {
        for background in [Palette.card, Palette.heroPanel] {
            for text in [Palette.white, Palette.textSecondary, Palette.textBody] {
                let dimmed = text.over(background, alpha: NowText.dimOpacity)
                #expect(dimmed.contrast(with: background) >= 4.5, "\(text) on \(background)")
            }
        }
        #expect(Palette.textSecondary.contrast(with: Palette.heroPanel) >= 4.5)
    }
}

@Suite("Feels like (ECCC wind chill and humidex)")
struct FeelsLikeTests {
    @Test func windChillFormula() {
        // ECCC wind chill formula at −10 °C and 20 km/h: −17.9 (ECCC's chart shows −18).
        #expect(abs(FeelsLike.windChill(temp: -10, windKMH: 20) - (-17.86)) < 0.01)
        #expect(ValueText.shortTemperature(FeelsLike.windChill(temp: -10, windKMH: 20)) == "\u{2212}18°")
    }

    @Test func windChillOnlyAtZeroOrBelowWithFiveKilometresAnHour() {
        #expect(FeelsLike.from(temp: 0, windKMH: 5, dewPoint: -3) == .windChill(FeelsLike.windChill(temp: 0, windKMH: 5)))
        #expect(FeelsLike.from(temp: 0.1, windKMH: 30, dewPoint: -3) == .air(0.1))
        #expect(FeelsLike.from(temp: -5, windKMH: 4.9, dewPoint: -8) == .air(-5))
        #expect(FeelsLike.from(temp: -5, windKMH: nil, dewPoint: -8) == .air(-5))
    }

    @Test func humidexFormula() {
        // ECCC humidex formula at 30 °C with a 15 °C dew point: 34.0.
        #expect(abs(FeelsLike.humidex(temp: 30, dewPoint: 15) - 33.98) < 0.01)
    }

    @Test func humidexOnlyAtTwentyOrAboveAndAtLeastOneDegreeHigher() {
        #expect(FeelsLike.from(temp: 30, windKMH: 10, dewPoint: 15) == .humidex(FeelsLike.humidex(temp: 30, dewPoint: 15)))
        #expect(FeelsLike.from(temp: 19.9, windKMH: 10, dewPoint: 19) == .air(19.9))
        // Dry air: humidex less than 1 degree above the temperature.
        #expect(FeelsLike.humidex(temp: 20, dewPoint: 0) - 20 < 1)
        #expect(FeelsLike.from(temp: 20, windKMH: 0, dewPoint: 0) == .air(20))
        #expect(FeelsLike.from(temp: 25, windKMH: 0, dewPoint: nil) == .air(25))
    }

    @Test func noTemperatureNoFeelsLike() {
        #expect(FeelsLike.from(temp: nil, windKMH: 30, dewPoint: 1) == nil)
        #expect(NowText.feelsValue(nil, unit: .celsius) == ValueText.missing)
        #expect(NowText.feelsNote(nil) == nil)
    }

    @Test func notesAndUnits() {
        #expect(NowText.feelsNote(.windChill(-18)) == "Wind chill")
        #expect(NowText.feelsNote(.humidex(34)) == "Humidex")
        #expect(NowText.feelsNote(.air(3.5)) == "Air temperature")
        #expect(NowText.feelsValue(.windChill(-17.86), unit: .fahrenheit) == "0°")   // −0.15 °F, never "−0"
        #expect(NowText.feelsValue(.humidex(33.98), unit: .celsius) == "34°")
    }
}

/// Review finding 10 (27 Nov 2026): temperature can come from a minute record and pressure from the hourly
/// record before it. The card's age is its oldest value's, and the newer values are named with their own age.
/// Times from the real 26 Nov 2026 01:07 UTC block (docs/JSON_SCHEMA.md): minute 01:07, hourly 01:00.
@Suite("Now card ages when records differ")
struct NowCardMixedAgeTests {
    private static let mixed: [String: Any] = [
        "observed_at": "2026-11-26T01:07:00Z",
        "values_from": ["minute_at": "2026-11-26T01:07:00Z", "hourly_at": "2026-11-26T01:00:00Z",
                        "temp": "minute", "dew_point": "hourly", "humidity": "minute", "wind": "hourly", "gust": "hourly"],
    ]
    private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func lines(_ obs: StationObservation, now: String) -> [String] {
        let age = ObservationAge(observedAt: obs.shownAsOf, now: at(now))
        return NowText.label(obs, age: age) + NowText.newerLine(obs, now: at(now), age: age)
    }

    @Test func labelCountsFromTheOldestValueAndNamesTheNewerOnes() throws {
        let obs = try NowFixture.observation(Self.mixed)
        #expect(obs.observedAt == at("2026-11-26T01:07:00Z"))
        #expect(obs.shownAsOf == at("2026-11-26T01:00:00Z"))
        #expect(lines(obs, now: "2026-11-26T01:40:00Z") ==
                ["Observed at Kitimat Forest Ave, 40\(nbsp)min ago", "Newer: temperature and humidity, 33\(nbsp)min ago"])
        #expect(lines(obs, now: "2026-11-26T01:07:20Z") ==
                ["Observed at Kitimat Forest Ave, 7\(nbsp)min ago", "Newer: temperature and humidity, just now"])
    }

    @Test func dimmingFollowsTheOldestValue() throws {
        // Hourly records stopped at 01:00 while minute records kept coming (a 22:00-style station gap).
        var block = Self.mixed
        block["observed_at"] = "2026-11-26T04:30:00Z"
        block["values_from"] = (Self.mixed["values_from"] as! [String: Any]).merging(["minute_at": "2026-11-26T04:30:00Z"]) { $1 }
        let obs = try NowFixture.observation(block)
        let age = ObservationAge(observedAt: obs.shownAsOf, now: at("2026-11-26T04:35:00Z"))
        #expect(age.state == .dimmed)  // was fresh when the card went by observed_at
        #expect(lines(obs, now: "2026-11-26T04:35:00Z") ==
                ["Observed at Kitimat Forest Ave", "Last observation 3\(nbsp)h ago", "Newer: temperature and humidity, 5\(nbsp)min ago"])
    }

    @Test func oneRecordOrAnOlderBlockGivesOneAge() throws {
        let hourlyOnly = try NowFixture.observation([
            "observed_at": "2026-11-26T01:00:00Z",
            "values_from": ["minute_at": NSNull(), "hourly_at": "2026-11-26T01:00:00Z", "temp": "hourly",
                            "dew_point": "hourly", "humidity": "hourly", "wind": "hourly", "gust": "hourly"]])
        #expect(hourlyOnly.shownAsOf == at("2026-11-26T01:00:00Z"))
        #expect(lines(hourlyOnly, now: "2026-11-26T01:40:00Z") == ["Observed at Kitimat Forest Ave, 40\(nbsp)min ago"])
        let old = try NowFixture.observation()  // no values_from: every value from the hourly record
        #expect(old.shownAsOf == NowFixture.observedAt && old.newerValues == nil)
    }

    @Test func minuteValuesAloneUseTheMinuteTime() throws {
        // Only minute values on the card (everything hourly is missing): its age is the minute record's.
        var block = Self.mixed
        for key in ["dew_point", "wind_kmh", "gust_kmh", "pressure_kpa", "pressure_tendency", "precip_1h_mm",
                    "high_so_far", "low_so_far", "precip_so_far_mm"] { block[key] = NSNull() }
        let obs = try NowFixture.observation(block)
        #expect(obs.shownAsOf == at("2026-11-26T01:07:00Z"))
        #expect(obs.newerValues == nil)
    }

    @Test func hiddenCardHasNoNewerLine() throws {
        let obs = try NowFixture.observation(Self.mixed)
        #expect(lines(obs, now: "2026-11-26T14:00:00Z") ==
                ["Observed at Kitimat Forest Ave", "Last observation 13\(nbsp)h ago"])
    }
}
