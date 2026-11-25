"""Publish: the latest Consensus for one place as a small public JSON file.

Inputs (all under data/store/<place>/):
- scores.json (nightly, backend/wxc/score.py): habit fixes and errors per
  source, lead and variable, as known on its issue date.
- state.json and the raw pulls it points to (hourly, backend/wxc/refresh.py):
  the newest run of every deterministic source.
- history/normal_records_<id>.json: the 1991 to 2020 normal (days 8 to 14).
- now.json (hourly, backend/wxc/obs.py): the latest station observation, for
  places with an approved station only. Published as is in "now".

Output: public/<place>.json, described in docs/JSON_SCHEMA.md and checked
against docs/place-v1.schema.json by the tests.

Method: the same code the backtest checks (consensus.blend, certainty.certainty)
with the rules in docs/ALGORITHM.md. Day N is the ECCC climate day N days
after the issue date (lead N), as in the backtest. Ensembles get no weight.

Nothing local goes into the file: no paths, no URLs we called, no machine
names. Only place data from config/places.json, forecast numbers and credits.
"""
from __future__ import annotations

import datetime as dt
import json
import math
import time
from pathlib import Path

import numpy as np
import pandas as pd

from . import certainty as cert
from . import consensus as cs
from . import eccc
from . import horizon as hz
from . import obs
from .daily import CLIMATE_DAY_OFFSET_H
from .refresh import _write_json, iso, load_state, refusal_logger
from .score import ALL_LEADS, NORMAL, _daily_from_pull

SCHEMA_VERSION = 1
STALE_AFTER_H = 6     # no new pull for this long: stale (CLAUDE.md, reliability)
LATE_RUN_H = 24       # a source whose newest run is this much older than the
                      # newest run of any source is late: its share goes to the rest
NORMAL_LABEL = "1991 to 2020 normal"
OPEN_METEO = {"text": "Weather data by Open-Meteo.com",
              "licence": "CC BY 4.0",
              "url": "https://open-meteo.com/",
              "licence_url": "https://creativecommons.org/licenses/by/4.0/"}
ECCC = {"text": eccc.CREDIT,
        "licence": "ECCC Data Servers End-use Licence",
        "url": "https://eccc-msc.github.io/open-data/licence/readme_en/",
        "licence_url": "https://eccc-msc.github.io/open-data/licence/readme_en/"}


def issue_date_at(now: int) -> dt.date:
    t = dt.datetime.fromtimestamp(now, dt.timezone.utc)
    return (t + dt.timedelta(hours=CLIMATE_DAY_OFFSET_H)).date()


def _r(x, nd: int):
    if x is None:
        return None
    x = float(x)
    return None if math.isnan(x) or math.isinf(x) else round(x, nd)


def _pct(p):
    p = _r(p, 6)
    return None if p is None else int(round(100 * p))


# --- inputs from the store ----------------------------------------------------

def load_pulls(store: Path, place_id: str, pool: list[str], log=None) -> dict:
    """Newest saved pull of every deterministic source: daily values, run and
    fetch time (Unix seconds)."""
    state = load_state(store, place_id)
    out = {}
    for m in pool:
        s = state.get(m)
        if not s:
            continue
        try:
            rec = json.loads((store / s["file"]).read_text())
            daily = _daily_from_pull(rec)
        except Exception as e:
            if log:
                log(m, "publish", f"saved pull unreadable: {e}")
            continue
        if daily is None:
            continue
        runs = s.get("runs") or {}
        out[m] = {"daily": daily, "run_unix": max(runs.values()) if runs else s["fetched_unix"],
                  "fetched_unix": s["fetched_unix"]}
    return out


def load_normal(store: Path, place: dict) -> pd.DataFrame | None:
    cid = (place.get("normal") or {}).get("climate_id")
    path = store / place["id"] / "history" / f"normal_records_{cid}.json"
    if not cid or not path.exists():
        return None
    return hz.daily_normal(json.loads(path.read_text()))


# --- the forecast -----------------------------------------------------------

def _stats(scores: dict, lead: int, var: str) -> dict:
    return (scores.get("leads", {}).get(str(lead)) or {}).get(var, {}).get("sources", {})


def _temperature(F: pd.Series, st: dict):
    hf = pd.Series({m: v.get("habit_fix") for m, v in st.items()}, dtype=float)
    mse = pd.Series({m: v.get("mse") for m, v in st.items()}, dtype=float)
    F = F[[m for m in F.index if m in st]]
    return cs.blend(F, hf, mse)


def _precip(F: pd.Series, st: dict):
    """Inverse-MAE weighted amount among sources present (no guardrails),
    as consensus.precip_consensus."""
    mae = pd.Series({m: v.get("mae") for m, v in st.items()}, dtype=float)
    F = F[[m for m in F.index if m in st]].dropna()
    w = (1.0 / mae.reindex(F.index)).replace([np.inf, -np.inf], np.nan).dropna()
    if w.empty:
        return float("nan")
    return float((F[w.index] * w).sum() / w.sum())


