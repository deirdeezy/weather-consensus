import Foundation
import Testing
@testable import WeatherConsensus

private let nbsp = "\u{00A0}"

@Suite("Unit conversion")
struct UnitConversionTests {
    @Test func celsiusIsUnchanged() {
        #expect(ValueText.temperature(6.3) == "6.3\(nbsp)°C")
        #expect(ValueText.temperature(6.3, in: .celsius) == "6.3\(nbsp)°C")
        #expect(ValueText.shortTemperature(6.3, in: .celsius) == "6°")
    }

    @Test func fahrenheitWholeDegrees() {
        #expect(ValueText.shortTemperature(6.3, in: .fahrenheit) == "43°")       // 43.34
        #expect(ValueText.shortTemperature(2.4, in: .fahrenheit) == "36°")       // 36.32
        #expect(ValueText.shortTemperature(-1.3, in: .fahrenheit) == "30°")      // 29.66
        #expect(ValueText.shortTemperature(0, in: .fahrenheit) == "32°")
        #expect(ValueText.shortTemperature(-20, in: .fahrenheit) == "\u{2212}4°")
        #expect(ValueText.shortTemperature(-40, in: .fahrenheit) == "\u{2212}40°")
        #expect(ValueText.shortTemperature(nil, in: .fahrenheit) == ValueText.missing)
    }

    @Test func fahrenheitRoundsHalfAwayFromZeroAndNeverShowsMinusZero() {
        // 1.25 °C is exactly 34.25 °F: one decimal rounds up, whole degrees round down.
        #expect(ValueText.temperature(1.25, in: .fahrenheit) == "34.3\(nbsp)°F")
        #expect(ValueText.shortTemperature(1.25, in: .fahrenheit) == "34°")
        // 2.5 °C is exactly 36.5 °F, which rounds to 37.
        #expect(ValueText.shortTemperature(2.5, in: .fahrenheit) == "37°")
        // −17.8 °C is −0.04 °F: no "−0".
        #expect(ValueText.temperature(-17.8, in: .fahrenheit) == "0.0\(nbsp)°F")
        #expect(ValueText.shortTemperature(-17.8, in: .fahrenheit) == "0°")
        #expect(ValueText.temperature(-40, in: .fahrenheit) == "\u{2212}40.0\(nbsp)°F")
        #expect(ValueText.temperature(nil, in: .fahrenheit) == ValueText.missing)
    }

    @Test func inchesExactValues() {
        #expect(ValueText.precipitation(21.2, in: .inches) == "0.83\(nbsp)in")   // 0.8346
        #expect(ValueText.precipitation(25.4, in: .inches) == "1.00\(nbsp)in")
        #expect(ValueText.precipitation(0, in: .inches) == "0.00\(nbsp)in")
        #expect(ValueText.precipitation(0.1, in: .inches) == "<0.01\(nbsp)in")   // 0.0039
        #expect(ValueText.precipitation(0.3, in: .inches) == "0.01\(nbsp)in")    // 0.0118
        #expect(ValueText.precipitation(nil, in: .inches) == ValueText.missing)
        #expect(ValueText.precipitation(21.2, in: .millimetres) == "21.2\(nbsp)mm")
        #expect(ValueText.millimetres(21.2) == "21.2\(nbsp)mm")
    }

    /// The closed row's "<1 mm" case in inches: anything under 1 mm shows two decimals, and an amount that
    /// rounds to 0.00 in shows "<0.01 in". "Dry" stays for exactly 0 in both units.
    @Test func rowPrecipitationInInches() {
        #expect(ValueText.rowPrecipitation(0.3, in: .millimetres) == "<1\(nbsp)mm")
        #expect(ValueText.rowPrecipitation(0.3, in: .inches) == "0.01\(nbsp)in")
        #expect(ValueText.rowPrecipitation(0.96, in: .inches) == "0.04\(nbsp)in")
        #expect(ValueText.rowPrecipitation(0.1, in: .inches) == "<0.01\(nbsp)in")
        #expect(ValueText.rowPrecipitation(21.2, in: .inches) == "0.83\(nbsp)in")
        #expect(ValueText.rowPrecipitation(0, in: .inches) == "Dry")
        #expect(ValueText.rowPrecipitation(nil, in: .inches) == ValueText.missing)
    }

