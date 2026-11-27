# Published JSON (schema version 1)

One file per place: `public/<place>.json` (for example `public/kitimat.json`), written by `backend/scripts/publish.py`. In Stage 2 it is served by GitHub Pages and read by the app. Formal schema: `docs/place-v1.schema.json` (JSON Schema 2020-12); the tests check every published file against it.

## Rules for readers (the app)
- **Ignore unknown fields.** New fields are added without changing `schema_version`. Swift `Codable` ignores unknown keys by default; keep it that way (no strict decoding).
- **Treat every number as optional.** Any forecast value can be `null` (a source missing, no track record yet). Show a dash, never crash.
- **Decode `tier` as a string,** not a closed enum. Unknown values: fall back to the tier the app works out from `certainty`.
- **`schema_version` changes only for a breaking change** (a field removed, renamed, or its type or meaning changed). If that ever happens, version 1 keeps being published at the old path until old app versions are gone, and the new version goes to a new path (`public/v2/<place>.json`). An app that sees a `schema_version` it does not know should show "Update the app" rather than guess.
- **Units are metric.** The app converts (deg F = deg C x 1.8 + 32; in = mm / 25.4).
- **`track_record` is optional.** Older files and places scored before 27 Nov 2026 do not have it. Never fill it from anything else. Its two parts, `archive` and `live`, are different kinds of numbers: show which one a number is, and never put them side by side as if they were the same.
- **`now` is optional.** Only places with an approved station have it. If it is missing, hide every observed value; never fill them from a forecast.
- **Work out staleness yourself as well.** If the backend stops, no new file is written, so `stale` can never turn true. The app should also treat data as stale when `issued_at` or `fresh_data_at` is older than `stale_after_hours`.

## Top level
| Field | Type | Meaning |
|---|---|---|
| `schema_version` | integer | `1`. |
| `place` | object | See below. |
| `issued_at` | UTC time | When this file was written (`YYYY-MM-DDTHH:MM:SSZ`). |
| `issue_date` | date | The ECCC climate day (UTC minus 6 h) the forecast was issued on. Day N = `issue_date` + N. |
| `newest_run_at` | UTC time or null | Start time of the newest model run used. Not for "Updated X hours ago": a run starts hours before its data is available. |
| `fresh_data_at` | UTC time or null | When the backend last pulled any new run. Use it for "Updated X hours ago"; if it is null, use `issued_at`. |
| `stale` | boolean | True when no new run was pulled for more than `stale_after_hours`. The app shows it and lowers Certainty. |
| `stale_after_hours` | number | `6` today. |
| `weights_as_of` | date or null | Issue date of the nightly scores the weights and habit fixes come from. |
| `scores_computed_at` | UTC time or null, optional | When those nightly scores were computed (`scores.json` `computed_at`). Added 27 Nov 2026 without a version change; null or absent for scores from before then. Normally within a day of `issued_at`; older means the last nightly scoring failed or its new scores were rejected (not good enough for days 1 to 7) and the last good scores are still in use. |
| `units` | object | `{"temperature": "degC", "precipitation": "mm", "chance": "percent"}`. |
| `sources` | array | Every source that has weight on any day: `{"id", "label"}`. Colour in the source bar is chosen by `id` in the app. |
| `days` | array | Days 1 to 14 in order. See below. |
| `credits` | array | `{"text", "licence", "url", "licence_url"}`. Show every `text` in About. |
| `now` | object, optional | Latest station observation (see below). Added 25 Nov 2026 without a version change. |
| `track_record` | object, optional | How each source has done against the station, its weight today and its habit fix (see below). Added 27 Nov 2026 without a version change. |
| `backtest_file` | object, optional | Pointer to the place's backtest file (see below): `{"path", "sha256", "bytes"}`. Added 27 Nov 2026 without a version change. |

