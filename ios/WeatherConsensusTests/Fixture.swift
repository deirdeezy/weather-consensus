import Foundation
@testable import WeatherConsensus

/// The test fixture: a saved copy of the live `kitimat.json` from GitHub Pages,
/// downloaded 25 Nov 2026 04:30 UTC (issued_at 2026-11-25T04:07:24Z). Real data, not sample data.
/// File: `WeatherConsensusTests/Fixtures/fixture-kitimat-2026-11-25T0407Z.json`.
enum Fixture {
    static let name = "fixture-kitimat-2026-11-25T0407Z"

    private final class BundleToken {}

    static func data() throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        else {
            throw FixtureError.missing
        }
        return try Data(contentsOf: url)
    }

    static func forecast() throws -> PlaceForecast {
        try ForecastDecoder.decode(data())
    }

    /// The fixture as a mutable JSON object, for building edge cases from real data.
    static func jsonObject() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data()) as! [String: Any]
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// The fixture with `issued_at` moved on by `hours`, as the next hourly file would be.
    static func data(issuedHoursLater hours: Int) throws -> Data {
        var object = try jsonObject()
        let issued = try forecast().issuedAt.addingTimeInterval(TimeInterval(hours) * 3600)
        object["issued_at"] = issued.formatted(.iso8601)
        return try encode(object)
    }

    enum FixtureError: Error { case missing }

    /// A second real file: `kitimat.json` scored and published on this Mac on 27 Nov 2026 00:49 UTC from a copy of
    /// the `data` branch with the track record code (issued_at 2026-11-27T00:49:39Z), before the live file had
    /// `track_record`. Real data, not sample data. Its `backtest` block was added afterwards with the backend's own
    /// `publish.backtest_block` from the committed `data/backtest/kitimat.json` (also real, from `backtest.py`).
    /// File: `Fixtures/fixture-kitimat-track-record-2026-11-27T0049Z.json`.
    static let trackRecordName = "fixture-kitimat-track-record-2026-11-27T0049Z"

    static func trackRecordData() throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: trackRecordName, withExtension: "json")
            ?? bundle.url(forResource: trackRecordName, withExtension: "json", subdirectory: "Fixtures")
        else { throw FixtureError.missing }
        return try Data(contentsOf: url)
    }

    static func trackRecordForecast() throws -> PlaceForecast {
        try ForecastDecoder.decode(trackRecordData())
    }

    static func trackRecordObject() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: trackRecordData()) as! [String: Any]
    }
}

/// A fresh, empty store folder in the test run's temporary directory.
func makeTemporaryStore() -> ForecastStore {
    ForecastStore(directory: URL.temporaryDirectory
        .appending(path: "ForecastStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory))
}
