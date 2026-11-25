import SwiftUI

extension EnvironmentValues {
    /// A fixed "now" for previews and the debug stale-data run. nil: the real clock.
    @Entry var nowOverride: Date? = nil
}

/// The Weather tab, built from the design canvas (v8): living sky, navy cards, Inter, and the 14 days as
/// canvas compact rows that open into a Certainty breakdown (`DayRows.swift`). Only values the published file has are shown
/// (no current conditions, wind, hourly or condition icons yet: schema v1 has none).
struct WeatherScreen: View {
    let model: ForecastScreenModel
    var openSettings: () -> Void = {}
    var openConsensus: () -> Void = {}

    @State private var expandedDay: Int?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.nowOverride) private var nowOverride

    /// Two columns when there is width to spare (iPhone Duo inner display, large phones in landscape)
    /// or little height (any phone in landscape). Size classes only, never device or orientation.
    private var twoColumns: Bool {
        horizontalSizeClass == .regular || verticalSizeClass == .compact
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = nowOverride ?? context.date
            let style = skyStyle(now: now)
            ScrollView {
                content(now: now, style: style)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: twoColumns ? 1100 : 640)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background { SkyView(style: style) }
            .overlay {
                if model.forecast == nil { emptyState(style: style) }
            }
            .refreshable { await model.load() }
        }
        .task { await model.load() }
    }

    // MARK: Layout

    @ViewBuilder
    private func content(now: Date, style: SkyStyle) -> some View {
        let regular = twoColumns
        // AnyLayout keeps each column's identity when the size class changes (iPhone Duo fold and unfold),
        // so expanded rows and scroll position survive.
        let layout = regular
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(spacing: 14))
        layout {
            VStack(spacing: 14) {
                header(style: style)
                if let forecast = model.forecast {
                    StatusCard(forecast: forecast, now: now, problemNote: problemNote)
                    CertaintyExplainer(forecast: forecast, openConsensus: openConsensus)
                }
            }
            .frame(maxWidth: regular ? 380 : .infinity)

            if let forecast = model.forecast {
                VStack(spacing: 14) {
                    ForecastCard(forecast: forecast, expandedDay: $expandedDay)
                    CreditsCard(credits: forecast.credits)
                }
            }
        }
    }

    private func header(style: SkyStyle) -> some View {
        let ink = Color(style.headerInk)
        let backdrop = Color(style.headerBackdrop.color).opacity(style.headerBackdrop.opacity)
        return HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "mappin")
                    .font(.inter(17, .bold, relativeTo: .title2))
                    .accessibilityHidden(true)
                Text(verbatim: model.forecast?.place.name ?? "")
                    .font(.inter(24, .extraBold, relativeTo: .title))
                    .tracking(-0.24)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Capsule().fill(backdrop))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .opacity(model.forecast == nil ? 0 : 1)

            Spacer(minLength: 0)

            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(backdrop))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Settings"))
        }
    }

    private func emptyState(style: SkyStyle) -> some View {
        VStack(spacing: 14) {
            if model.isLoading {
                ProgressView().tint(Color(style.headerInk))
            } else {
                Card {
                    VStack(spacing: 8) {
                        Image(systemName: "icloud.slash").font(.system(size: 30)).accessibilityHidden(true)
                        Text("No forecast yet").font(.inter(18, .extraBold, relativeTo: .headline))
                        Text(problemNote ?? String(localized: "Pull down to try again."))
                            .font(.inter(14, .regular, relativeTo: .subheadline))
                            .foregroundStyle(Color(Palette.textBody))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 420)
                .padding(24)
            }
        }
    }

    private func skyStyle(now: Date) -> SkyStyle {
        guard let forecast = model.forecast else {
            return SkyStyle(time: .day, weather: nil)
        }
        return SkyStyle(time: SkyTime.at(now, place: forecast.place), weather: SkyWeather.from(forecast))
    }

    /// Why the screen is showing an older file, if it is.
    private var problemNote: String? {
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

// MARK: - Cards

/// Navy card from the canvas.
struct Card<Content: View>: View {
    var padding = EdgeInsets(top: 16, leading: 14, bottom: 14, trailing: 14)
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(Palette.card)))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: Color(Palette.ink).opacity(0.22), radius: 12, y: 10)
    }
}

