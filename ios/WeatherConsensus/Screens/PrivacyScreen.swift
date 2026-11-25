import SwiftUI

/// The privacy policy, in plain language, inside the app (pushed from About).
/// GitHub's wording checked 25 Nov 2026: GitHub Pages, "About GitHub Pages", Data collection
/// (https://docs.github.com/en/pages/getting-started-with-github-pages/about-github-pages#data-collection), and the
/// GitHub General Privacy Statement, effective 27 Apr 2026
/// (https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).
/// Apple's crash sharing checked 25 Nov 2026: https://www.apple.com/legal/privacy/data/en/app-analytics/ and
/// https://help.apple.com/xcode/mac/current/en.lproj/deve2819c518.html (TestFlight sends crash data automatically).
struct PrivacyScreen: View {
    let model: ForecastScreenModel

    var body: some View {
        SkyPage(model: model) {
            ForEach(PrivacyText.sections.prefix(3)) { section in sectionCard(section) }
        } right: {
            ForEach(PrivacyText.sections.dropFirst(3)) { section in sectionCard(section) }
            SkyNote { Text(verbatim: PrivacyText.updated) }
        }
        .navigationTitle(Text("Privacy policy"))
        .modifier(NavyBar())
    }

    private func sectionCard(_ section: PrivacyText.Section) -> some View {
        SectionCard(title: section.title) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(section.paragraphs, id: \.self) { Paragraph(text: $0) }
                ForEach(section.links, id: \.url) { CardLink(title: $0.title, url: $0.url) }
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
    }
}

nonisolated enum PrivacyText {
    struct Link: Sendable { let title: String; let url: URL }

    struct Section: Identifiable, Sendable {
        let title: String
        let paragraphs: [String]
        var links: [Link] = []
        var id: String { title }
    }

    static let githubPrivacyURL = URL(string: "https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement")!
    static let githubPagesDataURL = URL(string: "https://docs.github.com/en/pages/getting-started-with-github-pages/about-github-pages#data-collection")!

    static let updated = String(localized: "Last updated 25 November 2026", comment: "Privacy policy date")

    static let sections: [Section] = [
        Section(title: String(localized: "In short"), paragraphs: [
            String(localized: "Weather Consensus collects nothing about you. There is no account, no sign-in, no ads, no analytics and no tracking."),
        ]),
        Section(title: String(localized: "What stays on your phone"), paragraphs: [
            String(localized: "Your settings (units and the living sky) and your places are stored only on this phone. The app never sends them anywhere."),
            String(localized: "The latest forecast file is saved on the phone too, so the forecast still shows when you are offline. Each new file replaces the old one. Deleting the app deletes all of it."),
        ]),
        Section(title: String(localized: "What the app downloads"), paragraphs: [
            String(localized: "To show the forecast, the app downloads a public forecast file for each place from GitHub Pages. The file is the same for everyone. The app adds nothing about you to the request: no account, no device identifier, no location and no settings."),
        ]),
        Section(title: String(localized: "What GitHub may keep"), paragraphs: [
            String(localized: "GitHub hosts the forecast file and, like any web host, may keep standard server logs. GitHub says that when a GitHub Pages site is visited, the visitor's IP address is logged and stored for security purposes. Your phone's internet address is part of every request it makes."),
            String(localized: "Those logs are GitHub's. This app has no access to them."),
        ], links: [
            Link(title: String(localized: "GitHub Privacy Statement"), url: githubPrivacyURL),
            Link(title: String(localized: "GitHub Pages: data collection"), url: githubPagesDataURL),
        ]),
        Section(title: String(localized: "Location, links and crash reports"), paragraphs: [
            String(localized: "The app never asks for your location. Places are fixed names, not where you are."),
            String(localized: "Links in the app, such as credits and licences, open in your browser. Those sites have their own privacy policies."),
            String(localized: "If you have turned on Share With App Developers (Settings, Privacy & Security, Analytics & Improvements), Apple may share crash reports and usage statistics for this app with its developer. Test builds from TestFlight send crash reports to the developer. That is Apple's feature, under Apple's privacy policy; the app adds nothing of its own."),
        ]),
        Section(title: String(localized: "Changes"), paragraphs: [
            String(localized: "If this policy changes, the new version comes with an app update."),
        ]),
    ]
}

