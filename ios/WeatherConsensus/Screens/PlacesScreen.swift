import SwiftUI

/// The Places tab, from the design canvas artboard `Places.dc.html`: one card per place on the living sky.
/// Kitimat only for now. The card shows what the published file has: the place, whether it is
/// station-checked and against which station, day 1's high and low, precipitation and Certainty.
/// Left out (nothing behind them yet): current temperature and condition icon, wind, "Current location",
/// "Edit", "Add a place", other places (docs/BUILD_PLAN.md, step 5).
struct PlacesScreen: View {
    let model: ForecastScreenModel
    var openWeather: () -> Void = {}

    @Environment(\.nowOverride) private var nowOverride
    @Environment(\.livingSky) private var livingSky

    var body: some View {
        SkyPage(model: model) {
            HStack {
                PlaceTitlePill(name: PlacesText.title, style: style, showsPin: false)
                Spacer(minLength: 0)
            }
            if let forecast = model.forecast {
                PlaceCard(forecast: forecast, open: openWeather)
                SkyNote {
                    VStack(spacing: 4) {
                        Text(verbatim: PlacesText.morePlaces)
                        OpenMeteoCredit(credits: forecast.credits)
                    }
                }
            }
        } right: {
            // One place: one column everywhere (a second column would only hold the note).
            EmptyView()
        }
        .overlay {
            if model.forecast == nil { NoForecastView(model: model, style: style) }
        }
        .refreshable { await model.load() }
        .task { await model.refreshIfDue() }
    }

    private var style: SkyStyle {
        SkyStyle.current(for: model.forecast, now: nowOverride ?? .now, living: livingSky)
    }
}

/// "Weather data by Open-Meteo.com", linked, next to the data (Open-Meteo's licence asks for a link wherever
/// its data is shown). Text and link from the file's credits.
private struct OpenMeteoCredit: View {
    let credits: [PlaceForecast.Credit]

    var body: some View {
        if let credit = credits.first(where: { $0.url.contains("open-meteo.com") }),
           let url = URL(string: credit.url), url.scheme == "https" {
            Link(destination: url) {
                Text(verbatim: credit.text).font(.inter(12.5, .bold, relativeTo: .caption))
                    .foregroundStyle(Color(Palette.link))
                    .frame(minHeight: 44)
            }
            .accessibilityHint(Text("Opens in your browser"))
        }
    }
}

/// One place (canvas place card): name and check status, then day 1's values and Certainty.
/// The whole card is one button that opens the Weather tab (canvas: the card links to the main screen).
struct PlaceCard: View {
    let forecast: PlaceForecast
    let open: () -> Void

    @Environment(\.unitChoice) private var units
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: open) {
            Card(padding: EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16)) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: forecast.place.name).font(.inter(19, .extraBold, relativeTo: .title3))
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color(Palette.textSecondary))
                        }
                        Text(verbatim: PlacesText.checkLine(forecast.place))
                            .font(.inter(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(Color(Palette.textSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let day = forecast.days.first {
                        tiles(day)
                        footer(day)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: PlacesText.cardLabel(forecast, units: units)))
        .accessibilityHint(Text("Opens the Weather tab"))
        .accessibilityAddTraits(.isButton)
    }

    private func tiles(_ day: PlaceForecast.Day) -> some View {
        let big = dynamicTypeSize.isAccessibilitySize
        let layout = big ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            tile(PlacesText.highLowLabel(day), PlacesText.highLow(day, unit: units.temperature), colour: Palette.white)
            tile(String(localized: "Precipitation"), PlacesText.precipitation(day, unit: units.rain), colour: Palette.rain)
        }
    }

    private func tile(_ label: String, _ value: String, colour: RGB) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: label).font(.inter(11.5, .regular, relativeTo: .caption2))
                .foregroundStyle(Color(Palette.textSecondary))
            Text(verbatim: value).font(.inter(14, .bold, relativeTo: .subheadline))
                .foregroundStyle(Color(colour))
                .monospacedDigit()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(Palette.detail)))
    }

    private func footer(_ day: PlaceForecast.Day) -> some View {
        let big = dynamicTypeSize.isAccessibilitySize
        let layout = big ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                         : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            HStack(spacing: 6) {
                CertaintyRing(certainty: day.certainty, tier: day.certaintyTier)
                    .frame(width: 16, height: 16)
                Text(verbatim: PlacesText.certaintyLine(day))
                    .font(.inter(12.5, .medium, relativeTo: .caption))
                    .foregroundStyle(Color(Palette.textBody))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !big { Spacer(minLength: 0) }
            Text(verbatim: PlacesText.checkPill(forecast.place))
                .font(.inter(12.5, .semibold, relativeTo: .caption))
                .foregroundStyle(Color(Palette.textBody))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(Palette.cardInner)))
        }
    }
}

/// Every string on the Places tab, built from the published file.
nonisolated enum PlacesText {
    static let title = String(localized: "Places", comment: "Places tab title")
    static let morePlaces = String(localized: "More places are coming.", comment: "Places tab, under the place list")

    static func isStationChecked(_ place: PlaceForecast.Place) -> Bool {
        !place.consensusOnly && place.truthStation != nil
    }

    /// "Station-checked" or "Consensus only" (canvas pill).
    static func checkPill(_ place: PlaceForecast.Place) -> String {
        isStationChecked(place)
            ? String(localized: "Station-checked", comment: "A place whose forecasts are scored against a weather station")
            : String(localized: "Consensus only", comment: "A place with no station of its own")
    }

    /// "Checked against Kitimat Forest Ave (ECCC)", or why it is not checked.
    static func checkLine(_ place: PlaceForecast.Place) -> String {
        guard isStationChecked(place), let station = place.truthStation else {
            return String(localized: "No station here, so these numbers are not checked locally.",
                          comment: "Places card, place with no station")
        }
        return String(localized: "Checked against \(ConsensusText.stationValue(station))",
                      comment: "Places card: the station the place is checked against. The value is the station and its network.")
    }

    /// "Wed high / low".
    static func highLowLabel(_ day: PlaceForecast.Day) -> String {
        String(localized: "\(ValueText.weekday(day.date)) high / low", comment: "Places card tile label. The value is a short weekday.")
    }

    /// "6° / 2°".
    static func highLow(_ day: PlaceForecast.Day, unit: TemperatureUnit) -> String {
        "\(ValueText.shortTemperature(day.high, in: unit)) / \(ValueText.shortTemperature(day.low, in: unit))"
    }

    /// "100% · 21 mm" (canvas order: chance, then amount).
    static func precipitation(_ day: PlaceForecast.Day, unit: RainUnit) -> String {
        "\(ValueText.percent(day.precipChance)) · \(ValueText.rowPrecipitation(day.precipMM, in: unit))"
    }

    /// "Wednesday's Certainty 91%".
    static func certaintyLine(_ day: PlaceForecast.Day) -> String {
        String(localized: "\(ValueText.fullWeekday(day.date))'s Certainty \(ValueText.percent(day.certainty))",
               comment: "Places card. Values: a weekday name, the Certainty percent.")
    }

    /// VoiceOver for the whole card.
    static func cardLabel(_ forecast: PlaceForecast, units: UnitChoice) -> String {
        let place = "\(forecast.place.name). \(checkPill(forecast.place)). \(checkLine(forecast.place))."
        guard let day = forecast.days.first else { return place }
        return "\(place) \(DayRowText.label(day, units: units))"
    }
}
