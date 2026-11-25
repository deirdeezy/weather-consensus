import Foundation
import SwiftUI
import Testing
@testable import WeatherConsensus

/// The Consensus tab: every number comes from the published file (fixture: the real file of 25 Nov 2026).
@Suite("Consensus tab")
struct ConsensusScreenTests {
    private func facts() throws -> ConsensusFacts { ConsensusFacts(try Fixture.forecast()) }

    /// The fixture with one change, decoded through the real decoder.
    private func forecast(_ change: (inout [String: Any]) -> Void) throws -> PlaceForecast {
        var object = try Fixture.jsonObject()
        change(&object)
        return try ForecastDecoder.decode(Fixture.encode(object))
    }

    @Test func modelsAndNormalComeFromTheFile() throws {
        let facts = try facts()
        #expect(facts.models.count == 9)
        #expect(!facts.models.contains { $0.id == "normal" })
        #expect(facts.normal?.id == "normal")
        #expect(ConsensusText.modelsHead(facts.models.count) == "9 FORECAST MODELS")
        #expect(ConsensusText.modelsHead(1) == "1 FORECAST MODEL")
    }

    @Test func chipsFollowTheCanvasOrderWithUnknownIdsLast() throws {
        let facts = try facts()
        #expect(facts.models.map { facts.names.name(for: $0.id) } ==
                ["Env. Canada", "ECMWF", "ECMWF AI", "UK Met Office", "DWD ICON", "NOAA GFS", "Japan JMA", "China CMA", "Météo-France"])
        // Unknown ids go last, in file order; the count is still the file's.
        let forecast = try forecast { object in
            var sources = object["sources"] as! [[String: Any]]
            sources.insert(["id": "new_b", "label": "New B"], at: 0)
            sources.insert(["id": "new_a", "label": "New A"], at: 3)
            object["sources"] = sources
        }
        let models = ConsensusFacts(forecast).models
        #expect(models.count == 11)
        #expect(models.suffix(2).map(\.id) == ["new_b", "new_a"])
        #expect(models.first?.id == "gem_seamless")
    }

    @Test func gatherTextMakesNoFrequencyPromise() {
        #expect(ConsensusText.gatherText(placeName: "Kitimat", hasNormal: true) ==
                "We check each source for new forecast runs and pull them as they come out. Further out, Kitimat's 1991 to 2020 normal joins in as one more source.")
        #expect(ConsensusText.gatherText(placeName: "Kitimat", hasNormal: false) ==
                "We check each source for new forecast runs and pull them as they come out.")
    }

    /// No app text promises how often we refresh or score (owner decision): checked in every key and
    /// value of the String Catalog, which holds every localized string in the app.
    @Test func noFrequencyPromiseAnywhereInTheApp() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "WeatherConsensus/Localizable.xcstrings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let catalog = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        var texts = Array(strings.keys)
        func collect(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let value = dict["value"] as? String { texts.append(value) }
                dict.values.forEach(collect)
            } else if let array = node as? [Any] { array.forEach(collect) }
        }
        collect(strings)
        let promise = try Regex(#"(?i)\bevery (hour|night|morning|evening|week|\d+ (hours?|minutes?))\b|\bhourly\b|\bnightly\b|\bdaily\b|update(s|d)? every day"#)
        for text in texts {
            #expect(text.firstMatch(of: promise) == nil, "\(text)")
        }
        #expect(texts.contains { $0.hasPrefix("We check each source for new forecast runs") })
    }

    @MainActor @Test(arguments: [SourceBar.large, SourceBar.small])
    func sourceBarHeightIsFixedAtEveryTextSize(thickness: CGFloat) throws {
        #expect(SourceBar.large == 22 && SourceBar.small == 14)
        let forecast = try Fixture.forecast()
        for size in [DynamicTypeSize.large, .accessibility5] {
            let bar = SourceBar(weights: forecast.days[0].weights, names: SourceNames(forecast), thickness: thickness)
                .frame(width: 300)
                .environment(\.dynamicTypeSize, size)
            let renderer = ImageRenderer(content: bar)
            renderer.scale = 1
            let image = try #require(renderer.uiImage)
            #expect(image.size.height == thickness, "\(size): \(image.size.height)")
        }
    }

    @Test func noNormalMeansNoNormalChipOrSentence() throws {
        let forecast = try forecast { object in
            object["sources"] = (object["sources"] as! [[String: Any]]).filter { $0["id"] as? String != "normal" }
            object["days"] = (object["days"] as! [[String: Any]]).map { day in
                var day = day
                day["weights"] = (day["weights"] as! [[String: Any]]).filter { $0["id"] as? String != "normal" }
                return day
            }
        }
        let facts = ConsensusFacts(forecast)
        #expect(facts.normal == nil)
        #expect(!ConsensusText.gatherText(placeName: "Kitimat", hasNormal: false).contains("normal"))
        #expect(!ConsensusText.shiftText(facts: facts).contains("normal"))
    }

    @Test func sharesKeepFileOrderDropZeroAndAddToOne() throws {
        let day = try Fixture.forecast().days[0]
        let shares = ConsensusFacts.shares(day)
        #expect(shares.map(\.id) == day.weights.map(\.id))
        #expect(abs(shares.reduce(0) { $0 + $1.share } - 1) < 1e-9)

        let zero = PlaceForecast.Day(day: 1, date: day.date, high: nil, low: nil, precipMM: nil, precipChance: nil,
                                     certainty: nil, tier: nil,
                                     weights: [.init(id: "a", weight: 0.5), .init(id: "b", weight: 0)])
        #expect(ConsensusFacts.shares(zero).map(\.id) == ["a"])
        let empty = PlaceForecast.Day(day: 1, date: day.date, high: nil, low: nil, precipMM: nil, precipChance: nil,
                                      certainty: nil, tier: nil, weights: [])
        #expect(ConsensusFacts.shares(empty).isEmpty)
    }

    @Test func shiftDaysAreOneSevenAndThirteen() throws {
        #expect(try facts().shiftDays.map(\.day) == [1, 7, 13])
        // A shorter file shows what it has.
        let short = try forecast { object in
            object["days"] = Array((object["days"] as! [[String: Any]]).prefix(8))
        }
        #expect(ConsensusFacts(short).shiftDays.map(\.day) == [1, 7])
    }

    @Test func shiftTextGivesTheNormalsShareFromTheFile() throws {
        let text = ConsensusText.shiftText(facts: try facts())
        // Day 13 of the fixture: the normal has 0.35 of the high.
        #expect(text.hasSuffix("On day 13, the Kitimat normal (1991 to 2020) is 35% of the high."))
    }

    @Test func examplesAreTheFirstDayOfEachTierInTheFile() throws {
        let examples = try facts().examples
        // The fixture has High days 1 to 5 and Medium days 6 to 14, and no Low day.
        #expect(examples.map(\.day) == [1, 6])
        #expect(examples.map(\.certaintyTier) == [.high, .medium])
        #expect(ConsensusText.exampleTitle(examples[0]) == "\(ValueText.date(examples[0].date)) · High")
        #expect(ConsensusText.exampleSentence(examples[0]) == "About 9 of 10 days like this land within 2\u{00A0}°C.")
        #expect(ConsensusText.exampleSentence(examples[1]) == "About 7 of 10 days like this land within 2\u{00A0}°C.")
    }

    @Test func heroTextNamesThePlaceAndHasNoFixedSourceCount() throws {
        let facts = try facts()
        #expect(!ConsensusText.heroTitle.contains { $0.isNumber })
        let body = ConsensusText.heroBody(placeName: facts.placeName, consensusOnly: false)
        #expect(body.contains("what really happened in Kitimat"))
        #expect(!body.contains { $0.isNumber })
        let borrowed = ConsensusText.heroBody(placeName: "Lakelse Lake", consensusOnly: true)
        #expect(borrowed.contains("Lakelse Lake has no weather station"))
        #expect(!borrowed.contains("check each against"))
        // Step 1 only has the normal's years in it.
        let gather = ConsensusText.gatherText(placeName: facts.placeName, hasNormal: true)
        #expect(gather.replacingOccurrences(of: "1991 to 2020", with: "").allSatisfy { !$0.isNumber })
    }

    @Test func diagramLabelReadsSourcesAndCertainty() throws {
        let day = try Fixture.forecast().days[0]
        #expect(ConsensusText.diagramLabel(day) == "Wednesday: 9 sources blend into one consensus. Certainty 91 percent, High tier.")
    }

    @Test func homeworkUsesTheTruthStationAndScoreDate() throws {
        let place = try Fixture.forecast().place
        let station = try #require(place.truthStation)
        #expect(ConsensusText.homeworkText(place).contains("the Kitimat Forest Ave weather station"))
        #expect(ConsensusText.stationValue(station) == "Kitimat Forest Ave (ECCC)")
        #expect(try Fixture.forecast().weightsAsOf?.description == "2026-11-24")

        let borrowed = try forecast { object in
            var place = object["place"] as! [String: Any]
            place["consensus_only"] = true
            place["truth_station"] = NSNull()
            object["place"] = place
        }
        let text = ConsensusText.homeworkText(borrowed.place)
        #expect(text.contains("no weather station of its own"))
        #expect(!text.contains("Forest Ave"))
    }

    @Test func dayHeadingsComeFromTheFile() throws {
        let forecast = try Fixture.forecast()
        #expect(ConsensusText.dayConsensusHead(forecast.days[0]) == "WEDNESDAY'S CONSENSUS")
        #expect(ConsensusText.leadDay(forecast.days[6]) == "Day 7")
        let label = ConsensusText.shiftRowLabel(forecast.days[12], names: SourceNames(forecast))
        #expect(label.hasPrefix("Day 13, \(ValueText.spokenDate(forecast.days[12].date)). Sources for the high: "))
        #expect(ValueText.spokenDate(forecast.days[12].date).contains("Monday"))
        #expect(label.contains("Kitimat normal (1991 to 2020) 35%"))
    }

    @Test func chartLabelReadsEveryDay() throws {
        let days = try Fixture.forecast().days
        let label = ConsensusText.chartLabel(days)
        #expect(label.hasPrefix("Certainty by day: \(ValueText.spokenDate(days[0].date)) 91%"))
        for day in days {
            #expect(label.contains("\(ValueText.spokenDate(day.date)) \(ValueText.percent(day.certainty))"))
        }
        #expect(ValueText.narrowWeekday(days[0].date) == "W")
    }

    @Test func missingCertaintyShowsADash() throws {
        let forecast = try forecast { object in
            var days = object["days"] as! [[String: Any]]
            days[1]["certainty"] = NSNull()
            days[1]["tier"] = NSNull()
            object["days"] = days
        }
        #expect(ConsensusText.chartLabel(forecast.days).contains("\(ValueText.spokenDate(forecast.days[1].date)) \(ValueText.missing)"))
        // A day with no Certainty is never picked as a worked example.
        #expect(!ConsensusFacts(forecast).examples.contains { $0.day == 2 })
    }

    @Test func stepLabelsForVoiceOver() {
        #expect(ConsensusText.stepLabel(4, ConsensusText.weightTitle) == "Step 4: We weight by track record")
    }

    @Test func heroPanelAndStepNumberHaveEnoughContrast() {
        for text in [Palette.white, Palette.textSecondary, Palette.textBody] {
            #expect(text.contrast(with: Palette.heroPanel) >= 4.5, "\(text) on hero panel")
        }
        for tier in [Palette.tierHigh, Palette.tierMedium, Palette.tierLow] {
            #expect(tier.contrast(with: Palette.heroPanel) >= 3, "\(tier) on hero panel")
        }
        // Step numbers: navy on a white circle. Chips: white on the inner navy.
        #expect(Palette.ink.contrast(with: Palette.white) >= 4.5)
        #expect(Palette.white.contrast(with: Palette.cardInner) >= 4.5)
        // Fact tiles: navy ink at 35% over the card.
        let tile = Palette.ink.over(Palette.card, alpha: 0.35)
        for text in [Palette.white, Palette.textSecondary] {
            #expect(text.contrast(with: tile) >= 4.5, "\(text) on fact tile")
        }
    }

    @Test func everyConsensusStringKeepsUnitsJoined() throws {
        let facts = try facts()
        var strings = [ConsensusText.sureText, ConsensusText.shiftText(facts: facts), ConsensusText.chartLabel(facts.forecast.days)]
        for day in facts.forecast.days {
            strings += [ConsensusText.exampleSentence(day), ConsensusText.exampleLabel(day), ConsensusText.diagramLabel(day),
                        ConsensusText.shiftRowLabel(day, names: facts.names)]
        }
        for text in strings {
            #expect(UnitSpacingTests.offenders(in: text).isEmpty, "\(text)")
        }
    }

    @Test func skyForNoForecastIsPlainDay() {
        #expect(SkyStyle.current(for: nil, now: .now) == SkyStyle(time: .day, weather: nil))
    }
}
