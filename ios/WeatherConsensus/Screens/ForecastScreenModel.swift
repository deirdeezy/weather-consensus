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

    private let loader: ForecastLoader

    init(placeID: String, loader: ForecastLoader) {
        self.placeID = placeID
        self.loader = loader
    }

    /// A model that already holds a forecast (previews).
    init(placeID: String, forecast: PlaceForecast, loader: ForecastLoader) {
        self.placeID = placeID
        self.loader = loader
        self.forecast = forecast
        self.origin = .savedCopy
    }

    /// Puts the saved file on screen at once, before the first frame, so the sky starts on the place's
    /// time of day (the launch screen hands over to it) instead of the default day sky. Does nothing if a
    /// forecast is already showing or nothing is saved.
    func showSavedCopy() {
        if forecast == nil, let saved = loader.savedForecast(placeID: placeID) {
            forecast = saved
            origin = .savedCopy
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
    }
}
