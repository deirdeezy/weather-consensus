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
| `refresh.yml` | minute 10 every hour (Cloudflare Worker); GitHub cron minute 17 as backup | `refresh.py`, `obs.py`, `publish.py`, save `data`, deploy Pages | job 1: `contents: write`; deploy: `pages: write`, `id-token: write` |
| `nightly.yml` | 09:52 and 15:52 (Cloudflare Worker); GitHub cron 09:47 and 15:47 as backup | `score.py --if-needed`, `publish.py`, save `data`, `missing.py`; a retry job on a fresh runner if Open-Meteo refused calls for a rate limit; deploy Pages; re-enable both workflows | job 1 and retry: `contents: write`; deploy: `pages: write`, `id-token: write`; keepalive: `actions: write` |

- Both also run by hand (Actions tab, Run workflow). Nightly has a "force" box to rescore.
- What starts them: next section.
- Job bodies are scripts (`backend/ci/hourly.sh`, `nightly.sh`, `save_data.sh`) so they run the same locally.
- Default token permissions are none (`permissions: {}`); each job asks only for what it needs. The checkout of `main` keeps no credentials.
- Actions are pinned to commit SHAs (checkout v7.0.1, cache v6.1.0, setup-uv v10.4.0, upload-pages-artifact v5.0.0, deploy-pages v5.0.1; latest releases on 25 Nov 2026).

### What starts the runs
GitHub's own schedule is best effort ("can be delayed during periods of high loads"; queued jobs "may be dropped"). On its first day it fired 1 of 19 hourly slots (04:17 to 22:17 UTC, 25 Nov 2026; the one run was 9 minutes late) and one nightly run at 19:37 UTC, 3 h 50 min or more after its slot (Actions API, `event: schedule`). Manual dispatches started within a second. So the runs are started from outside, and GitHub's cron stays as a backup.

