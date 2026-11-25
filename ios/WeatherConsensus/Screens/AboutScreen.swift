import SwiftUI

/// About, pushed from Settings, from the design canvas artboard `About.dc.html`.
/// Left out: the "Tested on a year of Kitimat weather" card (the published file has no track record yet),
/// the Warnings credit (no warnings yet), "Send feedback" and "Rate on the App Store".
struct AboutScreen: View {
    let model: ForecastScreenModel

    var body: some View {
        SkyPage(model: model) {
            header
            Card(padding: EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)) {
                VStack(alignment: .leading, spacing: 10) {
                    capsHead(String(localized: "Why it exists"))
                    Paragraph(text: AboutText.why)
                }
            }
            PromiseTiles()
        } right: {
            creditsCard
            SectionCard(title: String(localized: "More")) {
                NavigationLink(value: SettingsPage.privacy) {
                    SettingsRowLabel(title: String(localized: "Privacy policy")) {
                        ChipIcon(systemImage: "hand.raised", colours: ChipColours.green)
                    }
                }
                .buttonStyle(.plain)
                RowDivider()
                NavigationLink(value: SettingsPage.acknowledgements) {
                    SettingsRowLabel(title: String(localized: "Acknowledgements")) {
                        ChipIcon(systemImage: "text.book.closed", colours: ChipColours.violet)
                    }
                }
                .buttonStyle(.plain)
            }
            SkyNote {
                HStack(spacing: 8) {
                    MountainGlyph().frame(width: 40, height: 13)
                    Text(verbatim: AboutText.madeIn)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .navigationTitle(Text("About"))
        .modifier(NavyBar())
    }

    private var header: some View {
        Card(padding: EdgeInsets(top: 22, leading: 16, bottom: 20, trailing: 16)) {
            VStack(spacing: 6) {
                AppMark()
                    .frame(width: 108, height: 108)
                    .shadow(color: Color(Palette.ink).opacity(0.3), radius: 14, y: 14)
                Text("Weather Consensus")
                    .font(.inter(28, .extraBold, relativeTo: .largeTitle))
                    .tracking(-0.5)
                    .padding(.top, 12)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: AboutText.version(AppVersion.current))
                    .font(.inter(14, .regular, relativeTo: .subheadline))
                    .foregroundStyle(Color(Palette.textSecondary))
                Text(verbatim: AboutText.tagline)
                    .font(.inter(17, .bold, relativeTo: .headline))
                    .padding(.top, 4)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
    }

    private var creditsCard: some View {
        SectionCard(title: String(localized: "Data and credits")) {
            let forecast = model.forecast
            if let forecast, let agencies = AboutText.agencies(forecast) {
                creditRow(String(localized: "Forecasts")) { Paragraph(text: agencies) }
                RowDivider()
            }
            creditRow(String(localized: "Delivered by")) {
                Paragraph(text: AboutText.deliveredBy)
                HStack(spacing: 16) {
                    CardLink(title: "Open-Meteo.com", url: AboutText.openMeteoURL)
                    CardLink(title: "CC BY 4.0", url: AboutText.ccByURL)
                }
            }
            if let place = forecast?.place, let checked = AboutText.checkedAgainst(place) {
                RowDivider()
                creditRow(String(localized: "Checked against")) { Paragraph(text: checked) }
            }
            if let forecast, AboutText.hasNormal(forecast) {
                RowDivider()
                creditRow(String(localized: "Normals")) { Paragraph(text: AboutText.normals) }
            }
        }
    }

    private func creditRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: label).font(.inter(13, .bold, relativeTo: .footnote))
                .foregroundStyle(Color(Palette.textSecondary))
            content()
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func capsHead(_ text: String) -> some View {
        Text(verbatim: text.uppercased())
            .font(.inter(12.5, .extraBold, relativeTo: .caption))
            .tracking(0.9)
            .foregroundStyle(Color(Palette.textSecondary))
            .accessibilityAddTraits(.isHeader)
    }
}

/// The four canvas tiles: No ads, No tracking, No account, Just the forecast. Two columns, one at
/// accessibility text sizes.
private struct PromiseTiles: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            tile(String(localized: "No ads")) { ChipIcon(systemImage: "nosign", colours: ChipColours.orange) }
            tile(String(localized: "No tracking")) { ChipIcon(systemImage: "eye.slash", colours: ChipColours.violet) }
            tile(String(localized: "No account")) { ChipIcon(systemImage: "person", colours: ChipColours.blue) }
            tile(String(localized: "Just the forecast")) { ChipIcon(fill: ChipColours.grey.fill) { ThreeCircles() } }
        }
    }

    private func tile<Chip: View>(_ title: String, @ViewBuilder chip: () -> Chip) -> some View {
        HStack(spacing: 10) {
            chip()
            Text(verbatim: title).font(.inter(15, .bold, relativeTo: .body))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(Palette.card)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}

/// The app's three-circle mark from the canvas `AppIcon` (light variant, as on the Icon artboard), drawn in
/// SwiftUI on its 1024 x 1024 grid: sky gradient and glow, two mountain ridges, three circles blended with
/// "screen" among themselves, corner radius 229. Step 6 adds the real app icon (Icon Composer).
struct AppMark: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 1024
            let full = CGRect(x: 0, y: 0, width: 1024 * s, height: 1024 * s)
            context.clip(to: Path(roundedRect: full, cornerRadius: 229 * s, style: .continuous))
            context.fill(Path(full), with: .linearGradient(
                Gradient(colors: [Color(RGB(0x3D7FE8)), Color(RGB(0x12306B))]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: full.height)))
            context.fill(Path(full), with: .radialGradient(
                Gradient(colors: [Color(RGB(0xA8CCFF)).opacity(0.35), Color(RGB(0xA8CCFF)).opacity(0)]),
                center: CGPoint(x: 512 * s, y: 471 * s), startRadius: 0, endRadius: 512 * s))
            context.fill(Self.ridge([(0, 862), (150, 752), (262, 820), (420, 694), (560, 802), (690, 718), (820, 810), (1024, 704)], s),
                         with: .color(Color(RGB(0x1D4588))))
            context.fill(Self.ridge([(0, 936), (180, 842), (330, 904), (500, 818), (660, 908), (820, 846), (1024, 926)], s),
                         with: .color(Color(RGB(0x163873))))
            // The canvas isolates the circles, so they blend with each other, not with the sky.
            context.drawLayer { layer in
                layer.blendMode = .screen
                for (x, y, hex) in [(406.0, 418.0, UInt32(0xFFC531)), (618, 418, 0xFF6B6B), (512, 602, 0x3FC8F0)] {
                    let r = 196.0
                    layer.fill(Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)),
                               with: .color(Color(RGB(hex))))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private static func ridge(_ points: [(Double, Double)], _ s: Double) -> Path {
        Path { path in
            path.move(to: CGPoint(x: points[0].0 * s, y: points[0].1 * s))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0 * s, y: point.1 * s)) }
            path.addLine(to: CGPoint(x: 1024 * s, y: 1024 * s))
            path.addLine(to: CGPoint(x: 0, y: 1024 * s))
            path.closeSubpath()
        }
    }
}

