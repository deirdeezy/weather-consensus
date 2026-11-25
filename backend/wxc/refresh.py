"""Hourly refresh: pull only the sources that posted a new run.

1. Read Open-Meteo model-update metadata for every source. These calls do not
   count toward the API limits (https://open-meteo.com/en/docs/model-updates).
2. A source is new when any of its metadata paths shows a run newer than the
   one we last pulled, and that run has been on the API for 10 minutes
   (Open-Meteo's advice on the same page).
3. Pull each new source once (live forecast or Ensemble API), save the raw
   answer under data/store/<place>/<YYYY-MM-DD>/, then record the run in
   data/store/<place>/state.json.
4. Every failed try and every source we could not pull is appended to
   data/store/refusals.jsonl.

If no metadata path of a source can be read, the source is pulled anyway once
our last pull is FALLBACK_HOURS old, so a metadata outage cannot freeze us.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import time
from dataclasses import dataclass
from pathlib import Path

from . import openmeteo as om

AVAILABLE_WAIT_S = 600  # Open-Meteo: wait 10 minutes after availability time
FALLBACK_HOURS = 6
FORECAST_DAYS = 16  # API maximum; covers day 14 after the climate-day shift
META_TRIES = 3


@dataclass(frozen=True)
class Source:
    id: str
    kind: str  # "deterministic" or "ensemble"
    meta_paths: tuple[str, ...]

    @property
    def ensemble(self) -> bool:
        return self.kind == "ensemble"


def sources_from_config(cfg: dict) -> list[Source]:
    out = [Source(m, "deterministic", tuple(cfg["meta_paths"][m])) for m in cfg["deterministic_pool"]]
    for m, e in cfg["ensembles"].items():
        if not m.startswith("_"):
            out.append(Source(m, "ensemble", (e["meta_path"],)))
    return out


def iso(unix: int) -> str:
    return dt.datetime.fromtimestamp(unix, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _usable(m) -> bool:
    return isinstance(m, dict) and all(
        isinstance(m.get(k), (int, float))
        for k in ("last_run_initialisation_time", "last_run_availability_time"))


def read_meta(sources, get, log) -> dict:
    """Metadata per (path, ensemble). None where it could not be read."""
    out: dict = {}
    for s in sources:
        for p in s.meta_paths:
            key = (p, s.ensemble)
            if key in out:
                continue
            try:
                m = get(om.meta_url(p, s.ensemble), tries=META_TRIES, log=lambda k, d: None)
            except Exception as e:
                m = None
                log(s.id, "meta", f"{p}: {e}")
            else:
                if not _usable(m):
                    log(s.id, "meta", f"{p}: unexpected metadata")
                    m = None
            out[key] = m
    return out


def decide(sources, meta: dict, state: dict, now: int) -> list[tuple[Source, dict]]:
    """Sources to pull now, each with its ready run times per metadata path."""
    todo = []
    for s in sources:
        seen = state.get(s.id, {})
        had = seen.get("runs", {})
        ready, readable = {}, False
        for p in s.meta_paths:
            m = meta.get((p, s.ensemble))
            if not m:
                continue
            readable = True
            if now >= m["last_run_availability_time"] + AVAILABLE_WAIT_S:
                ready[p] = int(m["last_run_initialisation_time"])
        if readable:
            new = any(t > had.get(p, 0) for p, t in ready.items())
        else:
            new = now - seen.get("fetched_unix", 0) >= FALLBACK_HOURS * 3600
        if new:
            todo.append((s, ready))
    return todo


def _write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, separators=(",", ":")))
    os.replace(tmp, path)  # never leave a half-written file


def save_raw(store: Path, place_id: str, s: Source, url: str, payload: dict,
             runs: dict, now: int) -> Path:
    t = dt.datetime.fromtimestamp(now, dt.timezone.utc)
    path = store / place_id / t.strftime("%Y-%m-%d") / f"{t:%H%M%S}Z_{s.id}.json"
    _write_json(path, {
        "source": s.id, "kind": s.kind, "place": place_id, "fetched_at": iso(now),
        "runs": {p: iso(v) for p, v in runs.items()}, "url": url,
        "credit": om.CREDIT, "response": payload,
    })
    return path


def load_state(store: Path, place_id: str) -> dict:
    p = store / place_id / "state.json"
    return json.loads(p.read_text()) if p.exists() else {}


def refresh(place: dict, cfg: dict, store: Path, now: int | None = None,
            get=om.get_json, echo=print, dry_run: bool = False) -> dict:
    """One refresh pass for one place. Returns what was pulled and what failed."""
    now = int(time.time() if now is None else now)
    pid = place["id"]
    refusals = store / "refusals.jsonl"

    def log(source: str, kind: str, detail: str) -> None:
        rec = {"time": iso(int(time.time())), "place": pid, "source": source,
               "kind": kind, "detail": str(detail)[:300]}
        refusals.parent.mkdir(parents=True, exist_ok=True)
        with refusals.open("a") as f:
            f.write(json.dumps(rec) + "\n")
        echo(f"  refused  {source}: {kind}: {rec['detail']}")

    sources = sources_from_config(cfg)
    meta = read_meta(sources, get, log)
    state = load_state(store, pid)
    todo = decide(sources, meta, state, now)
    result = {"place": pid, "checked": len(sources), "new": [s.id for s, _ in todo],
              "pulled": [], "failed": []}
    if dry_run:
        return result

    for s, ready in todo:
        build = om.ensemble_url if s.ensemble else om.forecast_url
        url = build(place["lat"], place["lon"], place["elevation_m"], s.id, FORECAST_DAYS)
        try:
            payload = get(url, log=lambda k, d, sid=s.id: log(sid, k, d))
        except om.LimitRefused as e:
            log(s.id, "gave_up", e)
            result["failed"].append(s.id)
            continue
        except Exception as e:
            log(s.id, "error", e)
            result["failed"].append(s.id)
            continue
        path = save_raw(store, pid, s, url, payload, ready, now)
        had = state.get(s.id, {}).get("runs", {})
        runs = {p: max(t, had.get(p, 0)) for p, t in {**had, **ready}.items()}
        state[s.id] = {"runs": runs, "fetched_unix": now, "fetched_at": iso(now),
                       "file": str(path.relative_to(store))}
        _write_json(store / pid / "state.json", state)  # save after each pull
        result["pulled"].append(s.id)
        echo(f"  pulled   {s.id} -> {path.relative_to(store)}")
    return result
