import SwiftUI

/// The hourly strip (beta, 28 Nov 2026), from the design canvas's "Hourly" card (`Main.dc.html`; titled "Hour by
/// hour" here, since the app never promises an update frequency and "hourly" reads like one): tiles of
/// time, condition icon, temperature and chance of precipitation, six to a row, with a line for each new day.
/// 48 hours from the current hour, then the 3-hour blocks to 96 h. The first 12 show; a button shows the rest.
/// Left out on purpose: the canvas's coloured confidence dot under each hour and its explanation (there is no
/// hourly Certainty, and the app makes no accuracy claim for the beta). Times on the phone's own clock.
struct HourlyCard: View {
    let forecast: PlaceForecast
    let now: Date

    @State private var showAll: Bool

    init(forecast: PlaceForecast, now: Date, showAll: Bool = false) {
        self.forecast = forecast
        self.now = now
        _showAll = State(initialValue: showAll)
    }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.unitChoice) private var units

    static let collapsedCount = 12

    var body: some View {
        let entries = HourlyText.upcoming(forecast.hourlyStrip, now: now)
        if !entries.isEmpty {
            Card(padding: EdgeInsets(top: 16, leading: 12, bottom: 14, trailing: 12)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Hour by hour").font(.inter(18, .extraBold, relativeTo: .headline))
                            .accessibilityAddTraits(.isHeader)
                        BetaPill()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    Text("New. Each hour blends the same sources as the days.",
                         comment: "Hourly card note: a beta, no accuracy claim")
                        .font(.inter(12.5, .regular, relativeTo: .caption))
                        .foregroundStyle(Color(Palette.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)

                    let shown = showAll ? entries : Array(entries.prefix(Self.collapsedCount))
                    ForEach(HourlyText.groups(shown, place: forecast.place, now: now), id: \.id) { group in
                        groupHeader(group.title)
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(group.entries) { entry in
                                HourTile(entry: entry, place: forecast.place)
                            }
                        }
                    }

                    if entries.count > Self.collapsedCount {
                        Button {
                            withAnimation(.snappy) { showAll.toggle() }
                        } label: {
                            HStack(spacing: 8) {
                                Text(showAll ? String(localized: "Show less")
                                             : String(localized: "Show all 48 hours and 3-hour blocks"))
                                Image(systemName: showAll ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 13, weight: .bold))
                                    .accessibilityHidden(true)
                            }
                            .font(.inter(14, .bold, relativeTo: .subheadline))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(showAll ? Text("Expanded") : Text("Collapsed"))
                    }
                }
            }
        }
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 3 : (dynamicTypeSize >= .xxLarge ? 4 : 6)
        return Array(repeating: GridItem(.flexible(), spacing: 6), count: count)
    }

    private func groupHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(.inter(13, .bold, relativeTo: .footnote))
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

/// One hour or one 3-hour block: time, icon, temperature, chance (shown at 30% or more, as the canvas).
struct HourTile: View {
    let entry: ForecastHour
    let place: PlaceForecast.Place

    @Environment(\.unitChoice) private var units

