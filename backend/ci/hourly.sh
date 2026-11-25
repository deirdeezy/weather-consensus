#!/usr/bin/env bash
# Hourly job body (.github/workflows/refresh.yml). Run from the repo root with
# the data branch checked out at data/store.
# 1. refresh.py: pull the sources that posted a new run (refusals logged).
# 2. obs.py: latest station observation for places with an approved station.
# 3. publish.py: write public/<place>.json (stale flag after 6 h without a pull).
# 4. Save data/store to the data branch.
# A source (or station) that could not be read is a warning, not a failure: the run still
# publishes and saves. The job fails only if publishing or saving fails.
set -uo pipefail
start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
py() { uv run --no-sync python "$@"; }

if ! py backend/scripts/refresh.py; then
  echo "::warning::Some sources were not pulled this hour (see refusals below)"
fi

if ! py backend/scripts/obs.py; then
  echo "::warning::No new station observation this hour (see refusals below)"
fi

py backend/scripts/publish.py
published=$?

bash backend/ci/save_data.sh "Refresh $start" || exit 1

{ echo "## Hourly refresh $start"; py backend/scripts/refusals.py --since "$start"; } >> "$summary"
exit $published
