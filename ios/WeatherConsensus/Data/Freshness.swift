import Foundation

/// How old a forecast file is, and whether to treat it as stale.
///
/// - "Updated X hours ago" counts from `fresh_data_at`, when the backend last got new forecast
///   data; from `issued_at` if `fresh_data_at` is missing. Not `newest_run_at`: that is when a model
///   run started, hours before its data is available (docs/JSON_SCHEMA.md).
/// - Stale when the file says so (`stale`), or when `issued_at` or `fresh_data_at` is older than
///   `stale_after_hours`. The app has to check this itself: if the backend stops, no new file is
///   written and `stale` can never turn true (docs/JSON_SCHEMA.md, "Work out staleness yourself").
nonisolated struct Freshness: Equatable, Sendable {
    /// When the data was last updated: `fresh_data_at`, or `issued_at` if that is missing.
    let updatedAt: Date
    /// Whole hours since `updatedAt`, never negative.
    let hoursSinceUpdate: Int
    /// The file's own `stale` flag.
    let fileSaysStale: Bool
    /// `issued_at` or `fresh_data_at` is older than `stale_after_hours`.
    let tooOld: Bool

    var isStale: Bool { fileSaysStale || tooOld }

    init(forecast: PlaceForecast, now: Date) {
        let limit = forecast.staleAfterHours * 3600
        let sinceIssued = now.timeIntervalSince(forecast.issuedAt)
        updatedAt = forecast.freshDataAt ?? forecast.issuedAt
        hoursSinceUpdate = max(0, Int(now.timeIntervalSince(updatedAt) / 3600))
        fileSaysStale = forecast.stale
        var tooOld = sinceIssued > limit
        if let freshDataAt = forecast.freshDataAt, now.timeIntervalSince(freshDataAt) > limit {
            tooOld = true
        }
        self.tooOld = tooOld
    }

    /// "Updated less than an hour ago", "Updated 1 hour ago", "Updated 5 hours ago".
    var updatedText: String {
        if hoursSinceUpdate == 0 {
            return String(localized: "Updated less than an hour ago")
        }
        return String(localized: "Updated \(hoursSinceUpdate) hours ago",
                      comment: "How long ago the backend last got new forecast data. Plural by hour count.")
    }
}