## `place`
| Field | Type | Meaning |
|---|---|---|
| `id`, `name` | string | From `config/places.json`. |
| `lat`, `lon` | number | Forecast point (the truth station's location). |
| `elevation_m` | number or null | Metres (1 m = 3.28 ft). |
| `timezone` | string or null | IANA name, for local display. |
| `truth_station` | object or null | `{"network", "id", "name"}`: the station each source is scored against (ECCC climate id in Canada). |
| `consensus_only` | boolean | True when the place has no station of its own: weights are borrowed, so its numbers are not checked locally. Show the "Consensus only" label. |

## `days[]`
| Field | Type | Meaning |
|---|---|---|
| `day` | integer | Lead day, 1 to 14. |
| `date` | date | The climate day forecast (local day, UTC minus 6 h boundaries, as ECCC reports it). |
| `high`, `low` | number or null | Consensus high and low, deg C, 1 decimal. |
| `precip_mm` | number or null | Consensus precipitation amount, mm, 1 decimal. |
| `precip_chance` | integer or null | Chance of 1 mm or more, percent. |
| `certainty` | integer or null | Chance the day's high lands within 2 deg C (3.6 deg F) of `high`, percent. Always null when `high` is null (since 27 Nov 2026; the formal schema refuses a file that breaks this). |
| `tier` | string or null | `High` (75+), `Medium` (50 to 74), `Low` (under 50), from the rounded `certainty`. Null when `certainty` is null. |
| `weights` | array | `{"id", "weight"}` for the high, largest first; weights are shares (0 to 1, 3 decimals) and add to about 1. Scale bar lengths by their sum. |
| `source_counts` | object, optional | `{"high", "low", "precip"}`: how many sources (the normal included) went into each value that day. Added 27 Nov 2026 without a version change, for calibrating Certainty by source count later. 0 means no value (`high` null, and so no Certainty). |

Notes:
- Day 1 is the next climate day: the first day the backtest scores (lead 1). Today is not in version 1.
- Weights are for the high only. Sources whose run does not reach a day get no weight that day (for example ICON and UK Met Office stop near day 6, Meteo-France near day 3), so `weights` can change length from day to day.
- `normal` is the 1991 to 2020 climate normal, one more source from day 8 (highs and lows) as set by the horizon test (`docs/ALGORITHM.md`).
- Precipitation weights are not published (version 1 has one source bar per day, for the high).

## `track_record` (optional)
What the Consensus tab shows in step 2 ("We check their homework") and step 3 ("We fix their habits"). Written by `backend/wxc/publish.py` from the nightly `scores.json` (`backend/wxc/score.py`). Temperatures are deg C (a miss or a bias converts as x 1.8 for deg F, with no +32); rain is mm (in = mm / 25.4).

Two kinds of numbers, each labelled by `basis`:
- `archive`: each source's archived forecasts (Open-Meteo Previous Runs for days 1 to 7, Single Runs from 00 UTC for days 8 to 14) scored against the place's truth station by the nightly job. These are the numbers today's weights and habit fixes come from. A rolling backtest on archived data, not our own record.
- `live`: our own saved forecasts (every hourly pull since `since`) and our own published consensus (logged from 27 Nov 2026) scored against the same station. A miss is given only once there are `min_days` days; before that only the count. The record started on 25 Nov 2026, so it is too short to mean anything until about the end of December 2026.

| Field | Type | Meaning |
|---|---|---|
| `leads` | array of integers | Lead days covered: `[1, 7, 13]` today (as the day 1, 7 and 13 bars on the Consensus tab). |
| `scored_on` | date or null | Issue date of the nightly scores (same as `weights_as_of`). |
| `station_through` | date or null | Last day the station had reported when scored (ECCC posts a day or two late). |
| `archive.basis` | string | `archive`. |
| `archive.miss_window` | object | `{"from", "to", "days"}`: the target dates a miss covers (60 days ending the day before `scored_on`). The same window at every lead. |
| `archive.bias_window` | object | The same for the habit fix (30 days). |
| `archive.min_days` | integer | `20`: a 60-day window needs this many days before it gives a miss (the algorithm's own minimum). |
| `archive.consensus[]` | array | Per lead: `{"lead", "high", "low", "rain"}`, each `{"miss", "days"}`: the consensus's own average miss when rebuilt on the same archived forecasts with the same rules. |
| `archive.sources[]` | array | Per source and lead: `{"id", "lead", "high", "low", "rain"}`. A variable is missing when the source has no score for it at that lead. |
| `...high`, `...low` | object | `weight`: share in today's published consensus for that lead and variable (0 to 1, 3 decimals; `high` equals `days[].weights`), null if the source has no forecast in today's blend (its run does not reach that day, it is late, or the normal before it joins). `miss`: average absolute miss of the raw forecast before the habit fix, deg C, null with fewer than `min_days` days. `days`: days behind the miss. `bias`: the habit, the average of forecast minus observed over `bias_window`, deg C: positive runs warm (the habit fix takes it off), negative runs cold (the fix adds it). `bias_days`: days behind it (the fix needs 10). |
| `...rain` | object | `weight`, `miss` (mm) and `days`, as above. Rain has no habit fix. |
| `live.basis` | string | `live`. |
| `live.since` | date or null | Issue date of our first saved forecast. |
| `live.window` | object | Same 60 days as `archive.miss_window`. |
| `live.min_days` | integer | `20`, as for the archive. |
| `live.days[]` | array | `{"lead", "days"}`: how many target days our own record has scored at that lead. Fewer than `min_days`: show "too few days" with the count, never a number from `archive` in its place. |
| `live.consensus` | array or null | Our own published consensus scored like the sources: per lead `{"lead", "high", "low", "rain"}`, each `{"miss", "days"}`, `miss` null under `min_days`. Null until the first nightly scoring after 27 Nov 2026. From `consensus_log.jsonl` (below). |
| `live.sources[]` | array | `{"id", "lead", "high", "low", "rain"}`, each `{"miss", "days"}`; `miss` null under `min_days`. Deterministic sources only; one forecast per source, issue date and target: the last pull of the issue date. |

Notes:
- A miss is the plain average absolute error (the canvas's "average miss"). Weights come from the error left after the habit fix (inverse 60-day squared error), so a source with a steady habit can have a large miss and still a fair weight.
- `normal` appears with a weight from day 8 (highs and lows) and day 10 (rain), as in `days[].weights`; it is scored and has a bias at every lead it is in.
- `scored_on` can be a day behind `issue_date` before the nightly run.

Example (real data, Kitimat, scored on issue date 26 Nov 2026 from the `data` branch; day 1 shortened to two sources):

```json
"track_record": {"leads": [1, 7, 13], "scored_on": "2026-11-26", "station_through": "2026-11-24",
  "archive": {"basis": "archive", "miss_window": {"from": "2026-09-27", "to": "2026-11-25", "days": 60}, "bias_window": {"from": "2026-10-27", "to": "2026-11-25", "days": 30}, "min_days": 20,
    "consensus": [{"lead": 1, "high": {"miss": 0.96, "days": 59}, "low": {"miss": 0.78, "days": 59}, "rain": {"miss": 3.03, "days": 59}}, ...],
    "sources": [
      {"id": "gem_seamless", "lead": 1, "high": {"weight": 0.146, "miss": 1.03, "days": 59, "bias": 0.57, "bias_days": 29}, "low": {"weight": 0.107, "miss": 1.14, "days": 59, "bias": 0.51, "bias_days": 29}, "rain": {"weight": 0.132, "miss": 3.33, "days": 59}},
      {"id": "meteofrance_seamless", "lead": 1, "high": {"weight": 0.093, "miss": 2.83, "days": 59, "bias": 3.49, "bias_days": 29}, "low": {"weight": 0.082, "miss": 4.13, "days": 59, "bias": 4.44, "bias_days": 29}, "rain": {"weight": 0.084, "miss": 5.22, "days": 59}},
      ...]},
  "live": {"basis": "live", "since": "2026-11-25", "window": {"from": "2026-09-27", "to": "2026-11-25", "days": 60}, "min_days": 20,
    "days": [{"lead": 1, "days": 0}, {"lead": 7, "days": 0}, {"lead": 13, "days": 0}], "consensus": null, "sources": []}}
```

### Our own consensus record (not in the place file)
`publish.py` keeps one line per issue date in `data/store/<place>/consensus_log.jsonl` on the `data` branch: the last publish of that issue date (as the sources' live record keeps the last pull), replaced on each hourly run, earlier days kept. About 407 bytes per place per day.

```json
{"issue_date":"2026-11-26","issued_at":"2026-11-27T01:39:10Z","days":[[1,6.7,4.0,10.3,100,91],[2,5.0,1.7,1.3,56,92],...]}
```

Each `days` entry is `[lead, high, low, precip_mm, precip_chance, certainty]`, exactly as published (deg C, mm, percent; null stays null). `precip_mm` is kept as well as the chance so the rain miss can be compared with the backtest's. The nightly `score.py` matches every line to the station (`live_consensus.csv`) and sums it up in `scores.json` `live.consensus` per lead: high, low and rain average miss, the chance of precipitation's Brier score (wet = 1 mm or more), and Certainty said vs came true (high within 2 deg C), each with its days, over the same 60 target days and with the same 20-day minimum. The same measures `backtest.py` reports, so the live record can be set against the backtest.

### The issue ledger (not in the place file)
The consensus log above keeps only the last publish of each issue date, so its lead time drifts with the hour of the last run. The issue ledger records what was published at two fixed times a day, for scoring at a fixed lead time. `publish.py` appends to `data/store/<place>/issue_ledger.jsonl` on the `data` branch (added 27 Nov 2026):

- `morning`: the first publish from 13:00 UTC (05:00 in Kitimat on PST) until 01:00 UTC.
- `evening`: the first publish from 01:00 UTC (17:00 the day before in Kitimat) until 13:00 UTC.
- Both belong to the same issue date (the climate day, UTC minus 6 h). A slot whose runs all failed has no line; a late run fills its slot, and `issued_at` shows how late.
- Append-only: a line is never changed or removed; a slot that already has a line gets no second one.

One line per slot, compact (no spaces). Real values, but this line was made on the development Mac from a copy of the `data` branch on 27 Nov 2026 with the publish time set to 13:10 UTC to show a morning slot; it is not from the live ledger. Shortened (`...`):

```json
{"slot":"morning","slot_start":"2026-11-27T13:00:00Z","issue_date":"2026-11-27","issued_at":"2026-11-27T13:10:00Z","weights_as_of":"2026-11-27","scores_computed_at":"2026-11-27T09:56:36Z","stale":false,"src":["ecmwf_ifs","ecmwf_aifs025_single","gfs_seamless","gem_seamless","icon_seamless","ukmo_seamless","jma_seamless","cma_grapes_global","meteofrance_seamless","normal"],"run":["2026-11-27T06:00:00Z","2026-11-27T06:00:00Z","2026-11-27T06:00:00Z","2026-11-27T06:00:00Z","2026-11-27T06:00:00Z","2026-11-27T00:00:00Z","2026-11-27T00:00:00Z","2026-11-27T00:00:00Z","2026-11-27T06:00:00Z",null],
 "days":[[1,5.3,2.5,3.5,89,95,[102,149,89,144,145,165,68,44,93,null],[120,168,75,109,137,161,75,72,83,null],[130,102,85,130,107,114,134,111,87,null]],...,
         [14,1.7,-2.6,20.8,60,46,[null,350,300,null,null,null,null,null,null,350],[null,350,300,null,null,null,null,null,null,350],[null,null,430,null,null,null,null,null,null,570]]]}
```

- `src`: every source with a saved run, in pool order, then `normal` if it had weight on any day. `run`: each one's newest run start (UTC), null for the normal. A source with a run but no weight on any day was late (its run more than 24 h behind the newest).
- `days`: `[lead, high, low, precip_mm, precip_chance, certainty, high weights, low weights, precip weights]`. Values exactly as published. Weights in thousandths, in `src` order, null where the source had no weight that day.
- `weights_as_of`, `scores_computed_at`, `stale`: as in the place file at that moment.
- Size, Kitimat with 9 models and the normal: 2,832 bytes a line, **5,663 bytes a day** (measured 27 Nov 2026 on that copy), about 2 MB a year.
- Scored nightly by `score.py` exactly like the consensus log, per slot: `live_issues.csv` (one row per line and lead, with `slot` and `slot_start`) and `scores.json` `live.issues.morning` and `live.issues.evening` (same measures, window and 20-day minimum as `live.consensus`).

## The backtest file and `backtest_file` (optional)
The numbers behind the "Tested on real Kitimat weather" card live in their own file on the same site, `backtest/<place>.json` (for example `https://deirdeezy.github.io/weather-consensus/backtest/kitimat.json`), because they change only when the backtest is run again. Formal schema: `docs/backtest-v1.schema.json`. Written by `backend/scripts/backtest.py` to `data/backtest/<place>.json` (committed) and published by `publish.py` compact with sorted keys, so the same results always give the same bytes. Only places with a backtest have it (Kitimat today). Every number is computed by that script; nothing is added by hand.

The place file carries only the pointer:

| Field | Type | Meaning |
|---|---|---|
| `backtest_file.path` | string | `backtest/<place id>.json`, relative to the place file. |
| `backtest_file.sha256` | string | SHA-256 of the file's exact bytes, lowercase hex. A reader downloads the file again only when this differs from its saved copy, and keeps a download only if its hash matches. |
| `backtest_file.bytes` | integer | The file's size. |

Readers: no pointer, no card (older place files, places without a backtest). A missing or unreadable backtest file hides the card and never touches the forecast. Readers that do not know `backtest_file` ignore it. The backtest file's fields:

How it was tested: the consensus is rebuilt day by day on each source's archived forecasts (Open-Meteo Previous Runs), with the same habit fix (30 days), weights (60 days) and guardrails as live, and each day uses only data from before it (`method.past_data_only`). Then every scored day is compared with the station.

| Field | Type | Meaning |
|---|---|---|
| `basis` | string | `backtest`. |
| `station` | object | `{"network", "id", "name"}`: the station scored against. |
| `scored_from`, `scored_to` | date | First and last day scored: 1 Jan to 30 Oct 2026 for Kitimat (10 months, not a full year). |
| `warmup_from` | date or null | Earliest forecast used; days before `scored_from` only fill the rolling windows. |
| `method` | object | `past_data_only` (true), `history`, `habit_days`, `weight_days`. |
| `baseline` | string | The one model alone it is compared with: `ecmwf_ifs`. |
| `leads[]` | array | Days 1 to 7: `{"lead", "high", "low", "rain"}`. `high` and `low`: `consensus`, `baseline` and `equal_weights` (average miss, deg C) and `days` scored. `rain`: `consensus` and `baseline` (average miss, mm), `days`, `brier_chance` (our chance of 1 mm or more) and `brier_climatology` (always saying the period's wet-day share); lower is better. |
| `...sources[]` | array | In `high`, `low` and `rain`: every single source alone against the consensus, `{"id", "miss", "consensus", "days"}`: the source's raw forecast miss and the consensus's miss on the same days (the consensus's scored days where that source has a forecast; fewer where its run stops short of that lead). The consensus wins only when its miss is strictly lower. |

Not in it: "a common free default" (a claim about other apps, not something we test).

## `now` (optional)
The latest observation at the place's approved station (the newest minute or hourly record, value by value), and what the station has seen so far in the current climate day. Written by `backend/wxc/obs.py` from ECCC's real-time SWOB (MSC GeoMet `swob-realtime`). Observations, not a forecast: the name `today` is kept for a later lead 0 forecast, and `days` still starts at day 1.

Station rule: a place has `now` only if `config/places.json` approves a station for it (`obs_station`), the station is run by ECCC itself (no NAV CANADA or partner stations), and it is within 10 km of the place. Today only Kitimat (Kitimat Forest Ave, 2.0 km).

| Field | Type | Meaning |
|---|---|---|
| `observed_at` | UTC time | Time of the newest record any current value came from: `values_from.minute_at` if any value came from the minute record, otherwise `values_from.hourly_at`. Show its age; the app dims values after 3 h and hides them after 12 h. |
| `values_from` | object, optional | Which SWOB record the current values came from (added 26 Nov 2026; absent in older blocks, which are all hourly). `minute_at`: time of the minute record used, or null if none was used. `hourly_at`: time of the newest hourly record (pressure, tendency, `precip_1h_mm` and the so-far values always come from hourly records). `temp`, `dew_point`, `humidity`, `wind`, `gust`: `"minute"` or `"hourly"` each. Readers must accept other values. |
| `fetched_at` | UTC time | When the backend last got a good answer from ECCC. After a refusal the previous block is published again, unchanged. |
| `source` | string | `ECCC SWOB real-time (MSC GeoMet swob-realtime)`. |
| `station` | object | `{"network", "id", "name", "distance_km"}`: ECCC climate id, display name, distance from the place's point (km, 1 decimal; 1 km = 0.62 mi). |
| `temp`, `dew_point` | number or null | deg C, 1 decimal (SWOB `air_temp`, `dwpt_temp`), from the record named in `values_from`. |
| `humidity` | integer or null | Relative humidity, percent (`rel_hum`). |
| `wind_kmh`, `wind_dir_deg` | number, integer or null | 2-minute mean wind at 10 m (1 km/h = 0.62 mph) and the direction it blows from, degrees true, 0 to 359 (`avg_wnd_spd_10m_pst2mts`, `avg_wnd_dir_10m_pst2mts`; the 10-minute mean if those are missing). |
| `gust_kmh` | number or null | Highest wind speed in the last 10 minutes (`max_wnd_spd_10m_pst10mts`). |
| `pressure_kpa` | number or null | Mean sea level pressure, kPa, 2 decimals (`mslp` / 10; 1 kPa = 0.2953 inHg). |
| `pressure_tendency` | string or null | `rising`, `falling` or `steady` over 3 h, from the WMO tendency code (table 0200: 0 to 3 rising, 4 steady, 5 to 8 falling; a net change of 0 is steady). Readers must accept other values. |
| `pressure_change_3h_kpa` | number or null | Net change over 3 h, kPa (`pres_tend_amt_pst3hrs` / 10). |
| `precip_1h_mm` | number or null | Precipitation in the hour ending at `values_from.hourly_at` (`observed_at` in older blocks), mm (`pcpn_amt_pst1hr`). |
| `high_so_far`, `low_so_far` | number or null | Highest and lowest temperature in the hourly records after `so_far_since` (`max_air_temp_pst1hr`, `min_air_temp_pst1hr`), deg C. Null before the first hour is in. |
| `precip_so_far_mm` | number or null | Sum of the hourly amounts after `so_far_since`. Null if any of those hours is missing, as a value or as a whole record (a station gap), because the sum would undercount. |
| `so_far_since` | UTC time | Start of the climate day: 06 UTC, the same day boundary scoring uses. Show it in the phone's own time zone. |
| `so_far_hours` | integer | How many hourly records the so-far values cover (0 to 24). |

Notes:
- Current values (temp, dew point, humidity, wind, gust) come from whichever record is newer, the minute or the hourly one. A minute value is used only if it has a quality flag and the flag is "passed" (100); otherwise the hourly value is used, so a value is not left blank just because the minute record lacks it. Minute records carry no flag on dew point, wind or gust (checked on 200 records, 25 and 26 Nov 2026), so today those come from the hourly record.
- An hourly value whose SWOB quality flag is there and not "passed" (100) is published as null.
- Feels like (wind chill or humidex) is not published: the app works it out from `temp`, `wind_kmh` and `dew_point` with ECCC's formulas.

Example (real data, Kitimat Forest Ave, fetched 26 Nov 2026 01:07 UTC; saved answers in `tests/fixtures/`). Temperature and humidity are from the 01:07 minute record, the rest from the 01:00 hourly record. The 22:00 record is missing (a station gap), so there is no precipitation total. Tendency is null because the station's hourly records since the gap (23:00 to 01:00) carry no tendency:

```json
"now": {"observed_at": "2026-11-26T01:07:00Z", "fetched_at": "2026-11-26T01:07:44Z", "source": "ECCC SWOB real-time (MSC GeoMet swob-realtime)", "station": {"network": "ECCC", "id": "1064324", "name": "Kitimat Forest Ave", "distance_km": 2.0}, "values_from": {"minute_at": "2026-11-26T01:07:00Z", "hourly_at": "2026-11-26T01:00:00Z", "temp": "minute", "dew_point": "hourly", "humidity": "minute", "wind": "hourly", "gust": "hourly"}, "temp": 3.7, "dew_point": 3.7, "humidity": 100, "wind_kmh": 0.3, "wind_dir_deg": 190, "gust_kmh": 2.6, "pressure_kpa": 99.98, "pressure_tendency": null, "pressure_change_3h_kpa": null, "precip_1h_mm": 0.0, "high_so_far": 4.0, "low_so_far": 1.9, "precip_so_far_mm": null, "so_far_since": "2026-11-25T06:00:00Z", "so_far_hours": 18}
```

## Example
Day 1 and day 14 from the first live run, Kitimat (real data, issued 25 Nov 2026 03:42 UTC). Shortened (`...`) and spaced for reading; the published file has no spaces or line breaks.

```json
{
  "schema_version": 1,
  "place": {"id": "kitimat", "name": "Kitimat", "lat": 54.0536, "lon": -128.6336, "elevation_m": 98, "timezone": "America/Vancouver", "truth_station": {"network": "ECCC", "id": "1064324", "name": "Kitimat Forest Ave"}, "consensus_only": false},
  "issued_at": "2026-11-25T03:42:27Z",
  "issue_date": "2026-11-24",
  "newest_run_at": "2026-11-24T18:00:00Z",
  "fresh_data_at": "2026-11-25T03:42:10Z",
  "stale": false,
  "stale_after_hours": 6,
  "weights_as_of": "2026-11-24",
  "units": {"temperature": "degC", "precipitation": "mm", "chance": "percent"},
  "sources": [...],
  "days": [
    {"day": 1, "date": "2026-11-25", "high": 6.3, "low": 2.4, "precip_mm": 21.2, "precip_chance": 100, "certainty": 91, "tier": "High",
      "weights": [
        {"id": "ukmo_seamless", "weight": 0.167},
        {"id": "icon_seamless", "weight": 0.147},
        {"id": "ecmwf_aifs025_single", "weight": 0.146},
        {"id": "gem_seamless", "weight": 0.14},
        {"id": "ecmwf_ifs", "weight": 0.105},
        {"id": "meteofrance_seamless", "weight": 0.093},
        {"id": "gfs_seamless", "weight": 0.09},
        {"id": "jma_seamless", "weight": 0.069},
        {"id": "cma_grapes_global", "weight": 0.044}
      ]},
    ...,
    {"day": 14, "date": "2026-12-08", "high": 2.1, "low": -3.5, "precip_mm": 5.6, "precip_chance": 66, "certainty": 67, "tier": "Medium",
      "weights": [
        {"id": "ecmwf_aifs025_single", "weight": 0.35},
        {"id": "normal", "weight": 0.35},
        {"id": "gfs_seamless", "weight": 0.3}
      ]}
  ],
  "credits": [...]
}
```
