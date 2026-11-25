# Published JSON (schema version 1)

One file per place: `public/<place>.json` (for example `public/kitimat.json`), written by `backend/scripts/publish.py`. In Stage 2 it is served by GitHub Pages and read by the app. Formal schema: `docs/place-v1.schema.json` (JSON Schema 2020-12); the tests check every published file against it.

## Rules for readers (the app)
- **Ignore unknown fields.** New fields are added without changing `schema_version`. Swift `Codable` ignores unknown keys by default; keep it that way (no strict decoding).
- **Treat every number as optional.** Any forecast value can be `null` (a source missing, no track record yet). Show a dash, never crash.
- **Decode `tier` as a string,** not a closed enum. Unknown values: fall back to the tier the app works out from `certainty`.
- **`schema_version` changes only for a breaking change** (a field removed, renamed, or its type or meaning changed). If that ever happens, version 1 keeps being published at the old path until old app versions are gone, and the new version goes to a new path (`public/v2/<place>.json`). An app that sees a `schema_version` it does not know should show "Update the app" rather than guess.
- **Units are metric.** The app converts (deg F = deg C x 1.8 + 32; in = mm / 25.4).
- **Work out staleness yourself as well.** If the backend stops, no new file is written, so `stale` can never turn true. The app should also treat data as stale when `issued_at` or `fresh_data_at` is older than `stale_after_hours`.

## Top level
| Field | Type | Meaning |
|---|---|---|
| `schema_version` | integer | `1`. |
| `place` | object | See below. |
| `issued_at` | UTC time | When this file was written (`YYYY-MM-DDTHH:MM:SSZ`). |
| `issue_date` | date | The ECCC climate day (UTC minus 6 h) the forecast was issued on. Day N = `issue_date` + N. |
| `newest_run_at` | UTC time or null | Start time of the newest model run used. Use it for "Updated X hours ago". |
| `fresh_data_at` | UTC time or null | When the backend last pulled any new run. |
| `stale` | boolean | True when no new run was pulled for more than `stale_after_hours`. The app shows it and lowers Certainty. |
| `stale_after_hours` | number | `6` today. |
| `weights_as_of` | date or null | Issue date of the nightly scores the weights and habit fixes come from. |
| `units` | object | `{"temperature": "degC", "precipitation": "mm", "chance": "percent"}`. |
| `sources` | array | Every source that has weight on any day: `{"id", "label"}`. Colour in the source bar is chosen by `id` in the app. |
| `days` | array | Days 1 to 14 in order. See below. |
| `credits` | array | `{"text", "licence", "url", "licence_url"}`. Show every `text` in About. |

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
