import Foundation
import Testing
@testable import WeatherConsensus

@Suite("Living sky")
struct LivingSkyTests {
    /// Every sky: every time of day, with no weather (what ships now) and with each weather (the hook).
    static let allStyles: [SkyStyle] = SkyTime.allCases.flatMap { time in
        [SkyStyle(time: time, weather: nil)] + SkyWeather.allCases.map { SkyStyle(time: time, weather: $0) }
    }

    @Test func headerTextHasEnoughContrastOnEverySky() {
        for style in Self.allStyles {
            // WCAG AA for normal text is 4.5:1; the header is large and bold, so 3:1 would do. We hold 4.5.
            #expect(style.headerContrast >= 4.5, "\(style.time) \(String(describing: style.weather)): \(style.headerContrast)")
        }
    }

    @Test func roughWeatherIsRichNotGrey() {
        // "Rich, never gloomy": storm and rain skies keep colour (saturation) at the top of the sky.
        for time in SkyTime.allCases {
            for weather in [SkyWeather.storm, .rain] {
                let top = SkyStyle(time: time, weather: weather).top
                let maxC = max(top.red, top.green, top.blue)
                let minC = min(top.red, top.green, top.blue)
                let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
                #expect(saturation >= 0.35, "\(time) \(weather): saturation \(saturation)")
            }
        }
    }

    @Test func weatherHookIsEmptyUntilTheFileHasACondition() throws {
        #expect(SkyWeather.from(try Fixture.forecast()) == nil)
        #expect(SkyStyle(time: .day, weather: nil) == SkyStyle(time: .day, weather: nil))
    }

    @Test func timeOfDayFollowsSunriseAndSunset() throws {
        let rise = try #require(ISO8601DateFormatter().date(from: "2026-11-25T16:00:00Z"))
        let set = rise.addingTimeInterval(8 * 3600)
        let solar = SolarTimes(kind: .normal(sunrise: rise, sunset: set))
        #expect(SkyTime.at(rise.addingTimeInterval(-46 * 60), solar: solar) == .night)
        #expect(SkyTime.at(rise.addingTimeInterval(-45 * 60), solar: solar) == .dawn)
        #expect(SkyTime.at(rise.addingTimeInterval(59 * 60), solar: solar) == .dawn)
        #expect(SkyTime.at(rise.addingTimeInterval(60 * 60), solar: solar) == .day)
        #expect(SkyTime.at(set.addingTimeInterval(-45 * 60), solar: solar) == .dusk)
        #expect(SkyTime.at(set.addingTimeInterval(59 * 60), solar: solar) == .dusk)
        #expect(SkyTime.at(set.addingTimeInterval(60 * 60), solar: solar) == .night)
        #expect(SkyTime.at(rise, solar: SolarTimes(kind: .alwaysDown)) == .night)
        #expect(SkyTime.at(rise, solar: SolarTimes(kind: .alwaysUp)) == .day)
    }
}