def build(place: dict, cfg: dict, scores: dict, pulls: dict, normal: pd.DataFrame | None,
          now: int, now_block: dict | None = None) -> dict:
    """The public document for one place. Pure: no reading or writing."""
    pool = cfg["deterministic_pool"]
    issue = issue_date_at(now)
    newest_run = max((p["run_unix"] for p in pulls.values()), default=None)
    used = {m: p for m, p in pulls.items()
            if newest_run is not None and newest_run - p["run_unix"] <= LATE_RUN_H * 3600}
    fresh = max((p["fetched_unix"] for p in pulls.values()), default=None)
    stale = fresh is None or now - fresh > STALE_AFTER_H * 3600

    targets = [issue + dt.timedelta(days=L) for L in ALL_LEADS]
    N = hz.normal_for(normal, targets) if normal is not None else None
    labels = cfg.get("labels", {})
    shown = set()
    days = []
    for L, T in zip(ALL_LEADS, targets):
        row = {}
        for var in ("tmax", "tmin", "pcp"):
            row[var] = pd.Series({m: p["daily"][var].get(T, np.nan) if var in p["daily"] else np.nan
                                  for m, p in used.items()}, dtype=float)
        hi, spread, w = _temperature(_with_normal(row["tmax"], N, T, "tmax", L), _stats(scores, L, "tmax"))
        lo, _, _ = _temperature(_with_normal(row["tmin"], N, T, "tmin", L), _stats(scores, L, "tmin"))
        mm = _precip(_with_normal(row["pcp"], N, T, "pcp", L, hz.PCP_NORMAL_FROM_LEAD),
                     _stats(scores, L, "pcp"))
        models_pcp = row["pcp"].dropna()
        pop = float((models_pcp >= cs.WET_MM).mean()) if len(models_pcp) else float("nan")
        if N is not None and L >= hz.POP_MIX_FROM_LEAD and not math.isnan(pop):
            pop = (pop + float(N.at[T, "wet_share"])) / 2

        st = (scores.get("leads", {}).get(str(L)) or {}).get("tmax", {})
        p = cert.certainty(pd.Series([st.get("consensus_mae")], dtype=float),
                           pd.Series([spread], dtype=float),
                           pd.Series([st.get("spread_ref")], dtype=float)).iloc[0]
        c = _pct(p)
        weights = sorted(((m, _r(x, 3)) for m, x in w.dropna().items()), key=lambda t: -t[1])
        shown.update(m for m, _ in weights)
        days.append({
            "day": L,
            "date": T.isoformat(),
            "high": _r(hi, 1),
            "low": _r(lo, 1),
            "precip_mm": _r(max(mm, 0.0), 1) if not math.isnan(mm) else None,
            "precip_chance": _pct(pop),
            "certainty": c,
            "tier": None if c is None else cert.tier(c / 100),
            "weights": [{"id": m, "weight": x} for m, x in weights],
        })

    truth = place.get("truth")
    sources = [{"id": m, "label": labels.get(m, m)} for m in pool if m in shown]
    if NORMAL in shown:
        sources.append({"id": NORMAL, "label": NORMAL_LABEL})
    doc = {
        "schema_version": SCHEMA_VERSION,
        "place": {
            "id": place["id"],
            "name": place["name"],
            "lat": place["lat"],
            "lon": place["lon"],
            "elevation_m": place.get("elevation_m"),
            "timezone": place.get("timezone"),
            "truth_station": None if not truth else {
                "network": truth.get("network"), "id": truth.get("climate_id"),
                "name": truth.get("station")},
            "consensus_only": not truth,
        },
        "issued_at": iso(now),
        "issue_date": issue.isoformat(),
        "newest_run_at": iso(newest_run) if newest_run is not None else None,
        "fresh_data_at": iso(fresh) if fresh is not None else None,
        "stale": stale,
        "stale_after_hours": STALE_AFTER_H,
        "weights_as_of": scores.get("issue_date"),
        "units": {"temperature": "degC", "precipitation": "mm", "chance": "percent"},
        "sources": sources,
        "days": days,
        "credits": [OPEN_METEO, ECCC],
    }
    if now_block:  # only for a place with an approved station (backend/wxc/obs.py)
        doc["now"] = now_block
    return doc


def _with_normal(F: pd.Series, N, T, var: str, lead: int,
                 first: int = hz.NORMAL_FROM_LEAD) -> pd.Series:
    if N is None or lead < first:
        return F
    return pd.concat([F, pd.Series({NORMAL: N.at[T, var]}, dtype=float)])


# --- the job ----------------------------------------------------------------

def publish(place: dict, cfg: dict, store: Path, out_dir: Path, now: int | None = None,
            echo=print) -> dict:
    now = int(time.time() if now is None else now)
    pid = place["id"]
    log = refusal_logger(store, pid, echo)
    path = store / pid / "scores.json"
    if not path.exists():
        log("publish", "publish", "no scores.json: run score.py first")
        raise RuntimeError("no scores.json, nothing published")
    scores = json.loads(path.read_text())
    pulls = load_pulls(store, pid, cfg["deterministic_pool"], log)
    if not pulls:
        log("publish", "publish", "no saved pulls: run refresh.py first")
        raise RuntimeError("no saved pulls, nothing published")
    doc = build(place, cfg, scores, pulls, load_normal(store, place), now,
                obs.load_now(store, place))
    _write_json(out_dir / f"{pid}.json", doc)
    return doc
