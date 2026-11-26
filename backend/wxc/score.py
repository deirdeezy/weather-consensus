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
data/store/refusals.jsonl. Every download that could not be refreshed is also
listed in scores.json as downloads_stale (why "limit" for an Open-Meteo
rate-limit refusal, "error" otherwise), so a later nightly run rescores
(already_scored) and the workflow can retry on a fresh runner and fail the
run if limit refusals still left data missing (limit_losses). Single Runs
Open-Meteo answered it does not have are expected gaps, not stale.
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
from . import horizon as hz
from . import openmeteo as om
from .daily import CLIMATE_DAY_OFFSET_H, hourly_to_daily, previous_runs_daily
from .refresh import _write_json, api_id, iso, refusal_logger

HISTORY_DAYS = 200  # 60-day windows on top of 60 + 30 days of windows, plus leads
LEADS = range(1, 8)  # Previous Runs API offers previous_day1 to previous_day7
LONG_LEADS = range(8, 15)  # from Single Runs (backend/wxc/horizon.py)
ALL_LEADS = range(1, 15)
LIVE_LEADS = ALL_LEADS
NORMAL = "normal"


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

def _why(e: BaseException) -> str:
    return "limit" if om.is_limit(e) else "error"


def _fetch_or_stale(name: str, path: Path, fetch, log, stale: list | None = None,
                    download: str = "") -> dict | None:
    """Download and save; on failure, fall back to the last saved copy.
    A failure is appended to stale (scores.json downloads_stale)."""
    try:
        payload = fetch()
    except Exception as e:
        log(name, "error", e)
        rec = {"download": download or name, "source": name, "why": _why(e), "used": None}
        if stale is not None:
            stale.append(rec)
        if path.exists():
            rec["used"] = f"saved copy from {iso(int(path.stat().st_mtime))}"
            log(name, "used_stale", f"using {rec['used']}")
            return json.loads(path.read_text())
        return None
    _write_json(path, payload)
    return payload


def fetch_history(place: dict, cfg: dict, store: Path, issue: dt.date,
                  get=om.get_json, fetch_obs=eccc.fetch_daily, log=None,
                  stale: list | None = None) -> tuple:
    """Station observations and Previous Runs for every deterministic source."""
    hist = store / place["id"] / "history"
    start = (issue - dt.timedelta(days=HISTORY_DAYS)).isoformat()
    end = (issue - dt.timedelta(days=1)).isoformat()
    cid = place["truth"]["climate_id"]
    obs = _fetch_or_stale(f"eccc_{cid}", hist / f"eccc_daily_{cid}.json",
                          lambda: fetch_obs(cid, start, issue.isoformat()), log, stale, "station")
    prev = {}
    for m in cfg["deterministic_pool"]:
        url = om.previous_runs_url(place["lat"], place["lon"], place["elevation_m"], api_id(cfg, m),
                                   start, end, leads=LEADS)
        p = _fetch_or_stale(m, hist / f"prev_{m}.json",
                            lambda: get(url, log=lambda k, d, m=m: log(m, k, d)), log, stale,
                            "previous_runs")
        if p is not None:
            prev[m] = p
    return obs, prev


def fetch_long(place: dict, cfg: dict, store: Path, issue: dt.date, get=om.get_json,
               fetch_normal=hz.fetch_normal_records, log=None, echo=print,
               stale: list | None = None) -> tuple:
    """Single Runs for days 8 to 14 (only runs not yet saved) and the normal."""
    first = max(hz.SINGLE_RUNS_FROM, issue - dt.timedelta(days=HISTORY_DAYS))
    days = [first + dt.timedelta(days=i) for i in range((issue - first).days)]
    got = hz.fetch_single_runs(place, cfg["deterministic_pool"], days, store, get=get, log=log,
                         echo=lambda *a: None,
                         api_ids={m: api_id(cfg, m) for m in cfg["deterministic_pool"]})
    if stale is not None:
        stale += [{"download": "single_run", "used": None, **x} for x in got.get("lost", [])]
    long = {m: hz.single_runs_daily(store, place["id"], m, leads=LONG_LEADS)
            for m in cfg["deterministic_pool"]}
    long = {m: d for m, d in long.items() if d}
    cid = place.get("normal", {}).get("climate_id")
    normal = None
    if cid:
        path = store / place["id"] / "history" / f"normal_records_{cid}.json"
        recs = _fetch_or_stale(f"normal_{cid}", path, lambda: fetch_normal(cid), log, stale, "normal") \
            if not path.exists() else json.loads(path.read_text())
        if recs:
            normal = hz.daily_normal(recs)
    return long, normal


# --- habit fixes and weights ------------------------------------------------

