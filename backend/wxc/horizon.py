"""Days 8 to 14: long-lead history and the climate normal.

Long-lead history: the Previous Runs API stops at day 7, so days 8 to 14 use
the Single Runs API: the full 16-day run for one initialisation time.
https://open-meteo.com/en/docs/single-runs-api (checked 24 Nov 2026):
"Most models are archived from 2nd of April 2026. ECMWF IFS HRES at 9 km is
available from March 2024." Checked live: gfs_seamless and jma_seamless runs
from 1 Jun 2026 come back in full.

Ensembles: Open-Meteo does not archive past ensemble runs. Checked live
24 Nov 2026: Single Runs and Ensemble API with &run= answer "The requested
model run is not available" for ecmwf_ifs025_ensemble and its mean; the
Previous Runs API serves ensemble means only to day 7. So ensembles get a
track record only from our own stored pulls (from 25 Nov 2026).

One run per issue date: the 00 UTC run, which Open-Meteo posts by about
06 UTC, the start of that climate day. Lead L = target climate date minus
run date.

Normal: daily 1991 to 2020 average from the ECCC daily records of the
place's normal station, smoothed over +/- NORMAL_HALF_WINDOW days of the
calendar.
"""
from __future__ import annotations

import datetime as dt
import json
import time
from pathlib import Path

import pandas as pd

from . import eccc
from . import openmeteo as om
from .daily import hourly_to_daily
from .refresh import _write_json

SINGLE_RUNS_FROM = dt.date(2026, 4, 2)

# Set by the horizon test (backend/scripts/horizon.py, Kitimat, scored
# 1 Jul to 23 Nov 2026; numbers in docs/ALGORITHM.md):
NORMAL_FROM_LEAD = 8       # highs and lows: the normal joins as one more source
PCP_NORMAL_FROM_LEAD = 10  # precip amount: the normal only helps from day 10
POP_MIX_FROM_LEAD = 8      # chance of precip = average of the sources' share and
                           # the normal wet-day share (sources alone worse than
                           # climatology from day 9)
RUN_HOUR = "T00:00"
NORMAL_YEARS = (1991, 2020)
NORMAL_HALF_WINDOW = 7
PACE_S = 0.25  # stay well under 600 calls a minute
GONE_AFTER_DAYS = 2  # a run Open-Meteo still lacks after this is not coming
GONE_PHRASES = ("not available", "No data is available")


def utc_today() -> dt.date:
    """Today in UTC (the runners and Open-Meteo's run dates are UTC)."""
    return dt.datetime.now(dt.timezone.utc).date()


def expected_gap(e: BaseException) -> bool:
    """True when Open-Meteo answered that it has no such run: an expected gap,
    not a refusal. Rate-limit refusals and network failures are not gaps."""
    return not isinstance(e, om.LimitRefused) and any(s in str(e) for s in GONE_PHRASES)


def single_run_path(store: Path, place_id: str, model: str, day: dt.date) -> Path:
    return store / place_id / "single" / model / f"{day.isoformat()}.json"


def fetch_single_runs(place: dict, models: list[str], days: list[dt.date], store: Path,
                      get=om.get_json, log=None, sleep=time.sleep, echo=print,
                      api_ids: dict | None = None) -> dict:
    """Download every missing 00 UTC run. Saved runs are never fetched again.
    Files are named by the pilot key; api_ids gives the id sent to Open-Meteo.
    Returns counts plus "lost": runs not fetched for a reason other than an
    expected gap (rate limit, network), each {"source", "day", "why"} with why
    "limit" or "error"; they are asked for again next night."""
    done = failed = 0
    lost = []
    for m in models:
        for d in days:
            path = single_run_path(store, place["id"], m, d)
            gone = path.with_suffix(".missing")
            if path.exists() or gone.exists():
                continue
            url = om.single_run_url(place["lat"], place["lon"], place["elevation_m"],
                                    (api_ids or {}).get(m, m),
                                    d.isoformat() + RUN_HOUR, forecast_days=16)
            try:
                payload = get(url, log=lambda k, x, m=m: log(m, k, x) if log else None)
            except Exception as e:
                if log:
                    log(m, "single_run", f"{d}: {e}")
                failed += 1
                if not expected_gap(e):
                    lost.append({"source": m, "day": d.isoformat(),
                                 "why": "limit" if om.is_limit(e) else "error"})
                    continue
                if (utc_today() - d).days > GONE_AFTER_DAYS:
                    gone.parent.mkdir(parents=True, exist_ok=True)
                    gone.write_text(str(e)[:300])  # Open-Meteo has no such run: stop asking
                continue
            _write_json(path, payload)
            done += 1
            sleep(PACE_S)
        echo(f"  single runs {m}: done")
    return {"fetched": done, "failed": failed, "lost": lost}


