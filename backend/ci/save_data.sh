#!/usr/bin/env bash
# Commit and push the data branch checkout (data/store) after a job.
# Usage: bash backend/ci/save_data.sh "commit message"
# Commits as the GitHub Actions bot unless GIT_AUTHOR_* / GIT_COMMITTER_* are set.
# Pushes to the branch named by DATA_BRANCH (default: data). Retries after a
# rebase if the branch moved (the workflows also queue so only one job writes).
set -euo pipefail
msg="${1:?commit message}"
branch="${DATA_BRANCH:-data}"
cd "${DATA_DIR:-data/store}"

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-github-actions[bot]}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

git add -A
if git diff --cached --quiet; then
  echo "No data changes to save."
  exit 0
fi
git diff --cached --shortstat
git commit -q -m "$msg"
for try in 1 2 3; do
  if git push -q origin "HEAD:$branch"; then
    echo "Saved to the $branch branch: $(git rev-parse --short HEAD)"
    exit 0
  fi
  echo "Push refused (try $try); rebasing on the newest $branch branch."
  sleep $((try * 10))
  git pull -q --rebase origin "$branch"
done
echo "::error::Could not push the $branch branch"
exit 1
