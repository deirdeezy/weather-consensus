import SwiftUI

/// What the "Tested on real weather" card says, from the file's `backtest` block alone. Pure, for the tests.
nonisolated enum TestedText {
    /// Whole months in the scored period, rounded (1 Jan to 30 Oct 2026 is 10).
    static func months(_ backtest: Backtest) -> Int {
        guard let from = backtest.scoredFrom.utcMidnight, let to = backtest.scoredTo.utcMidnight else { return 0 }
        let days = to.timeIntervalSince(from) / 86_400 + 1
        return Int((days / (365.25 / 12)).rounded())
    }

    /// "TESTED ON 10 MONTHS OF REAL KITIMAT WEATHER" ("a year" only when the period is one).
    static func heading(_ backtest: Backtest, placeName: String) -> String {
        let m = months(backtest)
        let text = m == 12
            ? String(localized: "Tested on a year of real \(placeName) weather", comment: "Tested card heading. Value: place name.")
            : String(localized: "Tested on \(m) months of real \(placeName) weather",
                     comment: "Tested card heading. Values: whole months scored, place name.")
        return text.uppercased()
    }

    static let consensusName = String(localized: "Weather Consensus", comment: "Tested card tile: our blended forecast")

    /// "One model alone (ECMWF)".
    static func baselineName(_ backtest: Backtest, names: SourceNames) -> String {
        String(localized: "One model alone (\(names.name(for: backtest.baseline)))",
               comment: "Tested card tile. Value: the model's display name.")
    }

    static let tileCaption = String(localized: "average miss, day\u{00A0}1 highs", comment: "Tested card tile caption; day and 1 kept together")

    static func dayOne(_ backtest: Backtest) -> Backtest.Lead? { backtest.leads.first { $0.lead == 1 } }

    /// The tile number: "1.0°" (or "1.8°" in deg F: a difference, x 1.8).
    static func tileValue(_ miss: Double?, unit: TemperatureUnit) -> String {
        guard let miss else { return ValueText.missing }
        return TrackRecordText.missValue(miss, .high, units: UnitChoice(temperature: unit)) + "°"
    }

    /// How much closer the consensus was than the one model, percent; nil if either is missing.
    static func closer(_ tested: Backtest.Tested?) -> Int? {
        guard let c = tested?.consensus, let b = tested?.baseline, b > 0 else { return nil }
        return Int(((1 - c / b) * 100).rounded())
    }

    /// "29% closer than ECMWF alone on day 1 highs, and 32% on lows." Built from the two numbers each.
    static func sentence(_ backtest: Backtest, names: SourceNames) -> String? {
        guard let d1 = dayOne(backtest), let high = closer(d1.high), let low = closer(d1.low) else { return nil }
        let model = names.name(for: backtest.baseline)
        guard high > 0, low > 0 else {
            return String(localized: "Day 1 highs: \(high)% against \(model) alone; lows: \(low)%.",
                          comment: "Tested card when the consensus was not closer on both. Values: percents, model.")
        }
        return String(localized: "\(high)% closer than \(model) alone on day 1 highs, and \(low)% on lows.",
                      comment: "Tested card. Values: percent closer on highs, model name, percent on lows.")
    }

    /// How it was tested, period, days, and that it is not our live record.
    static func method(_ backtest: Backtest) -> String {
        let station = backtest.station?.name ?? String(localized: "the station")
        let days = dayOne(backtest)?.high?.days ?? 0
        let pastOnly = backtest.method?.pastDataOnly == true
        let how = pastOnly
            ? String(localized: "A backtest: each day was rebuilt from archived forecasts using only data from before it, then checked against \(station).",
                     comment: "Tested card footnote. Value: station name.")
            : String(localized: "A backtest on archived forecasts, checked against \(station).",
                     comment: "Tested card footnote. Value: station name.")
        let when = String(localized: "Scored \(dayMonthYear(backtest.scoredFrom)) to \(dayMonthYear(backtest.scoredTo)), \(days) days for day 1 highs. Not our own live record.",
                          comment: "Tested card footnote. Values: first day, last day, days scored.")
        return how + " " + when
    }

    /// "1 Jan 2026" (or the phone's order). Climate days are plain dates: formatted in UTC.
    static func dayMonthYear(_ date: LocalDate) -> String {
        guard let midnight = date.utcMidnight else { return date.description }
        return midnight.formatted(Date.FormatStyle(timeZone: .gmt).day().month(.abbreviated).year())
    }

    /// VoiceOver for the two tiles.
    static func tilesLabel(_ backtest: Backtest, names: SourceNames, unit: TemperatureUnit) -> String {
        let spoken = unit == .celsius ? String(localized: "degrees Celsius") : String(localized: "degrees Fahrenheit")
        let d1 = dayOne(backtest)
        let c = TrackRecordText.missValue(d1?.high?.consensus, .high, units: UnitChoice(temperature: unit))
        let b = TrackRecordText.missValue(d1?.high?.baseline, .high, units: UnitChoice(temperature: unit))
        let consensusValue = c + ValueText.nbsp + spoken
        let baselineValue = b + ValueText.nbsp + spoken
        return String(localized: "Average miss on day 1 highs: \(consensusName), \(consensusValue); \(baselineName(backtest, names: names)), \(baselineValue)",
                      comment: "VoiceOver for the tested card tiles. Values: name, miss with unit, name, miss with unit.")
    }
}