/// "Updated X hours ago", the stale note, the offline or error note, and "Consensus only".
struct StatusCard: View {
    let forecast: PlaceForecast
    let now: Date
    let problemNote: String?

    var body: some View {
        let freshness = Freshness(forecast: forecast, now: now)
        Card(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)) {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(verbatim: freshness.updatedText)
                } icon: {
                    Image(systemName: "clock").foregroundStyle(Color(Palette.textSecondary))
                }
                .font(.inter(14, .semibold, relativeTo: .subheadline))

                if freshness.isStale {
                    note(icon: "exclamationmark.triangle.fill", tint: Palette.tierMedium,
                         text: String(localized: "Stale: no new forecast data in over \(Int(forecast.staleAfterHours)) hours. Numbers may be out of date."))
                }
                if let problemNote {
                    note(icon: "wifi.slash", tint: Palette.textSecondary, text: problemNote)
                }
                if forecast.place.consensusOnly {
                    note(icon: "info.circle", tint: Palette.textSecondary,
                         text: String(localized: "Consensus only: no station here, so these numbers are not checked locally."))
                }
            }
        }
    }

    private func note(icon: String, tint: RGB, text: String) -> some View {
        Label {
            Text(verbatim: text).foregroundStyle(Color(Palette.textBody))
        } icon: {
            Image(systemName: icon).foregroundStyle(Color(tint))
        }
        .font(.inter(13.5, .medium, relativeTo: .footnote))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// What Certainty means, with the first day's real value as the worked example.
struct CertaintyExplainer: View {
    let forecast: PlaceForecast
    let openConsensus: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let big = dynamicTypeSize.isAccessibilitySize
        let headerLayout = big ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
        let legendLayout = big ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        Card {
            VStack(alignment: .leading, spacing: 10) {
                headerLayout {
                    HStack(spacing: 8) {
                        CertaintyRing(certainty: 75, tier: .high).frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        Text("Certainty").font(.inter(17, .extraBold, relativeTo: .headline))
                            .accessibilityAddTraits(.isHeader)
                    }
                    if !big { Spacer(minLength: 8) }
                    Button(action: openConsensus) {
                        Text("How it works ›").font(.inter(13, .bold, relativeTo: .footnote))
                            .foregroundStyle(Color(Palette.link))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the Consensus tab"))
                }
                Text("Every day blends several forecast sources, weighted by how well each has done here. The ring is the chance the high lands within 2\u{00A0}°C (3.6\u{00A0}°F) of our number.")
                    .font(.inter(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color(Palette.textBody))
                    .fixedSize(horizontal: false, vertical: true)

                if let firstDay = forecast.days.first(where: { $0.certainty != nil }) {
                    example(firstDay)
                }

                legendLayout {
                    legend(.high, String(localized: "75% and up"))
                    legend(.medium, String(localized: "50% to 74%"))
                    legend(.low, String(localized: "under 50%"))
                }
            }
        }
    }

    private func example(_ day: PlaceForecast.Day) -> some View {
        let filled = CertaintyText.filledDots(day.certainty)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: ValueText.percent(day.certainty)).font(.inter(22, .extraBold, relativeTo: .title2))
                Text(verbatim: ValueText.weekday(day.date)).font(.inter(12, .medium, relativeTo: .caption))
                    .foregroundStyle(Color(Palette.textSecondary))
            }
            VStack(alignment: .leading, spacing: 6) {
                CertaintyDots(day: day)
                Text("means about \(filled) of every 10 days like this land within 2\u{00A0}°C")
                    .font(.inter(12, .regular, relativeTo: .caption))
                    .foregroundStyle(Color(Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(ValueText.spokenDate(day.date)): Certainty \(ValueText.percent(day.certainty)). \(CertaintyText.dotsLabel(day))",
                                 comment: "VoiceOver label for the worked Certainty example"))
    }

    private func legend(_ tier: CertaintyTier, _ range: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Circle().fill(Color(Palette.tier(tier))).frame(width: 9, height: 9)
                Text(verbatim: ValueText.tier(tier)).font(.inter(12, .extraBold, relativeTo: .caption))
            }
            Text(verbatim: range).font(.inter(12, .regular, relativeTo: .caption))
                .foregroundStyle(Color(Palette.textSecondary))
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }
}

