import Foundation
import Testing
@testable import WeatherConsensus

/// A real place file with the beta fields (today, hourly, blocks, days[].condition, verification), published by the
/// backend on 28 Nov 2026 05:57 UTC from a copy of the `data` branch with commit 569f3ee. Real data, not sample data.
/// File: `Fixtures/fixture-kitimat-beta-2026-11-28T0557Z.json`.
enum BetaFixture {
    static let name = "fixture-kitimat-beta-2026-11-28T0557Z"
    private final class BundleToken {}

    static func data() throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        else { throw Fixture.FixtureError.missing }
        return try Data(contentsOf: url)
    }

    static func forecast() throws -> PlaceForecast { try ForecastDecoder.decode(data()) }
}

@MainActor
struct BetaFileTests {
    /// The app as it was before the beta UI reads the new file: every existing field decodes.
    @Test func fileWithTheBetaFieldsDecodes() throws {
        let forecast = try BetaFixture.forecast()
        #expect(forecast.days.count == 14)
        #expect(forecast.now != nil)
        #expect(forecast.trackRecord != nil)
        #expect(forecast.days.first?.high != nil)
    }
}

@MainActor
struct BetaDecodingTests {
    @Test func everyDayHasItsCondition() throws {
        let days = try BetaFixture.forecast().days
        #expect(days.allSatisfy { $0.condition != nil })
        #expect(days.first?.condition == .rain)
    }

    @Test func hourlyIs48HoursThen16BlocksOf3Hours() throws {
        let f = try BetaFixture.forecast()
        let hours = try #require(f.hourly).entries
        let blocks = try #require(f.blocks).entries
        #expect(hours.count == 48 && blocks.count == 16)
        #expect(hours.allSatisfy { $0.hours == 1 } && blocks.allSatisfy { $0.hours == 3 })
        #expect(blocks.first?.time == hours.last?.time.addingTimeInterval(3600))
        #expect(f.hourlyStrip.count == 64)
        #expect(hours.first?.condition == .cloudy)
    }

    @Test func todayAndNowConditionDecode() throws {
        let f = try BetaFixture.forecast()
        let today = try #require(f.today)
        #expect(today.high == 8.4 && today.low == 4.8 && today.verified == false)
        #expect(f.now?.condition?.condition == .cloudy)
        #expect(f.now?.condition?.falling == false)
    }

    @Test func nothingIsMarkedVerified() throws {
        let v = try #require(try BetaFixture.forecast().verification)
        #expect(v.verified == [] && v.conditionsVerified == [])
        #expect(!v.isVerified("hourly") && !v.isVerified("days.condition"))
    }

    @Test func unknownConditionShowsNoneAndABrokenBlockNeverTouchesTheForecast() throws {
        var object = try JSONSerialization.jsonObject(with: BetaFixture.data()) as! [String: Any]
        var days = object["days"] as! [[String: Any]]
        days[0]["condition"] = "thunder"
        object["days"] = days
        object["hourly"] = ["time": "not a list"]
        object["today"] = 42
        let f = try ForecastDecoder.decode(JSONSerialization.data(withJSONObject: object))
        #expect(f.days[0].condition == nil && f.days.count == 14)
        #expect(f.hourly == nil && f.today == nil && f.blocks != nil)
    }

    @Test func shortColumnsGiveNilsNotCrashes() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let s = ForecastSeries(stepH: 1, time: [t, t.addingTimeInterval(3600)], condition: ["rain"], temp: [])
        #expect(s.entries.count == 2)
        #expect(s.entries[1].condition == nil && s.entries[0].temp == nil)
    }
}

@MainActor
struct BetaDisplayTests {
    @Test func dayAndMomentWords() {
        #expect(ConditionText.day(.clear) == "Sunny")
        #expect(ConditionText.day(.partly) == "Sun and cloud")
        #expect(ConditionText.day(.mixed) == "Rain and snow")
        #expect(ConditionText.moment(.clear, night: true) == "Clear")
        #expect(ConditionText.moment(.partly, night: true) == "Partly cloudy")
        #expect(ConditionText.now(.rain, night: false) == "Raining")
        #expect(ConditionText.now(.cloudy, night: true) == "Cloudy")
    }

