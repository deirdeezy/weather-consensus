#!/usr/bin/env bash
# Run the workflow job scripts locally, as Actions would, against a stand-in
# for GitHub (a bare Git repo in a scratch folder). Uses live data: it calls
# Open-Meteo and ECCC like a real run (a few dozen calls).
# What it cannot test: GitHub's scheduler, the Actions cache, permissions,
# Pages deployment, runner IP limits. Those are checked on the first real run.
# Usage: bash backend/ci/local_test.sh <scratch-folder> <seeded-data-branch-folder>
set -euo pipefail
work="${1:?scratch folder}"
seed="${2:?folder made by seed_data_branch.sh}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$work"; work="$(cd "$work" && pwd)"
rm -rf "$work/origin.git" "$work/run" "$work/other"
export GITHUB_STEP_SUMMARY="$work/summary.md"; : > "$GITHUB_STEP_SUMMARY"
# Local commits use this repo's noreply identity, not the Actions bot's.
GIT_AUTHOR_NAME="$(git -C "$root" config --local user.name)"
GIT_AUTHOR_EMAIL="$(git -C "$root" config --local user.email)"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
case "$GIT_AUTHOR_EMAIL" in *@users.noreply.github.com) ;; *) echo "need a noreply user.email"; exit 1 ;; esac

step() { printf '\n=== %s\n' "$*"; }
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails+1)); fi; }
fails=0

step "Stand-in GitHub repo with main and data"
git init -q --bare "$work/origin.git"
git -C "$root" push -q "$work/origin.git" HEAD:refs/heads/main
git -C "$seed" push -q "$work/origin.git" data:refs/heads/data

step "Checkout as in the workflow: main, then data at data/store (depth 1)"
git clone -q --depth 1 --branch main "file://$work/origin.git" "$work/run"
git clone -q --depth 1 --branch data "file://$work/origin.git" "$work/run/data/store"
cd "$work/run"
uv sync -q --frozen --no-dev
before="$(git -C data/store rev-parse HEAD)"

step "Hourly job, first run"
t0=$(date +%s); bash backend/ci/hourly.sh; echo "took $(( $(date +%s) - t0 )) s"
after="$(git --git-dir="$work/origin.git" rev-parse data)"
check "public/kitimat.json written" "[ -s public/kitimat.json ]"
check "kitimat.json matches docs/place-v1.schema.json" \
  "uv run -q --with jsonschema python -c 'import json,jsonschema; jsonschema.validate(json.load(open(\"public/kitimat.json\")), json.load(open(\"docs/place-v1.schema.json\")))'"
check "kitimat.json not in main's Git" "[ -z \"\$(git ls-files public/*.json)\" ]"
echo "data branch: $before -> $after"
check "main untouched by the job" "[ -z \"\$(git status --porcelain --untracked-files=no)\" ]"

step "Hourly job, second run straight after (expect nothing new to pull)"
bash backend/ci/hourly.sh

step "Nightly job (IF_NEEDED=1, as scheduled)"
t0=$(date +%s); IF_NEEDED=1 bash backend/ci/nightly.sh; echo "took $(( $(date +%s) - t0 )) s"
check "Nightly re-downloads not committed" \
  "[ -z \"\$(git -C data/store ls-files | grep -E 'history/(prev_|eccc_daily_)')\" ]"
check "scores.json committed" "git -C data/store ls-files --error-unmatch kitimat/scores.json >/dev/null"

step "Nightly job again (skips only if yesterday's station day is in)"
IF_NEEDED=1 bash backend/ci/nightly.sh

step "Nightly job, forced (no saved downloads, like the first Actions run)"
t0=$(date +%s); IF_NEEDED=0 bash backend/ci/nightly.sh; echo "took $(( $(date +%s) - t0 )) s"
check "scored again and pushed" \
  "git --git-dir=\"$work/origin.git\" log -1 --format=%s data | grep -q 'Nightly scoring'"
check "kitimat.json still matches the schema" \
  "uv run -q --with jsonschema python -c 'import json,jsonschema; jsonschema.validate(json.load(open(\"public/kitimat.json\")), json.load(open(\"docs/place-v1.schema.json\")))'"

step "Push race, on a throwaway branch: another writer moves it first"
git --git-dir="$work/origin.git" branch race data
git clone -q --branch race "file://$work/origin.git" "$work/other"
(cd "$work/other" && echo "{}" > race_test.json && git add race_test.json &&
  git commit -q -m "race: other writer" && git push -q)
git -C data/store checkout -q -b race  # our job, still at the old tip
echo '{"race":"ours"}' > data/store/race_ours.json
DATA_BRANCH=race bash backend/ci/save_data.sh "race: this job"
check "rebase and push after a race" \
  "git --git-dir=\"$work/origin.git\" show race:race_test.json >/dev/null && git --git-dir=\"$work/origin.git\" show race:race_ours.json >/dev/null"
git -C data/store checkout -q data
git --git-dir="$work/origin.git" branch -D race >/dev/null

step "Commit identities on the data branch"
git --git-dir="$work/origin.git" log data --format='%an <%ae>' | sort | uniq -c

step "Size"
git --git-dir="$work/origin.git" count-objects -vH | grep -E 'size-pack'
du -sh data/store public

step "Summary written for the Actions run page"
cat "$GITHUB_STEP_SUMMARY"
echo; echo "Failures: $fails"
exit $fails
