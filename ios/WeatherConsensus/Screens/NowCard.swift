import SwiftUI

/// The Now card at the top of the Weather tab: the latest observation at the place's approved station,
/// from the file's optional `now` block. Built from the design canvas's top card ("CURRENT CONDITIONS",
/// `Main.dc.html`). Option b (owner decision, 28 Nov 2026): the station observation as before, plus the
/// condition from `now.condition` (rain or snow measured by the station, the sky from the forecast) and
/// today's high and low (`today`: the station so far and the forecast for the rest of the day). Both are a
/// beta with no accuracy claim. No summary line.
///
/// - Always labelled "Observed at <station>, X min ago", X counted from the oldest value shown. When some values
///   come from a newer minute record, a second line names them and their age ("Newer: temperature and humidity, 2 min ago").
/// - Over 3 h old: values dimmed, "Last observation X h ago". Over 12 h: values hidden, label only.
/// - Units follow Settings. Clock times use the phone's own time zone.
/// - Feels like: ECCC wind chill or humidex (`FeelsLike`), otherwise the air temperature.
/// - Sunrise and sunset come from `SolarTimes` (worked out on the phone, not observed).
struct NowCard: View {
    let observation: StationObservation
    let place: PlaceForecast.Place
    let now: Date
    var today: TodayForecast? = nil

    @Environment(\.unitChoice) private var units
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // The card's age is its oldest value's (minute and hourly records can differ by up to an hour).
        let age = ObservationAge(observedAt: observation.shownAsOf, now: now)
        VStack(alignment: .leading, spacing: 14) {
            header(age: age)
            if age.state != .hidden {
                Group {
                    temperatureBlock
                    tiles
                }
                .opacity(age.state == .dimmed && contrast != .increased ? NowText.dimOpacity : 1)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 16, bottom: 16, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(Palette.card))
                .overlay(alignment: .topLeading) {
                    // Decoration at a fixed height (canvas), so left out when larger text moves the content.
                    if age.state != .hidden && !dynamicTypeSize.isAccessibilitySize {
                        Ridges().allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: Color(Palette.ink).opacity(0.22), radius: 12, y: 10)
    }

    // MARK: Parts

    private func header(age: ObservationAge) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: NowText.title)
                .font(.inter(12.5, .extraBold, relativeTo: .caption))
                .tracking(0.9)
                .foregroundStyle(Color(Palette.textSecondary))
                .accessibilityAddTraits(.isHeader)
            ForEach(NowText.label(observation, age: age) + NowText.newerLine(observation, now: now, age: age), id: \.self) { line in
                Text(verbatim: line)
                    .font(.inter(13.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Color(Palette.textBody))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    private var temperatureBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            temperatureColumn
            Spacer(minLength: 0)
            if let condition = observation.condition?.condition, !dynamicTypeSize.isAccessibilitySize {
                ConditionIcon(condition: condition, night: Daylight.isNight(now, place: place), size: 72)
                    .padding(.top, 6)
            }
        }
    }

