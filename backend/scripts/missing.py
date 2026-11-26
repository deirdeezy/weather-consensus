"""After a nightly run: did Open-Meteo rate-limit refusals leave data missing?

Run from the repo root (the workflows do, after score.py):
    uv run python backend/scripts/missing.py                  # report, exit 0
    uv run python backend/scripts/missing.py --fail-on-limit  # exit 1 if any

Reads data/store/<place>/scores.json for today's issue date and lists
downloads_stale (backend/wxc/score.py). Only entries with why "limit" count:
Open-Meteo refused them for a rate limit, so a fresh runner (another internet
address) may get them. Single Runs Open-Meteo answered it does not have are
expected gaps and are never listed. Network errors are listed but do not count.

With GITHUB_OUTPUT set (GitHub Actions), writes om_refused=true|false for the
retry job in .github/workflows/nightly.yml.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from wxc.score import issue_date_now, limit_losses  # noqa: E402

STORE = ROOT / "data" / "store"
LIVE = {"stage1"}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--issue", type=dt.date.fromisoformat, help="issue date, default today")
    ap.add_argument("--store", type=Path, default=STORE)
    ap.add_argument("--fail-on-limit", action="store_true",
                    help="exit 1 if rate-limit refusals left data missing")
    args = ap.parse_args(argv)

    places = json.loads((ROOT / "config" / "places.json").read_text())["places"]
    issue = args.issue or issue_date_now()
    lost = {}
    for p in places:
        if p.get("status") in LIVE:
            got = limit_losses(args.store, p["id"], issue)
            if got:
                lost[p["id"]] = got
    for pid, items in lost.items():
        print(f"{pid}: {len(items)} downloads refused for a rate limit (issue date {issue}):")
        for x in items:
            print(f"  {x['download']} {x['source']}" + (f" {x['day']}" if x.get("day") else "")
                  + (f", used {x['used']}" if x.get("used") else ", nothing saved to use"))
    if not lost:
        print(f"No data missing from Open-Meteo rate-limit refusals (issue date {issue}).")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"om_refused={'true' if lost else 'false'}\n")
    if lost and args.fail_on_limit:
        print("::error::Open-Meteo rate-limit refusals left data missing after the retry")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