    /// Step 5b: Certainty text names the chosen unit only ("within 2 °C" or "within 3.6 °F"), never both.
    @Test func certaintyBandInTheChosenUnitOnly() throws {
        let day = try #require(try Fixture.forecast().days.first)
        #expect(CertaintyText.band(.celsius) == "2\(nbsp)°C")
        #expect(CertaintyText.band(.fahrenheit) == "3.6\(nbsp)°F")
        #expect(CertaintyText.oddsSentence(day, unit: .fahrenheit) ==
                "Odds that Wednesday's high lands within 3.6\(nbsp)°F of 43°.")
        #expect(CertaintyText.oddsSentence(day, unit: .celsius) ==
                "Odds that Wednesday's high lands within 2\(nbsp)°C of 6°.")
        #expect(CertaintyText.dotsSentence(day, unit: .fahrenheit) ==
                "Out of 10 days like this, about 9 land within 3.6\(nbsp)°F of our forecast high.")
        #expect(ConsensusText.exampleSentence(day, unit: .fahrenheit) ==
                "About 9 of 10 days like this land within 3.6\(nbsp)°F.")
        #expect(CertaintyText.dotsLabel(day, unit: .fahrenheit).contains("within 3.6\(nbsp)degrees Fahrenheit of our high"))
        #expect(CertaintyText.dotsLabel(day, unit: .celsius).contains("within 2\(nbsp)degrees Celsius of our high"))
        #expect(SettingsText.certaintyNote(.celsius) == "Certainty means the chance the high lands within 2\(nbsp)°C of our number.")
        #expect(SettingsText.certaintyNote(.fahrenheit) == "Certainty means the chance the high lands within 3.6\(nbsp)°F of our number.")
        #expect(CertaintyText.explainer(.fahrenheit).hasSuffix("within 3.6\(nbsp)°F of our number."))
        #expect(ConsensusText.sureText(.fahrenheit).contains("within 3.6\(nbsp)°F of our number"))
        for unit in TemperatureUnit.allCases {
            for text in [CertaintyText.band(unit), CertaintyText.spokenBand(unit), SettingsText.certaintyNote(unit),
                         CertaintyText.explainer(unit), ConsensusText.sureText(unit),
                         CertaintyText.oddsSentence(day, unit: unit), CertaintyText.dotsSentence(day, unit: unit),
                         CertaintyText.dotsLabel(day, unit: unit)] {
                let both = (text.contains("°C") || text.contains("Celsius")) && (text.contains("°F") || text.contains("Fahrenheit"))
                #expect(!both, "\(text)")
            }
        }
    }

    /// Step 5b: the chance-of-precipitation label names the threshold in the chosen unit.
    @Test func chanceLabelInTheChosenUnit() {
        #expect(ValueText.chanceLabel(.millimetres) == "Chance of 1\(nbsp)mm+")
        #expect(ValueText.chanceLabel(.inches) == "Chance of 0.04\(nbsp)in or more")
        // 1 mm is 0.0394 in: two decimals, like every inch amount.
        #expect(ValueText.precipitation(1, in: .inches) == "0.04\(nbsp)in")
    }

    @Test func dayRowReadsTheChosenUnits() throws {
        let day = try #require(try Fixture.forecast().days.first)
        let label = DayRowText.label(day, units: UnitChoice(temperature: .fahrenheit, rain: .inches))
        #expect(label.contains("High 43°, low 36°"))
        #expect(label.contains("Precipitation 0.83\(nbsp)in"))
        #expect(DayRowText.label(day) == DayRowText.label(day, units: .metric))
        #expect(DayRowText.label(day).contains("High 6°, low 2°"))
    }

    @Test func everyConvertedValueKeepsUnitsJoined() throws {
        let forecast = try Fixture.forecast()
        let imperial = UnitChoice(temperature: .fahrenheit, rain: .inches)
        for day in forecast.days {
            let strings = [ValueText.temperature(day.high, in: .fahrenheit), ValueText.precipitation(day.precipMM, in: .inches),
                           ValueText.rowPrecipitation(day.precipMM, in: .inches), DayRowText.label(day, units: imperial),
                           CertaintyText.oddsSentence(day, unit: .fahrenheit), CertaintyText.dotsSentence(day, unit: .fahrenheit),
                           PlacesText.precipitation(day, unit: .inches)]
            for text in strings {
                #expect(UnitSpacingTests.offenders(in: text).isEmpty, "\(text)")
                // "in" is not in the shared pattern (it is also an English word), so check it here.
                #expect(text.firstMatch(of: /\d[ \t]in\b/) == nil, "\(text)")
            }
        }
    }
}

