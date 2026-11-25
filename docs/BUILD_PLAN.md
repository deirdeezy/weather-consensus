# Build plan

Current stage: **Stage 1** (backend core, Kitimat only, on the main development Mac).

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
4. `score.py` (nightly): pull ECCC daily for Kitimat Forest Ave, match stored forecasts by lead, update habit fixes and weights.
5. Days 8 to 14: ensembles plus the 1991 to 2020 normal (Kitimat Townsite). Port the pilot's horizon test; Certainty must fall honestly with lead.
6. `publish.py`: write `public/kitimat.json` (schema in `docs/JSON_SCHEMA.md`, written in this stage): days 1 to 14 with high, low, precip, chance of precip, Certainty, tier, source weights, updated time, data credits.
7. Acceptance: tests pass; backtest unchanged; one live run produces a valid `kitimat.json`; refusals logged.

## Stage 2: hosting and shadow run (ask owner before starting)
- Create the public GitHub repo `weather-consensus`; push.
- GitHub Actions: hourly refresh at minute 17, nightly scoring; JSON to GitHub Pages; 6-hour stale check with failover plan.
- Shadow run 2 to 4 weeks: compare live Consensus to the station every day. Track refused runs; if more than about 1 in 20, move the main route to an always-on home Mac.

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
- MK Bay Marina coordinates; Lakelse Lake truth station.
- Terrace forecast at the airport (station) or in town.
- Add NOAA AI-GFS as source 13?
- Short Home Screen name ("Consensus"?). Bundle ID. Minimum iOS version.
