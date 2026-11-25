import SwiftUI

/// The Consensus tab ("How it works"), from the design canvas artboard `HowItWorks.dc.html` (v8):
/// a hero card, then the five steps (gather, check, fix habits, weight, say how sure), then the data credits.
/// Drawn on the living sky with navy cards, like the Weather tab. Every number comes from the published
/// file (schema v1); what the canvas shows that the file does not have is left out (docs/BUILD_PLAN.md).
struct ConsensusScreen: View {
    let model: ForecastScreenModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.nowOverride) private var nowOverride

    /// Same rule as the Weather tab: size classes only, never device or orientation.
    private var twoColumns: Bool {
        horizontalSizeClass == .regular || verticalSizeClass == .compact
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let style = SkyStyle.current(for: model.forecast, now: nowOverride ?? context.date)
            ScrollView {
                content(style: style)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: twoColumns ? 1100 : 640)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background { SkyView(style: style) }
            .overlay {
                if model.forecast == nil { NoForecastView(model: model, style: style) }
            }
            .refreshable { await model.load() }
        }
        // The Weather tab loads on appear; this covers opening the app straight onto this tab.
        .task {
            if model.forecast == nil && !model.isLoading { await model.load() }
        }
    }

    @ViewBuilder
    private func content(style: SkyStyle) -> some View {
        let layout = twoColumns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(spacing: 14))
        layout {
            VStack(spacing: 14) {
                HStack {
                    PlaceTitlePill(name: model.forecast?.place.name, style: style)
                    Spacer(minLength: 0)
                }
                if let forecast = model.forecast {
                    let facts = ConsensusFacts(forecast)
                    HeroCard(facts: facts)
                    GatherStep(facts: facts)
                    HomeworkStep(facts: facts)
                    HabitsStep(facts: facts)
                }
            }
            .frame(maxWidth: .infinity)

            if let forecast = model.forecast {
                let facts = ConsensusFacts(forecast)
                VStack(spacing: 14) {
                    WeightStep(facts: facts)
                    SureStep(facts: facts)
                    CreditsCard(credits: forecast.credits)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Facts from the file

/// Everything the Consensus tab shows, worked out from one published file. No other source of numbers.
nonisolated struct ConsensusFacts: Sendable {
    let forecast: PlaceForecast
    let names: SourceNames

    init(_ forecast: PlaceForecast) {
        self.forecast = forecast
        self.names = SourceNames(forecast)
    }

    var placeName: String { forecast.place.name }

    /// Day 1, the first day in the file (v1 starts at tomorrow).
    var firstDay: PlaceForecast.Day? { forecast.days.first }

    /// Canvas order for the step 1 chips. Ids not listed follow in file order.
    static let chipOrder = ["gem_seamless", "ecmwf_ifs", "ecmwf_aifs025_single", "ukmo_seamless", "icon_seamless",
                            "gfs_seamless", "jma_seamless", "cma_grapes_global", "meteofrance_seamless"]

    /// Forecast models in the file (every source with weight on any day), the normal left out,
    /// in the canvas order (`chipOrder`), then any other id in file order. The count is the file's.
    var models: [PlaceForecast.Source] {
        let inFile = forecast.sources.filter { $0.id != "normal" }
        let known = Self.chipOrder.compactMap { id in inFile.first { $0.id == id } }
        return known + inFile.filter { !Self.chipOrder.contains($0.id) }
    }

    /// The climate normal, when it has weight on any day.
    var normal: PlaceForecast.Source? { forecast.sources.first { $0.id == "normal" } }

    /// Days for "Further out, the consensus shifts": the canvas shows day 1, day 7 and day 13.
    var shiftDays: [PlaceForecast.Day] {
        [1, 7, 13].compactMap { lead in forecast.days.first { $0.day == lead } }
    }

    /// One worked example per tier, the first day of each tier in the file (High, then Medium, then Low).
    var examples: [PlaceForecast.Day] {
        CertaintyTier.allCases.compactMap { tier in
            forecast.days.first { $0.certainty != nil && $0.certaintyTier == tier }
        }
    }

    /// One source's share of a day's blend.
    struct Share: Identifiable, Equatable, Sendable {
        let id: String
        let share: Double
    }

    /// Sources with weight on a day, in file order (largest first), with their share of the blend (shares add to 1).
    static func shares(_ day: PlaceForecast.Day) -> [Share] {
        let weighted = day.weights.filter { $0.weight > 0 }
        let total = weighted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [] }
        return weighted.map { Share(id: $0.id, share: $0.weight / total) }
    }
}

// MARK: - Text

/// Words for the Consensus tab. Plain explanation plus values from the file; no fixed source count.
nonisolated enum ConsensusText {
    static let heroCaps = String(localized: "Weather Consensus").uppercased()
    static let heroTitle = String(localized: "Many forecasts in. One consensus out.",
                                  comment: "Consensus tab hero title. Never a fixed number of sources.")

    static func heroBody(placeName: String, consensusOnly: Bool) -> String {
        consensusOnly
            ? String(localized: "Most weather apps show you one computer model. We pull every major one and weigh them by track record into one consensus. \(placeName) has no weather station of its own, so its weights are borrowed and not checked here. Then we tell you how sure we are.",
                     comment: "Consensus tab hero text for a place with no station. The value is the place name.")
            : String(localized: "Most weather apps show you one computer model. We pull every major one, check each against what really happened in \(placeName), and weigh them by track record into one consensus. Then we tell you how sure we are.",
                     comment: "Consensus tab hero text. The value is the place name.")
    }

    /// VoiceOver for the hero diagram: "Wednesday: 9 sources blend into one consensus. Certainty 91 percent, High tier."
    static func diagramLabel(_ day: PlaceForecast.Day) -> String {
        let count = ConsensusFacts.shares(day).count
        return String(localized: "\(ValueText.fullWeekday(day.date)): \(count) sources blend into one consensus. \(CertaintyText.ringLabel(day)).",
                      comment: "VoiceOver label for the Consensus tab hero diagram: weekday, number of sources, Certainty")
    }

    static let consensusWord = String(localized: "consensus", comment: "Small label under the blended bar in the hero diagram")

    // Steps
    static let gatherTitle = String(localized: "We gather")
    static let homeworkTitle = String(localized: "We check their homework")
    static let habitsTitle = String(localized: "We fix their habits")
    static let weightTitle = String(localized: "We weight by track record")
    static let sureTitle = String(localized: "We tell you how sure we are")

    static func stepLabel(_ number: Int, _ title: String) -> String {
        String(localized: "Step \(number): \(title)", comment: "VoiceOver heading for a numbered step on the Consensus tab")
    }

    static func gatherText(placeName: String, hasNormal: Bool) -> String {
        hasNormal
            ? String(localized: "We check each source for new forecast runs and pull them as they come out. Further out, \(placeName)'s 1991 to 2020 normal joins in as one more source.",
                     comment: "Step 1 text. The value is the place name.")
            : String(localized: "We check each source for new forecast runs and pull them as they come out.",
                     comment: "Step 1 text, when the file has no climate normal")
    }

    /// "9 FORECAST MODELS" (counted from the file).
    static func modelsHead(_ count: Int) -> String {
        (count == 1
            ? String(localized: "1 forecast model")
            : String(localized: "\(count) forecast models", comment: "Step 1 heading over the model chips; counted from the file")
        ).uppercased()
    }

    static let normalHead = String(localized: "Plus the normal", comment: "Step 1 heading over the climate normal chip").uppercased()

    static func homeworkText(_ place: PlaceForecast.Place) -> String {
        guard !place.consensusOnly, let station = place.truthStation else {
            return String(localized: "\(place.name) has no weather station of its own, so its weights are borrowed and its numbers are not checked here.",
                          comment: "Step 2 text for a place with no station. The value is the place name.")
        }
        return String(localized: "We score each source's recent forecasts against what really happened at the \(station.name) weather station.",
                      comment: "Step 2 text. The value is the truth station's name.")
    }

    static let checkedAgainst = String(localized: "Checked against", comment: "Step 2 tile label: the truth station")
    static let latestScores = String(localized: "Latest scores", comment: "Step 2 tile label: the date of the latest scores")

    /// "Kitimat Forest Ave (ECCC)".
    static func stationValue(_ station: PlaceForecast.TruthStation) -> String {
        String(localized: "\(station.name) (\(station.network))", comment: "Station name, then its network in brackets")
    }

    static func habitsText(placeName: String) -> String {
        String(localized: "Every source has quirks in \(placeName). We correct them before they count, using the last 30 days of results.",
               comment: "Step 3 text. The value is the place name.")
    }

    static let weightText = String(localized: "Sources that have been closer lately count for more. Weights update as new scores come in, so the consensus leans toward whoever is doing best right now. Shares shown are for the high.",
                                   comment: "Step 4 text")

    /// "WEDNESDAY'S CONSENSUS".
    static func dayConsensusHead(_ day: PlaceForecast.Day) -> String {
        String(localized: "\(ValueText.fullWeekday(day.date))'s consensus", comment: "Step 4 heading over day 1's source bar. The value is a weekday.")
            .uppercased()
    }

    static let shiftHead = String(localized: "Further out, the consensus shifts").uppercased()

    /// VoiceOver for one of the day 1, 7 and 13 bars: "Day 7, Tuesday 1 December. Sources for the high: ..."
    static func shiftRowLabel(_ day: PlaceForecast.Day, names: SourceNames) -> String {
        let weighted = day.weights.filter { $0.weight > 0 }
        let total = weighted.reduce(0) { $0 + $1.weight }
        return "\(leadDay(day)), \(ValueText.spokenDate(day.date)). \(SourceText.barLabel(weights: weighted, total: total, names: names))"
    }

    /// "Day 7".
    static func leadDay(_ day: PlaceForecast.Day) -> String {
        String(localized: "Day \(day.day)", comment: "Lead day, 1 to 14")
    }

    /// Under the three bars. A plain fact about the schema, then the normal's share on the last bar, from the file.
    static func shiftText(facts: ConsensusFacts) -> String {
        let intro = String(localized: "Not every model runs two weeks ahead, and each one's track record changes with the range, so the blend changes from day to day.",
                           comment: "Step 4 text under the day 1, 7 and 13 bars")
        guard let last = facts.shiftDays.last,
              let normal = ConsensusFacts.shares(last).first(where: { $0.id == "normal" }) else { return intro }
        let name = facts.names.name(for: "normal")
        let tail = String(localized: "On day \(last.day), the \(name) is \(ValueText.share(normal.share)) of the high.",
                          comment: "Step 4: the climate normal's share on the last bar. Values: lead day, normal's name, share")
        return intro + " " + tail
    }

    static let sureText = String(localized: "The ring on every day is the odds its high lands within 2\u{00A0}°C (3.6\u{00A0}°F) of our number. Think of it as days out of 10.",
                                 comment: "Step 5 text")

    /// "Wed 25 Nov · High".
    static func exampleTitle(_ day: PlaceForecast.Day) -> String {
        "\(ValueText.date(day.date)) · \(ValueText.tier(day.certaintyTier))"
    }

    /// "About 9 of 10 days like this land within 2 °C."
    static func exampleSentence(_ day: PlaceForecast.Day) -> String {
        String(localized: "About \(CertaintyText.filledDots(day.certainty)) of 10 days like this land within 2\u{00A0}°C.",
               comment: "Step 5 worked example, under the 10 dots")
    }

    /// VoiceOver for a worked example: date, ring and dots.
    static func exampleLabel(_ day: PlaceForecast.Day) -> String {
        "\(ValueText.spokenDate(day.date)). \(CertaintyText.ringLabel(day)). \(CertaintyText.dotsLabel(day))"
    }

    static let chartHead = String(localized: "How sure we are, day by day").uppercased()

    /// VoiceOver for the day-by-day chart: every day with its Certainty.
    static func chartLabel(_ days: [PlaceForecast.Day]) -> String {
        let parts = days.map { "\(ValueText.spokenDate($0.date)) \(ValueText.percent($0.certainty))" }
        return String(localized: "Certainty by day: \(parts.formatted(.list(type: .and)))",
                      comment: "VoiceOver label for the 14-day Certainty chart; the list is dates with their Certainty")
    }
}

// MARK: - Shared pieces

/// Small caps heading inside a card (canvas: 11.5 pt, extra bold, tracked).
private struct CapsHead: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.inter(11.5, .extraBold, relativeTo: .caption2))
            .tracking(0.7)
            .foregroundStyle(Color(Palette.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Body copy on a navy card.
private struct BodyText: View {
    let text: String
    var size: CGFloat = 14

    var body: some View {
        Text(verbatim: text)
            .font(.inter(size, .regular, relativeTo: .subheadline))
            .lineSpacing(size * 0.25)
            .foregroundStyle(Color(Palette.textBody))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A numbered step card (canvas: number in a 30 pt circle, 18 pt title, then text and content).
/// The canvas draws white cards with navy numbers; here the card is navy, so the circle is white.
private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let text: String
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .headline) private var circle: CGFloat = 30

    var body: some View {
        Card(padding: EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(verbatim: number.formatted())
                        .font(.inter(15, .extraBold, relativeTo: .headline))
                        .foregroundStyle(Color(Palette.ink))
                        .frame(width: circle, height: circle)
                        .background(Circle().fill(Color.white))
                    Text(verbatim: title)
                        .font(.inter(18, .extraBold, relativeTo: .headline))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: ConsensusText.stepLabel(number, title)))
                .accessibilityAddTraits(.isHeader)

                BodyText(text: text)
                content
            }
        }
    }
}

