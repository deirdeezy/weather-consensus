# Weather Consensus

iOS weather app (SwiftUI) that blends up to 12 forecast sources, weights each by its track record at each place, and shows a Certainty % for every day. Starting places: Kitimat, Terrace, Lakelse Lake, MK Bay Marina (BC). No ads, no tracking, no account.

## Read first
- `docs/BUILD_PLAN.md`: stages, current stage, acceptance tests.
- `docs/ALGORITHM.md`: the algorithm and every test result behind it.
- `docs/XCODE.md`: what Xcode 27 can do for us and how to use it (iOS work).
- Design canvas (claude.ai artifact, owner can open): https://claude.ai/artifact/9faD7sbSkc3Tj5TjkRGfq2

## Writing style (for replies, docs, UI text and commit messages)
- Lead with the answer or decision, then reasoning, then next steps.
- Bullets and short headers. Numbered steps with exact menu paths for any setup.
- No filler. Max 1 or 2 clarifying questions; otherwise state assumptions and proceed.
- Never use an em dash or a double hyphen as punctuation.
- Metric and imperial for technical values in explanations.

## Rules
- Never invent accuracy numbers. Every accuracy claim must come from a script in this repo and its output. Label sample data as sample, in docs and in the UI.
- Test any algorithm change on history (`backend/scripts/backtest.py`) before shipping. Report before and after numbers.
- Check current docs for every external API, limit, price and Apple rule before coding against it, and cite the source in the commit or doc. Do not rely on memory.
- Open-Meteo: free tier is non-commercial only, 10,000 calls a day, 5,000 an hour, 600 a minute, 300,000 a month, counted per internet address. More than 10 variables or 2 weeks of data in one call counts as more than one call. Metadata (model-update) calls are free. Credit "Weather data by Open-Meteo.com" (CC BY 4.0) in the app and the published JSON.
- ECCC station data is the truth in Canada; NOAA stations in the US.
- Ask the owner before: creating the GitHub repo, turning on Actions or Pages, anything that costs money, App Store Connect or CloudKit production changes, deleting data.
- Repo lives in `~/Developer/weather-consensus`, never in iCloud Drive or Google Drive. Commit in small steps; push when a step is done (once the GitHub repo exists).
- Keep the cache (`data/cache/`) out of Git. It holds pilot downloads and can be re-fetched.

## Locked decisions (do not reopen unless the owner asks)
- Name: Weather Consensus. Feature: Consensus. Daily rating: Certainty (%). Tiers: High 75%+, Medium 50 to 74%, Low under 50%.
- Certainty = chance the day's high lands within 2 deg C of our number. Shown as a ring and 10 dots.
- Tabs: Weather, Radar, Consensus, Places. Gear on Weather opens Settings.
- Look: sky backgrounds, navy cards, Inter, coloured source bar (colour = source, length = weight). Living sky follows time of day and current weather; rough weather looks rich, never gloomy.
- Algorithm: per place, per lead day, per variable. 30-day habit fix, weights from inverse 60-day squared error, guardrails 2% floor and 35% cap. Days 8 to 14 lean on ensembles and the 1991 to 2020 normal.
- Hosting: $0. Public GitHub repo, GitHub Actions jobs (hourly refresh at minute 17, nightly scoring), one JSON file per place on GitHub Pages.
- Reliability: refresh only when a source posts a new run, retry on refusal, switch to a second route (an always-on home Mac or a free Google Cloud VM) after 6 hours without fresh data. App shows "Updated X hours ago" and lowers Certainty when data is stale.
- Alerts: warnings and big changes by Apple push (CloudKit first, test in TestFlight early; fallback direct APNs). Morning summary is a local notification.

## Xcode 27 (read docs/XCODE.md before any iOS work)
- Installed: Xcode 27.2 on the main development Mac (Swift 6.4, iOS 27.2 SDK), iOS platform only. Check current Apple docs when Xcode updates.
- Connect to Xcode's MCP server at the start of Stage 3: `claude mcp add --transport stdio xcode -- xcrun mcpbridge` (or a project `.mcp.json` with the owner's approval). Open the project in Xcode first.
- Use Xcode's tools instead of guessing: build and test, render previews (light/dark, sizes, widget timelines), boot simulators and tap through the app with screenshots, debugger console, build settings, entitlements and Info.plist keys, String Catalogs, Apple documentation search.
- Check your own UI work with previews or simulator screenshots before calling it done.
- Project: SwiftUI App life cycle in `ios/`, JSON project format (`.xcproj`, default in 27.2), `#Preview` only (PreviewProvider is deprecated), Swift Testing, String Catalog from day one, app icon in Icon Composer 2.0.
- iPhone Duo: lay out with size classes, never device idiom or orientation; keep state when the phone folds or unfolds; test in the Duo simulator.
- Never enable `xcrun mcp-server` or change Xcode Intelligence settings without asking the owner.

## Layout
```
backend/wxc/        Python package: daily.py, consensus.py, certainty.py, eccc.py, openmeteo.py
backend/scripts/    backtest.py (reproduces the pilot), later: refresh.py, score.py, publish.py
config/             places.json, sources.json
data/cache/         pilot downloads (git-ignored)
docs/               BUILD_PLAN.md, ALGORITHM.md, XCODE.md
public/             published JSON per place (later served by GitHub Pages)
tests/              pytest
ios/                SwiftUI app (stage 3)
```

## Commands
```
uv sync                                          # set up Python 3.12 and packages
uv run pytest -q                                 # tests
uv run python backend/scripts/backtest.py        # must show day 1 high about 1.00
uv run python backend/scripts/backtest.py --align
uv run python backend/scripts/refresh.py --dry-run  # which sources have a new run
uv run python backend/scripts/refresh.py         # pull them into data/store/
```