@Suite("Settings store")
@MainActor
struct SettingsStoreTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "SettingsStoreTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func defaultsAreCelsiusMillimetresAndLivingSky() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.temperatureUnit == .celsius)
        #expect(settings.rainUnit == .millimetres)
        #expect(settings.windUnit == .kilometresPerHour)
        #expect(settings.pressureUnit == .kilopascals)
        #expect(settings.livingSky)
        #expect(settings.units == .metric)
    }

    @Test func changesAreSavedAndReadBack() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.temperatureUnit = .fahrenheit
        settings.rainUnit = .inches
        settings.windUnit = .milesPerHour
        settings.pressureUnit = .inchesOfMercury
        settings.livingSky = false
        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.temperatureUnit == .fahrenheit)
        #expect(reopened.rainUnit == .inches)
        #expect(reopened.windUnit == .milesPerHour)
        #expect(reopened.pressureUnit == .inchesOfMercury)
        #expect(!reopened.livingSky)
        #expect(reopened.units == UnitChoice(temperature: .fahrenheit, rain: .inches, wind: .milesPerHour, pressure: .inchesOfMercury))
    }

    @Test func unreadableValuesFallBackToDefaults() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("kelvin", forKey: AppSettings.Key.temperatureUnit)
        defaults.set(42, forKey: AppSettings.Key.rainUnit)
        defaults.set("knots", forKey: AppSettings.Key.windUnit)
        defaults.set("hectopascals", forKey: AppSettings.Key.pressureUnit)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.windUnit == .kilometresPerHour)
        #expect(settings.pressureUnit == .kilopascals)
        #expect(settings.temperatureUnit == .celsius)
        #expect(settings.rainUnit == .millimetres)
        #expect(settings.livingSky)
    }

    /// Stored on the phone only: the store writes its five keys to the given defaults and nothing else.
    @Test func writesOnlyItsOwnKeys() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.temperatureUnit = .fahrenheit
        settings.rainUnit = .inches
        settings.windUnit = .milesPerHour
        settings.pressureUnit = .inchesOfMercury
        settings.livingSky = false
        let written = Set(defaults.persistentDomain(forName: name)?.keys.map { $0 } ?? [])
        #expect(written == Set(AppSettings.Key.all))
    }

    @Test func livingSkyOffIsOneCalmSkyAtEveryHour() throws {
        let forecast = try Fixture.forecast()
        for iso in ["2026-11-25T05:00:00Z", "2026-11-25T16:30:00Z", "2026-11-25T21:00:00Z", "2026-11-26T00:30:00Z"] {
            let now = try #require(ISO8601DateFormatter().date(from: iso))
            #expect(SkyStyle.current(for: forecast, now: now, living: false) == SkyStyle.calm)
        }
        // On, the night sky differs from the calm one.
        let night = try #require(ISO8601DateFormatter().date(from: "2026-11-25T05:00:00Z"))
        #expect(SkyStyle.current(for: forecast, now: night) != SkyStyle.calm)
        #expect(SkyStyle.calm.headerContrast >= 6)
        #expect(SkyStyle.calm.weather == nil)
    }

    @Test func versionComesFromTheBundle() {
        #expect(AppVersion.text(info: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]) == "1.0 (1)")
        #expect(AppVersion.text(info: ["CFBundleShortVersionString": "1.2"]) == "1.2")
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        #expect(version != nil)
        #expect(AppVersion.current.hasPrefix(version ?? "missing"))
        #expect(SettingsText.footer(version: "1.0 (1)") == "Weather Consensus 1.0 (1)")
        #expect(AboutText.version("1.0 (1)") == "Version 1.0 (1)")
    }
}