/// Data credits from the file. Required by the licences (CLAUDE.md); they move to About later.
struct CreditsCard: View {
    let credits: [PlaceForecast.Credit]

    var body: some View {
        Card(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Data").font(.inter(13, .extraBold, relativeTo: .footnote))
                    .foregroundStyle(Color(Palette.textSecondary))
                    .accessibilityAddTraits(.isHeader)
                ForEach(credits, id: \.text) { credit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: credit.text)
                            .font(.inter(12.5, .regular, relativeTo: .caption))
                            .foregroundStyle(Color(Palette.textBody))
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = URL(string: credit.url), url.scheme == "https" {
                            Link(destination: url) {
                                Text(verbatim: credit.licence).font(.inter(12.5, .bold, relativeTo: .caption))
                                    .foregroundStyle(Color(Palette.link))
                            }
                        }
                    }
                }
            }
        }
    }
}

#if DEBUG
extension ForecastScreenModel {
    /// Real published data saved on 25 Nov 2026 (`PreviewContent/preview-fixture-...json`, a development
    /// asset left out of archives), never the network. `offline: true` makes every refresh fail as offline.
    static func previewFixture(offline: Bool = false) -> ForecastScreenModel {
        let url = Bundle.main.url(forResource: "preview-fixture-kitimat-2026-11-25T0407Z", withExtension: "json")!
        let data = try! Data(contentsOf: url)
        let forecast = try! ForecastDecoder.decode(data)
        let store = ForecastStore(directory: URL.temporaryDirectory.appending(path: "PreviewForecasts"))
        let loader = ForecastLoader(store: store) { _ in
            if offline { throw URLError(.notConnectedToInternet) }
            return data
        }
        return ForecastScreenModel(placeID: "kitimat", forecast: forecast, loader: loader)
    }
}

/// Fixture times. The file was issued 25 Nov 2026 04:07 UTC. Kitimat clocks are UTC-7 in the iOS 27.2
/// time zone data; the sun rises about 16:20 UTC and sets about 00:24 UTC on that date.
enum PreviewClock {
    static let fresh = ISO8601DateFormatter().date(from: "2026-11-25T05:00:00Z")!     // night, about 1 hour old
    static let afternoon = ISO8601DateFormatter().date(from: "2026-11-25T21:00:00Z")! // day, stale (17 hours)
    static let stale = ISO8601DateFormatter().date(from: "2026-11-25T16:30:00Z")!     // dawn, stale (12 hours)
}

#Preview("Weather, light") {
    WeatherScreen(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.fresh)
        .preferredColorScheme(.light)
}

#Preview("Weather, dark") {
    WeatherScreen(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.fresh)
        .preferredColorScheme(.dark)
}

#Preview("Stale and offline, daytime", traits: .portrait) {
    WeatherScreen(model: .previewFixture(offline: true))
        .environment(\.nowOverride, PreviewClock.afternoon)
}

#Preview("Landscape", traits: .landscapeLeft) {
    WeatherScreen(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.stale)
}

#Preview("Largest text") {
    WeatherScreen(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.fresh)
        .dynamicTypeSize(.accessibility3)
}
#Preview("Day rows, largest text") {
    @Previewable @State var expanded: Int? = 1
    let model = ForecastScreenModel.previewFixture()
    ScrollView {
        ForecastCard(forecast: model.forecast!, expandedDay: $expanded).padding(16)
    }
    .background(Color(Palette.cardInner))
    .dynamicTypeSize(.accessibility3)
}

#Preview("Day rows, daytime sky") {
    @Previewable @State var expanded: Int? = 1
    let model = ForecastScreenModel.previewFixture()
    ScrollView {
        ForecastCard(forecast: model.forecast!, expandedDay: $expanded).padding(16)
    }
    .background(SkyView(style: SkyStyle(time: .day, weather: nil)))
    // Render with the canvas Contrast variant set to Increased Contrast.
}
#endif