/// A source chip: colour dot and display name (canvas step 1).
private struct SourceChip: View {
    let id: String
    let name: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(Palette.source(id))).frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .font(.inter(12.5, .bold, relativeTo: .caption))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color(Palette.cardInner)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(contrast == .increased ? 0.6 : 0.16), lineWidth: 1))
    }
}

/// Lays chips out in rows, wrapping to the next row when the width runs out.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.flatMap(\.items).map { $0.x + $0.size.width }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                                           proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat = 0
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row(y: 0)
        var x: CGFloat = 0
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width {
                // Larger text: a chip wider than the card wraps its own text instead.
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if x > 0 && x + size.width > width {
                let nextY = row.y + row.height + spacing
                rows.append(row)
                row = Row(y: nextY)
                x = 0
            }
            row.items.append((index, x, size))
            row.height = max(row.height, size.height)
            x += size.width + spacing
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// A label and a value on a darker tile (as the opened day's exact values).
private struct FactTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: label).font(.inter(11.5, .regular, relativeTo: .caption2))
                .foregroundStyle(Color(Palette.textSecondary))
            Text(verbatim: value).font(.inter(14, .extraBold, relativeTo: .subheadline))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(Palette.ink).opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hero

/// "Many forecasts in. One consensus out." with the canvas diagram: day 1's sources as dots, an arrow,
/// day 1's blended source bar, an arrow, day 1's Certainty ring.
private struct HeroCard: View {
    let facts: ConsensusFacts

