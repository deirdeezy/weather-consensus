import Foundation
import Testing
@testable import WeatherConsensus

/// Consensus tab steps 2 and 3 from `track_record`: parsing, unit conversions, and the empty,
/// too-few-days and live-ready states. Real data: the 27 Nov 2026 file (archive scored, live record 0 days)
/// and the 25 Nov 2026 file (no block). Edge cases are built from the real file.
@Suite("Track record")
struct TrackRecordTests {
    private func facts(_ forecast: PlaceForecast) -> TrackRecordFacts { TrackRecordFacts(forecast) }

    /// The 27 Nov file with one change to its `track_record`, decoded through the real decoder.
    private func forecast(_ change: (inout [String: Any]) -> Void) throws -> PlaceForecast {
        var object = try Fixture.trackRecordObject()
        var record = object["track_record"] as! [String: Any]
        change(&record)
        object["track_record"] = record
        return try ForecastDecoder.decode(Fixture.encode(object))
    }

    /// A date as the app writes it on this phone ("25 Nov" or "Nov 25").
    private func d(_ text: String) -> String { ValueText.dayMonth(LocalDate(text)!) }

    private let metric = UnitChoice.metric
    private let imperial = UnitChoice(temperature: .fahrenheit, rain: .inches)

    // MARK: Parsing

    @Test func realFileParses() throws {
        let record = try #require(try Fixture.trackRecordForecast().trackRecord)
        #expect(record.leads == [1, 7, 13])
        #expect(record.scoredOn == LocalDate("2026-11-26"))
        #expect(record.stationThrough == LocalDate("2026-11-24"))
        let archive = try #require(record.archive)
        #expect(archive.basis == "archive")
        #expect(archive.minDays == 20)
        #expect(archive.missWindow == .init(from: LocalDate("2026-09-27")!, to: LocalDate("2026-11-25")!, days: 60))
        #expect(archive.biasWindow?.days == 30)
        #expect(archive.consensus.first { $0.lead == 1 }?.high == .init(miss: 0.96, days: 59))
        #expect(archive.sources.filter { $0.lead == 1 }.count == 9)
        let gem = try #require(archive.sources.first { $0.id == "gem_seamless" && $0.lead == 1 })
        #expect(gem.high == .init(weight: 0.146, miss: 1.03, days: 59, bias: 0.57, biasDays: 29))
        #expect(gem.rain?.bias == nil && gem.rain?.miss == 3.33)
        let live = try #require(record.live)
        #expect(live.basis == "live" && live.since == LocalDate("2026-11-25") && live.minDays == 20)
        #expect(live.days.map(\.days) == [0, 0, 0])
        #expect(live.sources.isEmpty)
    }

    @Test func olderFileHasNoBlockAndShowsTheNote() throws {
        let forecast = try Fixture.forecast()
        #expect(forecast.trackRecord == nil)
        let facts = facts(forecast)
        #expect(!facts.hasArchive)
        #expect(facts.leads.isEmpty)
        #expect(facts.rows(.high, lead: 1, basis: .archive).isEmpty)
        #expect(facts.habits(.high).isEmpty)
        #expect(TrackRecordText.notInFile == "Each source's track record is not in this forecast file yet.")
    }

    @Test func unreadableBlockIsDroppedAndTheForecastStays() throws {
        let forecast = try self.forecast { $0["leads"] = "one, seven" }
        #expect(forecast.trackRecord == nil)
        #expect(forecast.days.count == 14)
    }

    @Test func unknownFieldsInTheBlockAreIgnored() throws {
        let count = try #require(try Fixture.trackRecordForecast().trackRecord?.archive?.sources.count)
        #expect(count == 18)  // 9 sources at day 1, fewer at days 7 and 13 (runs end; the normal joins)
        let forecast = try self.forecast { record in
            record["ensembles"] = ["x": 1]
            var archive = record["archive"] as! [String: Any]
            var sources = archive["sources"] as! [[String: Any]]
            sources[0]["colour"] = "#fff"
            archive["sources"] = sources
            record["archive"] = archive
        }
        #expect(forecast.trackRecord?.archive?.sources.count == count)
    }