    private var temperatureColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 2) {
                Text(verbatim: NowText.bigTemperature(observation.temp, unit: units.temperature))
                    .font(.inter(84, .bold, relativeTo: .largeTitle))
                    .tracking(-3.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: units.temperature == .celsius ? "°C" : "°F")
                    .font(.inter(28, .semibold, relativeTo: .title))
                    .padding(.top, 8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: NowText.spokenTemperature(observation.temp, unit: units.temperature)))
            if let condition = observation.condition?.condition {
                let word = ConditionText.now(condition, night: Daylight.isNight(now, place: place))
                HStack(spacing: 8) {
                    if dynamicTypeSize.isAccessibilitySize {
                        ConditionIcon(condition: condition, night: Daylight.isNight(now, place: place))
                    }
                    Text(verbatim: word).font(.inter(19, .extraBold, relativeTo: .title3))
                        .fixedSize(horizontal: false, vertical: true)
                    BetaPill()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: String(localized: "Now: \(word). Beta.",
                                                         comment: "VoiceOver, Now card: the current condition, a beta")))
            }
            if let today = NowText.today(today, unit: units.temperature) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 14))
                VStack(alignment: .leading, spacing: 2) {
                    layout {
                        arrowValue("arrow.up", Palette.warm, today.high)
                        arrowValue("arrow.down", Palette.link, today.low)
                    }
                    Text(verbatim: today.since)
                        .font(.inter(12.5, .regular, relativeTo: .caption))
                        .foregroundStyle(Color(Palette.textSecondary))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: today.spoken))
            } else if let soFar = NowText.soFar(observation, unit: units.temperature) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 14))
                VStack(alignment: .leading, spacing: 2) {
                    layout {
                        arrowValue("arrow.up", Palette.warm, soFar.high)
                        arrowValue("arrow.down", Palette.link, soFar.low)
                    }
                    Text(verbatim: soFar.since)
                        .font(.inter(12.5, .regular, relativeTo: .caption))
                        .foregroundStyle(Color(Palette.textSecondary))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: soFar.spoken))
            }
        }
        .padding(.horizontal, 4)
    }

    private func arrowValue(_ symbol: String, _ tint: RGB, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 12, weight: .heavy)).foregroundStyle(Color(tint))
            Text(verbatim: text)
        }
        .font(.inter(14, .bold, relativeTo: .subheadline))
    }

    private var tiles: some View {
        let columns = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        let feels = FeelsLike.from(temp: observation.temp, windKMH: observation.windKMH, dewPoint: observation.dewPoint)
        let sun = SolarTimes(date: now, latitude: place.lat, longitude: place.lon, timeZone: .current)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            Tile(title: String(localized: "Feels like"), icon: "thermometer.medium", tint: Palette.warm,
                 value: NowText.feelsValue(feels, unit: units.temperature), note: NowText.feelsNote(feels))
            Tile(title: String(localized: "Wind"), icon: "wind", tint: Palette.windTint,
                 value: NowText.windValue(observation, unit: units.wind),
                 note: NowText.windNote(observation, unit: units.wind),
                 arrowDegrees: NowText.arrowDegrees(observation, unit: units.wind),
                 spoken: NowText.spokenWind(observation, unit: units.wind))
            Tile(title: String(localized: "Humidity"), icon: "drop.fill", tint: Palette.rain,
                 value: ValueText.percent(observation.humidity.map { Int($0.rounded()) }),
                 note: NowText.dewNote(observation.dewPoint, unit: units.temperature))
            Tile(title: String(localized: "Pressure"), icon: "gauge.with.dots.needle.50percent", tint: Palette.textBody,
                 value: ValueText.pressure(observation.pressureKPA, in: units.pressure),
                 note: NowText.tendency(observation.pressureTendency))
            Tile(title: String(localized: "Last hour"), icon: "cloud.rain", tint: Palette.rain,
                 value: ValueText.precipitation(observation.precip1hMM, in: units.rain),
                 note: NowText.precipSoFarNote(observation, unit: units.rain),
                 spoken: NowText.spokenPrecip(observation, unit: units.rain))
            SunTile(lines: NowText.sun(sun))
        }
    }
}

/// One canvas tile: icon chip and title, big value, small note.
private struct Tile: View {
    let title: String
    let icon: String
    let tint: RGB
    let value: String
    let note: String?
    var arrowDegrees: Double? = nil
    var spoken: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TileTitle(title: title, icon: icon, tint: tint)
            Text(verbatim: value)
                .font(.inter(24, .extraBold, relativeTo: .title2))
                .tracking(-0.24)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                if let arrowDegrees {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(Palette.windTint))
                        .rotationEffect(.degrees(arrowDegrees))
                }
                Text(verbatim: note ?? " ")
                    .font(.inter(12.5, .regular, relativeTo: .caption))
                    .foregroundStyle(Color(Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(Palette.heroPanel)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken ?? [title, value, note].compactMap { $0 }.joined(separator: ", ")))
    }
}

