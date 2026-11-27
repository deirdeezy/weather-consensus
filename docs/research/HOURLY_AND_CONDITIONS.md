# Hourly forecasts and conditions: research

Research done 27 Nov 2026, before any hourly or conditions feature is built. Every number comes from scripts run on that day against data pulled that day, unless it is labelled **docs** (quoted from a cited source), **estimate**, or **small sample**. The research scripts were one-off and are not in this repo; the decisions they led to and the collection now running are below. Calls were made from a development machine, not a GitHub runner.

## Owner decisions (27 Nov 2026)
1. **Cloud truth:** GOES-18 Cloud Cover Layers, provisionally. Before conditions ship, validate it across seasons from its archive (May 2023 on), summer especially.
2. **Airport station reports (NAV CANADA):** internal validation only. Never saved to the repo or the `data` branch, never published, until NAV CANADA rights are confirmed.
3. **Window:** hourly to 48 h, 3-hour blocks to 96 h, daily from day 5.
4. **Conditions:** only the checkable ones: clear, partly cloudy, cloudy, rain, snow, mixed. Fog, showers, thunder and freezing rain come later through official ECCC warnings.
5. **Gusts:** hidden until 60 days of saved station gusts and a backtest.
6. **Start collecting now (shadow only):** the station's real-time hourly records, and the extra hourly variables with every model pull. GOES is backfilled later from its archive. Built 27 Nov 2026 (`docs/BUILD_PLAN.md`, Stage 4).

## Answer first
- **Cloud truth: GOES-18 Cloud Cover Layers (ABI-L2-CCLF), read at the Kitimat pixel.** Free, hourly, about 15 minutes late, history from 17 May 2023, one 2.2 MB file an hour. **Small sample (one month):** it agreed with a staffed airport station's hourly cloud reports better than any model analysis (3-class agreement 90%, 94% on good-quality pixels, vs 81% for the ECMWF analysis on the same hours).
- **Conditions truth has to be built.** Nothing reports "rain" or "cloudy" for Kitimat itself. Combined truth: GOES sky + Kitimat Forest Ave 1 h precipitation + station temperature and dew point (snow vs rain) + snow depth from the station records now being saved.
- **The airport station checks the satellite; it is not Kitimat's truth.** It is 46 km away, and NAV CANADA's redistribution rights are unconfirmed.
- **Window: hourly to 48 h, 3-hour blocks to 96 h, daily from day 5.** Hourly temperature holds past 96 h, but rain-this-hour skill falls to near zero after 96 h.
- **Weights per variable and lead block; the habit fix must follow the hour of day.** Cloud weights differ most (GEM and CMA cloud is poor here).
- **Conditions: derive them from blended cloud, precipitation and temperature,** not a vote of the models' weather codes (derived was right more often at every lead, **small sample**).
- **Today: nudge the first hours toward the latest observation** (first-hour temperature miss 0.66 to 0.32 °C), and clamp today's high and low to what was already observed.
- **No Certainty on hourly values.** Certainty stays daily. Hourly shows a chance of precipitation, calibrated and tested first.

---

## 1. Truth sources

