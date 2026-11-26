# Published JSON (schema version 1)

One file per place: `public/<place>.json` (for example `public/kitimat.json`), written by `backend/scripts/publish.py`. In Stage 2 it is served by GitHub Pages and read by the app. Formal schema: `docs/place-v1.schema.json` (JSON Schema 2020-12); the tests check every published file against it.

## Rules for readers (the app)
- **Ignore unknown fields.** New fields are added without changing `schema_version`. Swift `Codable` ignores unknown keys by default; keep it that way (no strict decoding).
- **Treat every number as optional.** Any forecast value can be `null` (a source missing, no track record yet). Show a dash, never crash.
- **Decode `tier` as a string,** not a closed enum. Unknown values: fall back to the tier the app works out from `certainty`.
- **`schema_version` changes only for a breaking change** (a field removed, renamed, or its type or meaning changed). If that ever happens, version 1 keeps being published at the old path until old app versions are gone, and the new version goes to a new path (`public/v2/<place>.json`). An app that sees a `schema_version` it does not know should show "Update the app" rather than guess.
- **Units are metric.** The app converts (deg F = deg C x 1.8 + 32; in = mm / 25.4).
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
| `units` | object | `{"temperature": "degC", "precipitation": "mm", "chance": "percent"}`. |
| `sources` | array | Every source that has weight on any day: `{"id", "label"}`. Colour in the source bar is chosen by `id` in the app. |
| `days` | array | Days 1 to 14 in order. See below. |
| `credits` | array | `{"text", "licence", "url", "licence_url"}`. Show every `text` in About. |
| `now` | object, optional | Latest station observation (see below). Added 25 Nov 2026 without a version change. |

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
| `certainty` | integer or null | Chance the day's high lands within 2 deg C (3.6 deg F) of `high`, percent. |
| `tier` | string or null | `High` (75+), `Medium` (50 to 74), `Low` (under 50), from the rounded `certainty`. |
| `weights` | array | `{"id", "weight"}` for the high, largest first; weights are shares (0 to 1, 3 decimals) and add to about 1. Scale bar lengths by their sum. |

Notes:
- Day 1 is the next climate day: the first day the backtest scores (lead 1). Today is not in version 1.
- Weights are for the high only. Sources whose run does not reach a day get no weight that day (for example ICON and UK Met Office stop near day 6, Meteo-France near day 3), so `weights` can change length from day to day.
- `normal` is the 1991 to 2020 climate normal, one more source from day 8 (highs and lows) as set by the horizon test (`docs/ALGORITHM.md`).
- Precipitation weights are not published (version 1 has one source bar per day, for the high).

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
