import Foundation
import Testing
@testable import WeatherConsensus

/// The backtest file: downloaded only when the place file's hash changes, one saved copy per place,
/// shown from that copy when offline, and never able to touch the forecast.
@Suite("Backtest file")
struct BacktestLoaderTests {
    /// Counts downloads and answers with the given bytes per URL path (or an error).
    final class FakeSite: @unchecked Sendable {
        var answers: [String: Result<Data, URLError>] = [:]
        private(set) var calls: [URL] = []
        private let lock = NSLock()

        func fetch(_ url: URL) throws -> Data {
            lock.withLock { calls.append(url) }
            guard let answer = answers[url.path()] else { throw URLError(.fileDoesNotExist) }
            return try answer.get()
        }
    }

    private let backtestPath = "/weather-consensus/backtest/kitimat.json"
    private let placePath = "/weather-consensus/kitimat.json"

    private func loader(_ site: FakeSite, store: ForecastStore = makeTemporaryStore()) -> BacktestLoader {
        BacktestLoader(store: store) { url in try site.fetch(url) }
    }

    private func ref(for data: Data) -> BacktestRef {
        BacktestRef(path: "backtest/kitimat.json", sha256: BacktestLoader.sha256(data), bytes: data.count)
    }

    /// The real backtest file with one number changed: a new version.
    private func otherVersion() throws -> Data {
        var bt = try Fixture.backtestObject()
        bt["scored_to"] = "2026-11-30"
        return try Fixture.encode(bt)
    }

