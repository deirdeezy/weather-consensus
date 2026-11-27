import Foundation
import Observation

/// State for one place's forecast screen. Shows the saved file at once, then refreshes from the network.
/// If a refresh fails or the new file cannot be read, the last good forecast stays on screen.
@Observable
final class ForecastScreenModel {
    let placeID: String
    private(set) var forecast: PlaceForecast?
    private(set) var origin: LoadResult.Origin = .none
    private(set) var problem: LoadProblem?
    private(set) var isLoading = false
    /// The tested card's numbers, from the backtest file the forecast points to. nil hides the card.
    private(set) var backtest: Backtest?

    private let loader: ForecastLoader
    private let backtests: BacktestLoader?

    init(placeID: String, loader: ForecastLoader, backtests: BacktestLoader? = nil) {
        self.placeID = placeID
        self.loader = loader
        self.backtests = backtests
    }

    /// A model that already holds a forecast (previews).
    init(placeID: String, forecast: PlaceForecast, loader: ForecastLoader, backtest: Backtest? = nil) {
        self.placeID = placeID
        self.loader = loader
        self.backtests = nil
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

    func load() async {
        showSavedCopy()
        isLoading = true
        let result = await loader.load(placeID: placeID)
        isLoading = false
        problem = result.problem
        if let newForecast = result.forecast {
            forecast = newForecast
            origin = result.origin
        }
        // No forecast in the result: keep whatever good forecast is already on screen.
        if let backtests {
            // Separate from the forecast: a missing or broken backtest file only hides the tested card.
            backtest = await backtests.load(placeID: placeID, ref: forecast?.backtestFile)
        }
    }
}
