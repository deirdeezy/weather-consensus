import CryptoKit
import Foundation
import os

/// `backtest_file` in the place file: where the place's backtest file is on the same GitHub Pages site,
/// and the SHA-256 of its exact bytes (docs/JSON_SCHEMA.md). Older app builds ignore it.
nonisolated struct BacktestRef: Codable, Equatable, Sendable {
    /// `backtest/<place id>.json`, relative to the place file.
    let path: String
    /// Lowercase hex SHA-256 of the file's bytes.
    let sha256: String
    let bytes: Int?

    /// The full URL, only for exactly `backtest/<this place>.json` on the app's one host; nil otherwise.
    func url(placeID: String) -> URL? {
        guard ForecastStore.isValidPlaceID(placeID), path == "backtest/\(placeID).json" else { return nil }
        return ForecastEndpoint.base.appending(path: path, directoryHint: .notDirectory)
    }
}

/// Downloads a place's backtest file only when its hash in the place file changes, keeps one copy per place
/// (the same store rules as the forecasts, in its own folder), and falls back to that copy when offline.
/// Anything wrong with the backtest file hides the tested card; it never touches the forecast.
nonisolated struct BacktestLoader: Sendable {
    let store: ForecastStore
    let fetch: ForecastLoader.Fetch

    private static let log = Logger(subsystem: "WeatherConsensus", category: "data")

    init(store: ForecastStore, fetch: @escaping ForecastLoader.Fetch) {
        self.store = store
        self.fetch = fetch
    }

    /// The loader the app uses: `Application Support/Backtests`, same GitHub Pages fetch as the forecasts.
    static func live() -> BacktestLoader {
        BacktestLoader(store: .appBacktests(), fetch: ForecastLoader.liveFetch())
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ data: Data) -> Backtest? {
        guard let b = try? JSONDecoder().decode(Backtest.self, from: data), b.basis == "backtest" else { return nil }
        return b
    }

    /// The saved copy, without the network (first frame, previews). Shown only when the place file points to one.
    func saved(placeID: String, ref: BacktestRef?) -> Backtest? {
        guard ref != nil, let data = store.savedData(placeID: placeID) else { return nil }
        return Self.decode(data)
    }

    /// The backtest to show for a place file's pointer:
    /// - no pointer: nil (no card);
    /// - saved copy with the same hash: the saved copy, no download;
    /// - otherwise download it; keep it only if its hash matches and it reads; else the saved copy (any
    ///   version, labelled with its own period) or nil.
    func load(placeID: String, ref: BacktestRef?) async -> Backtest? {
        guard let ref else { return nil }
        let saved = store.savedData(placeID: placeID)
        if let saved, Self.sha256(saved) == ref.sha256, let backtest = Self.decode(saved) {
            return backtest
        }
        guard let url = ref.url(placeID: placeID) else {
            Self.log.error("Backtest pointer for \(placeID, privacy: .public) refused: \(ref.path, privacy: .public)")
            return saved.flatMap(Self.decode)
        }
        do {
            let data = try await fetch(url)
            guard Self.sha256(data) == ref.sha256 else {
                Self.log.error("Backtest for \(placeID, privacy: .public): hash does not match the place file")
                return saved.flatMap(Self.decode)
            }
            guard let backtest = Self.decode(data) else {
                Self.log.error("Backtest for \(placeID, privacy: .public): unreadable")
                return saved.flatMap(Self.decode)
            }
            do throws(LoadProblem) {
                try store.save(data, placeID: placeID)
            } catch {
                Self.log.error("Could not save backtest \(placeID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return backtest
        } catch {
            Self.log.error("Backtest \(placeID, privacy: .public) not downloaded: \(String(describing: ForecastLoader.problem(from: error)), privacy: .public)")
            return saved.flatMap(Self.decode)
        }
    }
}

extension ForecastStore {
    /// `Application Support/Backtests`: one `<place id>.json` per place, older copies deleted, excluded from backup.
    nonisolated static func appBacktests() -> ForecastStore {
        ForecastStore(directory: URL.applicationSupportDirectory.appending(path: "Backtests", directoryHint: .isDirectory))
    }
}