    var body: some View {
        Card(padding: EdgeInsets(top: 20, leading: 18, bottom: 20, trailing: 18)) {
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: ConsensusText.heroCaps)
                    .font(.inter(12.5, .extraBold, relativeTo: .caption))
                    .tracking(1)
                    .foregroundStyle(Color(Palette.textSecondary))
                Text(verbatim: ConsensusText.heroTitle)
                    .font(.inter(26, .extraBold, relativeTo: .title))
                    .tracking(-0.26)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                BodyText(text: ConsensusText.heroBody(placeName: facts.placeName,
                                                      consensusOnly: facts.forecast.place.consensusOnly),
                         size: 14.5)
                if let day = facts.firstDay {
                    HeroDiagram(day: day, names: facts.names)
                }
            }
        }
    }
}

private struct HeroDiagram: View {
    let day: PlaceForecast.Day
    let names: SourceNames
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let big = dynamicTypeSize.isAccessibilitySize
        let layout = big
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 6))
        let shares = ConsensusFacts.shares(day)
        layout {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 6), count: 3), spacing: 6) {
                ForEach(shares) { item in
                    Circle().fill(Color(Palette.source(item.id))).frame(width: 18, height: 18)
                }
            }
            .fixedSize()
            arrow(down: big)
            VStack(spacing: 6) {
                SourceBar(weights: day.weights, names: names, thickness: SourceBar.small)
                Text(verbatim: ConsensusText.consensusWord)
                    .font(.inter(11.5, .bold, relativeTo: .caption2))
                    .foregroundStyle(Color(Palette.textSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: big ? 200 : 96)
            arrow(down: big)
            BigCertaintyRing(day: day, size: 62, fontSize: 16)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(Palette.heroPanel)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ConsensusText.diagramLabel(day)))
    }

    private func arrow(down: Bool) -> some View {
        Image(systemName: down ? "arrow.down" : "arrow.right")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color(Palette.textSecondary))
            .frame(maxWidth: down ? nil : .infinity)
    }
}

