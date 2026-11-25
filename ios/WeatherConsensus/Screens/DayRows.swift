import SwiftUI

/// The 14 days (design canvas v8, "14-day forecast" card).
struct ForecastCard: View {
    let forecast: PlaceForecast
    @Binding var expandedDay: Int?

    var body: some View {
        let names = SourceNames(forecast)
        Card(padding: EdgeInsets(top: 16, leading: 12, bottom: 8, trailing: 12)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("14-day forecast").font(.inter(18, .extraBold, relativeTo: .headline))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text("Tap a day for details").font(.inter(12.5, .regular, relativeTo: .caption))
                        .foregroundStyle(Color(Palette.textSecondary))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 12)

                ForEach(forecast.days) { day in
                    DayRow(day: day, names: names, isExpanded: expandedDay == day.day) {
                        withAnimation(.snappy) {
                            expandedDay = expandedDay == day.day ? nil : day.day
                        }
                    }
                }
            }
        }
    }
}

/// One day. Closed, it is the canvas compact row: day and date, precipitation, chance, high over low,
/// chevron, Certainty badge. The whole closed row (badge included) is one button that opens the panel.
struct DayRow: View {
    let day: PlaceForecast.Day
    let names: SourceNames
    let isExpanded: Bool
    let toggle: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.unitChoice) private var units
    @ScaledMetric(relativeTo: .body) private var minRowHeight: CGFloat = 62

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                closedRow
                    .frame(minHeight: minRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // One VoiceOver element: the button's own label replaces its children (badge included).
            .accessibilityLabel(DayRowText.label(day, units: units))
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(Text("Shows the Certainty breakdown and sources for this day"))

            if isExpanded {
                DayPanel(day: day, names: names)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isExpanded ? Color(Palette.rowOpen) : .clear))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var closedRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Largest text: the same values, stacked so nothing truncates.
            VStack(alignment: .leading, spacing: 6) {
                dateLabel
                HStack(spacing: 10) { precipitation; chance }
                HStack(spacing: 10) { highLow(stacked: true); chevron }
                CertaintyBadge(day: day)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    dateLabel.frame(minWidth: 44, alignment: .leading)
                    precipitation.frame(maxWidth: .infinity, alignment: .leading)
                    chance.frame(minWidth: 34, alignment: .leading)
                    highLow(stacked: false).frame(minWidth: 32, alignment: .trailing)
                    chevron.frame(width: 12)
                }
                .padding(.vertical, 6)
                .padding(.leading, 4)
                CertaintyBadge(day: day)
                    .padding(.trailing, 2)
            }
            .monospacedDigit()
        }
    }

    private var dateLabel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: ValueText.weekday(day.date)).font(.inter(15, .bold, relativeTo: .body))
            Text(verbatim: ValueText.dayMonth(day.date)).font(.inter(12, .regular, relativeTo: .caption))
                .foregroundStyle(Color(Palette.textSecondary))
        }
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private var precipitation: some View {
        if day.precipMM == 0 {
            Text(verbatim: ValueText.rowPrecipitation(day.precipMM, in: units.rain))
                .font(.inter(11.5, .semibold, relativeTo: .caption))
                .foregroundStyle(Color(Palette.textSecondary))
        } else {
            HStack(spacing: 3) {
                Image(systemName: "drop.fill").font(.system(size: 9)).accessibilityHidden(true)
                Text(verbatim: ValueText.rowPrecipitation(day.precipMM, in: units.rain))
                    .font(.inter(11.5, .bold, relativeTo: .caption))
            }
            .foregroundStyle(Color(Palette.rain))
            .lineLimit(1)
        }
    }

    private var chance: some View {
        Text(verbatim: ValueText.percent(day.precipChance))
            .font(.inter(13, .bold, relativeTo: .footnote))
            .foregroundStyle(Color(Palette.link))
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    private func highLow(stacked: Bool) -> some View {
        let high = Text(verbatim: ValueText.shortTemperature(day.high, in: units.temperature)).font(.inter(16, .extraBold, relativeTo: .body))
        let low = Text(verbatim: ValueText.shortTemperature(day.low, in: units.temperature)).font(.inter(13, .semibold, relativeTo: .footnote))
            .foregroundStyle(Color(Palette.textSecondary))
        if stacked {
            HStack(alignment: .firstTextBaseline, spacing: 8) { high; low }
        } else {
            VStack(alignment: .trailing, spacing: 0) { high; low }.fixedSize()
        }
    }

    private var chevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color(Palette.textSecondary))
    }
}