@Suite("Places, Settings and About screens")
struct NewScreenTests {
    private func forecast(consensusOnly: Bool = false, removeNormal: Bool = false, extraSource: [String: String]? = nil) throws -> PlaceForecast {
        var object = try Fixture.jsonObject()
        var place = object["place"] as! [String: Any]
        if consensusOnly {
            place["consensus_only"] = true
            place["truth_station"] = NSNull()
        }
        object["place"] = place
        var sources = object["sources"] as! [[String: Any]]
        if removeNormal { sources.removeAll { $0["id"] as? String == "normal" } }
        if let extraSource { sources.append(extraSource) }
        object["sources"] = sources
        return try ForecastDecoder.decode(Fixture.encode(object))
    }

    @Test func placeCardIsStationCheckedWithTheStationFromTheFile() throws {
        let forecast = try Fixture.forecast()
        #expect(PlacesText.checkPill(forecast.place) == "Station-checked")
        #expect(PlacesText.checkLine(forecast.place) == "Checked against Kitimat Forest Ave (ECCC)")
        #expect(PlacesText.morePlaces == "More places are coming.")
        let day = try #require(forecast.days.first)
        #expect(PlacesText.highLowLabel(day) == "Wed high / low")
        #expect(PlacesText.highLow(day, unit: .celsius) == "6° / 2°")
        #expect(PlacesText.highLow(day, unit: .fahrenheit) == "43° / 36°")
        #expect(PlacesText.precipitation(day, unit: .millimetres) == "100% · 21\(nbsp)mm")
        #expect(PlacesText.certaintyLine(day) == "Wednesday's Certainty 91%")
    }

    @Test func consensusOnlyPlaceSaysSo() throws {
        let place = try forecast(consensusOnly: true).place
        #expect(PlacesText.checkPill(place) == "Consensus only")
        #expect(PlacesText.checkLine(place).hasPrefix("No station here"))
        #expect(AboutText.checkedAgainst(place) == nil)
    }

    @Test func placeCardVoiceOverReadsPlaceStationAndDay() throws {
        let forecast = try Fixture.forecast()
        let label = PlacesText.cardLabel(forecast, units: UnitChoice(temperature: .fahrenheit, rain: .millimetres))
        #expect(label.hasPrefix("Kitimat. Station-checked. Checked against Kitimat Forest Ave (ECCC)."))
        #expect(label.contains("High 43°, low 36°"))
        #expect(label.contains("Certainty 91 percent, High tier"))
    }

    @Test func sourcesCountComesFromTheFile() throws {
        #expect(SettingsText.sourcesValue(try Fixture.forecast()) == "9 models and the normal")
        #expect(SettingsText.sourcesValue(try forecast(removeNormal: true)) == "9 models")
        #expect(SettingsText.sourcesValue(try forecast(extraSource: ["id": "new_x", "label": "New X"])) == "10 models and the normal")
        #expect(SettingsText.placeName(try Fixture.forecast()) == "Kitimat")
    }

