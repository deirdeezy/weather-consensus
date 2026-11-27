import Foundation
import Testing
@testable import WeatherConsensus

/// The "Tested on real Kitimat weather" card: only numbers from the file's `backtest` block, labelled as a
/// backtest, and our own live consensus kept apart in the track record.
@Suite("Tested card")
struct TestedCardTests {
    private func forecast() throws -> PlaceForecast { try Fixture.trackRecordForecast() }

    @Test func backtestParsesFromTheFile() throws {
        let b = try #require(try forecast().backtest)
        #expect(b.basis == "backtest" && b.baseline == "ecmwf_ifs")
        #expect(b.scoredFrom == LocalDate("2026-01-01") && b.scoredTo == LocalDate("2026-10-30"))
        #expect(b.method?.pastDataOnly == true)
        #expect(b.leads.map(\.lead) == Array(1...7))
        let high = try #require(b.leads[0].high)
        #expect(high.consensus == 1.004 && high.baseline == 1.424 && high.days == 285)
        #expect(high.sources?.count == 9)
    }

    @Test func headingCountsTheScoredMonthsNotAYear() throws {
        let b = try #require(try forecast().backtest)
        #expect(TestedText.months(b) == 10)
        #expect(TestedText.heading(b, placeName: "Kitimat") == "TESTED ON 10 MONTHS OF REAL KITIMAT WEATHER")
    }

    @Test func tilesAndSentenceComeFromTheTwoNumbers() throws {
        let f = try forecast()
        let b = try #require(f.backtest)
        let names = SourceNames(f)
        #expect(TestedText.tileValue(1.004, unit: .celsius) == "1.0°")
        #expect(TestedText.tileValue(1.424, unit: .celsius) == "1.4°")
        #expect(TestedText.tileValue(1.004, unit: .fahrenheit) == "1.8°")  // a difference: x 1.8
        #expect(TestedText.tileValue(1.424, unit: .fahrenheit) == "2.6°")
        #expect(TestedText.baselineName(b, names: names) == "One model alone (ECMWF)")
        #expect(TestedText.closer(b.leads[0].high) == 29)   // 1 - 1.004 / 1.424
        #expect(TestedText.closer(b.leads[0].low) == 32)    // 1 - 1.008 / 1.475
        #expect(TestedText.sentence(b, names: names) == "29% closer than ECMWF alone on day 1 highs, and 32% on lows.")
    }

    @Test func methodSaysBacktestPastDataOnlyAndPeriod() throws {
        let b = try #require(try forecast().backtest)
        let text = TestedText.method(b)
        #expect(text.contains("only data from before it"))
        #expect(text.contains("Kitimat Forest Ave"))
        #expect(text.contains(TestedText.dayMonthYear(LocalDate("2026-01-01")!)))
        #expect(text.contains(TestedText.dayMonthYear(LocalDate("2026-10-30")!)))
        #expect(text.contains("285 days") && text.hasSuffix("Not our own live record."))
    }

    @Test func noClaimsTheBacktestDoesNotMake() throws {
        let f = try forecast()
        let b = try #require(f.backtest)
        let all = [TestedText.heading(b, placeName: "Kitimat"), TestedText.sentence(b, names: SourceNames(f)) ?? "",
                   TestedText.method(b), TestedText.tilesLabel(b, names: SourceNames(f), unit: .celsius)].joined(separator: " ")
        for claim in ["free default", "a year", "About 30%", "rain"] {
            #expect(!all.contains(claim), "\(claim)")
        }
    }

    /// The backtest with one source's day `lead` low set to `miss` (consensus miss there stays as published).
    private func backtest(lowMiss miss: Double, lead: Int, source: String = "jma_seamless") throws -> Backtest {
        var object = try Fixture.trackRecordObject()
        var bt = object["backtest"] as! [String: Any]
        var leads = bt["leads"] as! [[String: Any]]
        let i = leads.firstIndex { ($0["lead"] as! Int) == lead }!
        var low = leads[i]["low"] as! [String: Any]
        var sources = low["sources"] as! [[String: Any]]
        let j = sources.firstIndex { ($0["id"] as! String) == source }!
        sources[j]["miss"] = miss == .infinity ? sources[j]["consensus"]! : miss
        low["sources"] = sources
        leads[i]["low"] = low
        bt["leads"] = leads
        object["backtest"] = bt
        return try #require(try ForecastDecoder.decode(Fixture.encode(object)).backtest)
    }