def single_runs_daily(store: Path, place_id: str, model: str,
                      leads=range(1, 15)) -> dict[int, pd.DataFrame]:
    """Daily values per lead from every saved run of one model."""
    parts: dict[int, list] = {L: [] for L in leads}
    for f in sorted((store / place_id / "single" / model).glob("*.json")):
        run = dt.date.fromisoformat(f.stem)
        h = json.loads(f.read_text())["hourly"]
        daily = hourly_to_daily(h["time"], h["temperature_2m"], h.get("precipitation"))
        for target, row in daily.iterrows():
            L = (target - run).days
            if L in parts:
                parts[L].append(row.rename(target))
    return {L: pd.DataFrame(rows) for L, rows in parts.items() if rows}


def daily_normal(payloads: list[dict], years=NORMAL_YEARS,
                 half_window: int = NORMAL_HALF_WINDOW) -> pd.DataFrame:
    """Normal tmax, tmin, pcp and wet-day share for each calendar day (1 to 366)."""
    obs = pd.concat([eccc.parse_daily(p) for p in payloads])
    obs = obs[~obs.index.duplicated()]
    idx = pd.to_datetime(pd.Index(obs.index))
    obs = obs[(idx.year >= years[0]) & (idx.year <= years[1])]
    idx = pd.to_datetime(pd.Index(obs.index))
    doy = idx.day_of_year.where(~((idx.month == 2) & (idx.day == 29)), 0)  # 29 Feb uses neighbours only
    doy = pd.Series(doy - ((idx.is_leap_year) & (idx.month > 2)).astype(int), index=obs.index)
    out = {}
    for day in range(1, 366):
        dist = (doy - day).abs()
        near = obs[(dist.where(dist <= 182, 365 - dist) <= half_window) & (doy > 0)]
        out[day] = {"tmax": near.tmax.mean(), "tmin": near.tmin.mean(), "pcp": near.pcp.mean(),
                    "wet_share": (near.pcp.dropna() >= 1.0).mean(), "n": int(near.tmax.count())}
    normal = pd.DataFrame(out).T
    normal.loc[366] = normal.loc[365]
    return normal


def normal_for(normal: pd.DataFrame, dates) -> pd.DataFrame:
    """The normal looked up for each date (29 Feb uses 28 Feb's normal)."""
    rows = []
    for d in dates:
        ts = pd.Timestamp(d)
        if ts.month == 2 and ts.day == 29:
            day = 59
        else:
            day = ts.day_of_year - (1 if ts.is_leap_year and ts.month > 2 else 0)
        rows.append(normal.loc[min(day, 365)].rename(d))
    return pd.DataFrame(rows)


def fetch_normal_records(climate_id: str, years=NORMAL_YEARS, fetch=eccc.fetch_daily) -> list[dict]:
    """ECCC daily records for the normal period, one payload per decade."""
    out = []
    for start in range(years[0], years[1] + 1, 10):
        end = min(start + 9, years[1])
        out.append(fetch(climate_id, f"{start}-01-01", f"{end}-12-31"))
    return out
