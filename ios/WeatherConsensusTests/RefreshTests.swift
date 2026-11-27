import Foundation
import Testing
@testable import WeatherConsensus

private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

/// A clock the test moves by hand.
@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func callAsFunction() -> Date { now }
}

/// Counts fetches; each one waits `delay` and returns the fixture issued `hours` after the real file.
actor FakeServer {
    private(set) var calls = 0
    var issuedHoursLater = 0
    var delay: Duration = .zero
    var offline = false

    func set(hours: Int) { issuedHoursLater = hours }
    func set(delay: Duration) { self.delay = delay }
    func set(offline: Bool) { self.offline = offline }

    func fetch() async throws -> Data {
        calls += 1
        let hours = issuedHoursLater
        if delay != .zero { try await Task.sleep(for: delay) }
        if offline { throw URLError(.notConnectedToInternet) }
        return try Fixture.data(issuedHoursLater: hours)
    }
}

@Suite("When to refresh")
struct RefreshPolicyTests {
    @Test func nextFileIsExpectedFromMinute15OfTheNextHour() {
        #expect(RefreshPolicy.nextExpectedIssue(after: utc("2026-11-27T13:11:20Z")) == utc("2026-11-27T14:15:00Z"))
        #expect(RefreshPolicy.nextExpectedIssue(after: utc("2026-11-27T13:58:00Z")) == utc("2026-11-27T14:15:00Z"))
        // A file from before minute 15 (a nightly run, say): the hourly one is due the same hour.
        #expect(RefreshPolicy.nextExpectedIssue(after: utc("2026-11-27T13:05:00Z")) == utc("2026-11-27T13:15:00Z"))
        #expect(RefreshPolicy.nextExpectedIssue(after: utc("2026-11-27T13:15:00Z")) == utc("2026-11-27T14:15:00Z"))
    }

    @Test func dueRules() {
        let issued = utc("2026-11-27T13:11:00Z")
        func due(_ now: String, last: String? = nil, issued: Date? = issued) -> Bool {
            RefreshPolicy.isDue(issuedAt: issued, lastAttempt: last.map(utc), now: utc(now))
        }
        #expect(due("2026-11-27T13:30:00Z", issued: nil))      // nothing on screen
        #expect(!due("2026-11-27T13:30:00Z"))                   // 19 min old, next not out yet
        #expect(!due("2026-11-27T14:10:00Z"))                   // 59 min old, 14:10 run not out
        #expect(due("2026-11-27T14:11:01Z"))                    // just over an hour old
        #expect(due("2026-11-27T14:15:00Z"))                    // the next hourly file should be out
        #expect(!due("2026-11-27T14:09:00Z", issued: utc("2026-11-27T13:10:00Z")))  // 59 min, 14:10 run not out
        #expect(due("2026-11-27T14:11:00Z", issued: utc("2026-11-27T13:10:00Z")))   // 61 min: over an hour
        #expect(due("2026-11-27T14:11:00Z", issued: utc("2026-11-27T13:05:00Z")))  // over an hour old
        #expect(due("2026-11-27T14:16:00Z", issued: utc("2026-11-27T13:58:00Z")))  // 18 min old, but a newer one is due
        #expect(!due("2026-11-27T15:00:00Z", last: "2026-11-27T14:59:30Z"))        // tried 30 s ago
        #expect(due("2026-11-27T15:00:00Z", last: "2026-11-27T14:58:59Z"))
    }
}

@MainActor
@Suite("Refresh on return and on every tab")
struct RefreshModelTests {
    private func model(_ server: FakeServer, clock: TestClock, store: ForecastStore = makeTemporaryStore()) -> ForecastScreenModel {
        let loader = ForecastLoader(store: store) { _ in try await server.fetch() }
        return ForecastScreenModel(placeID: "kitimat", loader: loader, clock: { clock() })
    }

    @Test func returningToTheAppLoadsOnlyWhenDue() async throws {
        let issued = try Fixture.forecast().issuedAt    // 25 Nov 2026 04:07:24 UTC, before that hour's run
        let clock = TestClock(utc("2026-11-25T04:10:00Z"))
        let server = FakeServer()
        let model = model(server, clock: clock)

        await model.refreshIfDue()                       // launch, nothing on screen: loads
        #expect(await server.calls == 1)
        clock.now = utc("2026-11-25T04:14:00Z")         // back to the foreground: 04:10 run not out yet
        await model.refreshIfDue()
        #expect(await server.calls == 1)
        clock.now = utc("2026-11-25T04:15:00Z")         // it should be out now
        await server.set(hours: 1)
        await model.refreshIfDue()
        #expect(await server.calls == 2)
        #expect(model.forecast?.issuedAt == issued.addingTimeInterval(3600))
        clock.now = utc("2026-11-25T05:14:00Z")         // 05:07 file: the 05:10 run is not out yet
        await model.refreshIfDue()
        #expect(await server.calls == 2)
        clock.now = utc("2026-11-25T05:20:00Z")
        await model.refreshIfDue()
        #expect(await server.calls == 3)
    }

