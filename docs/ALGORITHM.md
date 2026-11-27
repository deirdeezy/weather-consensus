# Algorithm

Per place, per lead day (1 to 14), per variable. Evidence labels: **backtest** = our own test on Kitimat history in this repo (one station; strong for Kitimat, unproven elsewhere until each place is tested).

## Steps
1. **Pull** the newest run of every source: 9 deterministic models and 3 ensembles (ECMWF ENS, NOAA GEFS, ECCC GEPS). Ensembles are stored and scored but get no weight yet (step 7).
2. **Daily values**: hourly to daily on the ECCC climate day (UTC minus 6 h; a day needs 22 of 24 hours). `wxc/daily.py`
3. **Habit fix**: subtract each source's average error over the last 30 days. Only days already verified at issue time count (window ends lead + 1 days before the target).
4. **Weights**: inverse of each source's mean squared error over the last 60 days, after the habit fix. Normalise to 100%. Guardrails: floor 2%, cap 35%. A late source's share is split among the rest. `wxc/consensus.py`
5. **Consensus** = weighted sum of habit-fixed forecasts.
6. **Precipitation**: amount weighted by inverse 60-day mean absolute error (no habit fix). Chance of precipitation = share of sources forecasting 1 mm or more.
7. **Days 8 to 14**: the deterministic models' archived 16-day runs (Open-Meteo Single Runs, 00 UTC, from 2 Apr 2026) plus the 1991 to 2020 normal (Kitimat Townsite daily records, +/- 7 calendar days) as one more source with its own habit fix and weight. Same habit fix, weights and guardrails as days 1 to 7, so the normal's share grows by itself as the models lose skill. Set by the horizon test (below):
   - Highs and lows: the normal joins from day 8.
   - Precipitation amount: the normal joins from day 10.
   - Chance of precipitation from day 8: average of the sources' share and the normal wet-day share.
   - Ensembles: Open-Meteo keeps no history of past ensemble runs, so they have no track record yet. They are pulled, stored and scored on every refresh from 25 Nov 2026 and join only after 60+ days of our own record and a backtest that shows they help. `wxc/horizon.py`