/// Acknowledgements (pushed from About): the font, the forecast data and the station data, with their licences.
struct AcknowledgementsScreen: View {
    let model: ForecastScreenModel

    var body: some View {
        SkyPage(model: model) {
            SectionCard(title: "Inter") {
                VStack(alignment: .leading, spacing: 8) {
                    Paragraph(text: AcknowledgementText.interCopyright)
                    Paragraph(text: AcknowledgementText.interLicence)
                    NavigationLink(value: SettingsPage.interLicence) {
                        HStack {
                            Text("Read the licence").font(.inter(15, .bold, relativeTo: .body))
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(Color(Palette.link))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)
            }
        } right: {
            SectionCard(title: "Open-Meteo") {
                VStack(alignment: .leading, spacing: 8) {
                    Paragraph(text: AcknowledgementText.openMeteo)
                    CardLink(title: "Open-Meteo.com", url: AboutText.openMeteoURL)
                    CardLink(title: String(localized: "CC BY 4.0 licence"), url: AboutText.ccByURL)
                }
                .padding(.vertical, 6)
            }
            SectionCard(title: String(localized: "Environment and Climate Change Canada")) {
                VStack(alignment: .leading, spacing: 8) {
                    Paragraph(text: AcknowledgementText.eccc)
                    CardLink(title: String(localized: "ECCC Data Servers End-use Licence"), url: AcknowledgementText.ecccLicenceURL)
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle(Text("Acknowledgements"))
        .modifier(NavyBar())
    }
}

nonisolated enum AcknowledgementText {
    /// Sources checked 25 Nov 2026: https://open-meteo.com/en/licence (CC BY 4.0; credit, link, say if changed),
    /// https://eccc-msc.github.io/open-data/licence/readme_en/ (attribution sentence, section 3),
    /// https://openfontlicense.org/ (OFL 1.1).
    static let ecccLicenceURL = URL(string: "https://eccc-msc.github.io/open-data/licence/readme_en/")!

    static var interCopyright: String {
        // The first line of the licence file shipped with the font.
        licenceText?.split(separator: "\n").first.map(String.init)
            ?? "Copyright (c) 2016 The Inter Project Authors"
    }

    static let interLicence = String(localized: "The Inter typeface is used under the SIL Open Font License, Version 1.1. The licence ships inside the app.")
    static let openMeteo = String(localized: "Weather data by Open-Meteo.com, under the Creative Commons Attribution 4.0 International licence (CC BY 4.0). We change the data: each source's forecasts are corrected for local habits and blended into one consensus.")
    static let eccc = String(localized: "Contains information licenced under the Data Server End-use Licence of Environment and Climate Change Canada. Station observations and the 1991 to 2020 climate normals come from ECCC.")

    /// The OFL text bundled with the font (`Fonts/Inter-OFL.txt`).
    static var licenceText: String? {
        guard let url = Bundle.main.url(forResource: "Inter-OFL", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// The full Inter licence, as shipped in the app bundle.
struct LicenceTextScreen: View {
    let model: ForecastScreenModel

    var body: some View {
        SkyPage(model: model) {
            Card {
                Text(verbatim: AcknowledgementText.licenceText ?? ValueText.missing)
                    .font(.inter(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color(Palette.textBody))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } right: {
            EmptyView()
        }
        .navigationTitle(Text("SIL Open Font License"))
        .modifier(NavyBar())
    }
}

#if DEBUG
#Preview("Privacy policy") {
    NavigationStack { PrivacyScreen(model: .previewFixture()) }
        .environment(\.nowOverride, PreviewClock.afternoon)
}

#Preview("Acknowledgements") {
    NavigationStack { AcknowledgementsScreen(model: .previewFixture()) }
        .environment(\.nowOverride, PreviewClock.fresh)
}
#endif