def build_scores(obs: pd.DataFrame, prev: dict, pool: list[str], issue: dt.date,
                 long: dict | None = None, normal: pd.DataFrame | None = None) -> dict:
    """Stats per lead and variable as known on the issue date.
    Days 1 to 7 from Previous Runs, days 8 to 14 from Single Runs, plus the
    normal as one more source from NORMAL_FROM_LEAD."""
    short = {m: previous_runs_daily(p, leads=LEADS) for m, p in prev.items()}
    long = long or {}
    start = obs.index.min()
    span = pd.date_range(start, issue + dt.timedelta(days=max(ALL_LEADS)), freq="D").date
    N = hz.normal_for(normal, span) if normal is not None else None
    leads_out = {}
    for lead in ALL_LEADS:
        models = short if lead in LEADS else long
        if not any(lead in d for d in models.values()):
            continue
        out = {}
        for var in ("tmax", "tmin", "pcp"):
            first = hz.PCP_NORMAL_FROM_LEAD if var == "pcp" else hz.NORMAL_FROM_LEAD
            use_normal = N is not None and lead >= first
            names = pool + ([NORMAL] if use_normal else [])
            F = pd.DataFrame({m: d[lead][var] for m, d in models.items() if lead in d})
            if use_normal:
                F[NORMAL] = N[var]
            F = F.reindex(columns=names)
            if var == "pcp":
                st = cs.precip_stats(F, obs[var], lead, issue)
                w = cs.weights_from_error(st["mae"], guardrails=False)
                out[var] = {"sources": {m: {"mae": _num(st["mae"][m]), "weight": _num(w[m])}
                                        for m in names}}
            else:
                st = cs.temperature_stats(F, obs[var], lead, issue)
                w = cs.weights_from_error(st["mse"])
                out[var] = {"consensus_mae": _num(st["consensus_mae"]),
                            "spread_ref": _num(st["spread_ref"]),
                            "sources": {m: {"habit_fix": _num(st["habit_fix"][m]),
                                            "mse": _num(st["mse"][m]), "weight": _num(w[m])}
                                        for m in names}}
        leads_out[str(lead)] = out
    seen = obs[(obs.index < issue)].dropna(how="all")
    targets = [issue + dt.timedelta(days=L) for L in ALL_LEADS]
    normal_out = None
    if N is not None:
        normal_out = {d.isoformat(): {k: _num(N.at[d, k]) for k in ("tmax", "tmin", "pcp", "wet_share")}
                      for d in targets}
    return {
        "issue_date": issue.isoformat(),
        "obs_through": seen.index.max().isoformat() if len(seen) else None,
        "sources_with_history": sorted(short),
        "sources_missing": [m for m in pool if m not in short],
        "long_sources_with_history": sorted(long),
        "method": {"history": "Open-Meteo Previous Runs API (days 1 to 7), "
                              "Single Runs API 00 UTC (days 8 to 14)",
                   "bias_days": cs.BIAS_DAYS, "weight_days": cs.WEIGHT_DAYS,
                   "floor": cs.FLOOR, "cap": cs.CAP, "climate_day_offset_h": CLIMATE_DAY_OFFSET_H,
                   "normal_from_lead": hz.NORMAL_FROM_LEAD if N is not None else None,
                   "pcp_normal_from_lead": hz.PCP_NORMAL_FROM_LEAD if N is not None else None,
                   "pop_mix_from_lead": hz.POP_MIX_FROM_LEAD if N is not None else None,
                   "pop_note": "from pop_mix_from_lead, chance of precip = (share of sources "
                               "with 1 mm or more + normal wet_share) / 2",
                   "ensembles": "pulled, stored and scored every refresh; no weight until 60+ "
                                "days of our own record and a backtest shows they help",
                   "weight_note": "weight = share if every source has a forecast; "
                                  "publish re-splits among sources present"},
        "normal": normal_out,
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

def already_scored(store: Path, place_id: str, issue: dt.date) -> bool:
    """True when scores.json is for this issue date and already has the
    station's day before it. The nightly workflow runs twice; the second run
    only rescores if ECCC had not posted yesterday's values by the first."""
    p = store / place_id / "scores.json"
    if not p.exists():
        return False
    s = json.loads(p.read_text())
    done = (issue - dt.timedelta(days=1)).isoformat()
    return (s.get("issue_date") == issue.isoformat() and (s.get("obs_through") or "") >= done
            and not s.get("downloads_stale"))


def limit_losses(store: Path, place_id: str, issue: dt.date) -> list[dict]:
    """Downloads that today's scoring could not refresh because Open-Meteo
    refused them for a rate limit. Empty if the place has no scores for this
    issue date (not scored today) or nothing was refused."""
    p = store / place_id / "scores.json"
    if not p.exists():
        return []
    s = json.loads(p.read_text())
    if s.get("issue_date") != issue.isoformat():
        return []
    return [x for x in s.get("downloads_stale") or [] if x.get("why") == "limit"]


def score(place: dict, cfg: dict, store: Path, issue: dt.date | None = None,
          get=om.get_json, fetch_obs=eccc.fetch_daily,
          fetch_normal=hz.fetch_normal_records, echo=print) -> dict:
    issue = issue or issue_date_now()
    pid = place["id"]
    log = refusal_logger(store, pid, echo)
    stale: list[dict] = []
    obs_payload, prev = fetch_history(place, cfg, store, issue, get, fetch_obs, log, stale)
    if obs_payload is None:
        raise RuntimeError("no station observations, scores not updated")
    obs = eccc.parse_daily(obs_payload)
    long, normal = fetch_long(place, cfg, store, issue, get, fetch_normal, log, echo, stale)
    scores = build_scores(obs, prev, cfg["deterministic_pool"], issue, long, normal)
    scores.update(place=pid, computed_at=iso(int(time.time())),
                  truth=place["truth"], credit=[om.CREDIT, eccc.CREDIT], downloads_stale=stale)
    _write_json(store / pid / "scores.json", scores)
    live = live_scores(store, pid, obs)
    live.to_csv(store / pid / "live_scores.csv", index=False)
    return {"scores": scores, "live": live}