    @Test func agenciesFollowTheCanvasFromTheFile() throws {
        #expect(AboutText.agencies(try Fixture.forecast()) ==
                "Environment and Climate Change Canada, ECMWF, NOAA, DWD, UK Met Office, JMA, CMA and Météo-France")
        let withNew = try forecast(extraSource: ["id": "new_x", "label": "New Agency X"])
        #expect(AboutText.agencies(withNew)?.hasSuffix("Météo-France and New Agency X") == true)
    }

    @Test func aboutCreditsComeFromTheFile() throws {
        let forecast = try Fixture.forecast()
        #expect(AboutText.checkedAgainst(forecast.place) == "ECCC weather station, Kitimat Forest Ave")
        #expect(AboutText.hasNormal(forecast))
        #expect(!AboutText.hasNormal(try self.forecast(removeNormal: true)))
        #expect(AboutText.normals == "ECCC climate normals, 1991 to 2020")
        #expect(AboutText.deliveredBy == "Open-Meteo, under CC\(nbsp)BY\(nbsp)4.0")
    }

    @Test func aboutTextHasNoFixedSourceCount() {
        #expect(AboutText.why.firstMatch(of: /\d/) == nil)
        #expect(AboutText.why.contains("checks many forecasts"))
        #expect(AboutText.tagline == "Many forecasts. One answer.")
    }

    @Test func privacyPolicyNamesGitHubAndLinksItsStatement() {
        let all = PrivacyText.sections.flatMap(\.paragraphs).joined(separator: " ")
        #expect(all.contains("collects nothing"))
        #expect(all.contains("GitHub Pages"))
        #expect(all.contains("server logs"))
        #expect(all.contains("stored only on this phone"))
        let links = PrivacyText.sections.flatMap(\.links).map(\.url)
        #expect(links.contains(PrivacyText.githubPrivacyURL))
        #expect(links.allSatisfy { $0.scheme == "https" && $0.host() == "docs.github.com" })
    }

    @Test func acknowledgementsCoverFontAndData() {
        #expect(AcknowledgementText.licenceText?.contains("SIL OPEN FONT LICENSE Version 1.1") == true)
        #expect(AcknowledgementText.interCopyright.hasPrefix("Copyright"))
        #expect(AcknowledgementText.openMeteo.contains("CC BY 4.0"))
        #expect(AcknowledgementText.eccc.hasPrefix("Contains information licenced under the Data Server End-use Licence of Environment and Climate Change Canada."))
        // Real-time observations are covered, and nothing suggests official status (licence section 5).
        #expect(AcknowledgementText.eccc.contains("real-time latest observation"))
        #expect(AcknowledgementText.eccc.contains("not an official ECCC product, and ECCC does not endorse it"))
    }

    /// No contact details anywhere in the app's text: no email address, phone number or personal web page.
    @Test func noContactDetailsInAnyString() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "WeatherConsensus/Localizable.xcstrings")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.firstMatch(of: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/) == nil)
        #expect(text.firstMatch(of: /\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}/) == nil)
        #expect(text.contains("Made in Kitimat, BC"))
    }

    @Test func newColoursHaveEnoughContrast() {
        for chip in ChipColours.all {
            #expect(chip.ink.contrast(with: chip.fill) >= 3, "\(chip)")
        }
        // Units control: chosen (navy on white) and not chosen (light on inner navy).
        #expect(Palette.ink.contrast(with: Palette.white) >= 4.5)
        #expect(Palette.textSecondary.contrast(with: Palette.cardInner) >= 4.5)
        // Switch on (green) against the card, and the tile and note text.
        #expect(Palette.tierHigh.contrast(with: Palette.card) >= 3)
        #expect(Palette.rain.contrast(with: Palette.detail) >= 4.5)
        #expect(Palette.textSecondary.contrast(with: Palette.detail) >= 4.5)
        #expect(Palette.textBody.contrast(with: Palette.card.over(Palette.white, alpha: 0.92)) >= 4.5)
        #expect(Palette.link.contrast(with: Palette.card.over(Palette.white, alpha: 0.92)) >= 4.5)
    }
}
