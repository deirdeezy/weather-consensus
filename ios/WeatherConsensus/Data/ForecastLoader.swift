import Foundation
import os

/// Where the published files live. The app's only network calls go to this GitHub Pages site.
nonisolated enum ForecastEndpoint {
    static let host = "deirdeezy.github.io"
    static let base = URL(string: "https://deirdeezy.github.io/weather-consensus/")!

    /// `https://deirdeezy.github.io/weather-consensus/<place id>.json`, or nil for a bad id.
    static func url(for placeID: String) -> URL? {
        guard ForecastStore.isValidPlaceID(placeID) else { return nil }
        return base.appending(path: "\(placeID).json", directoryHint: .notDirectory)
    }
}

/// What one load gave us.
nonisolated struct LoadResult: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// Just downloaded and saved.
        case network
        /// The download failed or could not be used; this is the last saved good file.
        case savedCopy
        /// Nothing to show: the download failed and nothing is saved yet.
        case none
    }

    let forecast: PlaceForecast?
    let origin: Origin
    /// Why the download was not used, if it was not.
    let problem: LoadProblem?
}

/// Fetches a place file, checks it, saves it, and falls back to the saved copy when anything goes wrong.
nonisolated struct ForecastLoader: Sendable {
    typealias Fetch = @Sendable (URL) async throws -> Data

    let store: ForecastStore
    let fetch: Fetch

    private static let log = Logger(subsystem: "WeatherConsensus", category: "data")

    init(store: ForecastStore, fetch: @escaping Fetch) {
        self.store = store
        self.fetch = fetch
    }

    /// The loader the app uses: GitHub Pages over an ephemeral session
    /// (no cookies, credentials or cache written to disk).
    static func live(store: ForecastStore = .appDefault()) -> ForecastLoader {
        ForecastLoader(store: store, fetch: liveFetch())
    }

    /// The one network call the app makes: a GET to GitHub Pages, refused for any other host.
    /// Shared by the place files and the backtest files.
    static func liveFetch() -> Fetch {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        return { url in
            guard url.scheme == "https", url.host() == ForecastEndpoint.host else {
                throw LoadProblem.network("Blocked request to a host other than GitHub Pages")
            }
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw LoadProblem.httpStatus(status) }
            return data
        }
    }

    /// Downloads the latest file for a place. On success the file replaces the saved copy, unless the saved
    /// copy was issued later (then the saved copy is returned and kept).
    /// On any failure (offline, bad answer, unknown schema version) the saved copy is returned
    /// and the problem is logged.
    func load(placeID: String) async -> LoadResult {
        guard let url = ForecastEndpoint.url(for: placeID) else {
            return fallback(placeID: placeID, problem: .network("Bad place id"))
        }

        let data: Data
        do {
            data = try await fetch(url)
        } catch {
            return fallback(placeID: placeID, problem: Self.problem(from: error))
        }

        let forecast: PlaceForecast
        do throws(LoadProblem) {
            forecast = try ForecastDecoder.decode(data)
        } catch {
            return fallback(placeID: placeID, problem: error)
        }

        // A cache somewhere on the way can still hand out an older file: never let it replace a newer one.
        if let saved = store.savedForecast(placeID: placeID), saved.issuedAt > forecast.issuedAt {
            Self.log.notice("Downloaded \(placeID, privacy: .public) is older than the saved file; kept the saved one")
            return LoadResult(forecast: saved, origin: .savedCopy, problem: nil)
        }

        do throws(LoadProblem) {
            try store.save(data, placeID: placeID)
        } catch {
            // The new file is good; show it even if it could not be saved.
            Self.log.error("Could not save \(placeID, privacy: .public): \(String(describing: error), privacy: .public)")
            return LoadResult(forecast: forecast, origin: .network, problem: error)
        }
        return LoadResult(forecast: forecast, origin: .network, problem: nil)
    }

    /// The saved file for a place, without touching the network.
    func savedForecast(placeID: String) -> PlaceForecast? {
        store.savedForecast(placeID: placeID)
    }

    private func fallback(placeID: String, problem: LoadProblem) -> LoadResult {
        Self.log.error("Load \(placeID, privacy: .public) failed, using saved copy: \(String(describing: problem), privacy: .public)")
        if let saved = store.savedForecast(placeID: placeID) {
            return LoadResult(forecast: saved, origin: .savedCopy, problem: problem)
        }
        return LoadResult(forecast: nil, origin: .none, problem: problem)
    }

    static func problem(from error: any Error) -> LoadProblem {
        if let problem = error as? LoadProblem { return problem }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .offline
            default:
                return .network(urlError.code.rawValue.description)
            }
        }
        return .network(error.localizedDescription)
    }
}
