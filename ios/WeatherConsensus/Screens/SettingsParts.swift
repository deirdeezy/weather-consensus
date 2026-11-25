import SwiftUI

// Shared pieces for the Places tab, the Settings sheet, About and its pages (design canvas artboards
// Places, Settings and About). The canvas draws these on a light gradient with white cards; here they sit
// on the living sky with navy cards, like the Weather and Consensus tabs.

/// Canvas icon chip colours (34 pt rounded squares): light fill, dark ink. Graphics, so 3:1 or more (tested).
nonisolated enum ChipColours {
    static let blue = (fill: RGB(0xE4EEFB), ink: RGB(0x174EA8))
    static let green = (fill: RGB(0xE2F6EF), ink: RGB(0x157A55))
    static let orange = (fill: RGB(0xFFE8DC), ink: RGB(0xB04A12))
    static let violet = (fill: RGB(0xECE8FB), ink: RGB(0x5B3FC4))
    static let sky = (fill: RGB(0xE0F1FF), ink: RGB(0x1F6FC0))
    static let grey = (fill: RGB(0xEEF3FA), ink: Palette.ink)

    static let all = [blue, green, orange, violet, sky, grey]
}

/// The three-circle mark, small, in the canvas colours (Settings "How Consensus works", About tile).
struct ThreeCircles: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 28, size.height / 22)
            let colours = [RGB(0xFF5A5F), RGB(0x4C8DFF), RGB(0x3DD68C)]
            for (index, centre) in [(9.0, 8.0), (19.0, 8.0), (14.0, 15.0)].enumerated() {
                let rect = CGRect(x: (centre.0 - 6.2) * scale, y: (centre.1 - 6.2) * scale,
                                  width: 12.4 * scale, height: 12.4 * scale)
                context.fill(Path(ellipseIn: rect), with: .color(Color(colours[index]).opacity(0.9)))
            }
        }
        .aspectRatio(28 / 22, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// A 34 pt chip with an icon (canvas settings rows). Grows with text size.
struct ChipIcon<Glyph: View>: View {
    let fill: RGB
    @ViewBuilder let glyph: Glyph
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 34

    var body: some View {
        glyph
            .frame(width: size * 0.56, height: size * 0.56)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous).fill(Color(fill)))
            .accessibilityHidden(true)
    }
}

extension ChipIcon where Glyph == AnyView {
    /// A chip with an SF Symbol in the chip's ink.
    init(systemImage: String, colours: (fill: RGB, ink: RGB)) {
        fill = colours.fill
        glyph = AnyView(Image(systemName: systemImage)
            .resizable().scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(Color(colours.ink)))
    }
}

/// A navy card with a caps heading inside it, then rows split by hairlines. The canvas puts the heading on
/// the page background; here it sits inside the card so it keeps its contrast on every sky.
struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Card(padding: EdgeInsets(top: 14, leading: 14, bottom: 6, trailing: 14)) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title.uppercased())
                    .font(.inter(12.5, .extraBold, relativeTo: .caption))
                    .tracking(0.9)
                    .foregroundStyle(Color(Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 4)
                content
            }
        }
    }
}

/// Hairline between rows (canvas #EEF2F8 on white; white at 10% on navy, 40% with Increase Contrast).
struct RowDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle().fill(Color.white.opacity(contrast == .increased ? 0.4 : 0.1)).frame(height: 1)
    }
}

/// Canvas settings row: chip, title (and subtitle), optional trailing value, chevron when it goes somewhere.
/// At accessibility text sizes the trailing value moves under the title so nothing truncates.
struct SettingsRowLabel<Chip: View>: View {
    let title: String
    var subtitle: String?
    var value: String?
    var showsChevron = true
    @ViewBuilder let chip: Chip
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let big = dynamicTypeSize.isAccessibilitySize
        HStack(spacing: 12) {
            chip
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.inter(16, .bold, relativeTo: .body))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(verbatim: subtitle).font(.inter(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(Color(Palette.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if big, let value {
                    Text(verbatim: value).font(.inter(15, .regular, relativeTo: .subheadline))
                        .foregroundStyle(Color(Palette.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !big, let value {
                Text(verbatim: value).font(.inter(15, .regular, relativeTo: .subheadline))
                    .foregroundStyle(Color(Palette.textSecondary))
                    .multilineTextAlignment(.trailing)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(Palette.textSecondary))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

/// Canvas units control: a rounded track with one button per unit; the chosen one is white with navy ink.
/// Each button is at least 52 x 44 pt. VoiceOver reads each option's full name and marks the chosen one.
struct UnitSegments<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, short: String, spoken: String)]
    @Binding var selection: Value
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let big = dynamicTypeSize.isAccessibilitySize
        let layout = big ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                         : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Text(verbatim: title).font(.inter(16, .bold, relativeTo: .body))
                .accessibilityHidden(true)
            if !big { Spacer(minLength: 0) }
            HStack(spacing: 2) {
                ForEach(options, id: \.value) { option in
                    let chosen = option.value == selection
                    Button {
                        selection = option.value
                    } label: {
                        Text(verbatim: option.short)
                            .font(.inter(14.5, .bold, relativeTo: .subheadline))
                            .foregroundStyle(Color(chosen ? Palette.ink : Palette.textSecondary))
                            .padding(.horizontal, 10)
                            .frame(minWidth: 52, minHeight: 44)
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
        .padding(.vertical, 8)
        .frame(minHeight: 64)
    }
}

/// A short line on the sky (footers, "More places are coming."). Drawn on a navy capsule so it keeps
/// its contrast on every sky, top or bottom of the screen.
struct SkyNote<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.inter(13.5, .semibold, relativeTo: .footnote))
            .foregroundStyle(Color(Palette.textBody))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(Palette.card).opacity(0.92)))
    }
}

/// The page frame for Places, Settings and About: the sky behind a scroll view, the content capped in width,
/// one column or two by size class only (never device or orientation).
struct SkyPage<Left: View, Right: View>: View {
    let model: ForecastScreenModel
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.nowOverride) private var nowOverride
    @Environment(\.livingSky) private var livingSky

    var body: some View {
        // A page with nothing in the right column stays one column.
        let twoColumns = (horizontalSizeClass == .regular || verticalSizeClass == .compact) && Right.self != EmptyView.self
        TimelineView(.everyMinute) { context in
            let style = SkyStyle.current(for: model.forecast, now: nowOverride ?? context.date, living: livingSky)
            ScrollView {
                // AnyLayout keeps each column's identity when the size class changes (iPhone Duo fold and unfold).
                let layout = twoColumns
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                    : AnyLayout(VStackLayout(spacing: 14))
                layout {
                    VStack(spacing: 14) { left }.frame(maxWidth: .infinity)
                    VStack(spacing: 14) { right }.frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: twoColumns ? 1000 : 600)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background { SkyView(style: style) }
        }
    }
}

/// Navy navigation bar for pages pushed in the Settings sheet, so the title keeps its contrast on any sky.
struct NavyBar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackground(Color(Palette.card), for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// A plain-language paragraph on a navy card.
struct Paragraph: View {
    let text: String
    var size: CGFloat = 15

    var body: some View {
        Text(verbatim: text)
            .font(.inter(size, .regular, relativeTo: .body))
            .lineSpacing(size * 0.3)
            .foregroundStyle(Color(Palette.textBody))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A link on a navy card: at least 44 pt tall, opens in the browser.
struct CardLink: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                Text(verbatim: title).font(.inter(15, .bold, relativeTo: .body))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color(Palette.link))
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityHint(Text("Opens in your browser"))
    }
}
