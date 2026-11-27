import Foundation

/// When the app should ask GitHub Pages for a newer place file without being asked (on launch, when it
/// comes back to the foreground, and when any tab appears). Pull to refresh always asks.
///
/// Due when there is no forecast, or the one on screen was issued more than an hour ago, or a newer one
/// should be out by now: the backend publishes every hour, its runs start at minute 10 UTC (Cloudflare
/// Worker; GitHub's own schedule at minute 17 is the backup) and the file is on Pages a few minutes later
/// (docs/HOSTING.md, "What starts the runs"), so the next file is expected from minute 15 of the next hour.
/// Never twice within a minute, so a failed attempt is not repeated on every tab switch.
nonisolated enum RefreshPolicy {
    /// A file older than this is always due.
    static let maxAge: TimeInterval = 3600
    /// Minute past each UTC hour at which the hourly run starts.
    static let runMinute = 10
    /// Minute past each UTC hour from which that run's file should be on GitHub Pages.
    static let expectedMinute = 15
    /// Shortest gap between two automatic attempts.
    static let minInterval: TimeInterval = 60

    /// The first time after `issuedAt` at which a newer file should be out. A file issued from minute 10 on is
    /// that hour's run, so the next is due at minute 15 of the next hour; one issued earlier in the hour (a
    /// nightly run, a late run from the hour before) is followed by this hour's run, due at minute 15.
    static func nextExpectedIssue(after issuedAt: Date) -> Date {
        let seconds = issuedAt.timeIntervalSince1970
        let hourStart = (seconds / 3600).rounded(.down) * 3600
        var next = hourStart + TimeInterval(expectedMinute * 60)
        if seconds >= hourStart + TimeInterval(runMinute * 60) { next += 3600 }
        return Date(timeIntervalSince1970: next)
    }

    static func isDue(issuedAt: Date?, lastAttempt: Date?, now: Date) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minInterval { return false }
        guard let issuedAt else { return true }
        return now.timeIntervalSince(issuedAt) > maxAge || now >= nextExpectedIssue(after: issuedAt)
    }
}
