# Build plan

Current stage: **Stage 1 done** (backend core, Kitimat only, on the main development Mac; 25 Nov 2026 UTC). Next: Stage 2, which needs the owner's go-ahead (GitHub repo, Actions, Pages). Nothing pushed yet.

Repo privacy fix (done 24 Nov 2026): local history rewritten so no commit holds personal details, and every commit's author and committer is the GitHub noreply identity. Not pushed; no GitHub repo yet.

## Stage 0: foundation (done 24 Nov 2026, in chat)
- Repo scaffold, CLAUDE.md, docs, config.
- Pilot logic ported to `backend/wxc`. `backtest.py` reproduces the pilot exactly: day 1 high 1.004 deg C, day 1 low 1.008, ECMWF 1.424.
- Certainty calibration checked on history: honest on average (see ALGORITHM.md).
- Guardrails (2% floor, 35% cap) tested: no measurable cost.
- Climate-day offset rechecked across -1 to -8 h: -6 h stays.

## Stage 1: backend core (local, Kitimat only)
1. `uv` project, Python 3.12. `uv run pytest` and `backtest.py` pass on the Mac. (Done 24 Nov 2026.)
2. Confirm current Open-Meteo docs: live forecast endpoint, model ids, Ensemble API ids, and the model-update metadata endpoint. Record links in `openmeteo.py`. (Done 24 Nov 2026: ensemble ids fixed in `config/sources.json`, GEFS uses the 0.5 deg run for 14 days, metadata paths per source added.)
3. `refresh.py`: check which sources have a new run; pull only those; save each raw pull under `data/store/` (date-stamped JSON); log every refusal. (Done 24 Nov 2026: first live run pulled all 12 sources, 0 refusals; a second run found nothing new and pulled nothing.)
4. `score.py` (nightly): pull ECCC daily for Kitimat Forest Ave, match stored forecasts by lead, update habit fixes and weights. (Done 24 Nov 2026: habit fixes and weights come from the Open-Meteo Previous Runs history, the same data the backtest uses; our own stored pulls are scored by lead in `live_scores.csv` and can take over once they cover 60+ days, after a backtest.)
5. Days 8 to 14: deterministic models' archived 16-day runs (Open-Meteo Single Runs, from 2 Apr 2026) plus the 1991 to 2020 normal (Kitimat Townsite) as one more source. Horizon test in `backend/scripts/horizon.py`; Certainty falls honestly with lead. Ensembles: pulled, stored and scored on every refresh, no weight yet (Open-Meteo keeps no history of past ensemble runs). (Done 24 Nov 2026; results in ALGORITHM.md. Follow-up tests, not shipped: lifting the 35% cap for the normal, and blending the models as one group against the normal.)
6. `publish.py`: write `public/kitimat.json` (schema in `docs/JSON_SCHEMA.md`, written in this stage): days 1 to 14 with high, low, precip, chance of precip, Certainty, tier, source weights, updated time, data credits. (Done 25 Nov 2026: schema version 1, formal schema in `docs/place-v1.schema.json`; unknown fields allowed so additions never break older apps; stale flag after 6 h without a new pull; about 6.5 KB; tests in `tests/test_publish.py`. `public/*.json` is git-ignored until the Stage 2 deploy method is chosen.)
7. Acceptance: tests pass; backtest unchanged; one live run produces a valid `kitimat.json`; refusals logged. (Done 25 Nov 2026: 42 tests pass; backtest day 1 high 1.004, low 1.008; live run pulled 3 new runs with 0 refusals and wrote a valid `kitimat.json`; excerpt in `docs/JSON_SCHEMA.md`.)

## Stage 2: hosting and shadow run (ask owner before starting)
- Create the public GitHub repo `weather-consensus`; push.
- GitHub Actions: hourly refresh at minute 17, nightly scoring; JSON to GitHub Pages; 6-hour stale check with failover plan.
- Shadow run 2 to 4 weeks: compare live Consensus to the station every day. Track refused runs; if more than about 1 in 20, move the main route to an always-on home Mac.
- `data/store/` must persist between Actions runs (refresh state, saved Single Runs, our own ensemble record). Decide how before turning on Actions.
- Decide how Pages gets `public/*.json` (deploy from the Actions run, or commit the files to a branch). The files are git-ignored for now.
- Job order each hour: `refresh.py` then `publish.py`; nightly: `score.py` then `publish.py`.
- Ensembles: from about 24 Jan 2027 (60 days of our own record), backtest adding them to days 8 to 14. They join only if they help.

## Stage 3: SwiftUI app (Xcode on the main development Mac; read docs/XCODE.md first)
- Decide minimum iOS version with the owner.
- Connect Claude Code to Xcode's MCP server; open the project in Xcode.
- New project in `ios/`: SwiftUI App life cycle, JSON project format, Swift Testing, String Catalog. App icon in Icon Composer 2.0 from the design canvas (three overlapping circles); preview both design generations.
- Weather tab and Consensus tab first, reading the published JSON. Then Places and Settings, then Radar.
- Living sky, navy cards, Inter, source bar, Certainty ring and dots, as on the design canvas. Use `#Preview(arguments:)` to show every time of day x weather.
- Adapt to every iPhone, including iPhone Duo outer and inner displays (size classes, state kept on fold).
- "Updated X hours ago"; Open-Meteo and ECCC credits in About.
- Acceptance: builds clean; previews render in light and dark; simulator screenshots of each tab on a standard iPhone and on iPhone Duo (both displays); VoiceOver reads the Certainty ring.

## Stage 4: more places, more weather, alerts
- Terrace, Lakelse Lake, MK Bay Marina (owner to confirm Lakelse truth and MK Bay coordinates).
- Wind, gusts, snow vs rain, condition icon, hourly: each tested on history before shipping.
- Warnings: ECCC alerts (Canada), NWS (US). Radar source.
- Push alerts (CloudKit, TestFlight early), morning summary. TestFlight beta.

## Open questions for the owner
- Version 1 of the JSON starts at tomorrow (day 1 = lead 1, the first day the backtest scores). Should the app also show today? That needs its own test first.
- MK Bay Marina coordinates; Lakelse Lake truth station.
- Terrace forecast at the airport (station) or in town.
- Add NOAA AI-GFS as source 13?
- Short Home Screen name ("Consensus"?). Bundle ID. Minimum iOS version.