private struct TileTitle: View {
    let title: String
    let icon: String
    let tint: RGB

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(tint))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color(tint).opacity(0.18)))
            Text(verbatim: title)
                .font(.inter(12.5, .bold, relativeTo: .caption))
                .foregroundStyle(Color(Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Sunrise and sunset at the place, on the phone's clock (canvas tile).
private struct SunTile: View {
    let lines: [NowText.SunLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TileTitle(title: String(localized: "Sunrise/Sunset", comment: "Now card tile title, as on the canvas"), icon: "sunrise", tint: Palette.tierMedium)
            ForEach(lines, id: \.text) { line in
                HStack(spacing: 7) {
                    if let symbol = line.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 15))
                            .symbolRenderingMode(.multicolor)
                            .foregroundStyle(Color(Palette.tierMedium))
                    }
                    Text(verbatim: line.text)
                        .font(.inter(17, .extraBold, relativeTo: .headline))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(Palette.heroPanel)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: lines.map(\.spoken).joined(separator: ", ")))
    }
}

/// The canvas's two ridges inside the top card (`Main.dc.html`: an SVG 390 x 90 at left −16, top 150).
private struct Ridges: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width + 32
            Canvas { context, _ in
                let scale = width / 390
                func path(_ points: [(Double, Double)]) -> Path {
                    var p = Path()
                    p.addLines(points.map { CGPoint(x: $0.0 * scale - 16, y: 150 + $0.1) })
                    p.closeSubpath()
                    return p
                }
                context.fill(path([(0, 90), (0, 52), (38, 26), (68, 44), (114, 6), (154, 36), (180, 22), (232, 56),
                                   (266, 34), (314, 64), (350, 44), (390, 70), (390, 90)]), with: .color(Color(RGB(0x1F4479))))
                context.fill(path([(0, 90), (0, 70), (52, 48), (88, 62), (146, 32), (190, 58), (230, 46), (280, 68),
                                   (326, 50), (390, 72), (390, 90)]), with: .color(Color(RGB(0x244D86))))
            }
        }
    }
}

// MARK: - Text

