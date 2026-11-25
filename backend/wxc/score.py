"""Nightly scoring: station truth in, habit fixes and weights out.

1. Pull ECCC daily observations for the place's truth station.
2. Pull Open-Meteo Previous Runs for every deterministic source, leads 1 to 7,
   over the last HISTORY_DAYS. This is the same kind of history the backtest
   uses, so live weights come from exactly the tested method. Our own stored
   pulls only start on 25 Nov 2026 (UTC); once they cover 60+ days we can
   test switching to them (backtest first).
3. Work out, as known on the issue date, each source's habit fix and error at
   each lead (consensus.temperature_stats / precip_stats) and write
   data/store/<place>/scores.json for publish.py.
4. Match every stored live pull to the station by lead and write
   data/store/<place>/live_scores.csv (the shadow-run record).

If a download fails, the last saved copy is used and the failure is logged in
data/store/refusals.jsonl.
"""
from __future__ import annotations

import datetime as dt
import json
import math
import time
from pathlib import Path

import pandas as pd

from . import consensus as cs
from . import eccc
from . import openmeteo as om
from .daily import CLIMATE_DAY_OFFSET_H, hourly_to_daily, previous_runs_daily
from .refresh import _write_json, iso, refusal_logger

HISTORY_DAYS = 200  # 60-day windows on top of 60 + 30 days of windows, plus leads
LEADS = range(1, 8)  # Previous Runs API offers previous_day1 to previous_day7
LIVE_LEADS = range(1, 15)


def issue_date_now(now: int | None = None) -> dt.date:
    """Today's ECCC climate date (UTC shifted by the climate-day offset)."""
    t = dt.datetime.fromtimestamp(time.time() if now is None else now, dt.timezone.utc)
    return (t + dt.timedelta(hours=CLIMATE_DAY_OFFSET_H)).date()


def _num(x):
    try:
        x = float(x)
    except (TypeError, ValueError):
        return None
    return None if math.isnan(x) or math.isinf(x) else round(x, 4)


# --- downloads ---------------------------------------------------------------

def _fetch_or_stale(name: str, path: Path, fetch, log) -> dict | None:
    """Download and save; on failure, fall back to the last saved copy."""
    try:
        payload = fetch()
    except Exception as e:
        log(name, "error", e)
        if path.exists():
            log(name, "used_stale", f"using saved copy from {iso(int(path.stat().st_mtime))}")
            return json.loads(path.read_text())
        return None
    _write_json(path, payload)
    return payload


def fetch_history(place: dict, cfg: dict, store: Path, issue: dt.date,
                  get=om.get_json, fetch_obs=eccc.fetch_daily, log=None) -> tuple:
    """Station observations and Previous Runs for every deterministic source."""
    hist = store / place["id"] / "history"
    start = (issue - dt.timedelta(days=HISTORY_DAYS)).isoformat()
    end = (issue - dt.timedelta(days=1)).isoformat()
    cid = place["truth"]["climate_id"]
    obs = _fetch_or_stale(f"eccc_{cid}", hist / f"eccc_daily_{cid}.json",
                          lambda: fetch_obs(cid, start, issue.isoformat()), log)
    prev = {}
    for m in cfg["deterministic_pool"]:
        url = om.previous_runs_url(place["lat"], place["lon"], place["elevation_m"], m, start, end,
                                   leads=LEADS)
        p = _fetch_or_stale(m, hist / f"prev_{m}.json",
                            lambda: get(url, log=lambda k, d, m=m: log(m, k, d)), log)
        if p is not None:
            prev[m] = p
    return obs, prev


# --- habit fixes and weights ------------------------------------------------