    @Test func hashMatchesWhatTheBackendPublished() throws {
        // f9e8...: SHA-256 printed by publish.backtest_pointer for the same bytes (Python hashlib)
        #expect(BacktestLoader.sha256(try Fixture.backtestData())
                == "f9e8a90b62bbea8b4003d20a5d3fd6b2b26a53f5efb014c515b9464cc1e8131d")
    }

    @Test func versionUnchangedMeansNoDownload() async throws {
        let data = try Fixture.backtestData()
        let site = FakeSite()
        site.answers[backtestPath] = .success(data)
        let loader = loader(site)
        #expect(await loader.load(placeID: "kitimat", ref: ref(for: data)) != nil)
        #expect(site.calls.count == 1)
        for _ in 0..<5 {
            #expect(await loader.load(placeID: "kitimat", ref: ref(for: data))?.scoredTo == LocalDate("2026-10-30"))
        }
        #expect(site.calls.count == 1)  // saved copy, same hash: never downloaded again
    }

    @Test func versionChangedMeansOneDownloadAndTheOldCopyIsReplaced() async throws {
        let old = try Fixture.backtestData()
        let new = try otherVersion()
        let site = FakeSite()
        let store = makeTemporaryStore()
        let loader = loader(site, store: store)
        site.answers[backtestPath] = .success(old)
        _ = await loader.load(placeID: "kitimat", ref: ref(for: old))
        site.answers[backtestPath] = .success(new)
        let b = await loader.load(placeID: "kitimat", ref: ref(for: new))
        #expect(b?.scoredTo == LocalDate("2026-11-30"))
        #expect(site.calls.count == 2)
        #expect(store.savedData(placeID: "kitimat") == new)
        #expect(store.storedFiles().map(\.lastPathComponent) == ["kitimat.json"])  // one file per place
        _ = await loader.load(placeID: "kitimat", ref: ref(for: new))
        #expect(site.calls.count == 2)
    }

    @Test func offlineShowsTheSavedCopy() async throws {
        let old = try Fixture.backtestData()
        let site = FakeSite()
        let loader = loader(site)
        site.answers[backtestPath] = .success(old)
        _ = await loader.load(placeID: "kitimat", ref: ref(for: old))
        site.answers[backtestPath] = .failure(URLError(.notConnectedToInternet))
        // a newer version is named but cannot be fetched: the saved one stays on screen
        let b = await loader.load(placeID: "kitimat", ref: ref(for: try otherVersion()))
        #expect(b?.scoredTo == LocalDate("2026-10-30"))
        #expect(loader.saved(placeID: "kitimat", ref: ref(for: old)) != nil)
    }

    @Test func missingFileHidesTheCard() async throws {
        let site = FakeSite()  // every request: file does not exist
        let b = await loader(site).load(placeID: "kitimat", ref: ref(for: try Fixture.backtestData()))
        #expect(b == nil)
    }

    @Test func unreadableOrWrongHashIsNeverSaved() async throws {
        let site = FakeSite()
        let store = makeTemporaryStore()
        let loader = loader(site, store: store)
        let junk = Data("{\"basis\":\"backtest\",\"leads\":\"seven\"}".utf8)
        site.answers[backtestPath] = .success(junk)
        #expect(await loader.load(placeID: "kitimat", ref: ref(for: junk)) == nil)  // hash matches, unreadable
        let real = try Fixture.backtestData()
        site.answers[backtestPath] = .success(real)
        #expect(await loader.load(placeID: "kitimat", ref: ref(for: try otherVersion())) == nil)  // hash differs
        #expect(store.storedFiles().isEmpty)
    }

    @Test func noPointerNoCardAndNoDownload() async throws {
        let site = FakeSite()
        #expect(await loader(site).load(placeID: "kitimat", ref: nil) == nil)
        #expect(site.calls.isEmpty)
    }

    @Test func pointerCanOnlyNameThisPlacesFileOnTheSameHost() throws {
        let data = try Fixture.backtestData()
        #expect(ref(for: data).url(placeID: "kitimat")?.absoluteString
                == "https://deirdeezy.github.io/weather-consensus/backtest/kitimat.json")
        for path in ["backtest/terrace.json", "../kitimat.json", "https://example.com/x.json", "backtest/kitimat.json?x=1"] {
            #expect(BacktestRef(path: path, sha256: "", bytes: nil).url(placeID: "kitimat") == nil, "\(path)")
        }
    }

    @Test func brokenBacktestNeverTouchesTheForecast() async throws {
        let placeData = try Fixture.trackRecordData()
        let site = FakeSite()
        site.answers[placePath] = .success(placeData)
        site.answers[backtestPath] = .success(Data("not json".utf8))
        let fetch: ForecastLoader.Fetch = { url in try site.fetch(url) }
        let model = ForecastScreenModel(placeID: "kitimat",
                                        loader: ForecastLoader(store: makeTemporaryStore(), fetch: fetch),
                                        backtests: BacktestLoader(store: makeTemporaryStore(), fetch: fetch))
        await model.load()
        #expect(model.forecast?.days.count == 14 && model.problem == nil)
        #expect(model.backtest == nil)
    }

    @Test func modelShowsTheCardWhenTheFileIsGood() async throws {
        let site = FakeSite()
        site.answers[placePath] = .success(try Fixture.trackRecordData())
        site.answers[backtestPath] = .success(try Fixture.backtestData())
        let fetch: ForecastLoader.Fetch = { url in try site.fetch(url) }
        let model = ForecastScreenModel(placeID: "kitimat",
                                        loader: ForecastLoader(store: makeTemporaryStore(), fetch: fetch),
                                        backtests: BacktestLoader(store: makeTemporaryStore(), fetch: fetch))
        await model.load()
        await model.load()
        #expect(model.backtest?.leads.count == 7)
        #expect(site.calls.filter { $0.path() == backtestPath }.count == 1)  // second load: hash unchanged
    }

    @Test func privacyPolicyNamesTheSecondFileOnTheSameSite() {
        let all = PrivacyText.sections.flatMap(\.paragraphs).joined(separator: " ")
        #expect(all.contains("from the same site a public file of test results"))
        #expect(PrivacyText.updated == "Last updated 27 November 2026")
        #expect(BacktestRef(path: "backtest/kitimat.json", sha256: "", bytes: nil)
            .url(placeID: "kitimat")?.host() == ForecastEndpoint.host)
    }
}
