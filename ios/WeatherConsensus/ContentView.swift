import SwiftUI
import UIKit

/// App shell: tabs Weather, Radar, Consensus, Places (locked). Only Weather is built so far;
/// the gear on Weather opens Settings (a placeholder for now).
struct ContentView: View {
    enum TabID: String, Hashable {
        case weather, radar, consensus, places
    }

    @State private var model: ForecastScreenModel
    // Kept per scene, so the open tab survives folding and unfolding iPhone Duo and app relaunches.
    @SceneStorage("selectedTab") private var selection: TabID = .weather
    @State private var showSettings = false

    init(model: ForecastScreenModel = ContentView.makeModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: TabID.weather) {
                WeatherScreen(model: model,
                              openSettings: { showSettings = true },
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
                PlaceholderScreen(title: String(localized: "Consensus"), image: ConsensusGlyph.image,
                                  message: String(localized: "How your forecast is made, source by source. Coming next."))
            } label: {
                Label { Text("Consensus") } icon: { Image(uiImage: ConsensusGlyph.image) }
            }
            Tab(value: TabID.places) {
                PlaceholderScreen(title: String(localized: "Places"), systemImage: "mappin.and.ellipse",
                                  message: String(localized: "Kitimat for now. More places are coming."))
            } label: {
                Label("Places", systemImage: "mappin.and.ellipse")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: $showSettings) {
            SettingsScreen()
        }
    }

    static func makeModel() -> ForecastScreenModel {
        #if DEBUG
        if let debug = DebugLaunch.model() { return debug }
        #endif
        return ForecastScreenModel(placeID: "kitimat", loader: .live())
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

/// Settings placeholder, opened by the gear on Weather.
struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlaceholderScreen(title: String(localized: "Settings"), systemImage: "gearshape",
                              message: String(localized: "Places, units, alerts and look will live here."))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
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
/// - `-now 2026-11-25T16:30:00Z`: pretend it is this time (for the stale-data case).
enum DebugLaunch {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func model() -> ForecastScreenModel? {
        guard arguments.contains("-fixture") else { return nil }
        return .previewFixture(offline: arguments.contains("-offline"))
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
