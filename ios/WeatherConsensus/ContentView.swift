import SwiftUI
import UIKit

/// App shell: tabs Weather, Radar, Consensus, Places (locked). Weather, Consensus and Places are built;
/// the gear on Weather opens Settings. The settings (units, living sky) flow to every screen from here.
struct ContentView: View {
    enum TabID: String, Hashable {
        case weather, radar, consensus, places
    }

    @State private var model: ForecastScreenModel
    @State private var settings: AppSettings
    // Kept per scene, so the open tab survives folding and unfolding iPhone Duo and app relaunches.
    @SceneStorage("selectedTab") private var selection: TabID = .weather
    @State private var showSettings = false
    @State private var settingsPath: [SettingsPage] = []

    init(model: ForecastScreenModel = ContentView.makeModel(), settings: AppSettings = AppSettings()) {
        _model = State(initialValue: model)
        _settings = State(initialValue: settings)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: TabID.weather) {
                WeatherScreen(model: model,
                              openSettings: {
                                  settingsPath = []
                                  showSettings = true
                              },
                              openConsensus: { selection = .consensus })
            } label: {
                Label("Weather", systemImage: "cloud.sun")
            }
            Tab(value: TabID.radar) {
                PlaceholderScreen(title: String(localized: "Radar"), systemImage: "map",
                                  message: String(localized: "Radar comes in a later step."))
            } label: {
                Label("Radar", systemImage: "map")
            }
            Tab(value: TabID.consensus) {
                ConsensusScreen(model: model)
            } label: {
                Label { Text("Consensus") } icon: { Image(uiImage: ConsensusGlyph.image) }
            }
            Tab(value: TabID.places) {
                PlacesScreen(model: model, openWeather: { selection = .weather })
            } label: {
                Label("Places", systemImage: "mappin.and.ellipse")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: $showSettings) {
            SettingsScreen(model: model, settings: settings, path: $settingsPath) { tab in
                showSettings = false
                selection = tab
            }
        }
        .environment(\.unitChoice, settings.units)
        .environment(\.livingSky, settings.livingSky)
        #if DEBUG
        .onAppear {
            if let tab = DebugLaunch.tab { selection = tab }
            if let page = DebugLaunch.settingsPath {
                settingsPath = page
                showSettings = true
            }
        }
        #endif
    }

    static func makeModel() -> ForecastScreenModel {
        #if DEBUG
        if let debug = DebugLaunch.model() { return debug }
        #endif
        let model = ForecastScreenModel(placeID: "kitimat", loader: .live())
        model.showSavedCopy()
        return model
    }
}

/// Placeholder for a tab that is not built yet.
struct PlaceholderScreen: View {
    let title: String
    var systemImage: String?
    var image: UIImage?
    let message: String

    init(title: String, systemImage: String, message: String) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    init(title: String, image: UIImage, message: String) {
        self.title = title
        self.image = image
        self.message = message
    }

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 40, weight: .regular))
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: 56)
                }
            }
            .foregroundStyle(Color(Palette.textSecondary))
            .accessibilityHidden(true)
            Text(verbatim: title).font(.inter(24, .extraBold, relativeTo: .title))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: message).font(.inter(15, .regular, relativeTo: .body))
                .foregroundStyle(Color(Palette.textBody))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(Palette.cardInner).ignoresSafeArea())
    }
}

/// The Consensus tab icon from the canvas: three overlapping circles, drawn once as a template image.
enum ConsensusGlyph {
    static let image: UIImage = {
        let size = CGSize(width: 28, height: 24)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            cg.setLineWidth(1.9)
            cg.setStrokeColor(UIColor.black.cgColor)
            for (x, y) in [(9.0, 9.0), (19.0, 9.0), (14.0, 16.0)] {
                cg.strokeEllipse(in: CGRect(x: x - 6.2, y: y - 6.2, width: 12.4, height: 12.4))
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()
}

#if DEBUG
/// Debug-only launch arguments, for simulator screenshots of fixed cases. Never in release builds.
/// - `-fixture`: show the saved 25 Nov 2026 file (real data) instead of the network.
/// - `-offline`: with `-fixture`, every refresh fails as offline.
/// - `-withNow`: with `-fixture`, add the real 25 Nov 2026 21:00 UTC Kitimat Forest Ave observation as `now`.
/// - `-now 2026-11-25T16:30:00Z`: pretend it is this time (for the stale-data case).
/// - `-tab consensus`: open on that tab.
/// - `-settings` (or `-settings about`, `privacy`, `acknowledgements`): open the Settings sheet, on that page.
/// Units and the living sky can be set for one run with the standard defaults arguments, for example
/// `-temperatureUnit fahrenheit -rainUnit inches -livingSky NO` (not saved).
enum DebugLaunch {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func model() -> ForecastScreenModel? {
        guard arguments.contains("-fixture") else { return nil }
        return .previewFixture(offline: arguments.contains("-offline"), withNow: arguments.contains("-withNow"))
    }

    /// `-tab consensus`: open on this tab (screenshots).
    static var tab: ContentView.TabID? {
        guard let index = arguments.firstIndex(of: "-tab"), arguments.indices.contains(index + 1) else { return nil }
        return ContentView.TabID(rawValue: arguments[index + 1])
    }

    /// `-settings`, `-settings about`: the Settings sheet, opened on launch at that page.
    static var settingsPath: [SettingsPage]? {
        guard let index = arguments.firstIndex(of: "-settings") else { return nil }
        guard arguments.indices.contains(index + 1), let page = SettingsPage(rawValue: arguments[index + 1]) else { return [] }
        switch page {
        case .about: return [.about]
        case .privacy: return [.about, .privacy]
        case .acknowledgements: return [.about, .acknowledgements]
        case .interLicence: return [.about, .acknowledgements, .interLicence]
        }
    }

    static var now: Date? {
        guard let index = arguments.firstIndex(of: "-now"), arguments.indices.contains(index + 1) else { return nil }
        return ISO8601DateFormatter().date(from: arguments[index + 1])
    }
}

#Preview("App, light") {
    ContentView(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.fresh)
        .preferredColorScheme(.light)
}

#Preview("App, dark") {
    ContentView(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.fresh)
        .preferredColorScheme(.dark)
}

#Preview("App, landscape", traits: .landscapeLeft) {
    ContentView(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.afternoon)
}
// iPhone Duo sizes measured in the iPhone Duo simulator (iOS 27.2): outer display 466 x 678 pt,
// inner display open 951 x 669 pt. Render these on the "iPhone Duo" preview destination.
#Preview("iPhone Duo, folded", traits: .fixedLayout(width: 466, height: 678)) {
    ContentView(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.fresh)
        .environment(\.horizontalSizeClass, .compact)
}

#Preview("iPhone Duo, unfolded", traits: .fixedLayout(width: 951, height: 669)) {
    ContentView(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.afternoon)
        .environment(\.horizontalSizeClass, .regular)
}
#endif