### 1a. Kitimat Forest Ave (ECCC climate id 1064324, automatic, 2.0 km from the forecast point)
**ECCC climate-hourly** (https://api.weather.gc.ca/collections/climate-hourly)
- History from 14 Mar 2020. Dec 2023 to Nov 2026: 26,129 of 26,207 hours present.
- Filled: temperature, dew point, humidity, station pressure 100%; 1 h precipitation 99.5% (Feb 2024 17% missing); wind speed 98.7% (Dec 2025 22% missing); wind direction 100% (tens of degrees).
- Never filled: visibility, "Weather" (always "NA"). No gusts, no snow depth, no cloud.
- Precipitation is the hour ending at `UTC_DATE`: correlation with ECMWF hourly precipitation 0.724 at lag 0 vs 0.705 and 0.681 at ±1 h.
- Delay: about a day (records to 27 Nov 06 UTC were there at 22:40 UTC the same day; one check).
- Sheltered: 38.5% of hours calm, 10% at 10 km/h (6 mph) or more, maximum 24 km/h (15 mph) in 3 years.

**SWOB real-time** (https://api.weather.gc.ca/collections/swob-realtime; provider MSC, automatic, per https://dd.meteo.gc.ca/today/observations/doc/swob-xml_station_list.csv)
- Keeps about 30 days (oldest record 29 Oct 2026 when read 27 Nov).
- Hourly records carry: air temperature (3 sensors), dew point, humidity, wet-bulb, station and sea-level pressure, 3 h tendency, wind (2 min, 10 min, 1 h means) and direction, **maximum wind past 10 min and past hour with its time**, gust and peak-wind elements in some hours only, 1 h precipitation (weighing gauge) and **a separate rainfall sensor**, 3/6/24 h precipitation, **snow depth (3 sensors)**, past 1/6/24 h max and min temperature, quality flags.
- No cloud, present weather, visibility or precipitation-type sensor.
- Last 30 days: mean hourly maximum wind 10.5 km/h vs mean wind 3.2 km/h. 30 of 275 wet hours had gauge precipitation and nothing on the rain sensor: possibly snow, **not verified**.
- No gust history before 29 Oct 2026 exists in any hourly source. ECCC climate-daily `SPEED_MAX_GUST` is filled on 18% of days (reported only above a threshold, not confirmed); `SNOW_ON_GROUND` on 24%.
- Usage policy: https://eccc-msc.github.io/open-data/usage-policy/readme_en (meaningful User-Agent, ask only for needed data, contact MSC above 86,400 requests a day).
- Licence: ECCC Data Server End-use Licence (https://eccc-msc.github.io/open-data/licence/readme_en/): use allowed "including for commercial purposes", attribution required, no implied endorsement, third-party rights not covered unless the contributor granted them.

### 1b. Cloud and conditions candidates
| Candidate | History | Delay | Fit for Kitimat | Licence | Effort |
|---|---|---|---|---|---|
| GOES-18 CCL, full disk | 17 May 2023 on (bucket listing) | ~15 min (file made 18:15 for an 18:00 scan) | Pixel at Kitimat, 10 km at nadir, view angle 62° (our calculation) | NOAA open data, attribution requested | Medium |
| Open-Meteo Historical `ecmwf_ifs` | 2017 on | None (docs) | 9 km grid point 4 km away | CC BY 4.0 | Low |
| `ecmwf_ifs_analysis_long_window` | 2024 on | 2 days (measured) | Same grid | CC BY 4.0 | Low |
| ERA5 | 1940 on | 5 days (docs) | 25 km | CC BY 4.0 (via Open-Meteo) | Low |
| Staffed airport station, 46 km north (hourly human sky reports in oktas; ECCC climate-hourly sky terms) | Long | Near real time | 46 km, 217 m elevation | ECCC licence; **NAV CANADA rights unconfirmed** | Low, internal only |
| Automatic airport station, 121 km west | | | Reports no sky condition | | Not useful |

**Open-Meteo Historical API** (docs: https://open-meteo.com/en/docs/historical-weather-api)
- Hourly `cloud_cover`, `_low`, `_mid`, `_high`, `weather_code`, `snowfall`, `rain`; no visibility. The long-window dataset omits precipitation and snowfall (docs; measured 0%). Weather code "is calculated from cloud cover analysis, precipitation and snowfall" (docs).
- `ecmwf_ifs` with no delay is the start of IFS forecasts, and ERA5 is an ECMWF model. Scoring forecasts against either would favour ECMWF. Not a fair truth for weighting.
- Agreement with the staffed airport station's hourly total cloud, at the station's grid point, 1 Nov 2025 to 26 Nov 2026 (about 9,300 hours):

| Dataset | Miss (% points) | Bias | r | 3 classes right | ECCC 4 sky terms right |
|---|---|---|---|---|---|
| ECMWF IFS (no delay) | 14.6 | -6.7 | 0.76 | 77% | 60% |
| IFS long window (2 days) | 14.0 | -6.4 | 0.77 | 77% | 60% |
| ERA5 (5 days) | 12.8 | -3.3 | 0.79 | 80% | 63% |

  - By quarter (IFS), 3 classes right: 89% (Q4 2025), 83% (Q1 2026), 69% (Q2), 69% (Q3), 81% (Q4). Summer is the weak season. Day and night equal (77% each).
  - Classes: clear under 30%, partly 30 to 70%, cloudy over 70%.
  - The ECCC sky terms are Clear (0 tenths), Mainly Clear (1 to 4), Mostly Cloudy (5 to 9), Cloudy (10) (docs: https://climate.weather.gc.ca/glossary_e.html). The station's ECCC sky term and its aviation report agree on the class 76% of the time (the okta-to-tenths mapping is approximate).
- Representativeness: in the IFS analysis itself, Kitimat and the airport station fall in different sky classes 16% of hours (miss 9.2 points).

**GOES-18 ABI L2 Cloud Cover Layers** (bucket `noaa-goes18`, https://registry.opendata.aws/noaa-goes/)
- In the bucket: clear sky mask (ACMF/ACMC/ACMM), **cloud cover layers (CCLF/CCLC/CCLM)**, cloud top height (ACHA).
- CCLF: one file an hour, 2.2 MB, 10 km at nadir. `TCF` total cloud fraction; `CF1` to `CF5` (surface to 5,000 ft, 5,000 to 10,000, 10,000 to 18,000, 18,000 to 24,000, above 24,000 ft); `DQF` good, degraded or bad. The CONUS sectors do not reach Kitimat, so full disk only. Clear sky mask full disk: 6 files an hour, 21 MB each.
- Kitimat view angle 62.2° (our calculation). The clear sky mask is made out to 70° (docs: "out to a sensor zenith angle of 70°").
- Accuracy targets (docs, NOAA Enterprise Cloud Mask ATBD v1.2, 2020, https://www.nesdis.noaa.gov/s3/2025-12/ATBD_Enterprise_Cloud_Mask_v1.2_2020_10_01.pdf): 87% globally; snow-covered land 88% by day, 85% at night; snow-free land 90% and 88%.
- Layers (docs, CCL ATBD v1.0, 2021, https://www.nesdis.noaa.gov/s3/2025-12/ATBD_Enterprise_Cloud_Cover_Layers_v1.0_2021-02.pdf): "60% Correct Classification" per layer. Single-layer, top-down view, so low cloud under higher cloud is missed. The total is the useful part.
- **Small sample**, 27 Oct to 25 Nov 2026, 3-hourly (240 times):
  - Quality: good 76% at Kitimat (bad 22%), 75% at the airport station; about the same day and night.
  - Agreement with the airport station's reports:

| Source | All pixels: miss / 3 classes right | Good pixels only (n 181) |
|---|---|---|
| GOES CCL | 8.2 points / 90% | 5.5 / 94% |
| ECMWF IFS analysis | 12.3 / 81% | 9.1 / 87% |
| ERA5 | 10.9 / 83% | 8.8 / 88% |

  - One mostly overcast late-autumn month, which flatters every source. It needs a full year, summer included (owner decision 1).
- Cost at $0 (estimate): 24 files a day = 53 MB of download, one pixel read with `h5py`. A month of 3-hourly files took 629 MB.
- Licence (docs): "open to the public and can be used as desired"; "NOAA requests attribution"; no implied endorsement.
- Open-Meteo Satellite Radiation API: GOES-19 since Apr 2025, radiation only, no cloud cover (docs: https://open-meteo.com/en/docs/satellite-radiation-api).

**Precipitation**
- The Kitimat station is the truth. The IFS "analysis" at Kitimat calls 40% of hours wet vs 23% at the station (hit 94%, false alarm 45%): model output, not observation.
- The airport station's precipitation reports match Kitimat's wet or dry hour 83% of the time. Not a substitute.

**Snow vs rain at Kitimat**
- Nov 2025 to Nov 2026: 2,206 wet hours (0.2 mm or more); 362 at 0.5 °C (33 °F) or below, 318 between 0.5 and 2.5 °C.
- Recipe: wet-bulb from station temperature and dew point (both 100% filled since 2020), confirmed going forward by snow-depth rise and the rain-sensor gap in the saved records.

**Not checkable at Kitimat:** fog, drizzle vs rain, showers, thunder, freezing rain. Humidity 100% is not fog.

### Recommended combined truth, per place, per hour
1. Sky: GOES CCL total cloud at the place pixel, good quality only; missing otherwise (no model fill).
2. Wet: station 1 h precipitation of 0.2 mm or more; intensity from the amount.
3. Phase: snow at a wet-bulb of 0.5 °C or below, rain at 2.0 °C or above, mixed between (estimate; tune on saved snow-depth records).
4. Class: rain, snow or mixed when wet; otherwise clear (under 30%), partly (30 to 70%), cloudy (over 70%).
5. Internal check only: the airport station's reports against its GOES pixel, kept outside the repo.

---

## 2. Forecast side (Open-Meteo)

### Variables by model
Single Runs, 130 runs (00 UTC, 2 Apr to 21 Nov 2026, leads 0 to 143 h, Kitimat).
| Model | Temp, precip, wind, direction, cloud, code, snowfall | Gusts | Visibility (docs) | Last lead with data |
|---|---|---|---|---|
| ECMWF IFS | yes | yes (docs: preceding 3 h max) | IFS HRES only | 143+ |
| ECMWF AIFS | yes | **no** | no | 143+ |
| NOAA GFS | yes | yes | listed; by model unconfirmed | 143+ |
| ECCC GEM | yes (cloud layers from humidity, docs) | yes | no | 143+ |
| DWD ICON | yes | yes | ends with DWD's 30 Nov 2026 feed change (docs) | 143+ |
| UK Met Office | yes | yes | yes | 143+ |
| JMA | yes (no fog or thunder codes, docs) | **no** | no | 143+ |
| CMA | yes | yes | derived | 122 |
| Météo-France | yes (no native weather code, docs) | yes | no | 102 |

- Native steps (docs and Open-Meteo metadata `temporal_resolution_seconds`):
  - IFS HRES: hourly to 90 h, 3-hourly to 144 h, then 6-hourly. AIFS: 6-hourly.
  - GFS: hourly to 120 h, then 3-hourly.
  - GEM: HRDPS hourly to 48 h, RDPS hourly to about 84 h, GDPS 3-hourly (docs; metadata says 3,600 s, a conflict).
  - ICON: hourly to 78 h, then 3-hourly. UKMO: hourly to 54 h, then 3-hourly to 144 h.
  - JMA GSM: 6-hourly. CMA: 3-hourly. Météo-France: hourly to about 2 to 3 days.
  - Open-Meteo interpolates to hourly (docs); the method per variable is not documented.
- Model pages (docs): https://open-meteo.com/en/docs/ecmwf-api, .../gfs-api, .../gem-api, .../dwd-api, .../ukmo-api, .../jma-api, .../cma-api, .../meteofrance-api. Each model's weather code is made differently, so a vote mixes unlike things. Snowfall is cm of snow; water = cm / 0.7.

### History for a backtest
- **Single Runs** (docs: https://open-meteo.com/en/docs/historical-forecast-api, "all other models from 2nd of April 2026"): all the variables above. JMA needs `jma_gsm`: `jma_seamless` single runs fail before mid-May 2026 ("jma_msm" not available).
- **Previous Runs** (https://open-meteo.com/en/docs/previous-runs-api), day 1 at Kitimat, measured from 1 Jan 2024:
  - GEM, GFS, ICON, CMA, Météo-France: from 19 Jan 2024. GFS weather code and snowfall from 6 Dec 2024. Météo-France gusts and wind from 7 Aug 2026.
  - JMA: from 1 Jan 2024, no gusts. UK Met Office: from Aug 2024. AIFS: from 18 Feb 2025, no gusts, code or snowfall.
  - **ECMWF IFS: temperature, code and snowfall only from 1 Oct 2025; cloud and wind from 2 Jan 2025; no gusts.** This differs from the Jan 2024 pilot (`docs/ALGORITHM.md`); open item in `docs/BUILD_PLAN.md`.
  - No model has `cloud_cover_low/mid/high` in Previous Runs; visibility for UK Met Office only.

### Call cost
- Measured `X-RateLimit-Cost`, all consistent with cost = variables / 10 x days / 14, minimum 1 (rule: https://open-meteo.com/en/pricing):
  - Single Run, 10 variables, 6 days: 1.0.
  - Historical, 8 variables, 391 days: 22.3.
  - Previous Runs, 6 variables, 1,060 days: 45.4.
  - Live forecast, 12 variables over 145 h (`start_hour`, `end_hour`): 1.2; 11 variables: 1.1; 14 variables over 16 days: 1.6.
- **Concurrency limit** (measured, not in the docs read): HTTP 429 "Too many concurrent requests" with about 10 calls in flight from one address. Counted calls are now paced (`backend/wxc/openmeteo.py`).

---

## 3. Hourly skill at Kitimat (measured)
- Method: Single Runs 00 UTC, 9 models; truth ECCC climate-hourly (gusts: SWOB, 30 days).
- Blends use past data only: habit fix = 30-day bias per lead block; weights = inverse 60-day squared error after the fix, 2% floor, 35% cap, at least 20 matches.
- Scored on runs from 1 Jun to 21 Nov 2026 (summer and autumn only).
- Lead 0 to 6 h is optimistic: a 00 UTC run is available about 5 to 7 h later.

### Temperature, average miss °C (x 1.8 for °F)
| Lead (h) | IFS | UKMO | AIFS | GEM | Equal | Habit-fixed equal | Weighted | n |
|---|---|---|---|---|---|---|---|---|
| 0 to 6 | 0.90 | 0.95 | 1.20 | 1.00 | 0.90 | 0.73 | **0.68** | 600 |
| 6 to 12 | 0.98 | 0.87 | 0.99 | 1.36 | 0.84 | 0.74 | **0.71** | 600 |
| 12 to 24 | 1.24 | 1.15 | 1.20 | 1.61 | 1.25 | 1.04 | **0.99** | 1,195 |
| 24 to 36 | 1.06 | 1.12 | 1.24 | 1.13 | 0.94 | 0.85 | **0.82** | 1,200 |
| 36 to 48 | 1.25 | 1.24 | 1.28 | 1.49 | 1.26 | 1.06 | **1.00** | 1,192 |
| 48 to 72 | 1.28 | 1.28 | 1.32 | 1.22 | 1.14 | 1.06 | **1.00** | 2,395 |
| 72 to 96 | 1.32 | 1.46 | 1.31 | 1.38 | 1.23 | 1.11 | **1.06** | 2,392 |
| 96 to 120 | 1.54 | 1.55 | 1.44 | 1.67 | 1.27 | 1.22 | **1.18** | 2,394 |
| 120 to 144 | 1.66 | 1.77 | 1.56 | 1.75 | 1.29 | 1.27 | **1.25** | 2,391 |

- The weighted blend beats every single model at every lead. The 12 to 24 h bump is the afternoon (04:00 to 16:00 local for a 00 UTC run), not lead.
- Daily-style weights (one set per 24 h lead day) cost 0.00 to 0.05 °C.
- **The habit fix must follow the hour of day.** In a season check (Previous Runs, GEM, GFS, ICON, JMA, CMA, equal blend), one 30-day all-hours fix made hourly temperature worse: winter day 1 from 1.49 to 1.62 °C, summer from 1.22 to 1.25.
- Winter (Dec 2024 to Mar 2025) vs summer (Jun to Sep 2025), equal blend, day 1: 1.49 vs 1.22 °C.

### Wind speed, average miss km/h (1 km/h = 0.62 mph)
| Lead (h) | Best single | Equal | Habit-fixed equal | Weighted |
|---|---|---|---|---|
| 0 to 6 | 2.81 (ICON) | 2.96 | 2.30 | **2.28** |
| 24 to 36 | 2.79 (IFS, AIFS) | 3.14 | 2.24 | **2.20** |
| 72 to 96 | 2.79 (GEM, AIFS) | 2.96 | 2.39 | **2.36** |
| 120 to 144 | 2.67 (GEM) | 3.03 | 2.56 | **2.55** |
- Most of the gain is the habit fix: the station is sheltered, so 10 m model wind needs heavy correction.

### Gusts (SWOB, 29 Oct to 26 Nov 2026, raw models, small sample)
- Average miss 4 to 7 km/h for GFS, GEM, ICON, UKMO; 9 to 13 for IFS and Météo-France (bias +6 to +12); CMA 9 to 18. AIFS and JMA have none.
- Too little truth for weights: gusts stay hidden (owner decision 5); the station archive now running supplies 60 days by about late January 2027.

### Wind direction (hours with 5 km/h or more: 43% of hours), average angle miss
- Single models 24° to 54°; **vector blend (average of u and v) 23° to 30°, best or tied at every lead.** Below 5 km/h show "Calm" or "Light", not a direction.

### Precipitation, 0.2 mm or more
Blend chance = share of models wet. Brier skill vs climatology: 1 = perfect, 0 = no better.
| Lead (h) | 1 h | 3 h blocks | 6 h blocks |
|---|---|---|---|
| 0 to 6 | 0.48 | 0.27 | |
| 6 to 12 | 0.31 | 0.46 | 0.46 |
| 12 to 24 | 0.30 | 0.51 | 0.66 |
| 24 to 36 | 0.45 | 0.48 | 0.48 |
| 36 to 48 | 0.33 | 0.49 | 0.61 |
| 48 to 72 | 0.27 | 0.37 | 0.49 |
| 72 to 96 | 0.25 | 0.35 | 0.46 |
| 96 to 120 | 0.01 | 0.10 | 0.25 |
| 120 to 144 | 0.13 | 0.22 | 0.34 |
- "Rain this hour" (blend chance 50% or more): right 85 to 89% of hours to 48 h, 83 to 85% to 96 h, 77% after. Hit rate 86 to 97% to 48 h, but false alarm 38 to 45%: the models over-call wet hours.
- Winter day 1 (Previous Runs, 5 models): hourly skill 0.43, 3 h 0.47. Summer days 2 and 3: hourly skill below zero. Summer showers are where hourly fails.
- Blocks with n = 100 to 200 are noisy.

### Cloud vs GOES at Kitimat (27 Oct to 21 Nov runs, 3-hourly, good pixels, small sample)
- Miss 4 to 16 points for GFS, UKMO, AIFS, ICON, IFS, Météo-France; **GEM 16 to 58 and CMA 16 to 60**; JMA 17 to 31. The equal blend (10 to 20) is dragged down by them, so per-variable weights are needed.

### Conditions (same small sample, 183 truth times, 93% cloudy or rain)
| Lead (h) | Derived from blend: right | Weather-code vote: right | Wet or dry right |
|---|---|---|---|
| 0 to 23 | 58% | 48% | 73% |
| 24 to 47 | 63% | 56% | 77% |
| 48 to 71 | 59% | 53% | 74% |
| 72 to 95 | 52% | 47% | 64% |
| 96 to 143 | 48% | 46% | 57% |
- Persistence (same class as 24 h earlier): 45%. Main error: truth "cloudy" forecast as "rain" (272 of 520 cloudy times). Test a habit-fixed, weighted precipitation amount and a tuned wet threshold first.

### Today: nudge toward the observation (issue at 06 UTC, weighted blend)
| Hours after issue | No nudge | Offset fading over 6 h |
|---|---|---|
| 1 | 0.66 | **0.32** |
| 2 to 3 | 0.69 | **0.49** |
| 4 to 6 | 0.83 | **0.75** |
| 7 to 12 | 1.02 | 0.99 |
| 13 to 48 | 0.89 to 0.95 | same |
- The 6 h fade was picked in-sample; confirm on new data.

### How many hours
- Hourly temperature stays useful to 144 h (1.0 to 1.25 °C), but the rain signal does not: hourly skill 0.3 to 0.45 to 48 h, 0.25 at 48 to 96 h, near 0 after.
- Hence hourly for 48 h, 3-hour blocks from 48 to 96 h, daily from day 5 (owner decision 3).

---

## 4. Design
- **Weights**: per variable and lead block (0-6, 6-12, 12-24, 24-48, 48-72, 72-96 h). Habit fix per lead block and hour of day. Same 2% floor and 35% cap, at least 20 matches. Reusing daily weights is fine for temperature, wrong for cloud and gusts.
- **Wind**: speed blended like temperature with a strong habit fix; gusts their own weights and fix (after 60 days); direction a speed-weighted vector average, nothing below 5 km/h.
- **Conditions**: derived from blended cloud, precipitation amount, wet-bulb and snowfall; verified against the combined truth. Only clear, partly cloudy, cloudy, rain, snow and mixed are shown (owner decision 4).
- **Today (lead 0)**: high = max(observed so far, habit-fixed forecast for the rest of the climate day); low the same; rain so far plus the rest. Nudge the first hours. A lead-0 Certainty would need its own calibration.
- **Certainty**: none hourly. Hourly chance of precipitation calibrated per block (reliability table) before it is shown.
- **Living sky and icons**: now = observed (station last hour + latest GOES cloud); later hours = forecast conditions. Map:
  - clear → `clear`; partly → `clear` with clouds, or a new `partly` case; cloudy → `cloudy`.
  - rain → `rain`; snow and mixed → `snow`.
  - `storm` only for heavy rain with strong gusts (thresholds to test), never thunder; `fog` not driven.
- **Schema** (additive, version 1 kept): `today`, `hourly` (48 entries), `blocks` (3 h, 48 to 96 h), daily condition, wind and gust max, snow, a `conditions_verified` list. Place file about 13.5 KB → about 22 KB (estimate).
- **Calls** (estimate): one 1.1-cost extra call per deterministic pull (built), plus hourly variables in the nightly Single Runs later. Score hourly variables from our own saved runs, not by re-downloading 200 days of Previous Runs each night (about 514 weighted calls a night).

## 5. Build plan
Backend first; nothing reaches the app until the backtest and a 2-week shadow run pass.
1. **Shadow collection** (built 27 Nov 2026): station hourly records and extra hourly variables, saved to the `data` branch; nothing published.
2. **GOES backfill and nightly point series** (later): CCLF at each place pixel from May 2023, 3-hourly for the backtest, hourly going forward; keep only the point series.
   - Test the pixel math against a saved CCLF file.
   - Validate across seasons against the airport station, kept outside the repo.
3. **Single Runs with the new variables** from 2 Apr 2026 (JMA via `jma_gsm`) for the backtest.
4. **`wxc/hourly.py` and `backend/scripts/hourly_backtest.py`**: per-variable, per-lead-block blend, habit fix by hour of day, vector wind, calibrated chance of precipitation.
   - Report before and after numbers vs equal and the best single model.
5. **`wxc/conditions.py`**: derived classes against the combined truth.
   - Tune on the first half of the period, score on the second; compare with persistence and the vote.
6. **Today**: observed clamp and nudge, backtested at every issue hour.
7. **Publish**: additive schema, formal schema, old-app fixture still decodes, size budget.
8. **Shadow run of 2 weeks**, then the app: hourly strip, 3-hour blocks, condition icons, today card, sky from observed now and forecast conditions.

**Backtest before anything ships:**
- Hourly blends by lead block, summer and winter.
- Habit fix by hour of day with every run time (00, 06, 12, 18 UTC) and real delays.
- Rain-chance calibration.
- Gusts (after 60 days of saved records).
- Cloud weights against GOES over at least 6 months.
- GOES against the airport station over a full year.
- Conditions against persistence and the vote.
- Today's clamp and nudge.

## Sources (read 27 Nov 2026)
- ECCC: https://api.weather.gc.ca/collections/climate-hourly ; https://api.weather.gc.ca/collections/swob-realtime ; https://dd.meteo.gc.ca/today/observations/doc/swob-xml_station_list.csv ; https://climate.weather.gc.ca/glossary_e.html ; https://eccc-msc.github.io/open-data/licence/readme_en/ ; https://eccc-msc.github.io/open-data/usage-policy/readme_en
- Open-Meteo: https://open-meteo.com/en/docs ; https://open-meteo.com/en/docs/historical-weather-api ; https://open-meteo.com/en/docs/historical-forecast-api ; https://open-meteo.com/en/docs/previous-runs-api ; https://open-meteo.com/en/docs/satellite-radiation-api ; https://open-meteo.com/en/pricing ; https://open-meteo.com/en/terms ; https://open-meteo.com/en/licence ; model pages listed in section 2
- NOAA GOES: https://registry.opendata.aws/noaa-goes/ ; https://github.com/NOAA-Big-Data-Program/nodd-data-docs/tree/main/GOES ; the two ATBDs linked in section 1b
- Airport station reports (internal validation only): Iowa Environmental Mesonet terms https://mesonet.agron.iastate.edu/disclaimer.php ; NOAA Aviation Weather Center data API https://aviationweather.gov/data/api/ (30 days kept). NAV CANADA's own reuse terms were not found.
