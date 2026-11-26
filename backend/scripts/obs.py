"""Fetch the latest station observation for each live place with an approved
station (config/places.json `obs_station`) and save data/store/<place>/now.json.

Run from the repo root, before publish.py:
    uv run python backend/scripts/obs.py
    uv run python backend/scripts/obs.py --place kitimat

How and why: backend/wxc/obs.py. Failed tries go to data/store/refusals.jsonl.
Exit code 1 if an approved station could not be read (the last block stays).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from wxc.obs import fetch_now  # noqa: E402

STORE = ROOT / "data" / "store"
LIVE = {"stage1"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--place")
    args = ap.parse_args()
    places = json.loads((ROOT / "config" / "places.json").read_text())["places"]
    places = ([p for p in places if p["id"] == args.place] if args.place
              else [p for p in places if p.get("status") in LIVE])
    if not places:
        sys.exit(f"unknown place: {args.place}")

    ok = True
    for place in places:
        st = place.get("obs_station")
        if not st:
            print(f"{place['name']}: no approved station, no observations")
            continue
        b = fetch_now(place, STORE)
        if b is None:
            print(f"{place['name']}: {st['name']}: nothing new saved")
            ok = False
            continue
        print(f"{place['name']}: {st['name']} ({b['station']['distance_km']} km), "
              f"observed {b['observed_at']} ({b['values_from']['temp']} record): "
              f"{b['temp']} deg C, wind {b['wind_kmh']} km/h ({b['values_from']['wind']}), "
              f"so far high {b['high_so_far']} low {b['low_so_far']} "
              f"precip {b['precip_so_far_mm']} mm ({b['so_far_hours']} h)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