8. **Certainty** = chance the day's high is within 2 deg C: Normal error with sigma = 1.25 x the consensus's own recent average miss at that lead, times (today's source disagreement / usual disagreement) ^ 0.25. `wxc/certainty.py`
9. **Nightly**: score yesterday against the station, update habit fixes and weights. **Hourly**: rebuild when any source posts a new run.

## Evidence (backtest, Kitimat Forest Ave, scored 1 Jan to 30 Oct 2026)
Reproduce with `uv run python backend/scripts/backtest.py`. The last scored day is 30 Oct 2026: the cached forecasts end at 23:00 UTC on 31 Oct, short of the 31 Oct climate day (it runs to 06 UTC on 1 Nov, and a day needs 22 of 24 hours); Nov and Dec 2025 only warm up the rolling windows. The script also writes `data/backtest/kitimat.json` (committed), which `publish.py` puts in the place file as `backtest` for the Consensus tab's "Tested on real Kitimat weather" card. Every number there is from this script.

Each single source alone vs the Consensus (added 27 Nov 2026; same script, same scored days per pair, raw source forecast, the Consensus rebuilt with past data only): the Consensus has the lower average miss against every source at every lead 1 to 7 for highs and for lows (108 pairs, no exception). Precipitation amount: lower in 50 of 54 pairs; not lower for UK Met Office at day 1 (2.587 vs 2.499 mm), ECMWF at day 3 (3.595 vs 3.477), UK Met Office at day 3 (3.690 vs 3.675) and NOAA GFS at day 7 (4.796 vs 4.715). The app's tested card claims highs and lows only.

| Day | High: Consensus | ECMWF | Equal weights | Low: Consensus | ECMWF |
|---|---|---|---|---|---|
| 1 | 1.00 | 1.42 | 1.20 | 1.01 | 1.47 |
| 2 | 1.14 | 1.46 | 1.27 | 1.03 | 1.55 |
| 3 | 1.23 | 1.58 | 1.34 | 1.09 | 1.61 |
| 4 | 1.43 | 1.72 | 1.47 | 1.27 | 1.70 |
| 5 | 1.51 | 1.84 | 1.57 | 1.31 | 1.85 |
| 6 | 1.77 | 2.13 | 1.79 | 1.47 | 2.12 |
| 7 | 2.15 | 2.43 | 2.10 | 1.61 | 2.28 |

Average miss in deg C (1 deg C = 1.8 deg F).

- Day 7: equal weights edges the Consensus (high 2.10 vs 2.15, low 1.60 vs 1.61). Track record matters less a week out. Idea to test in stage 1: blend toward equal weights as lead grows.
- Chance of precipitation, day 1: Brier score 0.092 vs 0.240 for climatology (lower is better).
- Guardrails (2% / 35%): identical highs; lows within 0.007 deg C. Kept as protection.
- Training window (day 1 high / low): 30 days 1.00 / 1.06; 60 days 1.00 / 1.07; 365 days 1.00 / 1.09; all history 0.98 / 1.08; best single model 1.08 / 1.21; equal weights 1.18 / 1.24. The gain comes from weighting, not long history (multi-year pilot, Jan 2024 to Oct 2026).
- Climate-day offset: -5 and -6 h within 0.02 deg C after the habit fix; -6 h best for chance of precipitation. -1 to -4 h clearly worse for highs.

### Certainty check
| Certainty said | Days | Came true (high within 2 deg C) |
|---|---|---|
| under 50% | 112 | 47% |
| 50 to 60% | 226 | 58% |
| 60 to 70% | 405 | 68% |
| 70 to 80% | 644 | 76% |
| 80 to 90% | 392 | 86% |
| 90%+ | 213 | 91% |

- Honest on average: says 73%, comes true 74% (highs, leads 1 to 7). Slightly cautious at days 1 to 3.
- Sigma factor: 1.15 to 1.2 fit marginally better in-sample; 1.25 kept (cautious, gain tiny).
- Disagreement term (exponent 0.25): small gain (Brier highs 0.1796 to 0.1792; lows 0.1427 to 0.1388). Exponent 0.5 hurt highs.
- **Limitation**: within one lead day, Certainty barely beats a fixed rate for that lead. It tells you how far ahead you can trust the forecast, honestly, but does not yet pick out individual shaky days well. Candidate fix for later: ensemble spread. Test before shipping.

## Days 8 to 14: horizon test (backtest)
Reproduce with `uv run python backend/scripts/horizon.py`. Kitimat Forest Ave, scored 1 Jul to 23 Nov 2026 (127 to 146 days per lead; summer and fall only, one station). History: Open-Meteo Single Runs, 00 UTC, from 2 Apr 2026 (2,069 runs; 55 runs Open-Meteo does not have). Days 1 to 7 here come from Single Runs, not Previous Runs, so they differ a little from the main table above. Consensus = models only for days 1 to 7, models plus the normal from day 8 (what ships). Normal alone = the normal with its own 30-day habit fix. Average miss in deg C (1 deg C = 1.8 deg F).

Highs (Certainty shown for days 8 to 14):

| Day | Days scored | Consensus | Best single model (hindsight) | Normal alone | Certainty said | Came true |
|---|---|---|---|---|---|---|
| 1 | 146 | 1.02 | 1.19 (GEM) | 3.16 | | |
| 2 | 146 | 1.16 | 1.47 (ECMWF IFS) | 3.20 | | |
| 3 | 146 | 1.28 | 1.69 (UKMO) | 3.22 | | |
| 4 | 146 | 1.56 | 1.98 (UKMO) | 3.23 | | |
| 5 | 146 | 1.86 | 2.21 (ECMWF AIFS) | 3.24 | | |
| 6 | 146 | 2.16 | 2.31 (ECMWF AIFS) | 3.25 | | |
| 7 | 146 | 2.39 | 2.64 (ECMWF AIFS) | 3.27 | | |
| 8 | 146 | 2.57 | 2.76 (ECMWF IFS) | 3.28 | 45% | 42% |
| 9 | 146 | 2.94 | 3.26 (ECMWF AIFS) | 3.27 | 40% | 40% |
| 10 | 143 | 3.05 | 3.39 (ECMWF AIFS) | 3.26 | 37% | 39% |
| 11 | 139 | 3.16 | 3.50 (ECMWF AIFS) | 3.25 | 37% | 40% |
| 12 | 135 | 3.33 | 3.82 (ECMWF AIFS) | 3.14 | 35% | 33% |
| 13 | 131 | 3.40 | 3.79 (ECMWF AIFS) | 3.13 | 33% | 37% |
| 14 | 127 | 3.59 | 4.04 (ECMWF AIFS) | 3.13 | 33% | 32% |

Lows:

| Day | Days scored | Consensus | Best single model (hindsight) | Normal alone |
|---|---|---|---|---|
| 1 | 146 | 0.82 | 0.96 (ECMWF IFS) | 1.98 |
| 2 | 146 | 0.79 | 1.06 (ECMWF IFS) | 2.00 |
| 3 | 146 | 0.87 | 1.09 (ECMWF IFS) | 2.01 |
| 4 | 146 | 0.87 | 1.13 (ECMWF AIFS) | 2.02 |
| 5 | 146 | 0.93 | 1.22 (ECMWF AIFS) | 2.03 |
| 6 | 146 | 1.29 | 1.52 (ECMWF AIFS) | 2.03 |
| 7 | 146 | 1.48 | 1.69 (ECMWF AIFS) | 2.03 |
| 8 | 146 | 1.46 | 1.85 (ECMWF AIFS) | 2.03 |
| 9 | 146 | 1.71 | 2.01 (GFS) | 2.03 |
| 10 | 143 | 1.84 | 2.21 (ECMWF AIFS) | 2.05 |
| 11 | 139 | 1.95 | 2.30 (ECMWF AIFS) | 2.08 |
| 12 | 135 | 2.06 | 2.60 (ECMWF AIFS) | 2.08 |
| 13 | 131 | 1.95 | 2.42 (ECMWF IFS) | 2.08 |
| 14 | 127 | 2.11 | 2.65 (GFS) | 2.09 |

- The normal as one more source, highs: costs 0.01 to 0.02 deg C at days 1 to 4, about even at days 5 and 8, helps from day 9 (day 14: 3.59 vs 4.04 models only). Lows: helps from day 6 (day 14: 2.11 vs 2.28). Its weight grows by itself: highs 17% at day 8, 35% (the cap) by day 14.
- **Open issue, highs at days 12 to 14: the normal alone beats the Consensus** (3.14 vs 3.33, 3.13 vs 3.40, 3.13 vs 3.59 deg C). Lows do not show this.
- **Cap test** (`uv run python backend/scripts/horizon.py --cap-test`, same days for every variant): letting the normal go past the 35% cap changes highs by 0.01 deg C or less at days 8 to 13 and helps only at day 14 (3.60 to 3.47 deg C). Mean over days 8 to 14, highs: 3.160 capped, 3.138 normal uncapped, 3.136 no cap at all; both halves of the period agree (Jul to Sep 3.865 to 3.849; Oct to Nov 1.958 to 1.927). Lows: no change (1.823 to 1.821). Certainty Brier, highs days 8 to 14: 0.2252 capped, 0.2256 uncapped. Uncapped, the normal's share still only reaches 35 to 48% by day 12 to 14, so the cap is not the main cause: inverse-error weights underrate the normal at long range, likely because the models miss together. Cap kept (locked decision); gain too small to reopen it. Next idea tested below.
- **Group test** (`uv run python backend/scripts/horizon.py --group-test`, same days for every variant): blend the models-only Consensus as one group against the habit-fixed normal, with the group's share from trailing 60-day errors known at issue time. Two ways: "inverse" (inverse squared error of the group vs the normal) and "pair" (best fixed mix of two forecasts whose misses move together, using their covariance).
  - Highs, mean miss over days 8 to 14: current 3.147, group inverse 3.081, group pair 3.035 deg C. Pair gains at days 10 to 14 (day 12: 3.33 to 3.17; day 13: 3.40 to 3.15; day 14: 3.59 to 3.19, close to the normal alone at 3.13) and loses a little at days 8, 9 and 11 (2.57 to 2.58, 2.94 to 2.98, 3.17 to 3.18). Both halves agree (Jul to Sep 3.924 to 3.843; Oct to Nov 1.958 to 1.797). The models' share falls to 16 to 17% at days 13 and 14.
  - Lows: no gain (current 1.870, inverse 1.866, pair 1.871).
  - Certainty breaks: Brier for highs at days 8 to 14 goes from 0.2246 (current) to 0.2453 (pair). The current method beats a fixed rate per lead picked with hindsight (0.2341); pair does worse than its fixed rate (0.2410), with or without the disagreement term. So with the pair blend, Certainty would no longer tell shaky days from steady ones at days 8 to 14.
  - Decision: not shipped. Better highs at days 10 to 14, but no gain for lows, small losses at days 8 and 9, and a worse Certainty. It would also change the locked weighting rule. Worth re-testing after a winter of data, together with a Certainty method that suits a blend led by the normal.
- Equal weights beat the Consensus for highs at days 8 and 9 (2.39 vs 2.57, 2.84 vs 2.94). Same pattern as day 7 in the pilot. Idea still to test: blend toward equal weights as lead grows.
- Precipitation amount (mm): the normal helps only from day 10 (day 14: 7.99 vs 9.06 models only), so it joins the amount from day 10.
- Chance of precipitation (Brier, lower is better): the share of sources with 1 mm or more is worse than the normal wet-day share from day 9 (day 14: 0.418 vs 0.232). The average of the two is best or tied from day 8 (day 8: 0.186; day 14: 0.273), so it is used from day 8.
- Certainty, highs, days 8 to 14: honest by lead; says 33 to 45% and comes true 32 to 43%. It falls with lead as it should. Over days 1 to 14 the top band (90%+) says 92% and comes true 83% (47 days): slightly overconfident there; watch in the shadow run.
- Lows at days 10 to 14: the same Certainty formula would say about 63 to 68% while the low lands within 2 deg C 56 to 63% of the time. Certainty is defined on the high only, so this does not affect the app; noted for when lows get their own rating.

## Live use (Stage 1)
- `backend/scripts/score.py` (nightly) pulls ECCC daily and 200 days of Open-Meteo Previous Runs (days 1 to 7), then writes each source's habit fix, error and weight per lead to `data/store/<place>/scores.json`.
- The live numbers use the same code and windows as the backtest. Check (`tests/test_score.py`, and 42 issue dates on pilot history): the live blend equals the backtest Consensus to within 0.0000000002 deg C. Station data from the issue day on is hidden, so nothing unknown at issue time is used.
- History coverage: Meteo-France has days 1 to 3 only, UK Met Office days 1 to 4. Past that they get no weight (same as the pilot).
- First live run (issue date 24 Nov 2026), day 1 high weights: UKMO 17%, ICON 15%, ECMWF AIFS 15%, GEM 14%, ECMWF IFS 10%, Meteo-France 9%, GFS 9%, JMA 7%, CMA 4%.
- `backend/scripts/publish.py` (hourly, after refresh) blends each source's newest saved run with the stats in `scores.json` using the same code (`consensus.blend`, `certainty.certainty`) and writes `public/<place>.json` (`docs/JSON_SCHEMA.md`). Two live-only rules, not in the backtest (which always has each source's run for each lead): a source whose newest run is more than 24 h older than the newest run of any source counts as late and its share goes to the rest; a source whose run does not cover a day gets no weight that day (live, ICON and UK Met Office stop at day 6, Meteo-France at day 3, CMA at day 4, GEM at day 9, JMA at day 10).
- First published file (issued 25 Nov 2026 03:42 UTC): Certainty for highs 91% on day 1, 58 to 70% on days 10 to 14. That is above the horizon test's 33 to 37% average for days 10 to 14 because the last 60 days were calm (consensus recent miss at day 14: 2.36 deg C, vs 3.59 over Jul to Nov). Certainty follows the recent record by design; watch it in the shadow run.

## Not yet tested
- Ensembles at any lead (no history from Open-Meteo; our own record starts 25 Nov 2026; test after 60+ days).
- Days 8 to 14 in winter and spring (the horizon test covers 1 Jul to 23 Nov 2026 only).
- Places other than Kitimat.
- Wind, gusts, snow vs rain, hourly values.
