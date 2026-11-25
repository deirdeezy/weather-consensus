import SwiftUI

/// The Certainty ring: track plus an arc for Certainty %, in the tier colour.
struct CertaintyRing: View {
    let certainty: Int?
    let tier: CertaintyTier?
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: Double(certainty ?? 0) / 100)
                .stroke(Color(Palette.tier(tier)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// Ring and percentage in a capsule, as on each day row of the canvas.
struct CertaintyBadge: View {
    let day: PlaceForecast.Day
    @ScaledMetric(relativeTo: .footnote) private var ringSize: CGFloat = 18

    var body: some View {
        HStack(spacing: 5) {
            CertaintyRing(certainty: day.certainty, tier: day.certaintyTier)
                .frame(width: ringSize, height: ringSize)
            Text(verbatim: ValueText.percent(day.certainty))
                .font(.inter(13, .bold, relativeTo: .footnote))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 40)
        .background(Capsule().fill(Color(Palette.cardInner)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CertaintyText.ringLabel(day))
    }
}

/// 10 dots: filled ones in the tier colour (about how many of 10 such days land within 2 deg C).
struct CertaintyDots: View {
    let day: PlaceForecast.Day
    @ScaledMetric(relativeTo: .caption) private var dot: CGFloat = 7
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let filled = CertaintyText.filledDots(day.certainty)
        HStack(spacing: dot * 0.45) {
            ForEach(0..<10, id: \.self) { index in
                if index < filled {
                    Circle().fill(Color(Palette.tier(day.certaintyTier)))
                } else if contrast == .increased {
                    Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                } else {
                    Circle().fill(Color.white.opacity(0.22))
                }
            }
            .frame(width: dot, height: dot)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CertaintyText.dotsLabel(day))
    }
}

/// The coloured source bar: one segment per source, colour = source, length = its weight for the high.
struct SourceBar: View {
    let weights: [PlaceForecast.Weight]
    let sources: [PlaceForecast.Source]
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 8

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
        .frame(height: height)
        .clipShape(Capsule())
        .background(Capsule().fill(Color.white.opacity(shown.isEmpty ? 0.12 : 0)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SourceText.barLabel(weights: shown, total: total, sources: sources))
    }
}

nonisolated enum SourceText {
    static func label(for id: String, in sources: [PlaceForecast.Source]) -> String {
        sources.first { $0.id == id }?.label ?? id
    }

    /// "Sources for the high: UK Met Office 17%, DWD ICON 15%, ..."
    static func barLabel(weights: [PlaceForecast.Weight], total: Double, sources: [PlaceForecast.Source]) -> String {
        guard total > 0 else { return String(localized: "No source weights for this day") }
        let parts = weights.map { "\(label(for: $0.id, in: sources)) \(ValueText.share($0.weight / total))" }
        return String(localized: "Sources for the high: \(parts.formatted(.list(type: .and)))",
                      comment: "VoiceOver label for the source bar; the list is source names with their share")
    }
}
