#!/usr/bin/env bash
# Build the first commit of the data branch from a local data/store, in a new
# folder, without touching data/store itself. Run once, before the first push.
# Usage: bash backend/ci/seed_data_branch.sh <empty-folder>
# Commits with this repo's git identity, which must be a GitHub noreply
# address (the global identity on a Mac is often a real name and email).
set -euo pipefail
out="${1:?empty folder for the new data branch}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$out"
[ -z "$(ls -A "$out")" ] || { echo "$out is not empty"; exit 1; }
name="$(git -C "$root" config --local user.name || true)"
email="$(git -C "$root" config --local user.email || true)"
case "$email" in
  *@users.noreply.github.com) ;;
  *) echo "Set a GitHub noreply user.email in this repo first (git config --local)"; exit 1 ;;
esac
cd "$out"
git init -q -b data
git config user.name "$name"
git config user.email "$email"
rsync -a --exclude-from="$root/backend/ci/data_branch/gitignore" "$root/data/store/" ./
cp "$root/backend/ci/data_branch/README.md" README.md
cp "$root/backend/ci/data_branch/gitignore" .gitignore
git add -A
git commit -q -m "Data branch: Stage 1 store (pulls from 25 Nov 2026, Single Runs, normal, scores)"
git log --format='%h %an <%ae>' -1
du -sh .git
