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
}

/// A fresh, empty store folder in the test run's temporary directory.
func makeTemporaryStore() -> ForecastStore {
    ForecastStore(directory: URL.temporaryDirectory
        .appending(path: "ForecastStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory))
}
