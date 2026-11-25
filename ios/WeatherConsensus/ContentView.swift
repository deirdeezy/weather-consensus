import SwiftUI

/// Placeholder until the Weather and Consensus tabs are built from the design canvas
/// (docs/BUILD_PLAN.md, Stage 3). Plain list of the 14 days, no styling.
struct ContentView: View {
    @State private var model = ForecastScreenModel(placeID: "kitimat", loader: .live())

    var body: some View {
        NavigationStack {
            ForecastScreen(model: model)
        }
    }
}

struct ForecastScreen: View {
    let model: ForecastScreenModel

    var body: some View {
        List {
            if let forecast = model.forecast {
                Section {
                    TimelineView(.everyMinute) { context in
                        let freshness = Freshness(forecast: forecast, now: context.date)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(freshness.updatedText)
                            if freshness.isStale {
                                Text("Stale: no new forecast run in over \(Int(forecast.staleAfterHours)) hours")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let note = statusNote {
                        Text(note).foregroundStyle(.secondary)
                    }
                    if forecast.place.consensusOnly {
                        Text("Consensus only")
                    }
                }

                Section("Next 14 days") {
                    ForEach(forecast.days) { day in
                        DayRow(day: day)
                    }
                }

                Section("Data") {
                    ForEach(forecast.credits, id: \.text) { credit in
                        Text(verbatim: credit.text).font(.footnote)
                    }
                }
            }
        }
        .overlay {
            if model.forecast == nil {
                if model.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "No forecast yet",
                        systemImage: "icloud.slash",
                        description: Text(statusNote ?? String(localized: "Pull down to try again."))
                    )
                }
            }
        }
        .navigationTitle(model.forecast?.place.name ?? String(localized: "Forecast"))
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    /// Why the screen is showing an older file, if it is.
    private var statusNote: String? {
        guard let problem = model.problem else { return nil }
        let hasForecast = model.forecast != nil
        switch problem {
        case .unsupportedSchemaVersion:
            return hasForecast
                ? String(localized: "A newer forecast needs an app update. Showing the last saved forecast.")
                : String(localized: "This forecast needs an app update.")
        case .offline:
            return hasForecast
                ? String(localized: "Offline. Showing the last saved forecast.")
                : String(localized: "Offline.")
        case .storage:
            return String(localized: "Could not save the forecast on this phone.")
        case .httpStatus, .network, .unreadable:
            return hasForecast
                ? String(localized: "Could not refresh. Showing the last saved forecast.")
                : String(localized: "Could not load the forecast.")
        }
    }
}

struct DayRow: View {
    let day: PlaceForecast.Day

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ValueText.date(day.date)).font(.headline)
            Text("High \(ValueText.temperature(day.high)) · Low \(ValueText.temperature(day.low))")
            Text("Precipitation \(ValueText.millimetres(day.precipMM)) · Chance \(ValueText.percent(day.precipChance))")
            Text("Certainty \(ValueText.percent(day.certainty)) · \(ValueText.tier(day.certaintyTier))")
        }
        .accessibilityElement(children: .combine)
    }
}

/// Plain text for values, metric for now. A missing value is a dash (docs/JSON_SCHEMA.md).
nonisolated enum ValueText {
    static let missing = "–"

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return missing }
        return celsius.formatted(.number.precision(.fractionLength(1))) + " °C"
    }

    static func millimetres(_ mm: Double?) -> String {
        guard let mm else { return missing }
        return mm.formatted(.number.precision(.fractionLength(1))) + " mm"
    }

    static func percent(_ value: Int?) -> String {
        guard let value else { return missing }
        return value.formatted() + "%"
    }

    static func tier(_ tier: CertaintyTier?) -> String {
        switch tier {
        case .high: String(localized: "High", comment: "Certainty tier, 75% and up")
        case .medium: String(localized: "Medium", comment: "Certainty tier, 50 to 74%")
        case .low: String(localized: "Low", comment: "Certainty tier, under 50%")
        case nil: missing
        }
    }

    /// "Wed 25 Nov". Climate days are plain dates, so format in UTC to keep the day fixed.
    static func date(_ date: LocalDate) -> String {
        guard let midnight = date.utcMidnight else { return date.description }
        return midnight.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated).day().month(.abbreviated))
    }
}

#if DEBUG
extension ForecastScreenModel {
    /// Real published data saved on 25 Nov 2026 (`PreviewContent/preview-fixture-...json`, a development asset left out of archives), never the network.
    static func previewFixture() -> ForecastScreenModel {
        let url = Bundle.main.url(forResource: "preview-fixture-kitimat-2026-11-25T0407Z", withExtension: "json")!
        let data = try! Data(contentsOf: url)
        let forecast = try! ForecastDecoder.decode(data)
        let store = ForecastStore(directory: URL.temporaryDirectory.appending(path: "PreviewForecasts"))
        let loader = ForecastLoader(store: store) { _ in data }
        return ForecastScreenModel(placeID: "kitimat", forecast: forecast, loader: loader)
    }
}

#Preview("Kitimat fixture") {
    NavigationStack {
        ForecastScreen(model: .previewFixture())
    }
}
#endif
