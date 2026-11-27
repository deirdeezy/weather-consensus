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
from .score import ALL_LEADS, LIVE_MIN_DAYS, NORMAL, _daily_from_pull

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
    as consensus.precip_consensus. Returns the amount and the shares used."""
    mae = pd.Series({m: v.get("mae") for m, v in st.items()}, dtype=float)
    F = F[[m for m in F.index if m in st]].dropna()
    w = (1.0 / mae.reindex(F.index)).replace([np.inf, -np.inf], np.nan).dropna()
    if w.empty:
        return float("nan"), w
    return float((F[w.index] * w).sum() / w.sum()), w / w.sum()


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
    used_weights = {}
    days = []
    for L, T in zip(ALL_LEADS, targets):
        row = {}
        for var in ("tmax", "tmin", "pcp"):
            row[var] = pd.Series({m: p["daily"][var].get(T, np.nan) if var in p["daily"] else np.nan
                                  for m, p in used.items()}, dtype=float)
        hi, spread, w = _temperature(_with_normal(row["tmax"], N, T, "tmax", L), _stats(scores, L, "tmax"))
        lo, _, w_lo = _temperature(_with_normal(row["tmin"], N, T, "tmin", L), _stats(scores, L, "tmin"))
        mm, w_pcp = _precip(_with_normal(row["pcp"], N, T, "pcp", L, hz.PCP_NORMAL_FROM_LEAD),
                            _stats(scores, L, "pcp"))
        used_weights[L] = {"tmax": w, "tmin": w_lo, "pcp": w_pcp}
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
    record = track_record(scores, used_weights, [s["id"] for s in sources])
    if record:
        doc["track_record"] = record
    if now_block:  # only for a place with an approved station (backend/wxc/obs.py)
        doc["now"] = now_block
    return doc


# --- the track record (Consensus tab, steps 2 and 3) --------------------------

TRACK_LEADS = (1, 7, 13)  # the leads the Consensus tab shows (as its day 1, 7 and 13 bars)
VARS = (("high", "tmax"), ("low", "tmin"), ("rain", "pcp"))


def _entry(st: dict, weight, temperature: bool) -> dict:
    e = {"weight": _r(weight, 3), "miss": _r(st.get("mae"), 2), "days": st.get("days")}
    if temperature:
        e["bias"] = _r(st.get("habit_fix"), 2)
        e["bias_days"] = st.get("bias_days")
    return e


def track_record(scores: dict, used: dict, order: list[str]) -> dict | None:
    """Each source's recent miss, today's weight and habit fix at TRACK_LEADS,
    labelled by where the numbers come from:
    - archive: the nightly scoring of each source's archived forecasts (Open-
      Meteo Previous Runs, days 1 to 7; Single Runs, days 8 to 14) against the
      station; the same numbers the weights and habit fixes come from.
    - live: our own saved forecasts against the station (since 25 Nov 2026);
      a miss only once LIVE_MIN_DAYS are in, otherwise the count alone.
    Never mixed: a reader picks one. None until scores.json has the fields
    (score.py SCORES_FORMAT 2), so an older scores.json publishes no block."""
    if scores.get("format", 1) < 2 or "windows" not in scores:
        return None
    rank = {m: i for i, m in enumerate(order)}
    leads = [L for L in TRACK_LEADS if str(L) in scores.get("leads", {})]
    consensus, sources = [], []
    for L in leads:
        stats = scores["leads"][str(L)]
        c = {"lead": L}
        for name, var in VARS:
            v = stats.get(var) or {}
            c[name] = {"miss": _r(v.get("consensus_mae"), 2), "days": v.get("consensus_days")}
        consensus.append(c)
        ids = sorted({m for _, var in VARS for m in (stats.get(var) or {}).get("sources", {})},
                     key=lambda m: (rank.get(m, len(rank)), m))
        for m in ids:
            e = {"id": m, "lead": L}
            for name, var in VARS:
                st = ((stats.get(var) or {}).get("sources") or {}).get(m)
                if st is None:
                    continue
                w = (used.get(L) or {}).get(var)
                weight = None if w is None or m not in w.index or pd.isna(w[m]) else w[m]
                e[name] = _entry(st, weight, var != "pcp")
            if any(e.get(n) and (e[n]["miss"] is not None or e[n]["weight"] is not None)
                   for n, _ in VARS):
                sources.append(e)
    live = scores.get("live") or {}
    live_leads = live.get("leads") or {}
    live_sources = []
    for L in leads:
        for m, vs in sorted((live_leads.get(str(L)) or {}).get("sources", {}).items(),
                            key=lambda t: (rank.get(t[0], len(rank)), t[0])):
            e = {"id": m, "lead": L}
            for name, var in VARS:
                if var in vs:
                    e[name] = {"miss": _r(vs[var].get("mae"), 2), "days": vs[var].get("days")}
            live_sources.append(e)
    return {
        "leads": leads,
        "scored_on": scores.get("issue_date"),
        "station_through": scores.get("obs_through"),
        "archive": {
            "basis": "archive",
            "miss_window": scores["windows"]["miss"],
            "bias_window": scores["windows"]["bias"],
            "min_days": LIVE_MIN_DAYS,
            "consensus": consensus,
            "sources": sources,
        },
        "live": {
            "basis": "live",
            "since": live.get("since"),
            "window": live.get("window") or scores["windows"]["miss"],
            "min_days": live.get("min_days", LIVE_MIN_DAYS),
            "days": [{"lead": L, "days": (live_leads.get(str(L)) or {}).get("days", 0)}
                     for L in leads],
            "consensus": None,
            "sources": live_sources,
        },
    }


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
