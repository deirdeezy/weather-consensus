import Foundation

/// What the Consensus tab's steps 2 and 3 show from `track_record`, worked out from the file alone.
/// Pure, so the tests can check every state: no block, too few days, live record ready.
nonisolated struct TrackRecordFacts: Sendable {
    let record: TrackRecord?
    let names: SourceNames
    let consensusOnly: Bool

    init(_ forecast: PlaceForecast) {
        self.record = forecast.trackRecord
        self.names = SourceNames(forecast)
        self.consensusOnly = forecast.place.consensusOnly
    }

    init(record: TrackRecord?, names: SourceNames, consensusOnly: Bool = false) {
        self.record = record
        self.names = names
        self.consensusOnly = consensusOnly
    }

    /// The file has a scored track record to show. False for older files (no block) and for a block
    /// with no sources: the cards then say the track record is not in this file yet.
    var hasArchive: Bool { !(record?.archive?.sources.isEmpty ?? true) }

    var archive: TrackRecord.Archive? { record?.archive }

    /// Lead days with at least one scored source, in file order.
    var leads: [Int] {
        guard let record, let archive = record.archive else { return [] }
        return record.leads.filter { lead in archive.sources.contains { $0.lead == lead } }
    }

    /// One line of the miss chart.
    struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// deg C or mm, as published. nil: too few days, or not recorded (live consensus).
        let miss: Double?
        let days: Int?
        /// Today's share, 0 to 1 (archive only). nil: not in today's blend, or a live row.
        let weight: Double?
        let isConsensus: Bool
    }

    static let consensusID = "consensus"

    /// The consensus first, then every source from the closest miss to the largest; a source with too
    /// few days goes last. Archive rows carry today's weight; live rows never do, and the live consensus
    /// is not recorded yet, so its row has no miss.
    func rows(_ variable: TrackVariable, lead: Int, basis: TrackBasis) -> [Row] {
        guard let record else { return [] }
        var sources: [Row]
        let consensus: Row
        switch basis {
        case .archive:
            guard let archive = record.archive else { return [] }
            let c = archive.consensus.first { $0.lead == lead }?.miss(variable)
            consensus = Row(id: Self.consensusID, name: TrackRecordText.consensusName, miss: c?.miss,
                            days: c?.days, weight: nil, isConsensus: true)
            sources = archive.sources.filter { $0.lead == lead }.compactMap { s in
                guard let scored = s.scored(variable) else { return nil }
                return Row(id: s.id, name: names.name(for: s.id), miss: scored.miss, days: scored.days,
                           weight: scored.weight, isConsensus: false)
            }
        case .live:
            guard let live = record.live else { return [] }
            consensus = Row(id: Self.consensusID, name: TrackRecordText.consensusName, miss: nil, days: nil,
                            weight: nil, isConsensus: true)
            sources = live.sources.filter { $0.lead == lead }.compactMap { s in
                guard let m = s.miss(variable) else { return nil }
                return Row(id: s.id, name: names.name(for: s.id), miss: m.miss, days: m.days, weight: nil,
                           isConsensus: false)
            }
        }
        sources.sort { a, b in
            switch (a.miss, b.miss) {
            case let (x?, y?): x == y ? a.name < b.name : x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.name < b.name
            }
        }
        return [consensus] + sources
    }

    /// Largest miss among the rows: the full bar length.
    static func longest(_ rows: [Row]) -> Double {
        rows.compactMap(\.miss).max() ?? 0
    }

    /// The day count most rows share (ties: the larger), so only rows that differ need saying.
    static func usualDays(_ rows: [Row]) -> Int? {
        let counts = Dictionary(grouping: rows.compactMap(\.days), by: { $0 }).mapValues(\.count)
        return counts.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }?.key
    }

    /// Our own record at one lead.
    struct LiveStatus: Equatable, Sendable {
        let days: Int
        let minDays: Int
        let since: LocalDate?
        var enough: Bool { days >= minDays }
    }

    func liveStatus(lead: Int) -> LiveStatus? {
        guard let live = record?.live else { return nil }
        return LiveStatus(days: live.days.first { $0.lead == lead }?.days ?? 0, minDays: live.minDays,
                          since: live.since)
    }

    /// True only when our own record has a real miss for this variable and lead. Until then the chart
    /// shows the archive alone and says how many live days there are.
    func liveHasNumbers(_ variable: TrackVariable, lead: Int) -> Bool {
        guard let status = liveStatus(lead: lead), status.enough else { return false }
        return rows(variable, lead: lead, basis: .live).contains { !$0.isConsensus && $0.miss != nil }
    }

    /// One source's habit for step 3.
    struct Habit: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// Forecast minus observed, deg C: positive runs warm.
        let bias: Double?
        let days: Int?
    }

    /// Habits for highs or lows at a lead, largest first; a source with no habit fix yet goes last.
    func habits(_ variable: TrackVariable, lead: Int = 1) -> [Habit] {
        guard variable.isTemperature, let archive = record?.archive else { return [] }
        return archive.sources.filter { $0.lead == lead }
            .compactMap { s -> Habit? in
                guard let scored = s.scored(variable) else { return nil }
                return Habit(id: s.id, name: names.name(for: s.id), bias: scored.bias, days: scored.biasDays)
            }
            .sorted { a, b in
                switch (a.bias, b.bias) {
                case let (x?, y?): abs(x) == abs(y) ? a.name < b.name : abs(x) > abs(y)
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): a.name < b.name
                }
            }
    }
}