    @Test func emptyArchiveCountsAsNotInFile() throws {
        let forecast = try self.forecast { record in
            var archive = record["archive"] as! [String: Any]
            archive["sources"] = [[String: Any]]()
            record["archive"] = archive
        }
        #expect(forecast.trackRecord != nil)
        #expect(!facts(forecast).hasArchive)
    }

    // MARK: Rows

    @Test func rowsAreConsensusFirstThenClosestMiss() throws {
        let forecast = try Fixture.trackRecordForecast()
        let rows = facts(forecast).rows(.high, lead: 1, basis: .archive)
        #expect(rows.first?.isConsensus == true && rows.first?.miss == 0.96 && rows.first?.weight == nil)
        let misses = rows.dropFirst().compactMap(\.miss)
        #expect(misses == misses.sorted())
        #expect(rows.dropFirst().first?.name == "Env. Canada")
        #expect(rows.last?.name == "Météo-France")
        // weights for highs are the day's published weights
        let day1 = Dictionary(uniqueKeysWithValues: forecast.days[0].weights.map { ($0.id, $0.weight) })
        for row in rows.dropFirst() { #expect(row.weight == day1[row.id]) }
        #expect(TrackRecordFacts.usualDays(rows.filter { !$0.isConsensus }) == 59)
        #expect(TrackRecordFacts.longest(rows) == 2.83)
    }

    @Test func normalAtDay13HasWeightAndASourceWithoutTodaysForecastHasADash() throws {
        let forecast = try self.forecast { record in
            var archive = record["archive"] as! [String: Any]
            var sources = archive["sources"] as! [[String: Any]]
            let i = sources.firstIndex { ($0["id"] as! String) == "gfs_seamless" && ($0["lead"] as! Int) == 13 }!
            var high = sources[i]["high"] as! [String: Any]
            high["weight"] = NSNull()
            sources[i]["high"] = high
            archive["sources"] = sources
            record["archive"] = archive
        }
        let rows = facts(forecast).rows(.high, lead: 13, basis: .archive)
        #expect(rows.first { $0.id == "normal" }?.weight == 0.35)
        let gfs = try #require(rows.first { $0.id == "gfs_seamless" })
        #expect(gfs.weight == nil && gfs.miss == 2.82)
        #expect(TrackRecordText.rowLabel(gfs, .high, units: metric, basis: .archive)
                == "NOAA GFS: average miss 2.8\u{00A0}degrees Celsius over 59 days. Not in today's blend")
    }

    @Test func tooFewDaysGoesLastWithItsCount() throws {
        let forecast = try self.forecast { record in
            var archive = record["archive"] as! [String: Any]
            var sources = archive["sources"] as! [[String: Any]]
            let i = sources.firstIndex { ($0["id"] as! String) == "gem_seamless" && ($0["lead"] as! Int) == 1 }!
            var high = sources[i]["high"] as! [String: Any]
            high["miss"] = NSNull()
            high["days"] = 12
            sources[i]["high"] = high
            archive["sources"] = sources
            record["archive"] = archive
        }
        let rows = facts(forecast).rows(.high, lead: 1, basis: .archive)
        let last = try #require(rows.last)
        #expect(last.id == "gem_seamless" && last.miss == nil && last.days == 12)
        #expect(TrackRecordText.missValue(last.miss, .high, units: metric) == ValueText.missing)
        #expect(TrackRecordText.rowLabel(last, .high, units: metric, basis: .archive) == "Env. Canada: Too few days (12)")
    }

    // MARK: Units

    @Test func missesConvertAsDifferences() {
        #expect(TrackRecordText.missValue(0.96, .high, units: metric) == "1.0")
        #expect(TrackRecordText.missValue(0.96, .high, units: imperial) == "1.7")   // x 1.8, no +32
        #expect(TrackRecordText.missValue(2.83, .low, units: imperial) == "5.1")
        #expect(TrackRecordText.missValue(3.03, .rain, units: metric) == "3.0")
        #expect(TrackRecordText.missValue(3.03, .rain, units: imperial) == "0.12")  // mm / 25.4
        #expect(TrackRecordText.missWithUnit(3.03, .rain, units: imperial) == "0.12\u{00A0}in")
        #expect(TrackRecordText.missWithUnit(0.96, .high, units: metric) == "1.0\u{00A0}°C")
        #expect(TrackRecordText.missHead(.rain, lead: 7, units: imperial) == "AVERAGE MISS, DAY 7 RAIN, IN")
        #expect(TrackRecordText.missHead(.high, lead: 1, units: metric) == "AVERAGE MISS, DAY 1 HIGHS, °C")
    }

