# Hosting (Stage 2)

Everything runs on GitHub for $0: a public repo, GitHub Actions for the jobs, a `data` branch for saved state, and GitHub Pages for the published JSON.

## How it fits together
| Piece | Where | Written by |
|---|---|---|
| Code, config, docs | `main` | people |
| Saved state: refresh state, raw pulls (incl. the ensemble record), Single Runs, the normal, `scores.json`, `live_scores.csv`, the latest station observation (`<place>/now.json`, about 0.6 KB, replaced each hour), `refusals.jsonl` | `data` branch (checked out at `data/store/`) | the workflows |
| Nightly re-downloads (Previous Runs, ECCC station data) | Actions cache, fallback copy only | nightly workflow |
| `kitimat.json` | GitHub Pages: `https://deirdeezy.github.io/weather-consensus/kitimat.json` | the workflows (never committed) |
| Pilot cache (`data/cache/`) | the development Mac only | never pushed |

- `main` never gets data commits; `public/*.json` stays git-ignored.
- The `data` branch has its own README with the layout and data credits (`backend/ci/data_branch/README.md`).
- Nightly re-downloads stay out of Git because `score.py` fetches them again every night (200-day windows, about 14 MB raw), so committing them would add churn for nothing.

## Jobs
| Workflow | When (UTC) | Steps | Permissions |
|---|---|---|---|
| `refresh.yml` | minute 17 every hour | `refresh.py`, `obs.py`, `publish.py`, save `data`, deploy Pages | job 1: `contents: write`; deploy: `pages: write`, `id-token: write` |
| `nightly.yml` | 09:47 and 15:47 | `score.py --if-needed`, `publish.py`, save `data`, deploy Pages; re-enable both workflows | job 1: `contents: write`; deploy: `pages: write`, `id-token: write`; keepalive: `actions: write` |

- Both also run by hand (Actions tab, Run workflow). Nightly has a "force" box to rescore.
- Job bodies are scripts (`backend/ci/hourly.sh`, `nightly.sh`, `save_data.sh`) so they run the same locally.
- Default token permissions are none (`permissions: {}`); each job asks only for what it needs. The checkout of `main` keeps no credentials.
- Actions are pinned to commit SHAs (checkout v7.0.1, cache v6.1.0, setup-uv v10.4.0, upload-pages-artifact v5.0.0, deploy-pages v5.0.1; latest releases on 25 Nov 2026).