// MARK: - Steps

/// Step 1: every model in the file as a chip, then the normal.
private struct GatherStep: View {
    let facts: ConsensusFacts

    var body: some View {
        StepCard(number: 1, title: ConsensusText.gatherTitle,
                 text: ConsensusText.gatherText(placeName: facts.placeName, hasNormal: facts.normal != nil)) {
            CapsHead(text: ConsensusText.modelsHead(facts.models.count))
            FlowLayout {
                ForEach(facts.models, id: \.id) { source in
                    SourceChip(id: source.id, name: facts.names.name(for: source.id))
                }
            }
            if let normal = facts.normal {
                CapsHead(text: ConsensusText.normalHead)
                FlowLayout {
                    SourceChip(id: normal.id, name: facts.names.name(for: normal.id))
                }
            }
        }
    }
}

/// Step 2: the station each source is scored against, and when the latest scores were made.
private struct HomeworkStep: View {
    let facts: ConsensusFacts
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let place = facts.forecast.place
        StepCard(number: 2, title: ConsensusText.homeworkTitle, text: ConsensusText.homeworkText(place)) {
            if !place.consensusOnly, let station = place.truthStation {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 6))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 6))
                layout {
                    FactTile(label: ConsensusText.checkedAgainst, value: ConsensusText.stationValue(station))
                    if let asOf = facts.forecast.weightsAsOf {
                        FactTile(label: ConsensusText.latestScores, value: ValueText.date(asOf))
                    }
                }
            }
        }
    }
}