/// The canvas footer mountains (56 x 18).
private struct MountainGlyph: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 56, sy = size.height / 18
            var path = Path()
            let points: [(Double, Double)] = [(0, 18), (12, 7), (19, 13), (29, 2), (38, 11), (44, 7), (56, 18)]
            path.move(to: CGPoint(x: points[0].0 * sx, y: points[0].1 * sy))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0 * sx, y: point.1 * sy)) }
            path.closeSubpath()
            context.fill(path, with: .color(Color(RGB(0x9FBCE0))))
        }
        .accessibilityHidden(true)
    }
}

/// Every About string that is fixed or built from the file.
nonisolated enum AboutText {
    static let tagline = String(localized: "Many forecasts. One answer.")
    static let why = String(localized: "Most weather apps show you one computer model, wrapped in ads. Weather Consensus checks many forecasts against what really happened here, gives the most accurate ones the biggest say, and tells you how sure it is.",
                            comment: "About, Why it exists")
    static let deliveredBy = String(localized: "Open-Meteo, under CC\u{00A0}BY\u{00A0}4.0")
    static let normals = String(localized: "ECCC climate normals, 1991 to 2020")
    static let madeIn = String(localized: "Made in Kitimat, BC", comment: "About footer")

    static let openMeteoURL = URL(string: "https://open-meteo.com/")!
    static let ccByURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!

    /// "Version 0.1 (1)".
    static func version(_ version: String) -> String {
        String(localized: "Version \(version)", comment: "About, under the name. The value is the version and build.")
    }

    /// The agency behind each model id, in the canvas order.
    static let agencyByID: [(id: String, agency: String)] = [
        ("gem_seamless", String(localized: "Environment and Climate Change Canada")),
        ("ecmwf_ifs", "ECMWF"),
        ("ecmwf_aifs025_single", "ECMWF"),
        ("gfs_seamless", "NOAA"),
        ("icon_seamless", "DWD"),
        ("ukmo_seamless", String(localized: "UK Met Office")),
        ("jma_seamless", "JMA"),
        ("cma_grapes_global", "CMA"),
        ("meteofrance_seamless", "Météo-France"),
    ]

    /// "Environment and Climate Change Canada, ECMWF, NOAA, DWD, UK Met Office, JMA, CMA and Météo-France":
    /// the agencies behind the models in the file, in the canvas order, each once. A model id the app does not
    /// know adds the file's label at the end. nil when the file has no models.
    static func agencies(_ forecast: PlaceForecast) -> String? {
        let ids = Set(forecast.sources.map(\.id))
        var names: [String] = []
        for entry in agencyByID where ids.contains(entry.id) && !names.contains(entry.agency) {
            names.append(entry.agency)
        }
        let known = Set(agencyByID.map(\.id)).union(["normal"])
        for source in forecast.sources where !known.contains(source.id) && !names.contains(source.label) {
            names.append(source.label)
        }
        guard let last = names.last else { return nil }
        guard names.count > 1 else { return last }
        // Canvas style: no comma before "and".
        return String(localized: "\(names.dropLast().joined(separator: ", ")) and \(last)",
                      comment: "About, Forecasts: a list of agencies, then the last one")
    }

    /// "ECCC weather station, Kitimat Forest Ave"; nil for a place with no station.
    static func checkedAgainst(_ place: PlaceForecast.Place) -> String? {
        guard !place.consensusOnly, let station = place.truthStation else { return nil }
        return String(localized: "\(station.network) weather station, \(station.name)",
                      comment: "About, Checked against. Values: the station's network (ECCC), the station name.")
    }

    static func hasNormal(_ forecast: PlaceForecast) -> Bool {
        forecast.sources.contains { $0.id == "normal" }
    }
}

#if DEBUG
#Preview("About") {
    NavigationStack { AboutScreen(model: .previewFixture()) }
        .environment(\.nowOverride, PreviewClock.afternoon)
}

#Preview("About, largest text") {
    NavigationStack { AboutScreen(model: .previewFixture()) }
        .environment(\.nowOverride, PreviewClock.afternoon)
        .dynamicTypeSize(.accessibility5)
}

#Preview("About, iPhone Duo unfolded", traits: .fixedLayout(width: 951, height: 669)) {
    NavigationStack { AboutScreen(model: .previewFixture()) }
        .environment(\.nowOverride, PreviewClock.fresh)
        .environment(\.horizontalSizeClass, .regular)
}

#Preview("App mark", traits: .sizeThatFitsLayout) {
    HStack(spacing: 20) {
        AppMark().frame(width: 108, height: 108)
        AppMark().frame(width: 44, height: 44)
    }
    .padding()
}
#endif