/// Every Now card string, built here so the tests can read them.
nonisolated enum NowText {
    /// Values over 3 h old are drawn at this opacity. Kept high enough that secondary text still has
    /// 4.5:1 on the card and the tiles (tested).
    static let dimOpacity = 0.72

    static let title = String(localized: "LATEST OBSERVATION", comment: "Now card heading, in capitals as on the canvas")

    /// "Observed at Kitimat Forest Ave, 40 min ago"; over 3 h old a second line, "Last observation 5 h ago".
    static func label(_ observation: StationObservation, age: ObservationAge) -> [String] {
        let name = observation.station?.name ?? String(localized: "the station", comment: "Now card: station with no name in the file")
        switch age.state {
        case .fresh:
            if age.minutes < 1 {
                return [String(localized: "Observed at \(name), just now", comment: "Now card label. Value: station name")]
            }
            if age.minutes < 60 {
                return [String(localized: "Observed at \(name), \(age.minutes)\u{00A0}min ago",
                               comment: "Now card label. Values: station name, minutes since the observation")]
            }
            return [String(localized: "Observed at \(name), \(age.hours)\u{00A0}h ago",
                           comment: "Now card label. Values: station name, whole hours since the observation (1 or 2)")]
        case .dimmed, .hidden:
            return [String(localized: "Observed at \(name)", comment: "Now card label for an old observation. Value: station name"),
                    String(localized: "Last observation \(age.hours)\u{00A0}h ago",
                           comment: "Now card, observation over 3 hours old. Value: whole hours")]
        }
    }

    /// "Newer: temperature and humidity, 2 min ago": the values from a minute record newer than the oldest
    /// value on the card. Empty when every value is as old as the label says, or the values are hidden.
    static func newerLine(_ observation: StationObservation, now: Date, age: ObservationAge) -> [String] {
        guard age.state != .hidden, let newer = observation.newerValues else { return [] }
        let newerAge = ObservationAge(observedAt: newer.at, now: now)
        guard newerAge.minutes != age.minutes else { return [] }
        let fields = newer.values.map(name).formatted(.list(type: .and))
        if newerAge.minutes < 1 {
            return [String(localized: "Newer: \(fields), just now", comment: "Now card, values from a newer record. Value: list of values, e.g. temperature and humidity")]
        }
        if newerAge.minutes < 60 {
            return [String(localized: "Newer: \(fields), \(newerAge.minutes)\u{00A0}min ago",
                           comment: "Now card, values from a newer record. Values: list of values, minutes since that record")]
        }
        return [String(localized: "Newer: \(fields), \(newerAge.hours)\u{00A0}h ago",
                       comment: "Now card, values from a newer record. Values: list of values, whole hours since that record")]
    }

    static func name(_ value: StationObservation.CurrentValue) -> String {
        switch value {
        case .temp: String(localized: "temperature", comment: "Now card, in the list of newer values")
        case .dewPoint: String(localized: "dew point", comment: "Now card, in the list of newer values")
        case .humidity: String(localized: "humidity", comment: "Now card, in the list of newer values")
        case .wind: String(localized: "wind", comment: "Now card, in the list of newer values")
        case .gust: String(localized: "gusts", comment: "Now card, in the list of newer values")
        }
    }

    /// "4" or "−2": whole degrees, as the canvas draws the big number. The unit is drawn beside it.
    static func bigTemperature(_ celsius: Double?, unit: TemperatureUnit) -> String {
        let short = ValueText.shortTemperature(celsius, in: unit)
        return short.hasSuffix("°") ? String(short.dropLast()) : short
    }

    static func spokenTemperature(_ celsius: Double?, unit: TemperatureUnit) -> String {
        guard celsius != nil else { return String(localized: "Temperature not available") }
        return String(localized: "Temperature \(ValueText.shortTemperature(celsius, in: unit))\(unit == .celsius ? "C" : "F")",
                      comment: "VoiceOver: observed temperature, e.g. Temperature 4°C")
    }

    struct SoFar: Equatable {
        let high: String
        let low: String
        let since: String
        let spoken: String
    }

    /// "High 4°", "Low 2°", "So far since 11:00 PM". Nil before the first hour of the climate day is in.
    static func soFar(_ observation: StationObservation, unit: TemperatureUnit,
                      timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent) -> SoFar? {
        guard observation.highSoFar != nil || observation.lowSoFar != nil, let since = observation.soFarSince else { return nil }
        let high = String(localized: "High \(ValueText.shortTemperature(observation.highSoFar, in: unit))", comment: "Now card: observed high so far")
        let low = String(localized: "Low \(ValueText.shortTemperature(observation.lowSoFar, in: unit))", comment: "Now card: observed low so far")
        let time = clock(since, timeZone: timeZone, locale: locale)
        let sinceText = String(localized: "So far since \(time)", comment: "Now card: start of the climate day on the phone's clock")
        return SoFar(high: high, low: low, since: sinceText,
                     spoken: String(localized: "Observed so far since \(time): high \(ValueText.shortTemperature(observation.highSoFar, in: unit)), low \(ValueText.shortTemperature(observation.lowSoFar, in: unit))",
                                    comment: "VoiceOver: observed high and low so far"))
    }

    /// Today's high and low (beta): the station so far and the forecast for the rest of the day.
    static func today(_ today: TodayForecast?, unit: TemperatureUnit) -> SoFar? {
        guard let today, today.high != nil || today.low != nil else { return nil }
        let high = String(localized: "High \(ValueText.shortTemperature(today.high, in: unit))", comment: "Now card: today's high")
        let low = String(localized: "Low \(ValueText.shortTemperature(today.low, in: unit))", comment: "Now card: today's low")
        return SoFar(high: high, low: low,
                     since: String(localized: "Today, observed so far and forecast", comment: "Now card: today's high and low, a beta"),
                     spoken: String(localized: "Today: high \(ValueText.shortTemperature(today.high, in: unit)), low \(ValueText.shortTemperature(today.low, in: unit)), observed so far and forecast. Beta.",
                                    comment: "VoiceOver: today's high and low, a beta"))
    }

    /// A clock time on the phone's clock ("11:00 PM" or "23:00", as the phone is set).
    static func clock(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    // Feels like

    static func feelsValue(_ feels: FeelsLike?, unit: TemperatureUnit) -> String {
        ValueText.shortTemperature(feels?.value, in: unit)
    }

    static func feelsNote(_ feels: FeelsLike?) -> String? {
        switch feels {
        case .windChill: String(localized: "Wind chill")
        case .humidex: String(localized: "Humidex")
        case .air: String(localized: "Air temperature", comment: "Feels like: no wind chill or humidex, so the air temperature")
        case nil: nil
        }
    }

    // Wind

    /// The wind in the chosen unit, whole numbers, or "Calm" when it rounds to 0.
    static func windValue(_ observation: StationObservation, unit: WindUnit) -> String {
        guard let kmh = observation.windKMH else { return ValueText.missing }
        if ValueText.windWhole(kmh, in: unit) == 0 { return String(localized: "Calm", comment: "Now card: wind rounds to 0") }
        return ValueText.wind(kmh, in: unit)
    }

    /// "From NNE · gusts 50" (canvas). Gusts only when they show higher than the wind.
    static func windNote(_ observation: StationObservation, unit: WindUnit) -> String? {
        let calm = observation.windKMH.map { ValueText.windWhole($0, in: unit) == 0 } ?? true
        let from = calm ? nil : observation.windDirDeg.map { String(localized: "From \(ValueText.compass($0))", comment: "Wind direction, e.g. From NNE") }
        let gust = gustWhole(observation, unit: unit).map { String(localized: "gusts \($0)", comment: "Now card: wind gust, number only, as on the canvas") }
        switch (from, gust) {
        case let (from?, gust?): return "\(from) · \(gust)"
        case let (from?, nil): return from
        case let (nil, gust?): return gust.prefix(1).uppercased() + gust.dropFirst()
        case (nil, nil): return nil
        }
    }

    /// The gust in whole units, when it is higher than the wind as shown.
    static func gustWhole(_ observation: StationObservation, unit: WindUnit) -> Int? {
        guard let gust = observation.gustKMH else { return nil }
        let g = ValueText.windWhole(gust, in: unit)
        let w = observation.windKMH.map { ValueText.windWhole($0, in: unit) } ?? 0
        return g > w ? g : nil
    }

    /// Arrow pointing where the wind blows to (the canvas rotates its arrow by direction + 180).
    static func arrowDegrees(_ observation: StationObservation, unit: WindUnit) -> Double? {
        guard let dir = observation.windDirDeg, let kmh = observation.windKMH, ValueText.windWhole(kmh, in: unit) > 0 else { return nil }
        return (dir + 180).truncatingRemainder(dividingBy: 360)
    }

    static func spokenWind(_ observation: StationObservation, unit: WindUnit) -> String {
        var parts = [String(localized: "Wind"), windValue(observation, unit: unit)]
        if let dir = observation.windDirDeg, arrowDegrees(observation, unit: unit) != nil {
            parts.append(String(localized: "from the \(ValueText.spokenCompass(dir))", comment: "VoiceOver: wind direction"))
        }
        if let g = gustWhole(observation, unit: unit) {
            parts.append(String(localized: "gusts \(ValueText.windNumber(g, in: unit))",
                                comment: "VoiceOver: wind gust with unit"))
        }
        return parts.joined(separator: ", ")
    }

    // Humidity, pressure, precipitation

    static func dewNote(_ dewPoint: Double?, unit: TemperatureUnit) -> String? {
        guard dewPoint != nil else { return nil }
        return String(localized: "Dew point \(ValueText.shortTemperature(dewPoint, in: unit))", comment: "Now card, under humidity")
    }

    /// "Rising", "Falling", "Steady"; nothing for a value the app does not know.
    static func tendency(_ value: String?) -> String? {
        switch value {
        case "rising": String(localized: "Rising", comment: "Pressure tendency over 3 hours")
        case "falling": String(localized: "Falling", comment: "Pressure tendency over 3 hours")
        case "steady": String(localized: "Steady", comment: "Pressure tendency over 3 hours")
        default: nil
        }
    }

    /// "8.2 mm since 11:00 PM".
    static func precipSoFarNote(_ observation: StationObservation, unit: RainUnit,
                                timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let total = observation.precipSoFarMM, let since = observation.soFarSince else { return nil }
        return String(localized: "\(ValueText.precipitation(total, in: unit)) since \(clock(since, timeZone: timeZone, locale: locale))",
                      comment: "Now card: precipitation so far today. Values: amount, start of the climate day")
    }

    static func spokenPrecip(_ observation: StationObservation, unit: RainUnit) -> String {
        var text = String(localized: "Precipitation in the last hour: \(ValueText.precipitation(observation.precip1hMM, in: unit))",
                          comment: "VoiceOver: precipitation in the last hour")
        if let note = precipSoFarNote(observation, unit: unit) { text += ", " + note }
        return text
    }

    // Sun

    struct SunLine: Equatable {
        let symbol: String?
        let text: String
        let spoken: String
    }

    static func sun(_ solar: SolarTimes, timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent) -> [SunLine] {
        switch solar.kind {
        case let .normal(sunrise, sunset):
            let rise = clock(sunrise, timeZone: timeZone, locale: locale)
            let set = clock(sunset, timeZone: timeZone, locale: locale)
            return [SunLine(symbol: "sunrise.fill", text: rise, spoken: String(localized: "Sunrise \(rise)")),
                    SunLine(symbol: "sunset.fill", text: set, spoken: String(localized: "Sunset \(set)"))]
        case .alwaysUp:
            let text = String(localized: "Sun up all day")
            return [SunLine(symbol: nil, text: text, spoken: text)]
        case .alwaysDown:
            let text = String(localized: "Sun down all day")
            return [SunLine(symbol: nil, text: text, spoken: text)]
        }
    }
}

#if DEBUG
#Preview("Now card") {
    let model = ForecastScreenModel.previewFixture(withNow: true)
    ScrollView {
        if let forecast = model.forecast, let now = forecast.now {
            NowCard(observation: now, place: forecast.place, now: now.observedAt.addingTimeInterval(40 * 60))
                .padding(16)
        }
    }
    .background(SkyView(style: SkyStyle(time: .day, weather: nil)))
}

