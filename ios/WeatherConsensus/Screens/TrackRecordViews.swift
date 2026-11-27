import SwiftUI

// Consensus tab steps 2 and 3 from `track_record` (canvas `HowItWorks.dc.html`: "Average miss on
// tomorrow's high" and the habit rows), on the established navy cards. Numbers only from the file.

/// A small segmented control on a navy card (the Settings units control, made to fit a card):
/// each option at least 44 pt high; at accessibility text sizes the options stack full width.
struct ChoiceSegments<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, short: String, spoken: String)]
    @Binding var selection: Value
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let big = dynamicTypeSize.isAccessibilitySize
        let layout = big ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(verbatim: option.short)
                        .font(.inter(13.5, .bold, relativeTo: .subheadline))
                        .foregroundStyle(Color(chosen ? Palette.ink : Palette.textSecondary))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(chosen ? Color.white : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(title), \(option.spoken)"))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(Palette.cardInner)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.16)))
    }
}

/// Small print on a navy card.
private struct NoteText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.inter(12, .regular, relativeTo: .caption))
            .lineSpacing(2)
            .foregroundStyle(Color(Palette.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Step 2

/// Step 2's track record: pickers for highs, lows or rain and the lead day, then the consensus and every
/// source by average miss with today's weight. Archive numbers are labelled as archive; our own record
/// is shown only once it has enough days, and then on its own (never mixed into the same chart).
struct TrackRecordChart: View {
    let facts: TrackRecordFacts
    let stationName: String?

    @State private var variable: TrackVariable = .high
    @State private var chosenLead: Int?
    @State private var basis: TrackBasis = .archive
    @Environment(\.unitChoice) private var units

    var body: some View {
        if let record = facts.record, facts.hasArchive {
            let leads = facts.leads
            let lead = chosenLead.flatMap { leads.contains($0) ? $0 : nil } ?? leads.first ?? 1
            let liveReady = facts.liveHasNumbers(variable, lead: lead)
            let shownBasis: TrackBasis = liveReady ? basis : .archive
            VStack(alignment: .leading, spacing: 10) {
                ChoiceSegments(title: TrackRecordText.variablePickerTitle,
                               options: TrackVariable.allCases.map {
                                   ($0, TrackRecordText.variableShort($0), TrackRecordText.variableSpoken($0))
                               },
                               selection: $variable)
                if leads.count > 1 {
                    ChoiceSegments(title: TrackRecordText.leadPickerTitle,
                                   options: leads.map {
                                       ($0, TrackRecordText.leadShort($0), TrackRecordText.leadSpoken($0))
                                   },
                                   selection: Binding(get: { lead }, set: { chosenLead = $0 }))
                }
                if liveReady {
                    ChoiceSegments(title: TrackRecordText.basisPickerTitle,
                                   options: TrackBasis.allCases.map {
                                       ($0, TrackRecordText.basisShort($0), TrackRecordText.basisShort($0))
                                   },
                                   selection: $basis)
                }
                MissChart(rows: facts.rows(variable, lead: lead, basis: shownBasis), variable: variable,
                          basis: shownBasis, lead: lead)
                    .padding(.top, 4)
                if shownBasis == .archive {
                    NoteText(text: TrackRecordText.archiveSource(record, stationName: stationName))
                    NoteText(text: TrackRecordText.weightNote(variable, lead: lead))
                } else {
                    NoteText(text: TrackRecordText.liveSource(stationName: stationName, window: record.live?.window))
                }
                if !liveReady, let status = facts.liveStatus(lead: lead) {
                    LiveNote(text: TrackRecordText.liveTooFew(status, lead: lead))
                }
            }
        } else {
            NoteText(text: TrackRecordText.notInFile)
        }
    }
}

/// Our own record when it is too short: a plain note, no numbers.
private struct LiveNote: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CapsHead(text: TrackRecordText.liveHead)
            Text(verbatim: text)
                .font(.inter(13, .regular, relativeTo: .footnote))
                .foregroundStyle(Color(Palette.textBody))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(Palette.cardInner)))
        .accessibilityElement(children: .combine)
    }
}

