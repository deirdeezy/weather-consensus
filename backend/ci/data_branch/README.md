# Weather Consensus: data branch

Saved state for the hourly and nightly jobs on `main` (`.github/workflows/`). The jobs check this branch out at `data/store/`, run, and commit back. Nothing here is edited by hand. Design and growth figures: `docs/HOSTING.md` on `main`.

## Layout
- `<place>/state.json`: refresh state. The newest run pulled from each source.
- `<place>/<YYYY-MM-DD>/<HHMMSS>Z_<source>.json`: every raw pull, as Open-Meteo sent it (deterministic models and ensembles). This is our own forecast record, including the ensemble record (Open-Meteo keeps no history of past ensemble runs).
- `<place>/single/<source>/<YYYY-MM-DD>.json`: archived 00 UTC runs (Open-Meteo Single Runs) for days 8 to 14. A `.missing` file marks a run Open-Meteo does not have.
- `<place>/history/normal_records_<id>.json`: station records for the 1991 to 2020 normal.
- `<place>/scores.json`: nightly habit fixes, errors and weights per source, lead and variable.
- `<place>/now.json`: the latest observation at the place's approved station (ECCC real-time SWOB), replaced every hour; places without an approved station have none.
- `<place>/hourly/<YYYY-MM-DD>/<HHMMSS>Z_<source>.json`: shadow collection (from 27 Nov 2026), the extra hourly variables (wind, gusts, cloud, weather code, snowfall, humidity, visibility) for lead 0 to 144 h of each deterministic run pulled. Not used by the forecast yet.
- `<place>/swob/`: shadow collection (from 27 Nov 2026), every field of every hourly record from the place's approved station (ECCC real-time SWOB keeps only about 30 days). `fields.json` plus `hourly-<YYYY-MM>.jsonl`; format in `docs/JSON_SCHEMA.md` on `main`.
- `<place>/live_scores.csv`: every stored pull scored against the station by lead (the shadow-run record).
- `refusals.jsonl`: every refused or failed call, one line each.

Downloads the nightly job fetches again every night (Previous Runs, station observations) are not kept here; they live in the Actions cache as a fallback copy.

## Credits and licences
- Weather data by Open-Meteo.com, licensed CC BY 4.0: https://open-meteo.com/ and https://creativecommons.org/licenses/by/4.0/
- Contains information licenced under the Data Server End-use Licence of Environment and Climate Change Canada: https://eccc-msc.github.io/open-data/licence/readme_en/
