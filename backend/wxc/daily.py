"""Hourly model output to daily values on the ECCC climate day.

Tested on Kitimat Forest Ave (scored Jan to Oct 2026): UTC hours are shifted
by -6 h before grouping into days. After the habit fix, offsets -5 and -6
are within 0.02 deg C of each other; -6 gave the best chance-of-precipitation
score (Brier 0.092 vs 0.096) and day 3 high, so it stays. Offsets -1 to -4
were clearly worse for highs. Re-run backend/scripts/backtest.py --align
when adding a new station.
"""
from __future__ import annotations

import pandas as pd

CLIMATE_DAY_OFFSET_H = -6
MIN_HOURS = 22  # a day needs at least 22 of 24 hourly values


def hourly_to_daily(times, temp, precip=None, offset_h: int = CLIMATE_DAY_OFFSET_H,
                    min_hours: int = MIN_HOURS) -> pd.DataFrame:
    """Return a DataFrame indexed by date with tmax, tmin and (optionally) pcp."""
    df = pd.DataFrame({
        "time": pd.to_datetime(times) + pd.Timedelta(hours=offset_h),
        "t": pd.to_numeric(pd.Series(temp, dtype="object"), errors="coerce"),
    })
    if precip is not None:
        df["p"] = pd.to_numeric(pd.Series(precip, dtype="object"), errors="coerce")
    df["date"] = df["time"].dt.date
    g = df.groupby("date")
    ok = g["t"].count() >= min_hours
    out = pd.DataFrame({"tmax": g["t"].max().where(ok), "tmin": g["t"].min().where(ok)})
    if precip is not None:
        out["pcp"] = g["p"].sum(min_count=min_hours)
    return out


def previous_runs_daily(payload: dict, offset_h: int = CLIMATE_DAY_OFFSET_H,
                        leads=range(1, 8)) -> dict[int, pd.DataFrame]:
    """Daily values per lead day from an Open-Meteo Previous Runs API response."""
    h = payload["hourly"]
    out: dict[int, pd.DataFrame] = {}
    for lead in leads:
        t = h.get(f"temperature_2m_previous_day{lead}")
        p = h.get(f"precipitation_previous_day{lead}")
        if t is None or all(v is None for v in t):
            continue
        out[lead] = hourly_to_daily(h["time"], t, p, offset_h)
    return out
