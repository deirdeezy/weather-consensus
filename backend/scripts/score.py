"""Nightly: score sources against the station, update habit fixes and weights.

Run from the repo root:
    uv run python backend/scripts/score.py                      # all live places
    uv run python backend/scripts/score.py --place kitimat
    uv run python backend/scripts/score.py --issue 2026-11-25   # as known on a date

Writes data/store/<place>/scores.json (for publish.py) and
live_scores.csv (our stored pulls vs the station). How: backend/wxc/score.py.
Exit code 1 if a place could not be scored.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from wxc.score import score  # noqa: E402

STORE = ROOT / "data" / "store"
LIVE = {"stage1"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--place")
    ap.add_argument("--issue", type=dt.date.fromisoformat, help="issue date, default today")
    args = ap.parse_args()

    cfg = json.loads((ROOT / "config" / "sources.json").read_text())
    places = json.loads((ROOT / "config" / "places.json").read_text())["places"]
    places = ([p for p in places if p["id"] == args.place] if args.place
              else [p for p in places if p.get("status") in LIVE])
    if not places:
        sys.exit(f"unknown place: {args.place}")

    ok = True
    for place in places:
        print(f"{place['name']}:")
        try:
            r = score(place, cfg, STORE, issue=args.issue)
        except Exception as e:
            print(f"  not scored: {e}")
            ok = False
            continue
        s = r["scores"]
        print(f"  issue date {s['issue_date']}, station data through {s['obs_through']}")
        print(f"  sources with history {len(s['sources_with_history'])}"
              + (f", missing: {', '.join(s['sources_missing'])}" if s["sources_missing"] else ""))
        for var in ("tmax", "tmin"):
            d1 = s["leads"]["1"][var]
            ws = sorted(((v["weight"] or 0, m) for m, v in d1["sources"].items()), reverse=True)
            print(f"  day 1 {var}: consensus recent miss {d1['consensus_mae']} deg C; weights "
                  + ", ".join(f"{m} {w:.0%}" for w, m in ws))
        print(f"  live pulls scored: {len(r['live'])} rows")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