    @Test func savedCopyOverAnHourOldIsDueOnLaunchWhateverTheTab() async throws {
        let store = makeTemporaryStore()
        try store.save(Fixture.data(), placeID: "kitimat")
        let clock = TestClock(utc("2026-11-25T09:00:00Z"))
        let server = FakeServer()
        let model = model(server, clock: clock, store: store)
        model.showSavedCopy()                            // the first frame, on Consensus or Places
        await model.refreshIfDue()
        #expect(await server.calls == 1)
    }

    @Test func aFailedAttemptIsNotRepeatedOnEveryTabSwitch() async throws {
        let clock = TestClock(utc("2026-11-25T09:00:00Z"))
        let server = FakeServer()
        await server.set(offline: true)
        let model = model(server, clock: clock)
        await model.refreshIfDue()
        await model.refreshIfDue()                       // another tab appears 0 s later
        #expect(await server.calls == 1)
        clock.now = clock.now.addingTimeInterval(61)
        await model.refreshIfDue()
        #expect(await server.calls == 2)
        await model.load()                               // pull to refresh always tries
        #expect(await server.calls == 3)
    }

    @Test func overlappingLoadsShareOneRequest() async throws {
        let clock = TestClock(utc("2026-11-25T09:00:00Z"))
        let server = FakeServer()
        await server.set(delay: .milliseconds(200))
        let model = model(server, clock: clock)
        async let a: Void = model.load()                 // foreground
        async let b: Void = model.load()                 // pull to refresh at the same moment
        async let c: Void = model.refreshIfDue()         // a tab appears
        _ = await (a, b, c)
        #expect(await server.calls == 1)
        #expect(model.forecast != nil)
        await model.load()                               // once it is done, a new load is a new request
        #expect(await server.calls == 2)
    }

    @Test func anOlderIssueNeverReplacesANewerOne() async throws {
        let clock = TestClock(utc("2026-11-25T09:00:00Z"))
        let server = FakeServer()
        let store = makeTemporaryStore()
        let model = model(server, clock: clock, store: store)
        let issued = try Fixture.forecast().issuedAt
        await server.set(hours: 2)
        await model.load()
        #expect(model.forecast?.issuedAt == issued.addingTimeInterval(7200))
        await server.set(hours: 1)                       // a cache hands out the previous file
        await model.load()
        #expect(model.forecast?.issuedAt == issued.addingTimeInterval(7200))
        #expect(store.savedForecast(placeID: "kitimat")?.issuedAt == issued.addingTimeInterval(7200))
        #expect(model.problem == nil)
        await server.set(hours: 3)
        await model.load()
        #expect(model.forecast?.issuedAt == issued.addingTimeInterval(3 * 3600))
    }

    @Test func loaderKeepsTheNewerSavedFile() async throws {
        let store = makeTemporaryStore()
        try store.save(Fixture.data(issuedHoursLater: 2), placeID: "kitimat")
        let loader = ForecastLoader(store: store) { _ in try Fixture.data() }
        let result = await loader.load(placeID: "kitimat")
        let issued = try Fixture.forecast().issuedAt
        #expect(result.origin == .savedCopy && result.problem == nil)
        #expect(result.forecast?.issuedAt == issued.addingTimeInterval(7200))
        #expect(store.savedForecast(placeID: "kitimat")?.issuedAt == issued.addingTimeInterval(7200))
    }
}

@Suite("No Certainty without a high")
struct CertaintyNeedsAHighTests {
    @Test func aDayWithNoHighShowsNoCertaintyOrTier() throws {
        var object = try Fixture.jsonObject()
        var days = object["days"] as! [[String: Any]]
        days[2]["high"] = NSNull()  // an older file could still say 80% and High here
        days[2]["certainty"] = 80
        days[2]["tier"] = "High"
        object["days"] = days
        let forecast = try ForecastDecoder.decode(Fixture.encode(object))
        let day = forecast.days[2]
        #expect(day.high == nil && day.certainty == nil && day.tier == nil && day.certaintyTier == nil)
        #expect(day.low != nil)
        #expect(forecast.days[0].certainty != nil && forecast.days[0].high != nil)
    }
}
