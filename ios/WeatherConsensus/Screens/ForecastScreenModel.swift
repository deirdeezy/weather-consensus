import Foundation
import Observation

/// State for one place's forecast screen. Shows the saved file at once, then refreshes from the network.
/// If a refresh fails or the new file cannot be read, the last good forecast stays on screen.
/// Overlapping loads share one request, and a file issued earlier than the one on screen never replaces it.
@Observable
final class ForecastScreenModel {
    let placeID: String
    private(set) var forecast: PlaceForecast?
    private(set) var origin: LoadResult.Origin = .none
    private(set) var problem: LoadProblem?
    private(set) var isLoading = false
    /// The tested card's numbers, from the backtest file the forecast points to. nil hides the card.
    private(set) var backtest: Backtest?

    /// When the last load started (automatic or pulled), by `clock`.
    private(set) var lastAttempt: Date?

    private let loader: ForecastLoader
    private let backtests: BacktestLoader?
    private let clock: () -> Date
    private var inFlight: Task<Void, Never>?

    init(placeID: String, loader: ForecastLoader, backtests: BacktestLoader? = nil,
         clock: @escaping () -> Date = { Date() }) {
        self.placeID = placeID
        self.loader = loader
        self.backtests = backtests
        self.clock = clock
    }

    /// A model that already holds a forecast (previews).
    init(placeID: String, forecast: PlaceForecast, loader: ForecastLoader, backtest: Backtest? = nil) {
        self.placeID = placeID
        self.loader = loader
        self.backtests = nil
        self.clock = { Date() }
        self.forecast = forecast
        self.origin = .savedCopy
        self.backtest = backtest
    }

    /// Puts the saved file on screen at once, before the first frame, so the sky starts on the place's
    /// time of day (the launch screen hands over to it) instead of the default day sky. Does nothing if a
    /// forecast is already showing or nothing is saved.
    func showSavedCopy() {
        if forecast == nil, let saved = loader.savedForecast(placeID: placeID) {
            forecast = saved
            origin = .savedCopy
            backtest = backtests?.saved(placeID: placeID, ref: saved.backtestFile)
        }
    }

    /// Loads now (pull to refresh). If a load is already running, waits for that one instead of starting
    /// a second request.
    func load() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await performLoad() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Loads only if `RefreshPolicy` says a newer file is due (launch, back to the foreground, a tab appears).
    func refreshIfDue() async {
        showSavedCopy()
        guard RefreshPolicy.isDue(issuedAt: forecast?.issuedAt, lastAttempt: lastAttempt, now: clock()) else { return }
        await load()
    }

    private func performLoad() async {
        showSavedCopy()
        lastAttempt = clock()
        isLoading = true
        let result = await loader.load(placeID: placeID)
        isLoading = false
        problem = result.problem
        // No forecast in the result, or one issued before the one on screen: keep what is on screen.
        if let newForecast = result.forecast, newForecast.issuedAt >= (forecast?.issuedAt ?? .distantPast) {
            forecast = newForecast
            origin = result.origin
        }
        if let backtests {
            // Separate from the forecast: a missing or broken backtest file only hides the tested card.
            backtest = await backtests.load(placeID: placeID, ref: forecast?.backtestFile)
        }
    }
}