nonisolated enum DayRowText {
    /// "Wednesday 25 November. Precipitation 21 mm, chance 100%. High 6°, low 2°. Certainty 91 percent, High tier."
    static func label(_ day: PlaceForecast.Day, units: UnitChoice = .metric) -> String {
        let amount = ValueText.rowPrecipitation(day.precipMM, in: units.rain)
        let precipitation = day.precipMM == 0
            ? amount
            : String(localized: "Precipitation \(amount)",
                     comment: "VoiceOver, day row: precipitation amount")
        return String(localized: "\(ValueText.spokenDate(day.date)). \(precipitation), chance \(ValueText.percent(day.precipChance)). High \(ValueText.shortTemperature(day.high, in: units.temperature)), low \(ValueText.shortTemperature(day.low, in: units.temperature)). \(CertaintyText.ringLabel(day)).",
                      comment: "VoiceOver label for a closed day row: date, precipitation, chance, high, low, Certainty and tier")
    }

    /// "HOW 9 SOURCES REACHED CONSENSUS", or "... AND THE NORMAL ..." when the normal has weight.
    static func blendHead(_ day: PlaceForecast.Day) -> String {
        let weighted = day.weights.filter { $0.weight > 0 }
        let models = weighted.filter { $0.id != "normal" }.count
        let withNormal = weighted.contains { $0.id == "normal" }
        let text: String = switch (models == 1, withNormal) {
        case (true, false): String(localized: "How 1 source reached consensus")
        case (true, true): String(localized: "How 1 source and the normal reached consensus")
        case (false, false): String(localized: "How \(models) sources reached consensus")
        case (false, true): String(localized: "How \(models) sources and the normal reached consensus")
        }
        return text.uppercased()
    }
}

/// Opened day (canvas breakdown, drawn inline on navy): big ring with %, tier pill, the odds sentence,
/// the 10 dots with their sentence, the source bar, every source with its share, then the exact values
/// in the file. Nothing the file does not have.
struct DayPanel: View {
    let day: PlaceForecast.Day
    let names: SourceNames
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.unitChoice) private var units

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            certaintyBox
            sourcesSection
            valuesSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(Palette.detail)))
    }

    private var certaintyBox: some View {
        let big = dynamicTypeSize.isAccessibilitySize
        let top = big ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                      : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        return VStack(alignment: .leading, spacing: 12) {
            top {
                BigCertaintyRing(day: day)
                VStack(alignment: .leading, spacing: 4) {
                    TierPill(tier: day.certaintyTier)
                    Text(verbatim: CertaintyText.oddsSentence(day, unit: units.temperature))
                        .font(.inter(14, .regular, relativeTo: .subheadline))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                caps(String(localized: "What \(ValueText.percent(day.certainty)) looks like").uppercased())
                CertaintyDots(day: day, fill: true)
                Text(verbatim: CertaintyText.dotsSentence(day, unit: units.temperature))
                    .font(.inter(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color(Palette.textBody))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true) // the dots say it
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(Palette.ink).opacity(0.35)))
    }

    private var sourcesSection: some View {
        let weighted = day.weights.filter { $0.weight > 0 }
        let total = weighted.reduce(0) { $0 + $1.weight }
        return VStack(alignment: .leading, spacing: 8) {
            caps(DayRowText.blendHead(day))
            SourceBar(weights: day.weights, names: names, thickness: 16)
            HStack(spacing: 8) {
                Text("SOURCE").frame(maxWidth: .infinity, alignment: .leading)
                Text("WEIGHT")
            }
            .font(.inter(10.5, .extraBold, relativeTo: .caption2))
            .tracking(0.5)
            .foregroundStyle(Color(Palette.textSecondary))
            .padding(.leading, 20)
            .padding(.top, 4)
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                ForEach(weighted, id: \.id) { item in
                    let share = total > 0 ? item.weight / total : 0
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(Color(Palette.source(item.id)))
                            .frame(width: 12, height: 12)
                        Text(verbatim: names.name(for: item.id))
                            .font(.inter(13.5, .bold, relativeTo: .subheadline))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ShareBar(share: share, colour: Palette.source(item.id))
                            .accessibilityHidden(true)
                        Text(verbatim: ValueText.share(share))
                            .font(.inter(12.5, .extraBold, relativeTo: .caption))
                            .monospacedDigit()
                            .frame(minWidth: 34, alignment: .trailing)
                    }
                    .frame(minHeight: 34)
                    .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var valuesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            caps(String(localized: "Exact values").uppercased())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 400 : 120), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                fact(String(localized: "High"), ValueText.temperature(day.high, in: units.temperature))
                fact(String(localized: "Low"), ValueText.temperature(day.low, in: units.temperature))
                fact(String(localized: "Precipitation"), ValueText.precipitation(day.precipMM, in: units.rain))
                fact(ValueText.chanceLabel(units.rain), ValueText.percent(day.precipChance))
            }
        }
    }

    private func caps(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.inter(11.5, .extraBold, relativeTo: .caption2))
            .tracking(0.7)
            .foregroundStyle(Color(Palette.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: label).font(.inter(11.5, .regular, relativeTo: .caption2))
                .foregroundStyle(Color(Palette.textSecondary))
            Text(verbatim: value).font(.inter(15, .extraBold, relativeTo: .subheadline))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(Palette.ink).opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}

/// Canvas per-source weight bar: 46 x 8 pt, full at the 35% cap (the weighting guardrail).
private struct ShareBar: View {
    let share: Double
    let colour: RGB

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.12))
            Capsule().fill(Color(colour)).frame(width: 46 * min(share / 0.35, 1))
        }
        .frame(width: 46, height: 8)
    }
}
