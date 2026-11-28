"""Nightly: score sources against the station, update habit fixes and weights.

Run from the repo root:
    uv run python backend/scripts/score.py                      # all live places
    uv run python backend/scripts/score.py --place kitimat
    uv run python backend/scripts/score.py --issue 2026-11-25   # as known on a date
    uv run python backend/scripts/score.py --if-needed          # skip places already scored
                                                                # with yesterday's station data

Writes data/store/<place>/scores.json (for publish.py) and
live_scores.csv (our stored pulls vs the station). How: backend/wxc/score.py.
Exit code 1 if a place could not be scored, including when the new scores
were not good enough to replace the last good ones (backend/wxc/score.py,
why_unusable): then scores.json is left as it was and the reasons are in
scores_rejected.json and the refusal log.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from wxc import openmeteo as om  # noqa: E402
from wxc import hourly, nowcast  # noqa: E402
from wxc.score import already_scored, issue_date_now, score  # noqa: E402

STORE = ROOT / "data" / "store"
LIVE = {"stage1"}


def summary_lines(s: dict) -> list[str]:
    """What the job log shows about new scores. Never fails on missing parts."""
    out = [f"issue date {s.get('issue_date')}, station data through {s.get('obs_through')}"]
    missing = s.get("sources_missing") or []
    out.append(f"sources with history {len(s.get('sources_with_history') or [])}"
               + (f", missing: {', '.join(missing)}" if missing else ""))
    d1 = (s.get("leads") or {}).get("1") or {}
    for var in ("tmax", "tmin"):
        v = d1.get(var)
        if not v:
            out.append(f"day 1 {var}: no stats")
            continue
        ws = sorted(((x.get("weight") or 0, m) for m, x in (v.get("sources") or {}).items()), reverse=True)
        out.append(f"day 1 {var}: consensus recent miss {v.get('consensus_mae')} deg C; weights "
                   + ", ".join(f"{m} {w:.0%}" for w, m in ws))
    for x in s.get("downloads_stale") or []:
        out.append(f"not refreshed ({x.get('why')}): {x.get('download')} {x.get('source')}"
                   + (f" {x['day']}" if x.get("day") else "") + (f", used {x['used']}" if x.get("used") else ""))
    return out


def score_now_log(place: dict) -> None:
    """The "now" log against the station (backend/wxc/nowcast.py): every night,
    whether or not the forecast scores are due. Never fails the run."""
    try:
        r = nowcast.score(STORE, place["id"], int(time.time()))
    except Exception as e:
        print(f"  now log not scored: {e}")
        return
    if r is None:
        print("  now log: nothing logged yet")
        return
    for L in r["leads"]:
        t, w = L["temp"], L["rain_or_snow"]
        print(f"  now log lead {L['lead']} h: temp miss {t['miss']} ({t['n']}), rain or snow "
              f"hit {w['hit_rate']} false alarm {w['false_alarm_ratio']} ({w['n']}, {w['wet_hours']} wet)")


def score_hourly(place: dict, cfg: dict, issue) -> None:
    """Hourly habit fix by hour of day (backend/wxc/hourly.py) from the saved
    Previous Runs copies and station records: nothing new is downloaded.
    Never fails the run."""
    try:
        r = hourly.score(STORE, place, cfg, issue, int(time.time()))
    except Exception as e:
        print(f"  hourly habit fix not computed: {e}")
        return
    if r is None:
        print("  hourly habit fix: no Previous Runs copies or station records yet")
        return
    cells = sum(1 for m in r["sources"].values() for L in m.values() for b in L["bias"] if b is not None)
    print(f"  hourly habit fix: {len(r['sources'])} sources, {cells} source x lead x hour cells "
          f"(station {r['station_from']} to {r['station_to']})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--place")
    ap.add_argument("--issue", type=dt.date.fromisoformat, help="issue date, default today")
    ap.add_argument("--if-needed", action="store_true",
                    help="skip a place whose scores.json already has yesterday's station data")
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
        score_now_log(place)
        issue = args.issue or issue_date_now()
        if args.if_needed and already_scored(STORE, place["id"], issue):
            print(f"  already scored for {issue} with station data through the day before"
                  " and every download fresh; skipped")
            score_hourly(place, cfg, issue)
            continue
        try:
            r = score(place, cfg, STORE, issue=issue)
        except Exception as e:
            print(f"  not scored: {e}")
            ok = False
            continue
        for line in summary_lines(r["scores"]):
            print("  " + line)
        print(f"  live pulls scored: {len(r['live'])} rows")
        score_hourly(place, cfg, issue)
    print(om.usage_summary())
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
