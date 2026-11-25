#!/usr/bin/env bash
# Nightly job body (.github/workflows/nightly.yml). Run from the repo root with
# the data branch checked out at data/store.
# 1. score.py: station truth, habit fixes, weights (scores.json, live_scores.csv).
#    With IF_NEEDED=1 (the scheduled runs) a place already scored today with
#    yesterday's station data is skipped, so the later run only redoes the work
#    if ECCC had not posted by the first.
# 2. publish.py with the new weights.
# 3. Save data/store to the data branch.
set -uo pipefail
start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
py() { uv run --no-sync python "$@"; }

flags=()
[ "${IF_NEEDED:-0}" = "1" ] && flags+=(--if-needed)
py backend/scripts/score.py ${flags[@]+"${flags[@]}"}
scored=$?
[ $scored -eq 0 ] || echo "::error::Scoring failed (see refusals below); the previous scores stay in use"

py backend/scripts/publish.py
published=$?

bash backend/ci/save_data.sh "Nightly scoring $start" || exit 1

{ echo "## Nightly scoring $start"; py backend/scripts/refusals.py --since "$start"; } >> "$summary"
[ $scored -eq 0 ] && [ $published -eq 0 ]