    @Test func everySourceLineFollowsTheRealResults() throws {
        let b = try #require(try forecast().backtest)
        let d1 = try #require(b.leads.first?.high?.sources)
        #expect(d1.count == 9 && d1.allSatisfy(\.consensusCloser))
        #expect(TestedText.closerThroughLead(b) == 7)
        #expect(TestedText.everySourceLine(b) == "Closer than every single source on highs and lows, at every range from 1 to 7 days.")
    }

    @Test func aLossIsNeverRoundedIntoAWin() throws {
        // a loss at day 3 on lows: the line stops at day 2
        #expect(TestedText.everySourceLine(try backtest(lowMiss: 0.5, lead: 3)) == "Closer than every single source on highs and lows at days 1 to 2.")
        // a tie is not a win
        let tie = try backtest(lowMiss: .infinity, lead: 2)
        #expect(TestedText.closerThroughLead(tie) == 1)
        #expect(TestedText.everySourceLine(tie) == "Closer than every single source on highs and lows on day\u{00A0}1.")
        // a loss at day 1: no line at all
        #expect(TestedText.everySourceLine(try backtest(lowMiss: 0.5, lead: 1)) == nil)
    }

    @Test func noComparisonInTheFileMeansNoLine() throws {
        var object = try Fixture.trackRecordObject()
        var bt = object["backtest"] as! [String: Any]
        bt["leads"] = (bt["leads"] as! [[String: Any]]).map { lead in
            var lead = lead
            for name in ["high", "low", "rain"] {
                var v = lead[name] as! [String: Any]
                v.removeValue(forKey: "sources")
                lead[name] = v
            }
            return lead
        }
        object["backtest"] = bt
        let b = try #require(try ForecastDecoder.decode(Fixture.encode(object)).backtest)
        #expect(TestedText.everySourceLine(b) == nil)
        #expect(TestedText.sentence(b, names: SourceNames(try forecast())) != nil)  // the ECMWF numbers stay
    }

    @Test func notCloserIsSaidPlainly() throws {
        let f = try forecast()
        var object = try Fixture.trackRecordObject()
        var bt = object["backtest"] as! [String: Any]
        var leads = bt["leads"] as! [[String: Any]]
        leads[0]["high"] = ["consensus": 1.5, "baseline": 1.4, "days": 285]
        bt["leads"] = leads
        object["backtest"] = bt
        let b = try #require(try ForecastDecoder.decode(Fixture.encode(object)).backtest)
        #expect(TestedText.closer(b.leads[0].high) == -7)
        let sentence = try #require(TestedText.sentence(b, names: SourceNames(f)))
        #expect(sentence.hasPrefix("Day 1 highs: ") && sentence.contains("7% against ECMWF alone; lows: 32%."))
        #expect(!sentence.contains("closer"))
    }

    @Test func noBlockNoCardAndAnUnreadableBlockIsDropped() throws {
        #expect(try Fixture.forecast().backtest == nil)
        var object = try Fixture.trackRecordObject()
        object["backtest"] = ["basis": "backtest", "leads": "seven"]
        let f = try ForecastDecoder.decode(Fixture.encode(object))
        #expect(f.backtest == nil && f.days.count == 14 && f.trackRecord != nil)
    }

    @Test func liveConsensusFillsTheConsensusRowOnlyFromOurRecord() throws {
        var object = try Fixture.trackRecordObject()
        var record = object["track_record"] as! [String: Any]
        var live = record["live"] as! [String: Any]
        live["days"] = [["lead": 1, "days": 22], ["lead": 7, "days": 0], ["lead": 13, "days": 0]]
        live["consensus"] = [["lead": 1, "high": ["miss": 0.88, "days": 22], "low": ["miss": NSNull(), "days": 3],
                              "rain": ["miss": 2.5, "days": 22]]]
        live["sources"] = [["id": "gem_seamless", "lead": 1, "high": ["miss": 1.1, "days": 22]]]
        record["live"] = live
        object["track_record"] = record
        let facts = TrackRecordFacts(try ForecastDecoder.decode(Fixture.encode(object)))
        let high = facts.rows(.high, lead: 1, basis: .live)
        #expect(high[0].isConsensus && high[0].miss == 0.88 && high[0].days == 22)   // not the archive's 0.96
        let low = facts.rows(.low, lead: 1, basis: .live)
        #expect(low[0].miss == nil && low[0].days == 3)
        #expect(TrackRecordText.rowLabel(low[0], .low, units: .metric, basis: .live) == "Consensus: Too few days (3)")
    }

    @Test func tileColoursKeepContrast() {
        #expect(Palette.white.contrast(with: Palette.heroPanel) >= 4.5)
        #expect(Palette.textSecondary.contrast(with: Palette.heroPanel) >= 4.5)
        #expect(Palette.textSecondary.contrast(with: Palette.testedBaseline) >= 4.5)
    }
}
