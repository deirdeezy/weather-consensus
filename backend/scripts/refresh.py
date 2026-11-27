"""Pull every source that has posted a new run since our last pull.

Run from the repo root:
    uv run python backend/scripts/refresh.py              # all live places
    uv run python backend/scripts/refresh.py --dry-run    # only show what is new
    uv run python backend/scripts/refresh.py --place kitimat

Raw pulls go to data/store/<place>/<YYYY-MM-DD>/, failed tries to
data/store/refusals.jsonl. How new runs are found: backend/wxc/refresh.py.
Exit code 1 if any source could not be pulled.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from wxc import openmeteo as om  # noqa: E402
from wxc.refresh import refresh  # noqa: E402

STORE = ROOT / "data" / "store"
LIVE = {"stage1"}  # place statuses that get refreshed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--place", help="place id from config/places.json")
    ap.add_argument("--dry-run", action="store_true", help="check for new runs, pull nothing")
    args = ap.parse_args()

    cfg = json.loads((ROOT / "config" / "sources.json").read_text())
    places = json.loads((ROOT / "config" / "places.json").read_text())["places"]
    if args.place:
        places = [p for p in places if p["id"] == args.place]
        if not places:
            sys.exit(f"unknown place: {args.place}")
    else:
        places = [p for p in places if p.get("status") in LIVE]

    failed = False
    for place in places:
        print(f"{place['name']}:")
        r = refresh(place, cfg, STORE, dry_run=args.dry_run)
        print(f"  checked {r['checked']}, new {len(r['new'])}: {', '.join(r['new']) or 'none'}")
        if not args.dry_run:
            print(f"  pulled {len(r['pulled'])}, failed {len(r['failed'])}"
                  + (f": {', '.join(r['failed'])}" if r["failed"] else ""))
            print(f"  extra hourly variables (shadow): saved {len(r['extra'])}, failed {len(r['extra_failed'])}"
                  + (f": {', '.join(r['extra_failed'])}" if r["extra_failed"] else ""))
        failed |= bool(r["failed"])
    print(om.usage_summary())
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