/// Words and numbers for the track record. Misses and habits are differences, so deg F is x 1.8 with no +32.
nonisolated enum TrackRecordText {
    static let consensusName = String(localized: "Consensus", comment: "Track record chart: the row for our blended forecast")

    // MARK: Numbers

    /// A temperature difference in the chosen unit.
    static func degrees(_ celsius: Double, in unit: TemperatureUnit) -> Double {
        unit == .celsius ? celsius : celsius * 9 / 5
    }

    /// Chart value, unit in the heading: "1.0" (deg C or deg F, one decimal), "3.0" (mm, one decimal),
    /// "0.12" (in, two decimals). A dash when there is no miss.
    static func missValue(_ miss: Double?, _ variable: TrackVariable, units: UnitChoice) -> String {
        guard let miss else { return ValueText.missing }
        if variable.isTemperature {
            return oneDecimal(degrees(miss, in: units.temperature))
        }
        return units.rain == .millimetres
            ? oneDecimal(miss)
            : (miss / 25.4).formatted(.number.precision(.fractionLength(2)))
    }

    /// "1.0 °C", "1.8 °F", "3.0 mm", "0.12 in".
    static func missWithUnit(_ miss: Double?, _ variable: TrackVariable, units: UnitChoice) -> String {
        guard miss != nil else { return ValueText.missing }
        return missValue(miss, variable, units: units) + ValueText.nbsp + unitSymbol(variable, units: units)
    }

    static func unitSymbol(_ variable: TrackVariable, units: UnitChoice) -> String {
        if variable.isTemperature { return units.temperature == .celsius ? "°C" : "°F" }
        return units.rain == .millimetres ? "mm" : "in"
    }

    /// Spoken unit for VoiceOver.
    static func spokenUnit(_ variable: TrackVariable, units: UnitChoice) -> String {
        if variable.isTemperature {
            return units.temperature == .celsius
                ? String(localized: "degrees Celsius") : String(localized: "degrees Fahrenheit")
        }
        return units.rain == .millimetres ? String(localized: "millimetres") : String(localized: "inches")
    }

    /// The habit fix as a pill: what we add, the opposite of the habit. "+1.1°", "−2.0°", "0.0°".
    static func fixPill(_ bias: Double?, unit: TemperatureUnit) -> String {
        guard let bias else { return ValueText.missing }
        let fix = rounded(-degrees(bias, in: unit))
        let text = oneDecimal(abs(fix))
        if fix > 0 { return "+" + text + "°" }
        if fix < 0 { return "\u{2212}" + text + "°" }
        return text + "°"
    }

    /// Which way the fix goes, for the pill colour: up (the source runs cold), down (warm) or none.
    enum FixDirection: Equatable, Sendable { case up, down, none }

    static func fixDirection(_ bias: Double?, unit: TemperatureUnit) -> FixDirection {
        guard let bias else { return .none }
        let fix = rounded(-degrees(bias, in: unit))
        return fix > 0 ? .up : fix < 0 ? .down : .none
    }

    private static func rounded(_ value: Double) -> Double {
        let tenths = (value * 10).rounded() / 10
        return tenths == 0 ? 0 : tenths
    }

    private static func oneDecimal(_ value: Double) -> String {
        rounded(value).formatted(.number.precision(.fractionLength(1)))
            .replacingOccurrences(of: "-", with: "\u{2212}")
    }

    // MARK: Pickers

    static func variableShort(_ variable: TrackVariable) -> String {
        switch variable {
        case .high: String(localized: "Highs", comment: "Track record picker: daily highs")
        case .low: String(localized: "Lows", comment: "Track record picker: daily lows")
        case .rain: String(localized: "Rain", comment: "Track record picker: precipitation amount")
        }
    }

    static func variableSpoken(_ variable: TrackVariable) -> String {
        switch variable {
        case .high: String(localized: "High temperatures", comment: "VoiceOver: the Highs option")
        case .low: String(localized: "Low temperatures", comment: "VoiceOver: the Lows option")
        case .rain: String(localized: "Rain and snow amount", comment: "VoiceOver: the Rain option (precipitation, snow as water)")
        }
    }

    static func leadShort(_ lead: Int) -> String {
        String(localized: "Day \(lead)", comment: "Lead day, 1 to 14")
    }

    static func leadSpoken(_ lead: Int) -> String {
        String(localized: "\(lead) days ahead", comment: "VoiceOver: track record lead day")
    }

    static let variablePickerTitle = String(localized: "Score", comment: "VoiceOver: track record picker for highs, lows or rain")
    static let leadPickerTitle = String(localized: "Forecast range", comment: "VoiceOver: track record picker for day 1, 7 or 13")
    static let basisPickerTitle = String(localized: "Numbers from", comment: "VoiceOver: track record picker, archived forecasts or our own record")

    static func basisShort(_ basis: TrackBasis) -> String {
        switch basis {
        case .archive: String(localized: "Archived runs", comment: "Track record picker: numbers from each source's archived forecasts")
        case .live: String(localized: "Our record", comment: "Track record picker: numbers from our own saved forecasts")
        }
    }

    // MARK: Step 2

    /// "AVERAGE MISS, DAY 1 HIGHS, °C".
    static func missHead(_ variable: TrackVariable, lead: Int, units: UnitChoice) -> String {
        let what: String
        switch variable {
        case .high: what = String(localized: "Average miss, day \(lead) highs", comment: "Track record chart heading")
        case .low: what = String(localized: "Average miss, day \(lead) lows", comment: "Track record chart heading")
        case .rain: what = String(localized: "Average miss, day \(lead) rain", comment: "Track record chart heading; rain includes snow as water")
        }
        return (what + ", " + unitSymbol(variable, units: units)).uppercased()
    }

    static let weightHead = String(localized: "Weight", comment: "Track record chart column: today's share in the consensus").uppercased()

    static func tooFew(_ days: Int?) -> String {
        String(localized: "Too few days (\(days ?? 0))", comment: "Track record row with too few scored days for an average. Value: days scored.")
    }

    static func daysShort(_ days: Int) -> String {
        days == 1 ? String(localized: "1 day") : String(localized: "\(days) days", comment: "Number of days scored")
    }

    static let notRecorded = String(localized: "Not recorded yet", comment: "Track record: our own consensus is not saved yet, so it has no live score")

    /// VoiceOver for one row.
    static func rowLabel(_ row: TrackRecordFacts.Row, _ variable: TrackVariable, units: UnitChoice,
                         basis: TrackBasis) -> String {
        guard let miss = row.miss else {
            if row.isConsensus && basis == .live { return "\(row.name): \(notRecorded)" }
            return "\(row.name): \(tooFew(row.days))"
        }
        let value = missValue(miss, variable, units: units) + ValueText.nbsp + spokenUnit(variable, units: units)
        var text = String(localized: "\(row.name): average miss \(value) over \(daysShort(row.days ?? 0))",
                          comment: "VoiceOver: track record row. Values: source, miss with unit, days.")
        if basis == .archive && !row.isConsensus {
            text += ". " + (row.weight.map { String(localized: "Weight today \(ValueText.share($0))") }
                            ?? String(localized: "Not in today's blend"))
        }
        return text
    }

    /// Where the archive numbers come from, in words. Always shown under the chart.
    static func archiveSource(_ record: TrackRecord, stationName: String?) -> String {
        guard let w = record.archive?.missWindow else {
            return String(localized: "From each source's archived forecasts, scored against the station. Not our own record.")
        }
        let station = stationName ?? String(localized: "the station")
        var text = String(localized: "From each source's archived forecasts, scored against \(station) for the \(w.days) days \(ValueText.dayMonth(w.from)) to \(ValueText.dayMonth(w.to)). Not our own record.",
                          comment: "Track record source line. Values: station, window length, first and last date.")
        if let through = record.stationThrough, through < w.to {
            text += " " + String(localized: "Station data through \(ValueText.dayMonth(through)).",
                                 comment: "Track record: the last day the station had reported")
        }
        return text
    }

    /// "Each row covers 59 days." when they agree.
    static func usualDaysLine(_ days: Int?) -> String? {
        guard let days else { return nil }
        return String(localized: "Each row covers \(daysShort(days)) unless it says otherwise.",
                      comment: "Track record: the usual number of days behind each average")
    }

    static func weightNote(_ variable: TrackVariable, lead: Int) -> String {
        let what = variableShort(variable).lowercased()
        return String(localized: "Weight is each source's share of today's consensus for \(what), day \(lead). It comes from the miss left after the habit fix (step 3), so a source with a steady habit can miss by more and still count. A dash: not in today's blend.",
                      comment: "Track record note under the chart. Values: highs/lows/rain, lead day.")
    }

    static func liveSource(stationName: String?, window: TrackRecord.Window?) -> String {
        let station = stationName ?? String(localized: "the station")
        let days = window?.days ?? 60
        return String(localized: "From our own saved forecasts, scored against \(station) over the last \(days) days. Our consensus itself is not recorded yet.",
                      comment: "Track record source line for our own record")
    }

    /// Our own record when it is too short: never replaced by archive numbers.
    static func liveTooFew(_ status: TrackRecordFacts.LiveStatus, lead: Int) -> String {
        guard let since = status.since else {
            return String(localized: "Our own record has not started here yet.", comment: "Track record: no live record")
        }
        return String(localized: "Our own record started \(ValueText.dayMonth(since)): \(status.days) of the \(status.minDays) days needed for day \(lead) so far. Too few to score, so none of it is shown yet.",
                      comment: "Track record: live record too short. Values: start date, days so far, days needed, lead day.")
    }

    static let liveHead = String(localized: "Our own record", comment: "Track record: heading over the live record note").uppercased()

    static let notInFile = String(localized: "Each source's track record is not in this forecast file yet.",
                                  comment: "Step 2 when the file has no track record (older file)")

    // MARK: Step 3

    static func habitHead(lead: Int) -> String {
        String(localized: "Day \(lead) habits", comment: "Step 3 heading over the habit list").uppercased()
    }

    /// "Highs run 0.6 °C warm here", "Lows run 1.6 °F cold here", "Highs right on average here".
    static func habitSentence(_ habit: TrackRecordFacts.Habit, _ variable: TrackVariable, unit: TemperatureUnit) -> String {
        guard let bias = habit.bias else {
            return variable == .high
                ? String(localized: "Highs: too few days for a habit fix")
                : String(localized: "Lows: too few days for a habit fix")
        }
        let size = abs(degrees(bias, in: unit))
        let amount = oneDecimal(size) + ValueText.nbsp + (unit == .celsius ? "°C" : "°F")
        let warm = rounded(degrees(bias, in: unit)) > 0
        let cold = rounded(degrees(bias, in: unit)) < 0
        switch (variable, warm, cold) {
        case (.high, true, _): return String(localized: "Highs run \(amount) warm here", comment: "Step 3: a source's highs are too warm on average")
        case (.high, _, true): return String(localized: "Highs run \(amount) cold here", comment: "Step 3: a source's highs are too cold on average")
        case (.high, _, _): return String(localized: "Highs right on average here")
        case (_, true, _): return String(localized: "Lows run \(amount) warm here", comment: "Step 3: a source's lows are too warm on average")
        case (_, _, true): return String(localized: "Lows run \(amount) cold here", comment: "Step 3: a source's lows are too cold on average")
        default: return String(localized: "Lows right on average here")
        }
    }

    /// VoiceOver: "ECMWF: highs run 0.4 degrees Celsius warm here, over 29 days. The fix takes 0.4 off."
    static func habitLabel(_ habit: TrackRecordFacts.Habit, _ variable: TrackVariable, unit: TemperatureUnit) -> String {
        var text = "\(habit.name): \(habitSentence(habit, variable, unit: unit))"
        if let days = habit.days, habit.bias != nil {
            text += ", " + String(localized: "over \(daysShort(days))")
        }
        switch fixDirection(habit.bias, unit: unit) {
        case .up: text += ". " + String(localized: "The fix adds \(fixPill(habit.bias, unit: unit).dropFirst())")
        case .down: text += ". " + String(localized: "The fix takes \(fixPill(habit.bias, unit: unit).dropFirst()) off")
        case .none: break
        }
        return text
    }

    static func habitSource(_ record: TrackRecord) -> String {
        guard let w = record.archive?.biasWindow else {
            return String(localized: "Rain has no habit fix: amounts are weighted as they are.")
        }
        return String(localized: "Averaged over the \(w.days) days \(ValueText.dayMonth(w.from)) to \(ValueText.dayMonth(w.to)), from the same archived forecasts as step 2. Rain has no habit fix: amounts are weighted as they are.",
                      comment: "Step 3 note. Values: window length, first and last date.")
    }

    static let habitsNotInFile = String(localized: "Each source's habit fix is not in this forecast file yet.",
                                        comment: "Step 3 when the file has no track record (older file)")
}
