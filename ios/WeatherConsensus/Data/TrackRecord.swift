import Foundation

/// `track_record` in the place file (docs/JSON_SCHEMA.md): how each source has done against the station,
/// its weight today and its habit fix, at a few lead days. Optional: older files do not have it, and a block
/// the app cannot read is dropped without touching the forecast (`PlaceForecast.init(from:)`).
///
/// Two kinds of numbers, never mixed:
/// - `archive`: each source's archived forecasts scored nightly against the station. The weights and habit
///   fixes come from these. A rolling backtest on archived data, not our own record.
/// - `live`: our own saved forecasts against the station. Too few days at first; then only counts.
/// Units as published: deg C and mm. `TrackRecordText` converts.
nonisolated struct TrackRecord: Codable, Equatable, Sendable {
    let leads: [Int]
    let scoredOn: LocalDate?
    let stationThrough: LocalDate?
    let archive: Archive?
    let live: Live?

    enum CodingKeys: String, CodingKey {
        case leads
        case scoredOn = "scored_on"
        case stationThrough = "station_through"
        case archive, live
    }

    /// Target dates a number covers.
    nonisolated struct Window: Codable, Equatable, Sendable {
        let from: LocalDate
        let to: LocalDate
        let days: Int
    }

    /// An average miss and the days behind it. `miss` is null with too few days.
    nonisolated struct Miss: Codable, Equatable, Sendable {
        let miss: Double?
        let days: Int?
    }

    /// One source at one lead for one variable (archive).
    nonisolated struct Scored: Codable, Equatable, Sendable {
        /// Share in today's published consensus, 0 to 1; nil when the source is not in today's blend.
        let weight: Double?
        /// Average absolute miss before the habit fix, deg C or mm.
        let miss: Double?
        let days: Int?
        /// Average of forecast minus observed, deg C: positive runs warm. Temperatures only.
        let bias: Double?
        let biasDays: Int?

        enum CodingKeys: String, CodingKey {
            case weight, miss, days, bias
            case biasDays = "bias_days"
        }

        init(weight: Double?, miss: Double?, days: Int?, bias: Double? = nil, biasDays: Int? = nil) {
            self.weight = weight
            self.miss = miss
            self.days = days
            self.bias = bias
            self.biasDays = biasDays
        }
    }

    nonisolated struct ConsensusMiss: Codable, Equatable, Sendable {
        let lead: Int
        let high: Miss?
        let low: Miss?
        let rain: Miss?

        func miss(_ variable: TrackVariable) -> Miss? {
            switch variable {
            case .high: high
            case .low: low
            case .rain: rain
            }
        }
    }

    nonisolated struct SourceScore: Codable, Equatable, Sendable {
        let id: String
        let lead: Int
        let high: Scored?
        let low: Scored?
        let rain: Scored?

        func scored(_ variable: TrackVariable) -> Scored? {
            switch variable {
            case .high: high
            case .low: low
            case .rain: rain
            }
        }
    }

    nonisolated struct Archive: Codable, Equatable, Sendable {
        let basis: String
        let missWindow: Window?
        let biasWindow: Window?
        let minDays: Int
        let consensus: [ConsensusMiss]
        let sources: [SourceScore]

        enum CodingKeys: String, CodingKey {
            case basis
            case missWindow = "miss_window"
            case biasWindow = "bias_window"
            case minDays = "min_days"
            case consensus, sources
        }
    }

    nonisolated struct LiveDays: Codable, Equatable, Sendable {
        let lead: Int
        let days: Int
    }

    nonisolated struct LiveScore: Codable, Equatable, Sendable {
        let id: String
        let lead: Int
        let high: Miss?
        let low: Miss?
        let rain: Miss?

        func miss(_ variable: TrackVariable) -> Miss? {
            switch variable {
            case .high: high
            case .low: low
            case .rain: rain
            }
        }
    }

    /// Our own record: each source's saved forecasts and, once scored, our own published consensus
    /// (`consensus`, null before the first nightly scoring of the consensus log).
    nonisolated struct Live: Codable, Equatable, Sendable {
        let basis: String
        let since: LocalDate?
        let window: Window?
        let minDays: Int
        let days: [LiveDays]
        let consensus: [ConsensusMiss]?
        let sources: [LiveScore]

        enum CodingKeys: String, CodingKey {
            case basis, since, window
            case minDays = "min_days"
            case days, consensus, sources
        }
    }
}

/// The three variables the track record covers.
nonisolated enum TrackVariable: String, CaseIterable, Sendable {
    case high, low, rain

    var isTemperature: Bool { self != .rain }
}

/// Which kind of numbers a chart shows. Never both at once.
nonisolated enum TrackBasis: String, CaseIterable, Sendable {
    case archive, live
}

/// `backtest` in the place file (docs/JSON_SCHEMA.md): the consensus and one model alone rebuilt day by day
/// on archived forecasts, each day using only data from before it, scored against the station. Written by
/// `backend/scripts/backtest.py`; every number is from that script. Optional; dropped if unreadable.
nonisolated struct Backtest: Codable, Equatable, Sendable {
    let basis: String
    let station: PlaceForecast.TruthStation?
    let scoredFrom: LocalDate
    let scoredTo: LocalDate
    let warmupFrom: LocalDate?
    let method: Method?
    /// Source id of the one model alone it is compared with (`ecmwf_ifs`).
    let baseline: String
    let leads: [Lead]

    enum CodingKeys: String, CodingKey {
        case basis, station, method, baseline, leads
        case scoredFrom = "scored_from"
        case scoredTo = "scored_to"
        case warmupFrom = "warmup_from"
    }

    nonisolated struct Method: Codable, Equatable, Sendable {
        let pastDataOnly: Bool
        enum CodingKeys: String, CodingKey { case pastDataOnly = "past_data_only" }
    }

    /// Average miss, deg C or mm, and days scored; `sources`: every single source against the consensus.
    nonisolated struct Tested: Codable, Equatable, Sendable {
        let consensus: Double?
        let baseline: Double?
        let days: Int
        let sources: [Versus]?

        init(consensus: Double?, baseline: Double?, days: Int, sources: [Versus]? = nil) {
            self.consensus = consensus
            self.baseline = baseline
            self.days = days
            self.sources = sources
        }
    }

    /// One single source alone against the consensus, on the same days.
    nonisolated struct Versus: Codable, Equatable, Sendable {
        let id: String
        let miss: Double?
        let consensus: Double?
        let days: Int

        /// Only a strictly lower consensus miss counts; a tie or a missing number is not a win.
        var consensusCloser: Bool {
            guard let miss, let consensus else { return false }
            return consensus < miss
        }
    }

    nonisolated struct Lead: Codable, Equatable, Sendable {
        let lead: Int
        let high: Tested?
        let low: Tested?
        let rain: Tested?
    }
}