### Station observations (the "now" block)
- `obs.py` makes one call an hour per place with an approved station (Kitimat only): ECCC's real-time SWOB on the MSC GeoMet OGC API (`https://api.weather.gc.ca/collections/swob-realtime/items`), hourly records since 06 UTC, only the fields we use (about 6 KB). Raw answers are not kept: only the processed block in `<place>/now.json`.
- MSC usage policy (https://eccc-msc.github.io/open-data/usage-policy/readme_en, checked 25 Nov 2026): a meaningful User-Agent (ours names the project and this repo, nothing else), only the data you use, no no-cache headers, contact MSC above 86,400 requests a day. We make 24.
- A refused or empty answer is logged (`eccc_swob`) and the last block stays; the app ages it by `observed_at`. The app still reads only GitHub Pages.

### Never two runs at once
Both workflows share one concurrency group (`data-branch`) with `queue: max`: a run waits for the one in progress; up to 100 can wait; none is cancelled. GitHub's default (`queue: single`) would cancel a waiting run when another queues. `save_data.sh` also rebases and retries a refused push (tested locally).

### Nightly scoring after ECCC posts
ECCC does not document when a day's values appear in the climate-daily API. On 25 Nov 2026 at 03:51 UTC the row for 24 Nov existed but was empty. So scoring runs twice: 09:47 UTC (01:47 PST) and 15:47 UTC (07:47 PST). The second run rescores only if the first did not have yesterday's station values (`score.py --if-needed`). The shadow run will show which slot gets the data; move the times then.

### Refusals
- Every failed call is a line in `refusals.jsonl` on the `data` branch (kinds in `backend/scripts/refusals.py`).
- Each run's page shows the refusals logged during that run (job summary).
- A source that could not be pulled is a warning, not a failed run: the run still publishes and saves. A run fails only if publishing, scoring or saving fails (GitHub emails the owner on failure).
- Shadow-run count: `uv run python backend/scripts/refusals.py --since <time>` on a checkout of `data`.

### Stale data
Unchanged from Stage 1: `kitimat.json` sets `stale: true` after 6 hours without a new pull, and the app also checks the times itself (`docs/JSON_SCHEMA.md`). Second route (home Mac or Google Cloud VM) is a plan, not built: switch only if the shadow run shows refusals above about 1 in 20.

## Limits (GitHub docs, checked 25 Nov 2026)
| Limit | Value | Our use |
|---|---|---|
| Repo size | ideally under 1 GB, under 5 GB strongly recommended | about 10 to 15 MB a month (below) |
| File size | warning over 50 MiB, blocked over 100 MiB | largest file 10 MB (normal records) |
| Actions minutes, public repo, standard runners | free | about 1 minute an hour |
| Job time | 6 hours per job | about 1 to 3 minutes |
| Actions cache | 10 GB per repo; entries unused for 7 days are removed | about 1 to 2 MB a night |
| `GITHUB_TOKEN` API | 1,000 requests an hour per repo | 2 a night |
| Pages | site under 1 GB; 100 GB a month bandwidth (soft); 10 builds an hour soft limit does not apply to custom Actions workflows | one 6.5 KB file, about 26 deploys a day |
| Schedule | can be delayed at high load, busiest at the top of the hour; runs on the default branch only | minute 17 and 47 |

Sources:
- https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github
- https://docs.github.com/en/actions/reference/limits
- https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching
- https://docs.github.com/en/billing/managing-billing-for-github-actions/about-billing-for-github-actions
- https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule
- https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-workflow-runs/disabling-and-enabling-a-workflow
- https://docs.github.com/en/rest/actions/workflows#enable-a-workflow
- https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/control-the-concurrency-of-workflows-and-jobs
- https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits
- https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages

## Scheduled workflows and the 60-day rule
GitHub: "In a public repository, scheduled workflows are automatically disabled when no repository activity has occurred in 60 days." The docs do not define activity. Three layers:
1. The workflows commit to the `data` branch every hour.
2. The nightly `keepalive` job calls the "Enable a workflow" API for both workflows (no change while enabled).
3. Any commit to `main` by the owner counts as activity in any reading of the rule.

Not proven until day 60. Watch for: the Actions tab shows a workflow as disabled, or `kitimat.json` goes stale. Fix: Actions tab, pick the workflow, Enable workflow (or `gh workflow enable refresh.yml`).

## Expected growth
Measured on the Stage 1 store, packed by Git (25 Nov 2026):
- Starting `data` branch: 1.9 MiB (2,124 Single Runs, normal records, the first pulls, scores).
- Deterministic pull: about 0.75 KiB each; about 45 a day (most sources post every 6 hours, some have several components).
- Ensemble pull: about 16 KiB each; about 10 a day (ECMWF ENS and GEFS 4 a day, GEPS 2).
- Single Runs: about 1 KiB each, 9 a day. `live_scores.csv` grows about 30 KiB a day once scored. Commits and folder listings: about 75 KiB a day.

Estimate: **about 350 KiB a day, 10 to 15 MB a month, 120 to 180 MB a year** (about 70% of it the ensemble record). At that rate the 1 GB guideline is about 6 years away. Unpacked, the checkout grows about 55 MB a month; each run downloads the packed size. Check the real number after the first week (`git count-objects -vH` on a fresh clone of `data`). If it ever matters: archive old months as release files, or check out only recent days in the hourly job.

## Open-Meteo calls from Actions
- Hourly: model-update metadata (free) plus about 55 pulls a day; nightly: 9 Previous Runs calls (about 20 calls each by Open-Meteo's weighting) and 9 Single Runs. Upper bound about 350 weighted calls a day, counting every ensemble member as a variable: under 4% of the 10,000 daily limit.
- GitHub runners share internet addresses with other users, and Open-Meteo counts limits per address. That is the main risk; refusals are logged and counted in the shadow run.

## Test locally
`backend/ci/local_test.sh` runs the job scripts against a stand-in for GitHub (a bare repo in a scratch folder), with live data:

```bash
bash backend/ci/seed_data_branch.sh /tmp/wxc-seed
```

```bash
bash backend/ci/local_test.sh /tmp/wxc-ci /tmp/wxc-seed
```

It checks: `kitimat.json` is written and matches the schema; it is not committed to `main`; nightly re-downloads are not committed; skipped and forced scoring; a push race is rebased and retried; commit identities; sizes. It cannot test GitHub's scheduler, the Actions cache, permissions, Pages deployment or runner address limits; the first runs on GitHub check those. Workflow syntax: `actionlint` (config in `.github/actionlint.yaml`; it does not know `queue` yet).

Result 25 Nov 2026: all checks passed; hourly job 11 s, forced nightly 19 s on the development Mac.

## Working with the data locally
```bash
git fetch origin data && git worktree add ../weather-consensus-data data
```
A second folder next to the repo, read only: the workflows are the only writers. Do not push to `data` by hand while they run.