/// Temperature and humidity from a minute record, the rest from the hourly record before it: the real Kitimat
/// Forest Ave block of 26 Nov 2026 01:07 UTC (docs/JSON_SCHEMA.md), seen at 01:40 UTC.
#Preview("Now card, values from two records") {
    let model = ForecastScreenModel.previewFixture()
    let iso = ISO8601DateFormatter()
    let observation = StationObservation(
        observedAt: iso.date(from: "2026-11-26T01:07:00Z")!,
        station: .init(network: "ECCC", id: "1064324", name: "Kitimat Forest Ave", distanceKM: 2.0),
        temp: 3.7, dewPoint: 3.7, humidity: 100, windKMH: 0.3, windDirDeg: 190, gustKMH: 2.6, pressureKPA: 99.98,
        precip1hMM: 0.0, highSoFar: 4.0, lowSoFar: 1.9, soFarSince: iso.date(from: "2026-11-25T06:00:00Z")!, soFarHours: 18,
        valuesFrom: .init(minuteAt: iso.date(from: "2026-11-26T01:07:00Z")!, hourlyAt: iso.date(from: "2026-11-26T01:00:00Z")!,
                          temp: "minute", dewPoint: "hourly", humidity: "minute", wind: "hourly", gust: "hourly"))
    ScrollView {
        if let forecast = model.forecast {
            NowCard(observation: observation, place: forecast.place, now: iso.date(from: "2026-11-26T01:40:00Z")!)
                .padding(16)
        }
    }
    .background(SkyView(style: SkyStyle(time: .night, weather: nil)))
}
#endif