    @Test func habitFixPillIsTheOppositeOfTheHabit() {
        #expect(TrackRecordText.fixPill(0.57, unit: .celsius) == "\u{2212}0.6°")    // runs warm: we take it off
        #expect(TrackRecordText.fixPill(0.57, unit: .fahrenheit) == "\u{2212}1.0°")
        #expect(TrackRecordText.fixPill(-1.1, unit: .celsius) == "+1.1°")           // runs cold: we add it
        #expect(TrackRecordText.fixPill(0.02, unit: .celsius) == "0.0°")
        #expect(TrackRecordText.fixPill(-0.04, unit: .celsius) == "0.0°")           // never "−0.0"
        #expect(TrackRecordText.fixDirection(0.57, unit: .celsius) == .down)
        #expect(TrackRecordText.fixDirection(-1.1, unit: .celsius) == .up)
        #expect(TrackRecordText.fixDirection(0.02, unit: .celsius) == TrackRecordText.FixDirection.none)
        #expect(TrackRecordText.fixPill(nil, unit: .celsius) == ValueText.missing)
    }

    @Test func habitSentencesInBothUnits() {
        let warm = TrackRecordFacts.Habit(id: "meteofrance_seamless", name: "Météo-France", bias: 3.49, days: 29)
        let cold = TrackRecordFacts.Habit(id: "gfs_seamless", name: "NOAA GFS", bias: -0.74, days: 29)
        let even = TrackRecordFacts.Habit(id: "jma_seamless", name: "Japan JMA", bias: -0.04, days: 29)
        #expect(TrackRecordText.habitSentence(warm, .high, unit: .celsius) == "Highs run 3.5\u{00A0}°C warm here")
        #expect(TrackRecordText.habitSentence(warm, .high, unit: .fahrenheit) == "Highs run 6.3\u{00A0}°F warm here")
        #expect(TrackRecordText.habitSentence(cold, .low, unit: .celsius) == "Lows run 0.7\u{00A0}°C cold here")
        #expect(TrackRecordText.habitSentence(even, .low, unit: .celsius) == "Lows right on average here")
        #expect(TrackRecordText.habitLabel(warm, .high, unit: .celsius)
                == "Météo-France: Highs run 3.5\u{00A0}°C warm here, over 29 days. The fix takes 3.5° off")
        #expect(TrackRecordText.habitLabel(cold, .high, unit: .celsius).hasSuffix("The fix adds 0.7°"))
    }

    @Test func habitsAreLargestFirstForHighsAndLowsOnly() throws {
        let facts = facts(try Fixture.trackRecordForecast())
        let highs = facts.habits(.high)
        #expect(highs.count == 9)
        #expect(highs.first?.name == "Météo-France" && highs.first?.bias == 3.49)
        #expect(highs.map { abs($0.bias ?? 0) } == highs.map { abs($0.bias ?? 0) }.sorted(by: >))
        #expect(facts.habits(.low).first?.bias == 4.44)
        #expect(facts.habits(.rain).isEmpty)
    }

    // MARK: Our own record

    @Test func liveRecordTooShortShowsTheCountNeverArchiveNumbers() throws {
        let facts = facts(try Fixture.trackRecordForecast())
        let status = try #require(facts.liveStatus(lead: 1))
        #expect(status == .init(days: 0, minDays: 20, since: LocalDate("2026-11-25")))
        #expect(!status.enough)
        #expect(!facts.liveHasNumbers(.high, lead: 1))
        #expect(TrackRecordText.liveTooFew(status, lead: 1)
                == "Our own record started \(ValueText.dayMonth(LocalDate("2026-11-25")!)): 0 of the 20 days needed for day 1 so far. Too few to score, so none of it is shown yet.")
        // the live rows hold no archive numbers
        let live = facts.rows(.high, lead: 1, basis: .live)
        #expect(live.count == 1 && live[0].isConsensus && live[0].miss == nil)
    }

    @Test func liveRecordNotStarted() {
        let status = TrackRecordFacts.LiveStatus(days: 0, minDays: 20, since: nil)
        #expect(TrackRecordText.liveTooFew(status, lead: 1) == "Our own record has not started here yet.")
    }

    @Test func liveRecordWithEnoughDaysStandsOnItsOwn() throws {
        let forecast = try self.forecast { record in
            var live = record["live"] as! [String: Any]
            live["days"] = [["lead": 1, "days": 25], ["lead": 7, "days": 12], ["lead": 13, "days": 0]]
            live["sources"] = [
                ["id": "gem_seamless", "lead": 1, "high": ["miss": 1.4, "days": 25], "low": ["miss": 1.1, "days": 25]],
                ["id": "ecmwf_ifs", "lead": 1, "high": ["miss": 1.2, "days": 24]],
                ["id": "ecmwf_ifs", "lead": 7, "high": ["miss": NSNull(), "days": 12]],
            ]
            record["live"] = live
        }
        let facts = facts(forecast)
        #expect(facts.liveHasNumbers(.high, lead: 1))
        #expect(!facts.liveHasNumbers(.rain, lead: 1))          // no live rain miss: archive only
        #expect(!facts.liveHasNumbers(.high, lead: 7))          // 12 of 20 days
        let rows = facts.rows(.high, lead: 1, basis: .live)
        #expect(rows.map(\.id) == [TrackRecordFacts.consensusID, "ecmwf_ifs", "gem_seamless"])
        #expect(rows.map(\.miss) == [nil, 1.2, 1.4])          // live values, not the archive's 1.31 and 1.03
        #expect(rows.allSatisfy { $0.weight == nil })
        #expect(TrackRecordText.rowLabel(rows[0], .high, units: metric, basis: .live) == "Consensus: Not recorded yet")
    }

    @Test func fixPillsAndNotesHaveEnoughContrast() {
        for direction in [TrackRecordText.FixDirection.up, .down, .none] {
            let tint = Palette.fixPill(direction)
            #expect(tint.ink.contrast(with: tint.fill) >= 4.5)
        }
        #expect(Palette.textSecondary.contrast(with: Palette.cardInner) >= 4.5)  // notes and live box
        #expect(Palette.textBody.contrast(with: Palette.cardInner) >= 4.5)
        #expect(Palette.ink.contrast(with: Palette.white) >= 4.5)                // chosen segment
    }

    // MARK: Words

    @Test func sourceLineSaysWhereNumbersComeFrom() throws {
        let record = try #require(try Fixture.trackRecordForecast().trackRecord)
        #expect(TrackRecordText.archiveSource(record, stationName: "Kitimat Forest Ave")
                == "From each source's archived forecasts, scored against Kitimat Forest Ave for the 60 days \(d("2026-09-27")) to \(d("2026-11-25")). Not our own record. Station data through \(d("2026-11-24")).")
        #expect(TrackRecordText.habitSource(record).hasPrefix("Averaged over the 30 days \(d("2026-10-27")) to \(d("2026-11-25"))"))
    }

    @Test func everyNewStringKeepsUnitsJoined() throws {
        let facts = facts(try Fixture.trackRecordForecast())
        var texts: [String] = []
        for units in [metric, imperial] {
            for variable in TrackVariable.allCases {
                for lead in facts.leads {
                    for row in facts.rows(variable, lead: lead, basis: .archive) {
                        texts.append(TrackRecordText.rowLabel(row, variable, units: units, basis: .archive))
                        texts.append(TrackRecordText.missWithUnit(row.miss, variable, units: units))
                    }
                }
            }
            for habit in facts.habits(.high) + facts.habits(.low) {
                texts.append(TrackRecordText.habitLabel(habit, .high, unit: units.temperature))
            }
        }
        for text in texts {
            #expect(!text.contains(" °") && !text.contains(" mm") && !text.hasSuffix(" in") && !text.contains(" degrees"), "\(text)")
        }
    }
}