def build_scores(obs: pd.DataFrame, prev: dict, pool: list[str], issue: dt.date) -> dict:
    """Stats per lead and variable as known on the issue date."""
    models = {m: previous_runs_daily(p, leads=LEADS) for m, p in prev.items()}
    leads_out = {}
    for lead in LEADS:
        out = {}
        for var in ("tmax", "tmin", "pcp"):
            F = pd.DataFrame({m: d[lead][var] for m, d in models.items() if lead in d})
            F = F.reindex(columns=pool)
            if var == "pcp":
                st = cs.precip_stats(F, obs[var], lead, issue)
                w = cs.weights_from_error(st["mae"], guardrails=False)
                out[var] = {"sources": {m: {"mae": _num(st["mae"][m]), "weight": _num(w[m])}
                                        for m in pool}}
            else:
                st = cs.temperature_stats(F, obs[var], lead, issue)
                w = cs.weights_from_error(st["mse"])
                out[var] = {"consensus_mae": _num(st["consensus_mae"]),
                            "spread_ref": _num(st["spread_ref"]),
                            "sources": {m: {"habit_fix": _num(st["habit_fix"][m]),
                                            "mse": _num(st["mse"][m]), "weight": _num(w[m])}
                                        for m in pool}}
        leads_out[str(lead)] = out
    seen = obs[(obs.index < issue)].dropna(how="all")
    return {
        "issue_date": issue.isoformat(),
        "obs_through": seen.index.max().isoformat() if len(seen) else None,
        "sources_with_history": sorted(models),
        "sources_missing": [m for m in pool if m not in models],
        "method": {"history": "Open-Meteo Previous Runs API", "bias_days": cs.BIAS_DAYS,
                   "weight_days": cs.WEIGHT_DAYS, "floor": cs.FLOOR, "cap": cs.CAP,
                   "climate_day_offset_h": CLIMATE_DAY_OFFSET_H,
                   "weight_note": "weight = share if every source has a forecast; "
                                  "publish re-splits among sources present"},
        "leads": leads_out,
    }


# --- our own stored pulls vs the station ------------------------------------

def _daily_from_pull(rec: dict) -> pd.DataFrame | None:
    h = rec["response"]["hourly"]
    if rec["kind"] == "deterministic":
        if "temperature_2m" not in h:
            return None
        return hourly_to_daily(h["time"], h["temperature_2m"], h.get("precipitation"))
    # ensemble: daily values per member, then the member average
    days = []
    for k in h:
        if k.startswith("temperature_2m"):
            suffix = k[len("temperature_2m"):]
            days.append(hourly_to_daily(h["time"], h[k], h.get("precipitation" + suffix)))
    return pd.concat(days).groupby(level=0).mean() if days else None


def live_scores(store: Path, place_id: str, obs: pd.DataFrame) -> pd.DataFrame:
    """Every stored pull's daily forecast next to the station, by lead."""
    rows = []
    for f in sorted((store / place_id).glob("????-??-??/*.json")):
        rec = json.loads(f.read_text())
        daily = _daily_from_pull(rec)
        if daily is None:
            continue
        fetched = dt.datetime.strptime(rec["fetched_at"], "%Y-%m-%dT%H:%M:%SZ")
        issue = (fetched + dt.timedelta(hours=CLIMATE_DAY_OFFSET_H)).date()
        for target, r in daily.iterrows():
            lead = (target - issue).days
            if lead not in LIVE_LEADS or target not in obs.index:
                continue
            for var in ("tmax", "tmin", "pcp"):
                fc, ob = r.get(var), obs.at[target, var]
                if pd.notna(fc) and pd.notna(ob):
                    rows.append({"issue_date": issue, "fetched_at": rec["fetched_at"],
                                 "source": rec["source"], "kind": rec["kind"], "lead": lead,
                                 "target_date": target, "var": var, "forecast": round(fc, 2),
                                 "obs": ob, "error": round(fc - ob, 2)})
    cols = ["issue_date", "fetched_at", "source", "kind", "lead", "target_date", "var",
            "forecast", "obs", "error"]
    return pd.DataFrame(rows, columns=cols)


# --- the nightly job --------------------------------------------------------

def score(place: dict, cfg: dict, store: Path, issue: dt.date | None = None,
          get=om.get_json, fetch_obs=eccc.fetch_daily, echo=print) -> dict:
    issue = issue or issue_date_now()
    pid = place["id"]
    log = refusal_logger(store, pid, echo)
    obs_payload, prev = fetch_history(place, cfg, store, issue, get, fetch_obs, log)
    if obs_payload is None:
        raise RuntimeError("no station observations, scores not updated")
    obs = eccc.parse_daily(obs_payload)
    scores = build_scores(obs, prev, cfg["deterministic_pool"], issue)
    scores.update(place=pid, computed_at=iso(int(time.time())),
                  truth=place["truth"], credit=[om.CREDIT, eccc.CREDIT])
    _write_json(store / pid / "scores.json", scores)
    live = live_scores(store, pid, obs)
    live.to_csv(store / pid / "live_scores.csv", index=False)
    return {"scores": scores, "live": live}
