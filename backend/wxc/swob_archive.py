"""Archive of the approved station's real-time SWOB hourly records (shadow only).

Why (owner decision, 27 Nov 2026, after the hourly and conditions research,
docs/research/HOURLY_AND_CONDITIONS.md): ECCC's archived climate-hourly data
for Kitimat Forest Ave has no gusts, no rain-sensor amount and no snow depth.
The real-time SWOB records carry them, but MSC GeoMet keeps only about 30 days
(oldest record 29 Oct 2026 when read on 27 Nov 2026). Saving every hourly
record keeps them for gust, snow-vs-rain and conditions scoring later. Nothing
here is published or shown in the app.

What is saved: every field of every hourly record (not minute records), as
ECCC sends it, made compact without losing anything:
- Fields whose value is almost always the same (units "<element>-uom",
  station names and ids, data provider, dataset, quality flags "-qa" (100 =
  passed) and data flags with their code sources, the station's coordinates)
  are kept once per place in data/store/<place>/swob/fields.json ("const",
  the first value seen). A record whose value differs keeps that field inline,
  a record without one of them lists it in "absent", and each record names
  the set of constant fields known when it was written ("c", an index into
  "sets"), so nothing is lost and nothing is added.
- Everything else goes inline, one JSON line per record, in
  data/store/<place>/swob/hourly-<YYYY-MM>.jsonl (by observation month, UTC),
  sorted by time, one line per observation time. A record ECCC sends again
  with different content replaces the saved line.
- expand() rebuilds the full record (tests: rebuilt == received).

Which records are asked for, each hourly run (one request, more pages only when
needed; all properties, so about 6.6 KB a record):
- Normally the last LOOKBACK_H hours (records post 0 to 6 minutes after the
  hour; a late one is caught next hour).
- Back to the oldest missing hour of the last REPAIR_H hours, so a refused run
  or a late record is filled in on a later run. Older gaps are left as gaps.
- First run, or after an outage: back to the newest saved record, at most
  FIRST_DAYS days (what the real-time service still has).

Rules as for the "now" block (backend/wxc/obs.py): only the place's approved
station (`obs_station`), only ECCC's own network (provider "MSC"). A refused
request is logged as source "eccc_swob_archive" and leaves the archive as it
was. Usage policy (https://eccc-msc.github.io/open-data/usage-policy/readme_en,
checked 25 Nov 2026): one more request an hour, 72 a day in all with the now
block, against a 86,400 contact threshold.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import time
import urllib.parse
from pathlib import Path

from .obs import ECCC_PROVIDER, URL, _time, get_json
from .refresh import _write_json, iso, refusal_logger

SOURCE_ID = "eccc_swob_archive"
LOOKBACK_H = 3      # always ask for at least the last 3 hours
REPAIR_H = 48       # re-ask for missing hours this recent
FIRST_DAYS = 29     # the real-time service keeps about 30 days
PAGE = 100          # records per request (the service's page size we use)
TIME_KEY = "date_tm-value"

# Fields that hold the same value in (almost) every record of a station.
CONST_SUFFIXES = ("-uom", "-qa", "-data_flag-value", "-data_flag-code_src", "-data_flag-uom")
CONST_KEYS = ("stn_nam-value", "tc_id-value", "wmo_synop_id-value", "data_pvdr-value",
              "msc_id-value", "clim_id-value", "_is-minutely_obs-value", "dataset")


def is_const(key: str) -> bool:
    return key in CONST_KEYS or key.endswith(CONST_SUFFIXES)


def folder(store: Path, place_id: str) -> Path:
    return store / place_id / "swob"


def month_file(store: Path, place_id: str, t: dt.datetime) -> Path:
    return folder(store, place_id) / f"hourly-{t:%Y-%m}.jsonl"


def _iso_t(t: dt.datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


# --- compact form ------------------------------------------------------------

def compact(props: dict, geometry, fields: dict) -> dict:
    """One record as saved: {"t", "c", "v", "absent"?, "geometry"?}.
    `fields` (fields.json) holds "const" (first value seen per constant field)
    and "sets" (the constant fields known when a record was written; "c" is
    the index of that list, so a field learned later is never added to an
    older record). Fields seen for the first time are added to `fields`."""
    const = fields.setdefault("const", {})
    sets = fields.setdefault("sets", [])
    for k in sorted(props):
        if is_const(k) and k not in const:
            const[k] = props[k]
    keys = sorted(const)
    if not sets or sets[-1] != keys:
        sets.append(keys)
    inline = {k: props[k] for k in sorted(props) if not (is_const(k) and const[k] == props[k])}
    t = _time(props)
    rec = {"t": _iso_t(t) if t else props.get(TIME_KEY), "c": len(sets) - 1, "v": inline}
    absent = [k for k in keys if k not in props]
    if absent:
        rec["absent"] = absent
    if geometry is not None:
        fields.setdefault("geometry", geometry)
        if fields["geometry"] != geometry:
            rec["geometry"] = geometry
    return rec


def expand(rec: dict, fields: dict) -> tuple[dict, dict | None]:
    """The full record (properties, geometry) from a saved line: the constant
    fields known when it was written, less the ones it did not carry, plus its
    own fields."""
    gone = set(rec.get("absent", []))
    const = fields.get("const", {})
    props = {k: const[k] for k in fields["sets"][rec["c"]] if k not in gone}
    props.update(rec["v"])
    return props, rec.get("geometry", fields.get("geometry"))


# --- reading and writing the archive -----------------------------------------

def load_fields(store: Path, place_id: str) -> dict:
    p = folder(store, place_id) / "fields.json"
    return json.loads(p.read_text()) if p.exists() else {}


def read_month(path: Path) -> dict[str, dict]:
    out = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if line.strip():
                rec = json.loads(line)
                out[rec["t"]] = rec
    return out


def saved_times(store: Path, place_id: str, since: dt.datetime) -> set[str]:
    """Observation times saved at or after `since` (this month and earlier ones it reaches)."""
    out: set[str] = set()
    for p in sorted(folder(store, place_id).glob("hourly-*.jsonl")):
        month = dt.datetime.strptime(p.stem[len("hourly-"):], "%Y-%m").replace(tzinfo=dt.timezone.utc)
        nxt = (month + dt.timedelta(days=32)).replace(day=1)
        if nxt <= since:
            continue
        out |= {t for t in read_month(p) if t >= _iso_t(since)}
    return out


def _write_lines(path: Path, recs: dict[str, dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text("".join(json.dumps(recs[t], separators=(",", ":"), sort_keys=True) + "\n"
                           for t in sorted(recs)))
    os.replace(tmp, path)


def save_records(store: Path, place_id: str, features: list[dict]) -> dict:
    """Merge hourly records into the month files. Returns counts."""
    fields = load_fields(store, place_id)
    before = json.dumps(fields, sort_keys=True)
    by_month: dict[Path, dict] = {}
    added = changed = 0
    for f in features:
        props = f["properties"]
        t = _time(props)
        if t is None:
            continue
        path = month_file(store, place_id, t)
        recs = by_month.setdefault(path, read_month(path))
        old = recs.get(_iso_t(t))
        if old is not None and expand(old, fields) == (props, f.get("geometry")):
            continue  # already saved exactly
        rec = compact(props, f.get("geometry"), fields)
        added += old is None
        changed += old is not None
        recs[rec["t"]] = rec
    for path, recs in by_month.items():
        _write_lines(path, recs)
    if json.dumps(fields, sort_keys=True) != before:
        _write_json(folder(store, place_id) / "fields.json", fields)
    return {"added": added, "changed": changed}


# --- what to ask for -----------------------------------------------------------

def start_time(store: Path, place_id: str, now: int) -> dt.datetime:
    """Oldest observation time to ask for this run."""
    t_now = dt.datetime.fromtimestamp(now - now % 3600, dt.timezone.utc)
    floor = t_now - dt.timedelta(days=FIRST_DAYS)
    saved = saved_times(store, place_id, floor)
    if not saved:
        return floor
    newest = dt.datetime.strptime(max(saved), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    since = min(t_now - dt.timedelta(hours=LOOKBACK_H), newest + dt.timedelta(hours=1))
    # the oldest missing whole hour of the last REPAIR_H hours, between the
    # oldest and the newest saved record in that span (before the archive
    # began nothing is missing)
    repair_from = _iso_t(max(t_now - dt.timedelta(hours=REPAIR_H), floor))
    recent = [t for t in saved if t >= repair_from]
    h = (dt.datetime.strptime(min(recent), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
         if recent else newest + dt.timedelta(hours=1))
    while h <= newest:
        if _iso_t(h) not in saved:
            since = min(since, h)
            break
        h += dt.timedelta(hours=1)
    return max(since, floor)


def query_url(climate_id: str, since: dt.datetime, offset: int = 0) -> str:
    """Hourly records since `since`, oldest first, every field."""
    q = {"f": "json", "clim_id-value": climate_id, "_is-minutely_obs-value": "false",
         "datetime": f"{since:%Y-%m-%dT%H:%M:%SZ}/..", "sortby": TIME_KEY,
         "limit": PAGE, "offset": offset}
    return URL + "?" + urllib.parse.urlencode(q)


def archive(place: dict, store: Path, now: int | None = None, get=get_json,
            echo=print) -> dict | None:
    """Fetch and save the approved station's hourly records. Returns counts,
    or None when the place has no station or the request was refused."""
    now = int(time.time() if now is None else now)
    station = place.get("obs_station")
    if not station:
        return None
    pid = place["id"]
    log = refusal_logger(store, pid, echo)
    since = start_time(store, pid, now)
    feats, offset = [], 0
    while True:
        try:
            payload = get(query_url(station["climate_id"], since, offset),
                          log=lambda k, d: log(SOURCE_ID, k, d))
        except Exception as e:
            log(SOURCE_ID, "gave_up", e)
            return None
        page = [f for f in payload.get("features", []) or []
                if isinstance(f, dict) and isinstance(f.get("properties"), dict)]
        feats += page
        if len(page) < PAGE:
            break
        offset += len(page)
    keep = [f for f in feats
            if str(f["properties"].get("clim_id-value")) == station["climate_id"]
            and f["properties"].get("_is-minutely_obs-value") is False
            and f["properties"].get("data_pvdr-value") == ECCC_PROVIDER
            and _time(f["properties"]) is not None]
    counts = save_records(store, pid, keep)
    counts.update(asked_from=_iso_t(since), received=len(feats), kept=len(keep))
    if not keep:
        log(SOURCE_ID, "obs", f"no hourly record for {station['climate_id']} since {_iso_t(since)}")
    return counts