    @Test func dayRowReadsItsCondition() throws {
        let day = try #require(try BetaFixture.forecast().days.first)
        let label = DayRowText.label(day)
        #expect(label.contains(". Rain. "))
        // A file without conditions reads as before.
        let old = try #require(try Fixture.forecast().days.first)
        #expect(!DayRowText.label(old).contains("Rain."))
    }

    @Test func hourTileReadsTimeConditionTemperatureAndChance() throws {
        let entry = ForecastHour(time: Date(timeIntervalSince1970: 1_800_000_000), hours: 1, condition: .rain,
                                 temp: 4.6, feelsLike: 4.6, precipChance: 60, precipMM: 0.4, windKMH: 10)
        let spoken = HourlyText.spoken(entry, night: false, unit: .celsius)
        #expect(spoken.contains("rain") || spoken.contains("Rain"))
        #expect(spoken.contains("5°") && spoken.contains("60%"))
        #expect(HourlyText.chance(entry) == "60%")
        let dry = ForecastHour(time: entry.time, hours: 1, condition: .cloudy, temp: 4, feelsLike: 4,
                               precipChance: 22, precipMM: 0, windKMH: 5)
        #expect(HourlyText.chance(dry) == "")  // shown from 30%, as the canvas
    }

    @Test func passedHoursDropAndDaysAndBlocksGroupApart() throws {
        let f = try BetaFixture.forecast()
        let start = try #require(f.hourly?.time.first)
        let upcoming = HourlyText.upcoming(f.hourlyStrip, now: start.addingTimeInterval(90 * 60))
        #expect(upcoming.first?.time == start.addingTimeInterval(3600))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        let groups = HourlyText.groups(upcoming, place: f.place, calendar: calendar)
        #expect(groups.map(\.entries.count).reduce(0, +) == upcoming.count)
        let blockGroups = groups.filter { $0.entries.first?.hours == 3 }
        #expect(!blockGroups.isEmpty && blockGroups.allSatisfy { $0.entries.allSatisfy { $0.hours == 3 } })
        #expect(blockGroups.allSatisfy { $0.title.contains("3-hour steps") })
    }

    @Test func todayHighAndLowLineForTheNowCard() throws {
        let line = try #require(NowText.today(try BetaFixture.forecast().today, unit: .celsius))
        #expect(line.high == "High 8°" && line.low == "Low 5°")
        #expect(NowText.today(nil, unit: .celsius) == nil)
    }

    @Test func noAccuracyClaimInTheBetaText() {
        let texts = ["New. Each hour blends the same sources as the days.", ConditionText.day(.rain),
                     String(localized: "Today, observed so far and forecast")]
        let claim = try! Regex(#"(?i)accura|verified|tested|checked against|reliable|precise"#)
        for t in texts { #expect(t.firstMatch(of: claim) == nil, "\(t)") }
    }
}

@MainActor
struct LivingSkyConditionTests {
    @Test func skyFollowsTheMeasuredNowWhileItIsFresh() throws {
        let f = try BetaFixture.forecast()
        let observed = try #require(f.now?.observedAt)
        #expect(SkyWeather.from(f, now: observed.addingTimeInterval(600)) == .cloudy)
    }

    @Test func oldObservationHandsTheSkyToTheHourlyForecast() throws {
        let f = try BetaFixture.forecast()
        let hour = try #require(f.hourly?.entries[10])
        let sky = SkyWeather.from(f, now: hour.time.addingTimeInterval(60))
        #expect(sky == hour.condition.map(SkyWeather.from))
    }

    @Test func conditionMapsToTheSixSkies() {
        #expect(SkyWeather.from(.clear) == .clear && SkyWeather.from(.partly) == .clear)
        #expect(SkyWeather.from(.cloudy) == .cloudy && SkyWeather.from(.rain) == .rain)
        #expect(SkyWeather.from(.snow) == .snow && SkyWeather.from(.mixed) == .snow)
    }

    @Test func noConditionAnywhereMeansTimeOfDayOnly() throws {
        #expect(SkyWeather.from(try Fixture.forecast()) == nil)
    }
}
