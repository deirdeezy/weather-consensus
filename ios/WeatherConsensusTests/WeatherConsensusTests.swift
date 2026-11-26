import Foundation
import Testing
@testable import WeatherConsensus

// All tests use the fixture: a saved copy of the live kitimat.json (see Fixture.swift).
// No test touches the network.

@Suite("Decoding schema v1")
struct DecodingTests {
    @Test func fixtureDecodesAllFourteenDays() throws {
        let forecast = try Fixture.forecast()
        #expect(forecast.schemaVersion == 1)
        #expect(forecast.place.id == "kitimat")
        #expect(forecast.place.name == "Kitimat")
        #expect(forecast.place.truthStation?.id == "1064324")
        #expect(forecast.place.consensusOnly == false)
        #expect(forecast.issuedAt == Date(timeIntervalSince1970: 1_795_579_644)) // 2026-11-25T04:07:24Z
        #expect(forecast.issueDate == LocalDate("2026-11-24"))
        #expect(forecast.staleAfterHours == 6)
        #expect(forecast.stale == false)
        #expect(forecast.units.temperature == "degC")
        #expect(forecast.sources.count == 10)
        #expect(forecast.days.map(\.day) == Array(1...14))
        #expect(forecast.credits.contains { $0.text == "Weather data by Open-Meteo.com" })
    }

    @Test func dayOneMatchesTheFile() throws {
        let day1 = try #require(try Fixture.forecast().days.first)
        #expect(day1.date == LocalDate("2026-11-25"))
        #expect(day1.high == 6.3)
        #expect(day1.low == 2.4)
        #expect(day1.precipMM == 21.2)
        #expect(day1.precipChance == 100)
        #expect(day1.certainty == 91)
        #expect(day1.tier == "High")
        #expect(day1.certaintyTier == .high)
        #expect(day1.weights.count == 9)
        #expect(day1.weights.first?.id == "ukmo_seamless")
    }

    @Test func unknownFieldsAreIgnored() throws {
        var object = try Fixture.jsonObject()
        object["a_field_added_later"] = ["nested": true]
        var days = object["days"] as! [[String: Any]]
        days[0]["wind_kmh"] = 30
        object["days"] = days
        let forecast = try ForecastDecoder.decode(Fixture.encode(object))
        #expect(forecast.days.count == 14)
    }

    @Test func nullValuesDecodeAsMissing() throws {
        var object = try Fixture.jsonObject()
        var days = object["days"] as! [[String: Any]]
        for key in ["high", "low", "precip_mm", "precip_chance", "certainty", "tier"] {
            days[3][key] = NSNull()
        }
        object["days"] = days
        object["newest_run_at"] = NSNull()
        object["fresh_data_at"] = NSNull()
        object["weights_as_of"] = NSNull()
        let forecast = try ForecastDecoder.decode(Fixture.encode(object))
        let day4 = forecast.days[3]
        #expect(day4.high == nil && day4.low == nil && day4.precipMM == nil)
        #expect(day4.precipChance == nil && day4.certainty == nil && day4.certaintyTier == nil)
        #expect(ValueText.temperature(day4.high) == ValueText.missing)
        #expect(forecast.newestRunAt == nil)
    }

    @Test func unknownTierFallsBackToCertainty() throws {
        var object = try Fixture.jsonObject()
        var days = object["days"] as! [[String: Any]]
        days[0]["tier"] = "Very high"   // certainty 91
        days[9]["tier"] = "Something new" // certainty 60
        object["days"] = days
        let forecast = try ForecastDecoder.decode(Fixture.encode(object))
        #expect(forecast.days[0].certaintyTier == .high)
        #expect(forecast.days[9].certaintyTier == .medium)
    }

    @Test(arguments: [(0, CertaintyTier.low), (49, .low), (50, .medium), (74, .medium), (75, .high), (100, .high)])
    func tierBoundaries(certainty: Int, expected: CertaintyTier) {
        #expect(CertaintyTier(certainty: certainty) == expected)
    }

    @Test func fixtureTiersMatchTheirCertainty() throws {
        for day in try Fixture.forecast().days {
            let certainty = try #require(day.certainty)
            #expect(day.certaintyTier == CertaintyTier(certainty: certainty))
        }
    }