@Suite("Sun times")
struct SolarTimesTests {
    private func times(_ iso: String, lat: Double, lon: Double, zone: String) throws -> (Date, Date) {
        let date = try #require(ISO8601DateFormatter().date(from: iso))
        let solar = SolarTimes(date: date, latitude: lat, longitude: lon, timeZone: try #require(TimeZone(identifier: zone)))
        guard case let .normal(sunrise, sunset) = solar.kind else {
            Issue.record("Expected a normal day")
            throw CancellationError()
        }
        return (sunrise, sunset)
    }

    @Test func equatorAtTheMarchEquinox() throws {
        // At 0, 0 on the equinox the day is 12 h plus about 7 min of refraction and sun radius,
        // centred on solar noon, which the equation of time puts near 12:07 UTC.
        let (rise, set) = try times("2026-03-20T12:00:00Z", lat: 0, lon: 0, zone: "UTC")
        let dayLength = set.timeIntervalSince(rise) / 60
        #expect(abs(dayLength - 727) < 5)
        let noon = rise.addingTimeInterval(set.timeIntervalSince(rise) / 2)
        let noonMinutes = noon.timeIntervalSince(try #require(ISO8601DateFormatter().date(from: "2026-03-20T00:00:00Z"))) / 60
        #expect(abs(noonMinutes - 727) < 5)
    }

    @Test func kitimatInLateNovember() throws {
        // Kitimat (from the fixture) at 54.05 N in late November: a day of about 8 h, centred on
        // solar noon near 20:22 UTC (longitude 128.63 W is 8 h 35 min behind Greenwich, less about
        // 13 min for the equation of time). Checked in UTC: the iOS 27.2 time zone data has
        // America/Vancouver on UTC-7 all year, so local clock times are not PST.
        let forecast = try Fixture.forecast()
        let place = forecast.place
        let (rise, set) = try times("2026-11-25T20:00:00Z", lat: place.lat, lon: place.lon, zone: try #require(place.timezone))
        let hours = set.timeIntervalSince(rise) / 3600
        #expect(hours > 7.5 && hours < 8.6)
        let noon = rise.addingTimeInterval(set.timeIntervalSince(rise) / 2)
        let midnight = try #require(ISO8601DateFormatter().date(from: "2026-11-25T00:00:00Z"))
        let noonMinutes = noon.timeIntervalSince(midnight) / 60
        #expect(abs(noonMinutes - (20 * 60 + 22)) < 10, "solar noon \(noon)")
    }

    @Test func polarDayAndNight() throws {
        let december = try #require(ISO8601DateFormatter().date(from: "2026-12-21T12:00:00Z"))
        let june = try #require(ISO8601DateFormatter().date(from: "2026-06-21T12:00:00Z"))
        #expect(SolarTimes(date: december, latitude: 80, longitude: 0, timeZone: .gmt).kind == .alwaysDown)
        #expect(SolarTimes(date: june, latitude: 80, longitude: 0, timeZone: .gmt).kind == .alwaysUp)
    }
}

@Suite("Weather tab values")
struct WeatherValueTests {
    @Test func dotsRoundToTheNearestTen() {
        #expect(CertaintyText.filledDots(91) == 9)
        #expect(CertaintyText.filledDots(95) == 10)
        #expect(CertaintyText.filledDots(67) == 7)
        #expect(CertaintyText.filledDots(4) == 0)
        #expect(CertaintyText.filledDots(nil) == 0)
        #expect(CertaintyText.filledDots(140) == 10)
    }

    @Test func shortTemperaturesUseWholeDegreesAndATrueMinus() {
        #expect(ValueText.shortTemperature(6.3) == "6°")
        #expect(ValueText.shortTemperature(-3.5) == "\u{2212}4°")
        #expect(ValueText.shortTemperature(-0.4) == "0°")
        #expect(ValueText.shortTemperature(nil) == ValueText.missing)
    }

    @Test func sharesAreWholePercents() {
        #expect(ValueText.share(0.167) == "17%")
        #expect(ValueText.share(0.004) == "<1%")
        #expect(ValueText.share(0) == "0%")
    }

    @Test func everyPublishedSourceHasAKnownColour() throws {
        let forecast = try Fixture.forecast()
        for source in forecast.sources {
            #expect(Palette.sourceColors[source.id] != nil, "No colour for \(source.id)")
        }
        // Colours tell sources apart: no two known sources share one.
        let colours = Array(Palette.sourceColors.values)
        #expect(Set(colours).count == colours.count)
        // Unknown ids still get a colour, the same one every time.
        #expect(Palette.source("new_model") == Palette.source("new_model"))
    }

    @Test func sourceBarLabelNamesEverySourceWithItsShare() throws {
        let forecast = try Fixture.forecast()
        let day = forecast.days[0]
        let total = day.weights.reduce(0) { $0 + $1.weight }
        let label = SourceText.barLabel(weights: day.weights, total: total, sources: forecast.sources)
        for weight in day.weights {
            #expect(label.contains(SourceText.label(for: weight.id, in: forecast.sources)))
        }
        #expect(label.contains("17%"))
    }

    @Test func ringLabelSaysPercentAndTier() throws {
        let day = try Fixture.forecast().days[0]
        let label = CertaintyText.ringLabel(day)
        #expect(label.contains("91"))
        #expect(label.contains("High"))
        #expect(CertaintyText.dotsLabel(day).contains("9 of 10"))
    }

    @Test func cardTextHasEnoughContrast() {
        let backgrounds = [Palette.card, Palette.cardInner, Palette.rowOpen, Palette.detail]
        for background in backgrounds {
            for text in [Palette.white, Palette.textSecondary, Palette.textBody, Palette.link] {
                #expect(text.contrast(with: background) >= 4.5, "\(text) on \(background)")
            }
        }
        // Tier names are written in the tier text colour on a day row (closed or open).
        for background in [Palette.card, Palette.cardInner, Palette.rowOpen] {
            for tier in CertaintyTier.allCases.map(Palette.tierText) {
                #expect(tier.contrast(with: background) >= 4.5, "\(tier) on \(background)")
            }
        }
        // Ring and dot colours are graphics: 3:1 on every navy.
        for background in [Palette.card, Palette.cardInner, Palette.rowOpen, Palette.detail] {
            for tier in [Palette.tierHigh, Palette.tierMedium, Palette.tierLow] {
                #expect(tier.contrast(with: background) >= 3, "\(tier) on \(background)")
            }
        }
    }

    @Test func interIsBundledAndRegisters() {
        #expect(AppFont.registered)
        #expect(Bundle.main.url(forResource: "Inter-OFL", withExtension: "txt") != nil)
    }
}
