# Algorithm

Per place, per lead day (1 to 14), per variable. Evidence labels: **backtest** = our own test on Kitimat history in this repo (one station; strong for Kitimat, unproven elsewhere until each place is tested).

## Steps
1. **Pull** the newest run of every source (9 deterministic models; 3 ensembles from day 7).
2. **Daily values**: hourly to daily on the ECCC climate day (UTC minus 6 h; a day needs 22 of 24 hours). `wxc/daily.py`
3. **Habit fix**: subtract each source's average error over the last 30 days. Only days already verified at issue time count (window ends lead + 1 days before the target).
4. **Weights**: inverse of each source's mean squared error over the last 60 days, after the habit fix. Normalise to 100%. Guardrails: floor 2%, cap 35%. A late source's share is split among the rest. `wxc/consensus.py`
5. **Consensus** = weighted sum of habit-fixed forecasts.
6. **Precipitation**: amount weighted by inverse 60-day mean absolute error (no habit fix). Chance of precipitation = share of sources forecasting 1 mm or more.
7. **Days 8 to 14**: shift weight to ensembles and the 1991 to 2020 normal (normal about one third by day 13). Stage 1 work.
8. **Certainty** = chance the day's high is within 2 deg C: Normal error with sigma = 1.25 x the consensus's own recent average miss at that lead, times (today's source disagreement / usual disagreement) ^ 0.25. `wxc/certainty.py`
9. **Nightly**: score yesterday against the station, update habit fixes and weights. **Hourly**: rebuild when any source posts a new run.

## Evidence (backtest, Kitimat Forest Ave, scored 1 Jan to 31 Oct 2026)
Reproduce with `uv run python backend/scripts/backtest.py`.

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

## Live use (Stage 1)
- `backend/scripts/score.py` (nightly) pulls ECCC daily and 200 days of Open-Meteo Previous Runs (days 1 to 7), then writes each source's habit fix, error and weight per lead to `data/store/<place>/scores.json`.
- The live numbers use the same code and windows as the backtest. Check (`tests/test_score.py`, and 42 issue dates on pilot history): the live blend equals the backtest Consensus to within 0.0000000002 deg C. Station data from the issue day on is hidden, so nothing unknown at issue time is used.
- History coverage: Meteo-France has days 1 to 3 only, UK Met Office days 1 to 4. Past that they get no weight (same as the pilot).
- First live run (issue date 24 Nov 2026), day 1 high weights: UKMO 17%, ICON 15%, ECMWF AIFS 15%, GEM 14%, ECMWF IFS 10%, Meteo-France 9%, GFS 9%, JMA 7%, CMA 4%.

## Not yet tested
- Days 8 to 14 blend with ensembles and the normal (pilot tested ECMWF alone vs the normal: skill to about day 9, gone by day 14).
- Places other than Kitimat.
- Wind, gusts, snow vs rain, hourly values.