/// Canvas "Average miss" bars: name, bar (shorter = closer), value, and today's weight (archive only).
struct MissChart: View {
    let rows: [TrackRecordFacts.Row]
    let variable: TrackVariable
    let basis: TrackBasis
    let lead: Int

    @Environment(\.unitChoice) private var units
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var nameWidth: CGFloat = 104
    @ScaledMetric(relativeTo: .footnote) private var valueWidth: CGFloat = 34
    @ScaledMetric(relativeTo: .footnote) private var weightWidth: CGFloat = 58

    var body: some View {
        let longest = TrackRecordFacts.longest(rows)
        let usual = TrackRecordFacts.usualDays(rows.filter { !$0.isConsensus })
        let big = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: big ? 14 : 7) {
            HStack(alignment: .bottom, spacing: 8) {
                CapsHead(text: TrackRecordText.missHead(variable, lead: lead, units: units))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if basis == .archive && !big {
                    CapsHead(text: TrackRecordText.weightHead)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: weightWidth, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
            ForEach(rows) { row in
                rowView(row, longest: longest, usual: usual, big: big)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: TrackRecordText.rowLabel(row, variable, units: units, basis: basis)))
            }
            if let line = TrackRecordText.usualDaysLine(usual) {
                NoteText(text: line).padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TrackRecordFacts.Row, longest: Double, usual: Int?, big: Bool) -> some View {
        let value = TrackRecordText.missValue(row.miss, variable, units: units)
        let caption: String? = {
            if row.miss == nil {
                return row.isConsensus && basis == .live ? TrackRecordText.notRecorded : TrackRecordText.tooFew(row.days)
            }
            if let days = row.days, days != usual, !row.isConsensus { return TrackRecordText.daysShort(days) }
            return nil
        }()
        let weight = basis == .archive && !row.isConsensus
            ? (row.weight.map(ValueText.share) ?? ValueText.missing) : ""
        let name = VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: row.name).font(.inter(13, row.isConsensus ? .extraBold : .bold, relativeTo: .footnote))
                .fixedSize(horizontal: false, vertical: true)
            if let caption {
                Text(verbatim: caption).font(.inter(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(Color(Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let bar = MissBar(id: row.id, fraction: row.miss.map { longest > 0 ? $0 / longest : 0 })
        Group {
            if big {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        name
                        Spacer(minLength: 8)
                        Text(verbatim: value).font(.inter(13, .extraBold, relativeTo: .footnote)).monospacedDigit()
                    }
                    bar
                    if !weight.isEmpty {
                        Text(verbatim: "\(TrackRecordText.weightHead.capitalized) \(weight)")
                            .font(.inter(12, .bold, relativeTo: .caption))
                            .foregroundStyle(Color(Palette.textSecondary))
                    }
                }
            } else {
                HStack(spacing: 8) {
                    name.frame(width: nameWidth, alignment: .leading)
                    bar
                    Text(verbatim: value).font(.inter(13, row.isConsensus ? .extraBold : .bold, relativeTo: .footnote))
                        .monospacedDigit()
                        .frame(width: valueWidth, alignment: .trailing)
                    if basis == .archive {
                        Text(verbatim: weight).font(.inter(13, .bold, relativeTo: .footnote))
                            .monospacedDigit()
                            .foregroundStyle(Color(Palette.textBody))
                            .frame(width: weightWidth, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.vertical, row.isConsensus ? 6 : 0)
        .padding(.horizontal, row.isConsensus ? 8 : 0)
        .background {
            if row.isConsensus {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Palette.cardInner))
            }
        }
        .padding(.horizontal, row.isConsensus ? -8 : 0) // canvas: the highlight reaches past the columns
    }
}

/// One bar: the source's colour, or the canvas gradient of source colours for the consensus.
/// Fixed height (does not grow with Dynamic Type, like the source bars). No bar when there is no miss.
private struct MissBar: View {
    let id: String
    let fraction: Double?

    static let consensusColors = ["gem_seamless", "ecmwf_ifs", "ukmo_seamless", "icon_seamless",
                                  "ecmwf_aifs025_single", "gfs_seamless"].map { Color(Palette.source($0)) }

    var body: some View {
        GeometryReader { proxy in
            if let fraction {
                Capsule()
                    .fill(id == TrackRecordFacts.consensusID
                          ? AnyShapeStyle(LinearGradient(colors: Self.consensusColors, startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(Color(Palette.source(id))))
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 6))
            }
        }
        .frame(height: 12)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

// MARK: - Step 3

/// Step 3's habit rows (canvas): colour, source, "Highs run 1.1 °C cold here", and the fix as a pill
/// ("+1.1°": what we add). Highs or lows; day 1 forecasts.
struct HabitList: View {
    let facts: TrackRecordFacts

    @State private var variable: TrackVariable = .high
    @Environment(\.unitChoice) private var units
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let lead = 1

    var body: some View {
        if let record = facts.record, facts.hasArchive {
            VStack(alignment: .leading, spacing: 10) {
                ChoiceSegments(title: TrackRecordText.variablePickerTitle,
                               options: [TrackVariable.high, .low].map {
                                   ($0, TrackRecordText.variableShort($0), TrackRecordText.variableSpoken($0))
                               },
                               selection: $variable)
                CapsHead(text: TrackRecordText.habitHead(lead: Self.lead)).padding(.top, 4)
                VStack(spacing: 8) {
                    ForEach(facts.habits(variable, lead: Self.lead)) { habit in
                        row(habit)
                    }
                }
                NoteText(text: TrackRecordText.habitSource(record))
            }
        } else {
            NoteText(text: TrackRecordText.habitsNotInFile)
        }
    }

    private func row(_ habit: TrackRecordFacts.Habit) -> some View {
        let big = dynamicTypeSize.isAccessibilitySize
        let layout = big ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                         : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(Color(Palette.source(habit.id)))
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: habit.name).font(.inter(14, .extraBold, relativeTo: .subheadline))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: TrackRecordText.habitSentence(habit, variable, unit: units.temperature))
                        .font(.inter(12.5, .regular, relativeTo: .caption))
                        .foregroundStyle(Color(Palette.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FixPill(bias: habit.bias, unit: units.temperature)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(Palette.cardInner)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: TrackRecordText.habitLabel(habit, variable, unit: units.temperature)))
    }
}

/// The fix as a pill, in the canvas tints: adding (source runs cold) orange, taking off (runs warm) blue.
struct FixPill: View {
    let bias: Double?
    let unit: TemperatureUnit

    var body: some View {
        let tint = Palette.fixPill(TrackRecordText.fixDirection(bias, unit: unit))
        Text(verbatim: TrackRecordText.fixPill(bias, unit: unit))
            .font(.inter(13, .extraBold, relativeTo: .footnote))
            .monospacedDigit()
            .foregroundStyle(Color(tint.ink))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color(tint.fill)))
            .fixedSize()
    }
}

#if DEBUG
#Preview("Track record, real 27 Nov file") {
    let forecast = ForecastScreenModel.previewFixture(trackRecord: true).forecast!
    ScrollView {
        VStack(spacing: 14) {
            Card { TrackRecordChart(facts: TrackRecordFacts(forecast), stationName: "Kitimat Forest Ave") }
            Card { HabitList(facts: TrackRecordFacts(forecast)) }
        }
        .padding(16)
    }
    .background(SkyView(style: SkyStyle(time: .day, weather: nil)))
}

#Preview("Track record, °F and in, largest text") {
    let forecast = ForecastScreenModel.previewFixture(trackRecord: true).forecast!
    ScrollView {
        VStack(spacing: 14) {
            Card { TrackRecordChart(facts: TrackRecordFacts(forecast), stationName: "Kitimat Forest Ave") }
            Card { HabitList(facts: TrackRecordFacts(forecast)) }
        }
        .padding(16)
    }
    .background(SkyView(style: SkyStyle(time: .night, weather: nil)))
    .environment(\.unitChoice, UnitChoice(temperature: .fahrenheit, rain: .inches))
    .dynamicTypeSize(.accessibility5)
}

#Preview("Track record, not in file") {
    let forecast = ForecastScreenModel.previewFixture().forecast!
    Card { TrackRecordChart(facts: TrackRecordFacts(forecast), stationName: nil) }
        .padding(16)
        .background(SkyView(style: SkyStyle(time: .day, weather: nil)))
}
#endif