/// Canvas "Tested on a year of real Kitimat weather" card, with the file's backtest numbers and period.
/// Navy card, two tiles (canvas rgba(9,26,54,0.5) and 0.25), one sentence and how it was tested.
struct TestedCard: View {
    let backtest: Backtest
    let placeName: String
    let names: SourceNames

    @Environment(\.unitChoice) private var units
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let d1 = TestedText.dayOne(backtest)
        Card(padding: EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)) {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: TestedText.heading(backtest, placeName: placeName))
                    .font(.inter(12.5, .extraBold, relativeTo: .caption))
                    .tracking(1)
                    .foregroundStyle(Color(Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
                layout {
                    tile(TestedText.consensusName, TestedText.tileValue(d1?.high?.consensus, unit: units.temperature),
                         fill: Palette.heroPanel, strong: true)
                    tile(TestedText.baselineName(backtest, names: names),
                         TestedText.tileValue(d1?.high?.baseline, unit: units.temperature),
                         fill: Palette.testedBaseline, strong: false)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: TestedText.tilesLabel(backtest, names: names, unit: units.temperature)))
                if let sentence = TestedText.sentence(backtest, names: names) {
                    Text(verbatim: sentence)
                        .font(.inter(14, .regular, relativeTo: .subheadline))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: TestedText.method(backtest))
                    .font(.inter(12, .regular, relativeTo: .caption))
                    .lineSpacing(2)
                    .foregroundStyle(Color(Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ label: String, _ value: String, fill: RGB, strong: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label).font(.inter(12.5, .regular, relativeTo: .caption))
                .foregroundStyle(Color(Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: value).font(.inter(30, .extraBold, relativeTo: .largeTitle))
                .foregroundStyle(strong ? Color.white : Color(Palette.textSecondary))
                .monospacedDigit()
            Text(verbatim: TestedText.tileCaption).font(.inter(12, .regular, relativeTo: .caption))
                .foregroundStyle(Color(Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(fill)))
    }
}

#if DEBUG
#Preview("Tested card") {
    let forecast = ForecastScreenModel.previewFixture(trackRecord: true).forecast!
    TestedCard(backtest: forecast.backtest!, placeName: "Kitimat", names: SourceNames(forecast))
        .padding(16)
        .background(SkyView(style: SkyStyle(time: .day, weather: nil)))
}

#Preview("Tested card, °F, largest text") {
    let forecast = ForecastScreenModel.previewFixture(trackRecord: true).forecast!
    ScrollView {
        TestedCard(backtest: forecast.backtest!, placeName: "Kitimat", names: SourceNames(forecast))
            .padding(16)
    }
    .background(SkyView(style: SkyStyle(time: .night, weather: nil)))
    .environment(\.unitChoice, UnitChoice(temperature: .fahrenheit, rain: .inches))
    .dynamicTypeSize(.accessibility5)
}
#endif
