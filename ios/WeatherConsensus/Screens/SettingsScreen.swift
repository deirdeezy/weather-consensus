import SwiftUI

/// Pages pushed inside the Settings sheet.
enum SettingsPage: String, Hashable {
    case about, privacy, acknowledgements, interLicence
}

/// Settings, opened by the gear on the Weather tab, from the design canvas artboard `Settings.dc.html`.
/// Only what works today: the place, units, living sky, links into Consensus and About.
/// Left out (nothing behind them yet): "Add a place", "Use my location", alerts (warnings, big changes,
/// morning summary, quiet hours), snow units, knots and hPa, clock, hourly rows, gentle motion,
/// send feedback. Settings are stored on this phone only (`AppSettings`).
struct SettingsScreen: View {
    let model: ForecastScreenModel
    @Bindable var settings: AppSettings
    var openTab: (ContentView.TabID) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    /// Owned by the app shell, which clears it each time the gear opens Settings.
    @Binding var path: [SettingsPage]

    init(model: ForecastScreenModel, settings: AppSettings, path: Binding<[SettingsPage]> = .constant([]),
         openTab: @escaping (ContentView.TabID) -> Void = { _ in }) {
        self.model = model
        self.settings = settings
        self.openTab = openTab
        _path = path
    }

    var body: some View {
        NavigationStack(path: $path) {
            SkyPage(model: model) {
                placesCard
                unitsCard
                lookCard
            } right: {
                consensusCard
                aboutCard
                SkyNote { Text(verbatim: SettingsText.footer(version: AppVersion.current)) }
            }
            .navigationTitle(Text("Settings"))
            .modifier(NavyBar())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .about: AboutScreen(model: model)
                case .privacy: PrivacyScreen(model: model)
                case .acknowledgements: AcknowledgementsScreen(model: model)
                case .interLicence: LicenceTextScreen(model: model)
                }
            }
        }
    }

    // MARK: Cards

    private var placesCard: some View {
        SectionCard(title: String(localized: "Places")) {
            Button { openTab(.places) } label: {
                SettingsRowLabel(title: SettingsText.placeName(model.forecast),
                                 subtitle: model.forecast.map { PlacesText.checkPill($0.place) }) {
                    ChipIcon(systemImage: "mappin.and.ellipse", colours: ChipColours.blue)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the Places tab"))
        }
    }

    private var unitsCard: some View {
        SectionCard(title: String(localized: "Units")) {
            UnitSegments(title: String(localized: "Temperature"),
                         options: [(.celsius, "°C", String(localized: "Celsius")),
                                   (.fahrenheit, "°F", String(localized: "Fahrenheit"))],
                         selection: $settings.temperatureUnit)
            RowDivider()
            UnitSegments(title: String(localized: "Rain"),
                         options: [(.millimetres, "mm", String(localized: "millimetres")),
                                   (.inches, "in", String(localized: "inches"))],
                         selection: $settings.rainUnit)
            RowDivider()
            UnitSegments(title: String(localized: "Wind"),
                         options: [(.kilometresPerHour, "km/h", String(localized: "kilometres per hour")),
                                   (.milesPerHour, "mph", String(localized: "miles per hour"))],
                         selection: $settings.windUnit)
            RowDivider()
            UnitSegments(title: String(localized: "Pressure"),
                         options: [(.kilopascals, "kPa", String(localized: "kilopascals")),
                                   (.inchesOfMercury, "inHg", String(localized: "inches of mercury"))],
                         selection: $settings.pressureUnit)
            RowDivider()
            Text(verbatim: SettingsText.certaintyNote(settings.temperatureUnit))
                .font(.inter(13, .regular, relativeTo: .footnote))
                .foregroundStyle(Color(Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
        }
    }

    private var lookCard: some View {
        SectionCard(title: String(localized: "Look and feel")) {
            Toggle(isOn: $settings.livingSky) {
                SettingsRowLabel(title: String(localized: "Living sky"), subtitle: SettingsText.livingSkyDetail,
                                 showsChevron: false) {
                    ChipIcon(systemImage: "cloud.sun", colours: ChipColours.sky)
                }
            }
            .tint(Color(Palette.tierHigh))
            .frame(minHeight: 72)
        }
    }

    private var consensusCard: some View {
        SectionCard(title: String(localized: "Consensus")) {
            Button { openTab(.consensus) } label: {
                SettingsRowLabel(title: String(localized: "How Consensus works")) {
                    ChipIcon(fill: ChipColours.grey.fill) { ThreeCircles() }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the Consensus tab"))
            RowDivider()
            Button { openTab(.consensus) } label: {
                SettingsRowLabel(title: String(localized: "Sources"),
                                 subtitle: model.forecast.map(SettingsText.sourcesValue) ?? ValueText.missing) {
                    ChipIcon(systemImage: "chart.bar", colours: ChipColours.green)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the Consensus tab"))
        }
    }

    private var aboutCard: some View {
        SectionCard(title: String(localized: "About")) {
            NavigationLink(value: SettingsPage.about) {
                SettingsRowLabel(title: String(localized: "About Weather Consensus")) {
                    ChipIcon(systemImage: "info.circle", colours: ChipColours.blue)
                }
            }
            .buttonStyle(.plain)
            RowDivider()
            SettingsRowLabel(title: SettingsText.noAds, subtitle: SettingsText.placesStay, showsChevron: false) {
                ChipIcon(systemImage: "checkmark.shield", colours: ChipColours.green)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Every Settings string that is built, not fixed.
nonisolated enum SettingsText {
    static let noAds = String(localized: "No ads, no tracking, no account")
    static let placesStay = String(localized: "Your places stay on your phone")
    static let livingSkyDetail = String(localized: "On: the background follows the time of day at the place. Off: a calm, fixed sky.",
                                        comment: "Settings, under the Living sky switch")
    /// "Certainty means the chance the high lands within 2 °C of our number." In the chosen unit only.
    static func certaintyNote(_ unit: TemperatureUnit) -> String {
        String(localized: "Certainty means the chance the high lands within \(CertaintyText.band(unit)) of our number.",
               comment: "Settings, under the units. Value: the Certainty band in the chosen unit.")
    }

    /// The place in the file; "Kitimat" (the only place) before the first file arrives.
    static func placeName(_ forecast: PlaceForecast?) -> String {
        forecast?.place.name ?? String(localized: "Kitimat", comment: "Place name")
    }

    /// "9 models and the normal", counted from the file's sources.
    static func sourcesValue(_ forecast: PlaceForecast) -> String {
        let models = forecast.sources.filter { $0.id != "normal" }.count
        let hasNormal = forecast.sources.contains { $0.id == "normal" }
        return switch (models == 1, hasNormal) {
        case (true, false): String(localized: "1 model")
        case (true, true): String(localized: "1 model and the normal")
        case (false, false): String(localized: "\(models) models", comment: "Settings, Sources row; counted from the file")
        case (false, true): String(localized: "\(models) models and the normal", comment: "Settings, Sources row; counted from the file")
        }
    }

    /// "Weather Consensus 0.1 (1)", version and build from the app bundle.
    static func footer(version: String) -> String {
        String(localized: "Weather Consensus \(version)", comment: "Settings footer. The value is the version and build, e.g. 1.0 (1).")
    }
}

#if DEBUG
#Preview("Settings") {
    @Previewable @State var path: [SettingsPage] = []
    SettingsScreen(model: .previewFixture(), settings: AppSettings(defaults: .preview), path: $path)
        .environment(\.nowOverride, PreviewClock.afternoon)
}

#Preview("Settings, night, °F", traits: .portrait) {
    let settings = AppSettings(defaults: .preview)
    settings.temperatureUnit = .fahrenheit
    return SettingsScreen(model: .previewFixture(), settings: settings)
        .environment(\.nowOverride, PreviewClock.fresh)
}

#Preview("Settings, largest text") {
    SettingsScreen(model: .previewFixture(), settings: AppSettings(defaults: .preview))
        .environment(\.nowOverride, PreviewClock.afternoon)
        .dynamicTypeSize(.accessibility5)
}

#Preview("Settings, iPhone Duo unfolded", traits: .fixedLayout(width: 951, height: 669)) {
    SettingsScreen(model: .previewFixture(), settings: AppSettings(defaults: .preview))
        .environment(\.nowOverride, PreviewClock.afternoon)
        .environment(\.horizontalSizeClass, .regular)
}

extension UserDefaults {
    /// A throwaway store for previews, so they never touch the app's real settings.
    static var preview: UserDefaults {
        let name = "preview-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }
}
#endif
