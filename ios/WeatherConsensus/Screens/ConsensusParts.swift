import SwiftUI

/// The Certainty ring: track plus an arc for Certainty %, in the tier colour (canvas: track white at 18%).
struct CertaintyRing: View {
    let certainty: Int?
    let tier: CertaintyTier?
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: Double(certainty ?? 0) / 100)
                .stroke(Color(Palette.tier(tier)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// Canvas day-row badge: 52 x 40 pt capsule, fill #10294F, 1 pt border white 16%, 18 pt ring with a 3 pt
/// stroke in the tier colour, then "NN%". It grows only if larger text needs the room.
/// Part of the row button, so VoiceOver reads it in the row's label.
struct CertaintyBadge: View {
    let day: PlaceForecast.Day
    @ScaledMetric(relativeTo: .footnote) private var ringSize: CGFloat = 18
    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = 40
    @ScaledMetric(relativeTo: .footnote) private var width: CGFloat = 52

    var body: some View {
        HStack(spacing: 4) {
            CertaintyRing(certainty: day.certainty, tier: day.certaintyTier)
                .frame(width: ringSize, height: ringSize)
            Text(verbatim: ValueText.percent(day.certainty))
                .font(.inter(13, .bold, relativeTo: .footnote))
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 3)
        .frame(minWidth: width, minHeight: height)
        .background(Capsule().fill(Color(Palette.cardInner)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Canvas breakdown ring: 72 pt, 8 pt stroke, percentage inside.
struct BigCertaintyRing: View {
    let day: PlaceForecast.Day
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 72

    var body: some View {
        ZStack {
            CertaintyRing(certainty: day.certainty, tier: day.certaintyTier, lineWidth: 8 * size / 72)
            Text(verbatim: ValueText.percent(day.certainty))
                .font(.inter(18, .extraBold, relativeTo: .title2))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(10 * size / 72)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CertaintyText.ringLabel(day))
    }
}

/// Canvas tier pill: light tint with dark ink (High #E3F6EC on #155F39, Medium #FFF3CC on #6B4A00,
/// Low #FFE8DC on #8A3510).
struct TierPill: View {
    let tier: CertaintyTier?

    var body: some View {
        let colours = Palette.tierPill(tier)
        Text(verbatim: ValueText.tier(tier))
            .font(.inter(12.5, .extraBold, relativeTo: .caption))
            .foregroundStyle(Color(colours.ink))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(colours.fill)))
            .accessibilityHidden(true) // the big ring says the tier
    }
}

/// 10 dots: filled ones in the tier colour (about how many of 10 such days land within 2 °C).
/// `fill: true` spreads them across the width, as in the canvas breakdown.
struct CertaintyDots: View {
    let day: PlaceForecast.Day
    var fill = false
    @ScaledMetric(relativeTo: .caption) private var dot: CGFloat = 7
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let filled = CertaintyText.filledDots(day.certainty)
        HStack(spacing: fill ? 5 : dot * 0.45) {
            ForEach(0..<10, id: \.self) { index in
                Group {
                    if index < filled {
                        Circle().fill(Color(Palette.tier(day.certaintyTier)))
                    } else if contrast == .increased {
                        Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                    } else {
                        Circle().fill(Color.white.opacity(0.22))
                    }
                }
                .modifier(DotSize(fill: fill, size: dot))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CertaintyText.dotsLabel(day))
    }

    private struct DotSize: ViewModifier {
        let fill: Bool
        let size: CGFloat
        func body(content: Content) -> some View {
            if fill {
                content.aspectRatio(1, contentMode: .fit).frame(maxWidth: 28)
            } else {
                content.frame(width: size, height: size)
            }
        }
    }
}

/// The coloured source bar: one segment per source, colour = source, length = its weight for the high.
struct SourceBar: View {
    let weights: [PlaceForecast.Weight]
    let names: SourceNames
    var thickness: CGFloat = 8
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    var body: some View {
        let shown = weights.filter { $0.weight > 0 }
        let total = shown.reduce(0) { $0 + $1.weight }
        GeometryReader { proxy in
            let gaps = CGFloat(max(shown.count - 1, 0)) * 2
            let usable = max(proxy.size.width - gaps, 0)
            HStack(spacing: 2) {
                ForEach(shown, id: \.id) { item in
                    Rectangle()
                        .fill(Color(Palette.source(item.id)))
                        .frame(width: total > 0 ? usable * item.weight / total : 0)
                }
            }
        }
        .frame(height: thickness * scale)
        .clipShape(Capsule())
        .background(Capsule().fill(Color.white.opacity(shown.isEmpty ? 0.12 : 0)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SourceText.barLabel(weights: shown, total: total, names: names))
    }
}

/// App display names for sources, keyed off source ids (design canvas v8). The JSON and the backend
/// keep their own ids and labels; a source id the app does not know shows the file's label.
nonisolated struct SourceNames: Sendable {
    let sources: [PlaceForecast.Source]
    let placeName: String

    init(sources: [PlaceForecast.Source], placeName: String) {
        self.sources = sources
        self.placeName = placeName
    }

    init(_ forecast: PlaceForecast) {
        self.init(sources: forecast.sources, placeName: forecast.place.name)
    }

    func name(for id: String) -> String {
        Self.displayName(for: id, placeName: placeName)
            ?? sources.first { $0.id == id }?.label
            ?? id
    }

    /// nil for an id the app has no name for.
    static func displayName(for id: String, placeName: String) -> String? {
        switch id {
        case "gem_seamless": String(localized: "Env. Canada", comment: "Source name: Environment and Climate Change Canada's GEM model")
        case "ecmwf_ifs": String(localized: "ECMWF", comment: "Source name, do not translate")
        case "ecmwf_aifs025_single": String(localized: "ECMWF AI", comment: "Source name: ECMWF's AI model (AIFS)")
        case "gfs_seamless": String(localized: "NOAA GFS", comment: "Source name, do not translate")
        case "icon_seamless": String(localized: "DWD ICON", comment: "Source name, do not translate")
        case "ukmo_seamless": String(localized: "UK Met Office", comment: "Source name, do not translate")
        case "jma_seamless": String(localized: "Japan JMA", comment: "Source name: Japan Meteorological Agency")
        case "cma_grapes_global": String(localized: "China CMA", comment: "Source name: China Meteorological Administration")
        case "meteofrance_seamless": String(localized: "Météo-France", comment: "Source name, do not translate")
        case "normal": String(localized: "\(placeName) normal (1991 to 2020)",
                              comment: "Source name: the place's 1991 to 2020 climate normal. The value is the place name.")
        default: nil
        }
    }
}

nonisolated enum SourceText {
    /// "Sources for the high: UK Met Office 17%, DWD ICON 15%, ..."
    static func barLabel(weights: [PlaceForecast.Weight], total: Double, names: SourceNames) -> String {
        guard total > 0 else { return String(localized: "No source weights for this day") }
        let parts = weights.map { "\(names.name(for: $0.id)) \(ValueText.share($0.weight / total))" }
        return String(localized: "Sources for the high: \(parts.formatted(.list(type: .and)))",
                      comment: "VoiceOver label for the source bar; the list is source names with their share")
    }
}
