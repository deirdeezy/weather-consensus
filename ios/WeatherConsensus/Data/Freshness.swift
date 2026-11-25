import Foundation

/// How old a forecast file is, and whether to treat it as stale.
///
/// - "Updated X hours ago" counts from `issued_at` (docs/BUILD_PLAN.md, Stage 3).
/// - Stale when the file says so (`stale`), or when `issued_at` or `fresh_data_at` is older than
///   `stale_after_hours`. The app has to check this itself: if the backend stops, no new file is
///   written and `stale` can never turn true (docs/JSON_SCHEMA.md, "Work out staleness yourself").
nonisolated struct Freshness: Equatable, Sendable {
    /// Whole hours since `issued_at`, never negative.
    let hoursSinceIssued: Int
    /// The file's own `stale` flag.
    let fileSaysStale: Bool
    /// `issued_at` or `fresh_data_at` is older than `stale_after_hours`.
    let tooOld: Bool

    var isStale: Bool { fileSaysStale || tooOld }

    init(forecast: PlaceForecast, now: Date) {
        let limit = forecast.staleAfterHours * 3600
        let sinceIssued = now.timeIntervalSince(forecast.issuedAt)
        hoursSinceIssued = max(0, Int(sinceIssued / 3600))
        fileSaysStale = forecast.stale
        var tooOld = sinceIssued > limit
        if let freshDataAt = forecast.freshDataAt, now.timeIntervalSince(freshDataAt) > limit {
            tooOld = true
        }
        self.tooOld = tooOld
    }

    /// "Updated less than an hour ago", "Updated 1 hour ago", "Updated 5 hours ago".
    var updatedText: String {
        if hoursSinceIssued == 0 {
            return String(localized: "Updated less than an hour ago")
        }
        return String(localized: "Updated \(hoursSinceIssued) hours ago",
                      comment: "How long ago the forecast file was published. Plural by hour count.")
    }
}