    @Test func otherSchemaVersionIsRejected() throws {
        var object = try Fixture.jsonObject()
        object["schema_version"] = 2
        #expect(throws: LoadProblem.unsupportedSchemaVersion(2)) {
            try ForecastDecoder.decode(Fixture.encode(object))
        }
    }

    @Test func missingRequiredFieldIsUnreadable() throws {
        var object = try Fixture.jsonObject()
        object.removeValue(forKey: "days")
        #expect(throws: LoadProblem.self) {
            try ForecastDecoder.decode(Fixture.encode(object))
        }
        #expect(throws: LoadProblem.self) {
            try ForecastDecoder.decode(Data("not json".utf8))
        }
    }
}

@Suite("Storage")
struct StorageTests {
    @Test func fileCountNeverGrowsAfterRepeatedLoads() async throws {
        let store = makeTemporaryStore()
        let hour = Counter()
        let loader = ForecastLoader(store: store) { _ in
            try Fixture.data(issuedHoursLater: await hour.next())
        }

        // A leftover from an interrupted write, as an older copy would be.
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: store.directory.appending(path: "kitimat.json.partial"))

        for round in 1...25 {
            let result = await loader.load(placeID: "kitimat")
            #expect(result.origin == .network)
            #expect(store.storedFiles().count == 1, "round \(round)")
        }
        #expect(store.storedFiles().map(\.lastPathComponent) == ["kitimat.json"])

        // The one file left is the newest one.
        let saved = try #require(store.savedForecast(placeID: "kitimat"))
        let first = try Fixture.forecast()
        #expect(saved.issuedAt == first.issuedAt.addingTimeInterval(24 * 3600))
    }

    @Test func oneFilePerPlace() async throws {
        let store = makeTemporaryStore()
        let loader = ForecastLoader(store: store) { _ in try Fixture.data() }
        for _ in 1...5 {
            _ = await loader.load(placeID: "kitimat")
            _ = await loader.load(placeID: "terrace")
        }
        let names = Set(store.storedFiles().map(\.lastPathComponent))
        #expect(names == ["kitimat.json", "terrace.json"])
    }

    @Test func savedFileKeepsTheRawBytes() async throws {
        let store = makeTemporaryStore()
        let data = try Fixture.data()
        let loader = ForecastLoader(store: store) { _ in data }
        _ = await loader.load(placeID: "kitimat")
        #expect(store.savedData(placeID: "kitimat") == data)
    }

    @Test func storeFolderIsExcludedFromBackup() async throws {
        let store = makeTemporaryStore()
        let loader = ForecastLoader(store: store) { _ in try Fixture.data() }
        _ = await loader.load(placeID: "kitimat")
        let values = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}

@Suite("Loader")
struct LoaderTests {
    @Test func offlineShowsTheLastSavedFile() async throws {
        let store = makeTemporaryStore()
        try store.save(Fixture.data(), placeID: "kitimat")
        let loader = ForecastLoader(store: store) { _ in throw URLError(.notConnectedToInternet) }

        let result = await loader.load(placeID: "kitimat")
        #expect(result.origin == .savedCopy)
        #expect(result.problem == .offline)
        #expect(result.forecast == (try Fixture.forecast()))
    }

    @Test func offlineWithNothingSavedShowsNothing() async {
        let loader = ForecastLoader(store: makeTemporaryStore()) { _ in throw URLError(.notConnectedToInternet) }
        let result = await loader.load(placeID: "kitimat")
        #expect(result.origin == .none)
        #expect(result.forecast == nil)
        #expect(result.problem == .offline)
    }

    @Test func serverErrorShowsTheLastSavedFile() async throws {
        let store = makeTemporaryStore()
        try store.save(Fixture.data(), placeID: "kitimat")
        let loader = ForecastLoader(store: store) { _ in throw LoadProblem.httpStatus(404) }
        let result = await loader.load(placeID: "kitimat")
        #expect(result.origin == .savedCopy)
        #expect(result.problem == .httpStatus(404))
    }

    @Test func newSchemaVersionKeepsTheLastGoodFile() async throws {
        let store = makeTemporaryStore()
        let good = try Fixture.data()
        try store.save(good, placeID: "kitimat")

        var object = try Fixture.jsonObject()
        object["schema_version"] = 2
        let v2 = try Fixture.encode(object)
        let loader = ForecastLoader(store: store) { _ in v2 }

        let result = await loader.load(placeID: "kitimat")
        #expect(result.origin == .savedCopy)
        #expect(result.problem == .unsupportedSchemaVersion(2))
        #expect(result.forecast?.schemaVersion == 1)
        // The unreadable file never replaces the good one.
        #expect(store.savedData(placeID: "kitimat") == good)
    }