/// Step 3: text only (the per-source fixes are not in schema v1).
private struct HabitsStep: View {
    let facts: ConsensusFacts

    var body: some View {
        StepCard(number: 3, title: ConsensusText.habitsTitle,
                 text: ConsensusText.habitsText(placeName: facts.placeName)) {
            EmptyView()
        }
    }
}

/// Step 4: day 1's weights as a bar and a legend, then day 1, 7 and 13 side by side.
private struct WeightStep: View {
    let facts: ConsensusFacts
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 64

    var body: some View {
        StepCard(number: 4, title: ConsensusText.weightTitle, text: ConsensusText.weightText) {
            if let day = facts.firstDay {
                CapsHead(text: ConsensusText.dayConsensusHead(day))
                SourceBar(weights: day.weights, names: facts.names, thickness: SourceBar.large)
                legend(day)
            }
            if !facts.shiftDays.isEmpty {
                CapsHead(text: ConsensusText.shiftHead).padding(.top, 6)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(facts.shiftDays) { day in
                        shiftRow(day)
                    }
                }
                Text(verbatim: ConsensusText.shiftText(facts: facts))
                    .font(.inter(13, .regular, relativeTo: .footnote))
                    .lineSpacing(3)
                    .foregroundStyle(Color(Palette.textBody))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legend(_ day: PlaceForecast.Day) -> some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .leading), count: columns),
                         alignment: .leading, spacing: 6) {
            ForEach(ConsensusFacts.shares(day)) { item in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(Palette.source(item.id)))
                        .frame(width: 10, height: 10)
                    Text(verbatim: facts.names.name(for: item.id))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: ValueText.share(item.share))
                        .monospacedDigit()
                }
                .font(.inter(13, .bold, relativeTo: .footnote))
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func shiftRow(_ day: PlaceForecast.Day) -> some View {
        let label = Text(verbatim: ConsensusText.leadDay(day))
            .font(.inter(12.5, .bold, relativeTo: .caption))
        let bar = SourceBar(weights: day.weights, names: facts.names, thickness: SourceBar.small)
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { label; bar }
            } else {
                HStack(spacing: 10) {
                    label.frame(width: labelWidth, alignment: .leading)
                    bar
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: ConsensusText.shiftRowLabel(day, names: facts.names)))
    }
}

