"""Write the latest Consensus for each live place to public/<place>.json.

Run from the repo root, after refresh.py (and score.py at least once):
    uv run python backend/scripts/publish.py                 # all live places
    uv run python backend/scripts/publish.py --place kitimat

File format: docs/JSON_SCHEMA.md. How: backend/wxc/publish.py.
Problems are logged to data/store/refusals.jsonl. Exit code 1 if a place
could not be published.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from wxc.publish import publish  # noqa: E402

STORE = ROOT / "data" / "store"
OUT = ROOT / "public"
LIVE = {"stage1"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--place")
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
            doc = publish(place, cfg, STORE, OUT)
        except Exception as e:
            print(f"  not published: {e}")
            ok = False
            continue
        d1 = doc["days"][0]
        size = (OUT / f"{place['id']}.json").stat().st_size
        print(f"  issued {doc['issued_at']}, newest run {doc['newest_run_at']}, "
              f"stale {doc['stale']}, weights as of {doc['weights_as_of']}")
        print(f"  day 1 ({d1['date']}): high {d1['high']}, low {d1['low']}, "
              f"precip {d1['precip_mm']} mm ({d1['precip_chance']}%), "
              f"Certainty {d1['certainty']}% {d1['tier']}")
        print(f"  wrote public/{place['id']}.json ({size:,} bytes)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