    @Test func brokenDownloadNeverReplacesTheGoodFile() async throws {
        let store = makeTemporaryStore()
        let good = try Fixture.data()
        try store.save(good, placeID: "kitimat")
        let loader = ForecastLoader(store: store) { _ in Data("<html>Oops</html>".utf8) }
        let result = await loader.load(placeID: "kitimat")
        #expect(result.origin == .savedCopy)
        #expect(store.savedData(placeID: "kitimat") == good)
    }

    @Test func onlyGitHubPagesIsCalled() throws {
        let url = try #require(ForecastEndpoint.url(for: "kitimat"))
        #expect(url.absoluteString == "https://deirdeezy.github.io/weather-consensus/kitimat.json")
        #expect(ForecastEndpoint.url(for: "../etc") == nil)
        #expect(ForecastEndpoint.url(for: "") == nil)
    }

    @Test func liveLoaderRefusesOtherHosts() async throws {
        let loader = ForecastLoader.live(store: makeTemporaryStore())
        let other = try #require(URL(string: "https://example.com/kitimat.json"))
        await #expect(throws: LoadProblem.self) {
            _ = try await loader.fetch(other)
        }
    }

    @MainActor
    @Test func screenKeepsTheLastGoodForecastWhenRefreshFails() async throws {
        let store = makeTemporaryStore()
        let online = Toggle(true)
        let loader = ForecastLoader(store: store) { _ in
            guard await online.value else { throw URLError(.notConnectedToInternet) }
            return try Fixture.data()
        }
        let model = ForecastScreenModel(placeID: "kitimat", loader: loader)
        await model.load()
        #expect(model.origin == .network)
        #expect(model.forecast?.days.count == 14)

        await online.set(false)
        try FileManager.default.removeItem(at: store.directory) // even with the saved file gone
        await model.load()
        #expect(model.forecast?.days.count == 14)
        #expect(model.problem == .offline)
    }

    /// The first frame draws the saved place's sky, not the default day sky (launch screen hand-over).
    @MainActor
    @Test func savedCopyIsOnScreenBeforeAnyNetworkCall() async throws {
        let store = makeTemporaryStore()
        try store.save(Fixture.data(), placeID: "kitimat")
        let calls = Toggle(false)
        let loader = ForecastLoader(store: store) { _ in
            await calls.set(true)
            throw URLError(.notConnectedToInternet)
        }
        let model = ForecastScreenModel(placeID: "kitimat", loader: loader)
        #expect(model.forecast == nil)
        model.showSavedCopy()
        #expect(model.forecast?.place.name == "Kitimat")
        #expect(model.origin == .savedCopy)
        #expect(await calls.value == false)

        let empty = ForecastScreenModel(placeID: "kitimat", loader: ForecastLoader(store: makeTemporaryStore()) { _ in
            throw URLError(.notConnectedToInternet)
        })
        empty.showSavedCopy()
        #expect(empty.forecast == nil)
    }
}

@Suite("Freshness")
struct FreshnessTests {
    @Test func hoursCountFromFreshDataAt() throws {
        let forecast = try Fixture.forecast()
        // Fixture: fresh_data_at 03:42:10Z, issued_at 04:07:24Z, newest_run_at 2026-11-24T18:00:00Z.
        let fresh = try #require(forecast.freshDataAt)
        #expect(Freshness(forecast: forecast, now: fresh).updatedAt == fresh)
        #expect(Freshness(forecast: forecast, now: fresh).hoursSinceUpdate == 0)
        #expect(Freshness(forecast: forecast, now: fresh.addingTimeInterval(59 * 60)).hoursSinceUpdate == 0)
        #expect(Freshness(forecast: forecast, now: fresh.addingTimeInterval(3 * 3600 + 120)).hoursSinceUpdate == 3)
        // 3 h 10 min after the pull is only 2 h 45 min after issued_at: counts from the pull, so 3.
        #expect(Freshness(forecast: forecast, now: fresh.addingTimeInterval(3 * 3600 + 10 * 60)).hoursSinceUpdate == 3)
        // A phone clock behind the server never shows a negative age.
        #expect(Freshness(forecast: forecast, now: fresh.addingTimeInterval(-600)).hoursSinceUpdate == 0)
    }