**Primary: a Cloudflare Worker cron (Workers Free plan), set up 26 Nov 2026.**
- Cron every 5 minutes. Slots: `refresh.yml` at minute 10 of every hour; `nightly.yml` at 09:52 and 15:52 UTC.
- For each slot it asks the Actions API whether a run of that workflow has started since 5 minutes before the slot (any event: schedule, dispatch, manual). If none has, it sends `workflow_dispatch` on `main`. It keeps checking for up to 45 minutes after the slot, so a failed dispatch is retried and a late GitHub cron run counts.
- It only starts runs. GitHub Actions is still the only writer of the `data` branch and Pages.
- Token: a fine-grained personal access token, this repository only, repository permission Actions: read and write (Metadata: read is added by GitHub). Nothing else. Per GitHub's permission table, that covers listing runs and dispatching workflows; it cannot push code, read secrets or change settings.
- Stored only as the Worker's encrypted secret `GH_TOKEN` (hidden in the Cloudflare dashboard and Wrangler after it is set). Never in this repo, a workflow, or a GitHub secret.
- The Worker has no public address: its `workers.dev` URL is turned off, so it runs only from its cron.
- Missed runs: no failure alert yet. Staleness shows in the app ("Updated X hours ago", the 6-hour `stale` flag, the Now card's age) and on the Actions tab. The Worker's last 100 cron runs are listed in the Cloudflare dashboard (Workers & Pages, the Worker, Settings, Trigger Events).

**Backup: GitHub cron.** The `schedule` lines in both workflows are unchanged (minute 17; 09:47 and 15:47).

**Double runs are harmless.** When the cron and the Worker both start a run, the shared queue (below) runs them one after the other. A second hourly run pulls nothing new (`refresh.py` pulls only sources with a new run), reads the station again (2 requests), writes the same file and saves nothing if nothing changed; it costs about 1 runner minute. A second nightly run skips places already scored (`score.py --if-needed`; a dispatch without inputs has `force` false).

Sources (checked 25 and 26 Nov 2026):
- https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule
- https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event
- https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens
- https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
- https://developers.cloudflare.com/workers/configuration/cron-triggers/
- https://developers.cloudflare.com/workers/platform/limits/ (Free: 100,000 requests a day, 5 cron triggers an account)
- https://developers.cloudflare.com/workers/configuration/secrets/

### Station observations (the "now" block)
- `obs.py` makes two calls an hour per place with an approved station (Kitimat only), on ECCC's real-time SWOB on the MSC GeoMet OGC API (`https://api.weather.gc.ca/collections/swob-realtime/items`): the hourly records since 06 UTC (about 6 KB) and the newest minute record (about 4.5 KB). Only the fields we use. Raw answers are not kept: only the processed block in `<place>/now.json`.
- Current temp, dew point, humidity, wind and gust come from whichever record is newer, the minute or the hourly one; a minute value is used only if its quality flag is there and passed. Minute records have no flag on dew point, wind or gust, so those come from the hourly record. Pressure, tendency and the so-far values always come from hourly records. `values_from` in the block says which record each value came from (`docs/JSON_SCHEMA.md`).
- Posting delay: ECCC documents none (records can be fetched "as soon as they become available"). Datamart file times for Kitimat Forest Ave on 25 Nov 2026: hourly records posted 0 to 6 minutes after the hour (22 records); minute records median 0, 95th percentile 3 minutes. The 22:00 UTC hourly record never came: the station sent nothing from 21:25 to 22:04. So minute 10 is late enough, and the minute record keeps "now" within minutes of the run.
- MSC usage policy (https://eccc-msc.github.io/open-data/usage-policy/readme_en, checked 25 Nov 2026): a meaningful User-Agent (ours names the project and this repo, nothing else), only the data you use, no no-cache headers, contact MSC above 86,400 requests a day. We make 48 (two an hour), more if a run is doubled.
- A refused or empty hourly answer is logged (`eccc_swob`) and the last block stays; the app ages it by `observed_at`. A refused minute answer is logged ("minute record") and the block is built from hourly records alone. The app still reads only GitHub Pages.

### Never two runs at once
Both workflows share one concurrency group (`data-branch`) with `queue: max`: a run waits for the one in progress; up to 100 can wait; none is cancelled. GitHub's default (`queue: single`) would cancel a waiting run when another queues. `save_data.sh` also rebases and retries a refused push (tested locally).

### Nightly scoring after ECCC posts
ECCC does not document when a day's values appear in the climate-daily API. On 25 Nov 2026 at 03:51 UTC the row for 24 Nov existed but was empty. So scoring runs twice: 09:47 UTC (01:47 PST) and 15:47 UTC (07:47 PST). The second run rescores only if the first did not have yesterday's station values (`score.py --if-needed`). The shadow run will show which slot gets the data; move the times then. A run that had to use a saved copy for any download also does not count as scored (next section), so the second slot redoes it.

### Refusals
- Every failed call is a line in `refusals.jsonl` on the `data` branch (kinds in `backend/scripts/refusals.py`).
- Each run's page shows the refusals logged during that run (job summary).
- A source that could not be pulled is a warning, not a failed run: the run still publishes and saves. A run fails only if publishing, scoring or saving fails (GitHub emails the owner on failure).
- Shadow-run count: `uv run python backend/scripts/refusals.py --since <time>` on a checkout of `data`.
- Each refusal line also names the runner's cloud and region (`runner`, from `backend/ci/runner_info.sh`, which both nightly jobs and the hourly job print first). The internet address itself is not logged.

### Nightly: Open-Meteo rate-limit refusals (built 26 Nov 2026)
Why: on 25 Nov 2026 the 19:37 UTC nightly got "Daily API request limit exceeded" for all 18 Open-Meteo calls (another user of the runner's shared address had used the quota). It scored on saved copies, and the 23:49 UTC nightly then skipped as "already scored", so nothing retried.
1. `score.py` lists every download it could not refresh in `scores.json` as `downloads_stale`: `download` (`previous_runs`, `single_run`, `station`, `normal`), `source`, `day` for Single Runs, `why` (`limit` for an Open-Meteo rate-limit refusal, `error` for anything else) and `used` (the saved copy, if any).
2. `already_scored` is false while that list has entries, so any later nightly (the retry job, the second slot, a manual run) rescores.
3. After saving, `missing.py` lists the `limit` entries for today's issue date and sets the job output `om_refused`.
4. `om_refused=true` starts the `retry` job: the same steps on a new runner (each job is a new VM; our first 9 runs landed in 6 cloud regions), uploaded as `github-pages-retry`. Deploy uses the retry's site when there is one.
5. The retry job ends with `missing.py --fail-on-limit`: if rate-limit refusals still left data missing, the job fails, the run fails and GitHub emails the owner. The site and data from the retry are still saved and deployed.
- Never counted: Single Runs Open-Meteo answers it does not have ("not available", "No data is available"). They are logged as `single_run` as before, are not stale and never fail a run. A rate-limit refusal is never treated as "gone" (it is asked for again next night).
- Network errors are stale (a later nightly rescores) but do not start the retry or fail the run.
- Retrying on the same runner is pointless for daily refusals: the address stays refused until Open-Meteo's daily reset (UTC midnight, `RateLimiter.swift`).
- The hourly job has no retry: the next hourly run is already on a new runner, and sources not pulled are pulled then.

### Stale data
Unchanged from Stage 1: `kitimat.json` sets `stale: true` after 6 hours without a new pull, and the app also checks the times itself (`docs/JSON_SCHEMA.md`). There is no failure alert for missed runs yet (see "What starts the runs"). Second route (home Mac or Google Cloud VM) is a plan, not built: switch only if the shadow run shows refusals above about 1 in 20.

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
| Schedule | can be delayed at high load, busiest at the top of the hour; queued jobs may be dropped; runs on the default branch only | backup only (minute 17 and 47); runs started by `workflow_dispatch` |

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
- Measured cost (Open-Meteo's `X-RateLimit-Cost` header, 26 Nov 2026): a deterministic pull 1.0, GEFS 7.09, ECMWF ENS 11.66, one Previous Runs call 20.0, one Single Run 1.0; a full nightly 18 calls, 189.0 weighted (local test run). Weighting: https://github.com/open-meteo/open-meteo/blob/main/docs/api-rate-limiting.md (calls = max(1, variables / 10 x max(1, days / 14)), every ensemble member and every model counts as variables).
- Every counted call prints its cost and Open-Meteo's `X-RateLimit-Remaining`, `-Limit` and `-Window` in the job log (host, path and model only, never the query); each script ends with a total. Metadata files carry no such headers (not counted). A low "remaining" on a run's first call means other users of that address.
- GitHub runners share internet addresses with other users, and Open-Meteo counts limits per address ("Usage is generally shared by requests from the same public IP address", https://github.com/open-meteo/open-meteo/blob/main/docs/api-rate-limiting.md). That is the main risk; refusals are logged and counted in the shadow run.
- It happened on 25 Nov 2026: the 19:37 UTC nightly run got "Daily API request limit exceeded" for all 18 Open-Meteo calls, from a runner whose address others had used up. Scoring fell back to the saved copies (Previous Runs saved at 04:07 UTC); the 24 Nov Single Runs it could not get are fetched on a later night. The run took 27 min 48 s instead of under a minute because each call was retried 8 times with 4 to 18 s waits (88 s a call). Since 26 Nov, `openmeteo.get_json` gives up at once on the hourly and daily limits (or a `Retry-After` over 2 minutes) and retries only the minutely one; a refused call now costs one request.
- If refusals stay common after the nightly retry: Open-Meteo's terms suggest Cloudflare Workers ("we apply limits per Cloudflare user", https://open-meteo.com/en/terms, checked 26 Nov 2026) and its rate-limit note says Worker traffic "may be grouped by Worker identity instead" of by address. Researched 26 Nov 2026 as a failover route (Actions would call the Worker only after a direct refusal); on hold by owner decision, not built. The Worker still only starts runs and fetches no weather data.

## Test locally
`backend/ci/local_test.sh` runs the job scripts against a stand-in for GitHub (a bare repo in a scratch folder), with live data:

```bash
bash backend/ci/seed_data_branch.sh /tmp/wxc-seed
```

```bash
bash backend/ci/local_test.sh /tmp/wxc-ci /tmp/wxc-seed
```

It checks: `kitimat.json` is written and matches the schema; it is not committed to `main`; nightly re-downloads are not committed; skipped and forced scoring; simulated Open-Meteo refusals (below); a push race is rebased and retried; commit identities; sizes. It cannot test GitHub's scheduler, the Actions cache, permissions, Pages deployment or runner address limits; the first runs on GitHub check those. Workflow syntax: `actionlint` (config in `.github/actionlint.yaml`; it does not know `queue` yet).

Result 25 Nov 2026: all checks passed; hourly job 11 s, forced nightly 19 s on the development Mac.

Simulated refusals (added 26 Nov 2026): `backend/ci/fake_open_meteo/sitecustomize.py`, loaded only when that folder is on `PYTHONPATH` and `WXC_FAKE_OPEN_METEO` is set (never in the workflows), answers Open-Meteo calls locally: `daily` (HTTP 429 daily limit, as on 25 Nov) or `gone-runs` (Single Runs "not available"). Checks: the first job succeeds on saved copies and reports `om_refused=true`; an `--if-needed` rerun no longer skips; a retry that is still refused fails `missing.py --fail-on-limit`; a retry on a working address rescores, leaves nothing stale and passes; the next `--if-needed` run skips again; expected Single Runs gaps leave nothing stale and do not fail. Result 26 Nov 2026: 24 of 24 checks passed, against a copy of the real `data` branch.

## Working with the data locally
```bash
git fetch origin data && git worktree add ../weather-consensus-data data
```
A second folder next to the repo, read only: the workflows are the only writers. Do not push to `data` by hand while they run.