/// Step 5: one worked example per tier present in the file, then Certainty for every day.
private struct SureStep: View {
    let facts: ConsensusFacts
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        StepCard(number: 5, title: ConsensusText.sureTitle, text: ConsensusText.sureText) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(facts.examples) { day in
                    example(day)
                }
            }
            CapsHead(text: ConsensusText.chartHead).padding(.top, 6)
            CertaintyByDayChart(days: facts.forecast.days)
        }
    }

    private func example(_ day: PlaceForecast.Day) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            BigCertaintyRing(day: day, size: 50, fontSize: 13)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: ConsensusText.exampleTitle(day))
                    .font(.inter(13, .extraBold, relativeTo: .footnote))
                CertaintyDots(day: day, fill: true)
                Text(verbatim: ConsensusText.exampleSentence(day))
                    .font(.inter(12, .regular, relativeTo: .caption))
                    .foregroundStyle(Color(Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ConsensusText.exampleLabel(day)))
    }
}

/// Canvas "How sure we are, day by day": one bar per day, height = Certainty %, colour = tier,
/// one-letter weekdays under it. At accessibility text sizes it turns into rows (date, bar, %) so nothing clips.
struct CertaintyByDayChart: View {
    let days: [PlaceForecast.Day]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var height: CGFloat = 92

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(verbatim: ValueText.date(day.date))
                                Spacer(minLength: 8)
                                Text(verbatim: ValueText.percent(day.certainty)).monospacedDigit()
                            }
                            .font(.inter(12, .bold, relativeTo: .caption))
                            GeometryReader { proxy in
                                Capsule().fill(Color(Palette.tier(day.certaintyTier)))
                                    .frame(width: proxy.size.width * fraction(day))
                            }
                            .frame(height: 8)
                        }
                    }
                }
            } else {
                VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(days) { day in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(Palette.tier(day.certaintyTier)))
                                .frame(height: height * fraction(day))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .frame(height: height)
                    HStack(spacing: 4) {
                        ForEach(days) { day in
                            Text(verbatim: ValueText.narrowWeekday(day.date))
                                .font(.inter(10.5, .bold, relativeTo: .caption2))
                                .foregroundStyle(Color(Palette.textSecondary))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ConsensusText.chartLabel(days)))
    }

    private func fraction(_ day: PlaceForecast.Day) -> CGFloat {
        CGFloat(min(max(day.certainty ?? 0, 0), 100)) / 100
    }
}

#if DEBUG
#Preview("Consensus, portrait") {
    ConsensusScreen(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.afternoon)
}

#Preview("Consensus, night") {
    ConsensusScreen(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.fresh)
        .preferredColorScheme(.dark)
}

#Preview("Consensus, landscape", traits: .landscapeLeft) {
    ConsensusScreen(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.afternoon)
}

#Preview("Consensus, iPhone Duo unfolded", traits: .fixedLayout(width: 951, height: 669)) {
    ConsensusScreen(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.afternoon)
        .environment(\.horizontalSizeClass, .regular)
}

#Preview("Consensus, largest text") {
    ConsensusScreen(model: .previewFixture())
        .environment(\.nowOverride, PreviewClock.afternoon)
        .dynamicTypeSize(.accessibility5)
}

#Preview("Step 4 source bars, largest text") {
    // Bars stay 22 and 14 pt high; the text around them scales.
    let forecast = ForecastScreenModel.previewFixture().forecast!
    ScrollView {
        WeightStep(facts: ConsensusFacts(forecast)).padding(16)
    }
    .background(SkyView(style: SkyStyle(time: .day, weather: nil)))
    .dynamicTypeSize(.accessibility5)
}
#endif