    var body: some View {
        let night = Daylight.isNight(entry.time.addingTimeInterval(Double(entry.hours) * 1800), place: place)
        VStack(spacing: 2) {
            Text(verbatim: HourlyText.time(entry))
                .font(.inter(11.5, .semibold, relativeTo: .caption2))
                .foregroundStyle(Color(Palette.textSecondary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            ConditionIcon(condition: entry.condition, night: night)
            Text(verbatim: ValueText.shortTemperature(entry.temp, in: units.temperature))
                .font(.inter(15, .bold, relativeTo: .subheadline))
            Text(verbatim: HourlyText.chance(entry))
                .font(.inter(11, .bold, relativeTo: .caption2))
                .foregroundStyle(Color(Palette.link))
                .frame(minHeight: 14)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(RGB(0x091A36)).opacity(0.32)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: HourlyText.spoken(entry, night: night, unit: units.temperature)))
    }
}

nonisolated enum HourlyText {
    static let chanceShownFrom = 30

    /// Entries from the current hour on (an hour or block that has fully passed is dropped).
    static func upcoming(_ entries: [ForecastHour], now: Date) -> [ForecastHour] {
        entries.filter { $0.time.addingTimeInterval(Double($0.hours) * 3600) > now }
    }

    struct Group: Identifiable {
        let id: String
        let title: String
        let entries: [ForecastHour]
    }

    /// Entries grouped by local day (phone's time zone), hours and 3-hour blocks apart.
    static func groups(_ entries: [ForecastHour], place: PlaceForecast.Place, now: Date = .now,
                       calendar: Calendar = .current) -> [Group] {
        var out: [Group] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.time)
            let key = "\(day.timeIntervalSince1970)-\(entry.hours)"
            if let last = out.last, last.id == key {
                out[out.count - 1] = Group(id: key, title: last.title, entries: last.entries + [entry])
            } else {
                out.append(Group(id: key, title: title(day, hours: entry.hours, now: now, calendar: calendar), entries: [entry]))
            }
        }
        return out
    }

    static func title(_ day: Date, hours: Int, now: Date = .now, calendar: Calendar = .current) -> String {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let name = calendar.isDate(day, inSameDayAs: now) ? String(localized: "Today")
            : calendar.isDate(day, inSameDayAs: tomorrow) ? String(localized: "Tomorrow")
            : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return hours > 1 ? String(localized: "\(name), in 3-hour steps", comment: "Hourly strip: day heading for 3-hour blocks") : name
    }

    static func time(_ entry: ForecastHour) -> String {
        entry.time.formatted(.dateTime.hour())
    }

    static func chance(_ entry: ForecastHour) -> String {
        guard let c = entry.precipChance, c >= chanceShownFrom else { return "" }
        return ValueText.percent(c)
    }

    /// "3 PM, rain, 5°, chance of precipitation 60%." For a block: "3 PM to 6 PM, ...".
    static func spoken(_ entry: ForecastHour, night: Bool, unit: TemperatureUnit) -> String {
        let start = entry.time.formatted(.dateTime.hour())
        let when = entry.hours > 1
            ? String(localized: "\(start) to \(entry.time.addingTimeInterval(Double(entry.hours) * 3600).formatted(.dateTime.hour()))")
            : start
        let cond = entry.condition.map { ConditionText.moment($0, night: night) } ?? String(localized: "no condition")
        let temp = ValueText.shortTemperature(entry.temp, in: unit)
        let chance = ValueText.percent(entry.precipChance)
        return String(localized: "\(when), \(cond), \(temp), chance of precipitation \(chance).",
                      comment: "VoiceOver, hourly tile: time, condition, temperature, chance")
    }
}

#if DEBUG
private struct BetaPreviewStack<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView { VStack(spacing: 14) { content }.padding(16) }
            .background { SkyView(style: SkyStyle(time: .day, weather: .cloudy)) }
    }
}

#Preview("Hourly card") {
    let model = ForecastScreenModel.previewFixture(beta: true)
    BetaPreviewStack { HourlyCard(forecast: model.forecast!, now: PreviewClock.beta) }
}

#Preview("Hourly card, all hours and blocks") {
    let model = ForecastScreenModel.previewFixture(beta: true)
    BetaPreviewStack { HourlyCard(forecast: model.forecast!, now: PreviewClock.beta, showAll: true) }
}

#Preview("Day rows with conditions") {
    @Previewable @State var expanded: Int? = 1
    let model = ForecastScreenModel.previewFixture(beta: true)
    BetaPreviewStack { ForecastCard(forecast: model.forecast!, expandedDay: $expanded) }
}

#Preview("Hourly card, largest text") {
    let model = ForecastScreenModel.previewFixture(beta: true)
    BetaPreviewStack { HourlyCard(forecast: model.forecast!, now: PreviewClock.beta) }
        .dynamicTypeSize(.accessibility3)
}
#endif