    @Test func freshDataAtWinsOverIssuedAtAndNewestRun() throws {
        var object = try Fixture.jsonObject()
        object["fresh_data_at"] = "2026-11-25T01:00:00Z"
        object["issued_at"] = "2026-11-25T05:00:00Z"
        object["newest_run_at"] = "2026-11-24T12:00:00Z"
        let forecast = try ForecastDecoder.decode(Fixture.encode(object))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-25T05:30:00Z"))
        let freshness = Freshness(forecast: forecast, now: now)
        #expect(freshness.updatedAt == forecast.freshDataAt)
        #expect(freshness.hoursSinceUpdate == 4) // not 0 (issued_at) and not 17 (newest_run_at)
        #expect(freshness.updatedText == "Updated 4 hours ago")
    }

    @Test func fallsBackToIssuedAtWhenFreshDataAtIsMissing() throws {
        var object = try Fixture.jsonObject()
        object["fresh_data_at"] = NSNull()
        let withNull = try ForecastDecoder.decode(Fixture.encode(object))
        object.removeValue(forKey: "fresh_data_at")
        let withoutKey = try ForecastDecoder.decode(Fixture.encode(object))
        for forecast in [withNull, withoutKey] {
            #expect(forecast.freshDataAt == nil)
            let issued = forecast.issuedAt
            let freshness = Freshness(forecast: forecast, now: issued.addingTimeInterval(2 * 3600 + 60))
            #expect(freshness.updatedAt == issued)
            #expect(freshness.hoursSinceUpdate == 2)
            #expect(freshness.updatedText == "Updated 2 hours ago")
        }
    }

    @Test func updatedText() throws {
        let forecast = try Fixture.forecast()
        let fresh = try #require(forecast.freshDataAt)
        #expect(Freshness(forecast: forecast, now: fresh).updatedText == "Updated less than an hour ago")
        #expect(Freshness(forecast: forecast, now: fresh.addingTimeInterval(3600)).updatedText == "Updated 1 hour ago")
        #expect(Freshness(forecast: forecast, now: fresh.addingTimeInterval(5 * 3600)).updatedText == "Updated 5 hours ago")
    }

    @Test func freshFileIsNotStale() throws {
        let forecast = try Fixture.forecast()
        // fresh_data_at is 03:42:10Z, issued_at 04:07:24Z, limit 6 h.
        let freshness = Freshness(forecast: forecast, now: forecast.issuedAt.addingTimeInterval(3600))
        #expect(!freshness.isStale)
    }

    @Test func fileStaleFlagIsUsed() throws {
        var object = try Fixture.jsonObject()
        object["stale"] = true
        let forecast = try ForecastDecoder.decode(Fixture.encode(object))
        let freshness = Freshness(forecast: forecast, now: forecast.issuedAt)
        #expect(freshness.fileSaysStale)
        #expect(freshness.isStale)
    }

    @Test func oldFreshDataIsStaleEvenIfTheFileSaysNot() throws {
        let forecast = try Fixture.forecast()
        let freshDataAt = try #require(forecast.freshDataAt)
        // 6 h 1 min after the last pull: stale, though issued_at is only 5.6 h old.
        let now = freshDataAt.addingTimeInterval(6 * 3600 + 60)
        let freshness = Freshness(forecast: forecast, now: now)
        #expect(!freshness.fileSaysStale)
        #expect(freshness.hoursSinceUpdate == 6)
        #expect(freshness.isStale)
    }

    @Test func oldIssuedAtIsStale() throws {
        var object = try Fixture.jsonObject()
        object["fresh_data_at"] = NSNull()
        let forecast = try ForecastDecoder.decode(Fixture.encode(object))
        #expect(!Freshness(forecast: forecast, now: forecast.issuedAt.addingTimeInterval(6 * 3600)).isStale)
        #expect(Freshness(forecast: forecast, now: forecast.issuedAt.addingTimeInterval(6 * 3600 + 1)).isStale)
    }
}

@Suite("Value text")
struct ValueTextTests {
    @Test func dayDateDoesNotShiftWithTimeZone() throws {
        let date = try #require(LocalDate("2026-11-25"))
        #expect(ValueText.date(date).contains("25"))
    }

    @Test func badDatesAreRejected() {
        #expect(LocalDate("2026-13-01") == nil)
        #expect(LocalDate("2026-1-01") == nil)
        #expect(LocalDate("25 Nov 2026") == nil)
    }
}

// Small actors so the @Sendable fetch closures can change state safely.
actor Counter {
    private var value = -1
    func next() -> Int { value += 1; return value }
}

actor Toggle {
    private(set) var value: Bool
    init(_ value: Bool) { self.value = value }
    func set(_ newValue: Bool) { value = newValue }
}
