"""Hourly forecast, 3-hour blocks, today and each day's condition (beta, 28 Nov 2026).

Owner decision (27 Nov 2026 evening): the hour-by-hour forecast and each day's
general weather go into the app first as a beta, verification after. Every
value here is marked unverified in the file (`verification`), the app makes no
accuracy claim for them, and none goes into an App Store release before its
backtest passes (docs/BUILD_PLAN.md). Methods and their evidence:
docs/ALGORITHM.md, "Hourly and conditions (beta)".

What is built, from the newest saved run of each source (state.json; the main
16-day pull carries temperature, precipitation, cloud, snowfall, humidity and
wind from 28 Nov 2026):
- hourly: 48 entries from the current UTC hour; blocks: 3-hour blocks from
  48 h to 96 h. Each: condition, temperature, feels like, chance and amount of
  precipitation, cloud, wind speed and direction (best effort; no gusts).
- today: the current climate day (06 to 06 UTC, as scoring): high and low
  from the station so far and the forecast for the rest of the day.
- days[].condition: the day's general weather.

Methods:
- Temperature: the daily weights (inverse 60-day squared error of the high and
  the low, averaged, with the 2% floor and 35% cap) for the lead day of the
  hour, and a habit fix by UTC hour of day from hourly_scores.json (30 days
  of Previous Runs against the station's saved hourly records,
  hourly_habit()). A source without an hourly fix uses its daily one (the mean
  of the high's and the low's); without either it is left out.
- The first hours are nudged toward the latest observation: offset
  (observed minus forecast at the observation hour) fading as exp(-hours/6)
  (research test: first-hour miss 0.66 to 0.32 deg C; in-sample, to confirm).
- Precipitation amount: the daily inverse-MAE weights (no habit fix), as the
  daily amount. Chance: the sources' wet share (0.2 mm or more in the hour or
  block), as the daily chance (1 mm or more in the day).
- Cloud, humidity and wind speed: the median of the sources (no weights can be
  checked yet; the median beat the mean for cloud against GOES, small sample).
  Wind direction: the sources' vector average. Snow share: snowfall in cm / 0.7
  = water mm, over the hour's precipitation, median of the wet sources.
- Condition: rain, snow or mixed when the chance is 50% or more (snow share
  0.8 or more snow, 0.2 or less rain, between mixed; no snowfall data:
  temperature 0 deg C or below snow, 2.0 or above rain, between mixed);
  otherwise from cloud: under 30% clear, 30 to 70% partly, over 70% cloudy.
- Feels like: ECCC wind chill at 0 deg C or below with wind 5 km/h or more
  (https://www.canada.ca/en/services/environment/weather/severeweather/wind-chill-index.html:
  "When temperatures are zero or below and the wind speed is 5 km/h or
  higher, we include wind chill in the weather conditions and forecasts");
  humidex at 25 deg C or more when at least 1 degree above the temperature,
  the forecast rule (https://www.canada.ca/en/services/environment/weather/severeweather/humidex.html:
  "For 24-hour forecasts: when the temperature reaches 25°C or higher and the
  Humidex is at least one degree higher"; current conditions use 20 deg C).
  Both checked 28 Nov 2026. Otherwise the temperature. Wind chill uses the
  models' 10 m wind, which runs high at a sheltered station (unverified).
- Day condition: over the climate day (the same 24 hours as the high, low and
  precipitation): rain, snow or mixed when the day's chance of 1 mm or more is
  50% or more (snow share of the day's totals, median of the wet sources;
  no snowfall data, as in pulls saved before 28 Nov 2026: the mean of the
  high and low, 0 deg C or below snow, 2.0 or above rain, between mixed);
  otherwise the median of the sources' mean cloud that day.
"""
from __future__ import annotations

import datetime as dt
import json
import math
import statistics
from pathlib import Path

import numpy as np
import pandas as pd

from . import consensus as cs
from .daily import CLIMATE_DAY_OFFSET_H
from .nowcast import hour_key, sky_class
from .refresh import _write_json, iso

HOURS = 48            # hourly entries from the current hour
BLOCK_H = 3
BLOCKS_TO_H = 96      # 3-hour blocks from HOURS to this lead
WET_HOUR_MM = 0.2     # a wet hour or block (as the research)
WET_DAY_MM = cs.WET_MM
NUDGE_FADE_H = 6.0
HABIT_DAYS = 30
HABIT_MIN = 10        # fewest hours in a habit-fix cell
HABIT_LEADS = range(1, 8)
SCORES = "hourly_scores.json"
METHOD = "beta_v1"
CLASSES = ("clear", "partly", "cloudy", "rain", "snow", "mixed")


# --- small helpers ---------------------------------------------------------------

def _r(x, nd=1):
    return None if x is None or (isinstance(x, float) and math.isnan(x)) else round(float(x), nd)


def _median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def climate_date(t: dt.datetime) -> dt.date:
    return (t + dt.timedelta(hours=CLIMATE_DAY_OFFSET_H)).date()


def phase_from_share(share, temp=None) -> str | None:
    if share is not None:
        return "snow" if share >= 0.8 else "rain" if share <= 0.2 else "mixed"
    if temp is None:
        return None
    return "snow" if temp <= 0 else "rain" if temp >= 2.0 else "mixed"


def wind_chill(t, v):
    return 13.12 + 0.6215 * t - 11.37 * v ** 0.16 + 0.3965 * t * v ** 0.16


def dew_point(t, rh):
    """Magnus formula (a = 17.625, b = 243.04 deg C)."""
    if rh is None or rh <= 0:
        return None
    g = math.log(rh / 100.0) + 17.625 * t / (243.04 + t)
    return 243.04 * g / (17.625 - g)


def humidex(t, td):
    e = 6.11 * math.exp(5417.7530 * (1 / 273.16 - 1 / (273.15 + td)))
    return t + 0.5555 * (e - 10.0)


def feels_like(t, wind_kmh, rh):
    """ECCC rules for forecasts (module docstring)."""
    if t is None:
        return None
    if t <= 0 and wind_kmh is not None and wind_kmh >= 5:
        return wind_chill(t, wind_kmh)
    if t >= 25:
        td = dew_point(t, rh)
        if td is not None:
            h = humidex(t, td)
            if h - t >= 1:
                return h
    return t


def vector_dir(dirs, speeds):
    u = v = 0.0
    n = 0
    for d, s in zip(dirs, speeds):
        if d is None or s is None:
            continue
        u += -s * math.sin(math.radians(d))
        v += -s * math.cos(math.radians(d))
        n += 1
    if n == 0 or (abs(u) < 1e-9 and abs(v) < 1e-9):
        return None
    return int(round((math.degrees(math.atan2(-u, -v)) + 360) % 360)) % 360


# --- hourly habit fix (nightly) ------------------------------------------------------

def hourly_habit(prev: dict, truth: pd.Series, issue: dt.date, pool: list[str]) -> dict:
    """Mean error (forecast minus station) per source, lead day and UTC hour,
    over the HABIT_DAYS climate days before the issue date (verified at issue
    time: target before issue date, lead + 1 days back as the daily windows).
    prev: Previous Runs payloads per source; truth: station temperature by
    UTC hour string 'YYYY-MM-DDTHH:00'."""
    out: dict = {}
    for m in pool:
        h = (prev.get(m) or {}).get("hourly") or {}
        times = h.get("time") or []
        if not times:
            continue
        src = {}
        for L in HABIT_LEADS:
            vals = h.get(f"temperature_2m_previous_day{L}")
            if not vals:
                continue
            end = issue - dt.timedelta(days=L + 1)     # newest target known at issue time
            start = end - dt.timedelta(days=HABIT_DAYS - 1)
            sums, counts = [0.0] * 24, [0] * 24
            for t, f in zip(times, vals):
                if f is None:
                    continue
                o = truth.get(t[:13] + ":00")
                if o is None or (isinstance(o, float) and math.isnan(o)):
                    continue
                tt = dt.datetime.strptime(t[:13], "%Y-%m-%dT%H")
                cd = climate_date(tt)
                if not (start <= cd <= end):
                    continue
                sums[tt.hour] += f - o
                counts[tt.hour] += 1
            src[str(L)] = {"bias": [round(s / c, 2) if c >= HABIT_MIN else None for s, c in zip(sums, counts)],
                           "n": counts}
        if src:
            out[m] = src
    return out


def station_hourly_temps(store: Path, place_id: str) -> pd.Series:
    from .nowcast import truth as station_truth
    T = station_truth(store, place_id)
    return pd.Series({t[:13] + ":00": v for t, v in T["temp"].items() if v is not None}, dtype=float)


def score(store: Path, place: dict, cfg: dict, issue: dt.date, now: int) -> dict | None:
    """Nightly: hourly_scores.json from the saved Previous Runs copies
    (history/prev_<source>.json, the nightly's own downloads; nothing new is
    fetched) and the station's saved hourly records. None without inputs."""
    hist = store / place["id"] / "history"
    prev = {}
    for m in cfg["deterministic_pool"]:
        p = hist / f"prev_{m}.json"
        if p.exists():
            try:
                prev[m] = json.loads(p.read_text())
            except Exception:
                continue
    truth = station_hourly_temps(store, place["id"])
    if not prev or truth.empty:
        return None
    out = {"issue_date": issue.isoformat(), "computed_at": iso(now), "method": METHOD,
           "window_days": HABIT_DAYS, "min_hours": HABIT_MIN,
           "truth": "station hourly records (swob/), air_temp passed checks",
           "station_from": truth.index.min(), "station_to": truth.index.max(),
           "sources": hourly_habit(prev, truth, issue, cfg["deterministic_pool"])}
    _write_json(store / place["id"] / SCORES, out)
    return out


def load_scores(store: Path, place_id: str) -> dict:
    p = store / place_id / SCORES
    try:
        return json.loads(p.read_text()) if p.exists() else {}
    except Exception:
        return {}


# --- the blend for one valid hour ------------------------------------------------------

def _lead(t: dt.datetime, issue: dt.date) -> int:
    return (climate_date(t) - issue).days


def _day_stats(scores: dict, L: int, var: str) -> dict:
    return (scores.get("leads", {}).get(str(max(L, 1))) or {}).get(var, {}).get("sources", {})


_WEIGHTS: dict = {}  # (id(scores), lead, sources) -> weights; cleared by build()


def temp_weights(scores: dict, L: int, present: list[str]) -> pd.Series:
    key = (id(scores), max(L, 1), tuple(sorted(present)))
    if key not in _WEIGHTS:
        _WEIGHTS[key] = _temp_weights(scores, L, present)
    return _WEIGHTS[key]


def _temp_weights(scores: dict, L: int, present: list[str]) -> pd.Series:
    hi, lo = _day_stats(scores, L, "tmax"), _day_stats(scores, L, "tmin")
    mse = {}
    for m in present:
        xs = [x for x in (hi.get(m, {}).get("mse"), lo.get(m, {}).get("mse"))
              if isinstance(x, (int, float)) and math.isfinite(x) and x > 0]
        if xs:
            mse[m] = sum(xs) / len(xs)
    if not mse:
        return pd.Series(dtype=float)
    return cs.weights_from_error(pd.Series(mse, dtype=float), None)


def daily_fix(scores: dict, L: int, m: str):
    hi, lo = _day_stats(scores, L, "tmax"), _day_stats(scores, L, "tmin")
    xs = [x for x in (hi.get(m, {}).get("habit_fix"), lo.get(m, {}).get("habit_fix"))
          if isinstance(x, (int, float)) and not math.isnan(x)]
    return sum(xs) / len(xs) if xs else None


def hour_fix(hscores: dict, m: str, L: int, hour: int):
    cell = ((hscores.get("sources") or {}).get(m) or {}).get(str(min(max(L, 1), 7))) or {}
    b = (cell.get("bias") or [None] * 24)[hour]
    return b


def blend_temp(sources: dict, key: str, t: dt.datetime, L: int, scores: dict, hscores: dict):
    fc = {}
    for m, s in sources.items():
        f = s["temp"].get(key)
        if f is None:
            continue
        b = hour_fix(hscores, m, L, t.hour)
        if b is None:
            b = daily_fix(scores, L, m)
        if b is None:
            continue
        fc[m] = f - b
    if not fc:
        return None
    w = temp_weights(scores, L, list(fc))
    w = w.dropna()
    if w.empty:
        return None
    return float(sum(fc[m] * w[m] for m in w.index) / w.sum())


def precip_weights(scores: dict, L: int, present: list[str]) -> pd.Series:
    st = _day_stats(scores, L, "pcp")
    mae = pd.Series({m: st.get(m, {}).get("mae") for m in present}, dtype=float)
    w = (1.0 / mae).replace([np.inf, -np.inf], np.nan).dropna()
    return w / w.sum() if len(w) else w


def _amount(vals: dict, scores: dict, L: int):
    if not vals:
        return None
    w = precip_weights(scores, L, list(vals))
    if w.empty:
        return _median(list(vals.values()))
    return float(sum(vals[m] * w[m] for m in w.index))


def hour_values(sources: dict, t: dt.datetime, issue: dt.date, scores: dict, hscores: dict) -> dict:
    key = hour_key(t)
    L = _lead(t, issue)
    precs = {m: s["precip"][key] for m, s in sources.items() if key in s["precip"]}
    wet_src = [m for m, p in precs.items() if p >= WET_HOUR_MM]
    shares = []
    for m in wet_src:
        sn = sources[m]["snowfall"].get(key)
        if sn is not None and precs[m] > 0:
            shares.append(min(1.0, sn / 0.7 / precs[m]))
    winds = [s["wind"].get(key) for s in sources.values()]
    dirs = [s["wind_dir"].get(key) for s in sources.values()]
    return {
        "temp": blend_temp(sources, key, t, L, scores, hscores),
        "precip_mm": _amount(precs, scores, L),
        "chance": (len(wet_src) / len(precs)) if precs else None,
        "snow_share": _median(shares),
        "cloud": _median([s["cloud"].get(key) for s in sources.values()]),
        "rh": _median([s["rh"].get(key) for s in sources.values()]),
        "wind": _median(winds),
        "wind_dir": vector_dir(dirs, winds),
        "precip_by_source": precs,
        "snow_by_source": {m: sources[m]["snowfall"].get(key) for m in precs},
    }


def condition_of(chance, snow_share, temp, cloud) -> str | None:
    if chance is not None and chance >= 0.5:
        return phase_from_share(snow_share, temp)
    if chance is None and cloud is None:
        return None
    return sky_class(cloud)


# --- the nudge toward the latest observation ---------------------------------------------

def nudge_offset(now_block: dict | None, sources, issue, scores, hscores):
    """(offset deg C, observation time) or (0, None)."""
    if not now_block or now_block.get("temp") is None or not now_block.get("observed_at"):
        return 0.0, None
    ot = dt.datetime.strptime(now_block["observed_at"], "%Y-%m-%dT%H:%M:%SZ")
    h0 = ot.replace(minute=0, second=0)
    a = blend_temp(sources, hour_key(h0), h0, _lead(h0, issue), scores, hscores)
    h1 = h0 + dt.timedelta(hours=1)
    b = blend_temp(sources, hour_key(h1), h1, _lead(h1, issue), scores, hscores)
    if a is None and b is None:
        return 0.0, None
    f = ot.minute / 60.0
    fc = a if b is None else b if a is None else a + (b - a) * f
    return float(now_block["temp"]) - fc, ot


def nudged(temp, t: dt.datetime, offset, obs_t):
    if temp is None or obs_t is None:
        return temp
    h = max(0.0, (t - obs_t).total_seconds() / 3600)
    return temp + offset * math.exp(-h / NUDGE_FADE_H)


# --- the published blocks ------------------------------------------------------------------

def _hour_entry(v: dict, t, offset, obs_t):
    temp = nudged(v["temp"], t, offset, obs_t)
    return {
        "time": t.strftime("%Y-%m-%dT%H:00:00Z"),
        "condition": condition_of(v["chance"], v["snow_share"], temp, v["cloud"]),
        "temp": _r(temp),
        "feels_like": _r(feels_like(temp, v["wind"], v["rh"])),
        "precip_chance": None if v["chance"] is None else int(round(100 * v["chance"])),
        "precip_mm": None if v["precip_mm"] is None else _r(max(v["precip_mm"], 0.0)),
        "cloud_pct": None if v["cloud"] is None else int(round(v["cloud"])),
        "wind_kmh": _r(v["wind"], 0) if v["wind"] is not None else None,
        "wind_dir_deg": v["wind_dir"],
    }


FIELDS = ("time", "condition", "temp", "feels_like", "precip_chance", "precip_mm",
          "cloud_pct", "wind_kmh", "wind_dir_deg")


def _columns(entries: list[dict]) -> dict:
    return {f: [e[f] for e in entries] for f in FIELDS}


def build(sources: dict, scores: dict, hscores: dict, now: int, issue: dt.date,
          now_block: dict | None, days: list[dict]) -> dict:
    """{"hourly", "blocks", "today", "day_conditions"} for publish.build.
    days: the published days (for the chance and high/low of each day)."""
    _WEIGHTS.clear()
    base = dt.datetime.fromtimestamp(now - now % 3600, dt.timezone.utc).replace(tzinfo=None)
    offset, obs_t = nudge_offset(now_block, sources, issue, scores, hscores)
    vals = {}
    for k in range(BLOCKS_TO_H):
        t = base + dt.timedelta(hours=k)
        vals[t] = hour_values(sources, t, issue, scores, hscores)

    hourly = [_hour_entry(vals[base + dt.timedelta(hours=k)], base + dt.timedelta(hours=k), offset, obs_t)
              for k in range(HOURS)]

    blocks = []
    for k in range(HOURS, BLOCKS_TO_H, BLOCK_H):
        ts = [base + dt.timedelta(hours=k + j) for j in range(BLOCK_H)]
        vs = [vals[t] for t in ts]
        temps = [nudged(v["temp"], t, offset, obs_t) for v, t in zip(vs, ts)]
        temps = [x for x in temps if x is not None]
        # wet share over the block: each source's block total
        totals, snows = {}, {}
        for v in vs:
            for m, p in v["precip_by_source"].items():
                totals[m] = totals.get(m, 0.0) + p
                sn = v["snow_by_source"].get(m)
                if sn is not None:
                    snows[m] = snows.get(m, 0.0) + sn
        wet = [m for m, p in totals.items() if p >= WET_HOUR_MM]
        shares = [min(1.0, snows[m] / 0.7 / totals[m]) for m in wet if m in snows and totals[m] > 0]
        chance = len(wet) / len(totals) if totals else None
        amounts = [v["precip_mm"] for v in vs if v["precip_mm"] is not None]
        mid = vs[1]
        temp = sum(temps) / len(temps) if temps else None
        cloud = _median([v["cloud"] for v in vs])
        blocks.append({
            "time": ts[0].strftime("%Y-%m-%dT%H:00:00Z"),
            "condition": condition_of(chance, _median(shares), temp, cloud),
            "temp": _r(temp),
            "feels_like": _r(feels_like(temp, mid["wind"], mid["rh"])),
            "precip_chance": None if chance is None else int(round(100 * chance)),
            "precip_mm": _r(max(sum(amounts), 0.0)) if len(amounts) == BLOCK_H else None,
            "cloud_pct": None if cloud is None else int(round(cloud)),
            "wind_kmh": _r(mid["wind"], 0) if mid["wind"] is not None else None,
            "wind_dir_deg": mid["wind_dir"],
        })

    return {"hourly": hourly, "blocks": blocks,
            "today": today_block(sources, scores, hscores, now, issue, now_block, offset, obs_t),
            "nudge": {"offset": _r(offset, 2), "observed_at": None if obs_t is None else obs_t.strftime("%Y-%m-%dT%H:%M:%SZ")}}


def today_block(sources, scores, hscores, now, issue, now_block, offset, obs_t) -> dict:
    start = dt.datetime.combine(issue, dt.time(0)) - dt.timedelta(hours=CLIMATE_DAY_OFFSET_H)
    end = start + dt.timedelta(hours=24)
    t = dt.datetime.fromtimestamp(now - now % 3600, dt.timezone.utc).replace(tzinfo=None)
    rest, totals, snows = [], {}, {}
    while t < end:
        v = hour_values(sources, t, issue, scores, hscores)
        rest.append((t, nudged(v["temp"], t, offset, obs_t), v))
        if t >= dt.datetime.fromtimestamp(now, dt.timezone.utc).replace(tzinfo=None):
            for m, p in v["precip_by_source"].items():
                totals[m] = totals.get(m, 0.0) + p
                sn = v["snow_by_source"].get(m)
                if sn is not None:
                    snows[m] = snows.get(m, 0.0) + sn
        t += dt.timedelta(hours=1)
    temps = [x for _, x, _ in rest if x is not None]
    nb = now_block or {}
    same_day = nb.get("so_far_since") == start.strftime("%Y-%m-%dT%H:%M:%SZ")
    hs, ls = (nb.get("high_so_far"), nb.get("low_so_far")) if same_day else (None, None)
    hi_f, lo_f = (max(temps) if temps else None), (min(temps) if temps else None)
    high = max(x for x in (hs, hi_f) if x is not None) if (hs is not None or hi_f is not None) else None
    low = min(x for x in (ls, lo_f) if x is not None) if (ls is not None or lo_f is not None) else None
    so_far = nb.get("precip_so_far_mm") if same_day else None
    amounts = [v["precip_mm"] for _, _, v in rest if v["precip_mm"] is not None]
    rest_mm = max(sum(amounts), 0.0) if amounts else None
    wet = [m for m, p in totals.items() if p >= WET_DAY_MM]
    chance = len(wet) / len(totals) if totals else None
    shares = [min(1.0, snows[m] / 0.7 / totals[m]) for m in wet if m in snows and totals[m] > 0]
    cloud = _median([_median([s["cloud"].get(hour_key(t)) for t, _, _ in rest]) for s in sources.values()])
    cond = (phase_from_share(_median(shares), hi_f) if chance is not None and chance >= 0.5
            else sky_class(cloud))
    return {
        "date": issue.isoformat(),
        "hours": {"from": start.strftime("%Y-%m-%dT%H:00:00Z"), "to": end.strftime("%Y-%m-%dT%H:00:00Z")},
        "high": _r(high), "low": _r(low),
        "high_from": None if high is None else
        ("observed" if hs is not None and (hi_f is None or hs >= hi_f) else "forecast"),
        "low_from": None if low is None else
        ("observed" if ls is not None and (lo_f is None or ls <= lo_f) else "forecast"),
        "precip_so_far_mm": so_far,
        "precip_rest_mm": _r(rest_mm),
        "precip_mm": _r((so_far or 0.0) + (rest_mm or 0.0)) if (so_far is not None or rest_mm is not None) else None,
        "precip_chance_rest": None if chance is None else int(round(100 * chance)),
        "condition": cond,
        "verified": False,
    }


def day_condition(sources: dict, date: dt.date, chance_pct, high, low) -> dict:
    """The day's general weather over its climate day (module docstring)."""
    start = dt.datetime.combine(date, dt.time(0)) - dt.timedelta(hours=CLIMATE_DAY_OFFSET_H)
    keys = [hour_key(start + dt.timedelta(hours=k)) for k in range(24)]
    clouds, shares = [], []
    for s in sources.values():
        cs_ = [s["cloud"][k] for k in keys if k in s["cloud"]]
        if len(cs_) >= 20:
            clouds.append(sum(cs_) / len(cs_))
        pr = [s["precip"][k] for k in keys if k in s["precip"]]
        sn = [s["snowfall"][k] for k in keys if k in s["snowfall"]]
        if len(pr) >= 20 and len(sn) >= 20 and sum(pr) >= WET_DAY_MM:
            shares.append(min(1.0, sum(sn) / 0.7 / sum(pr)))
    cloud = _median(clouds)
    if chance_pct is not None and chance_pct >= 50:
        share = _median(shares)
        if share is not None:
            cls = phase_from_share(share)
        elif high is not None and low is not None:  # no snowfall data: the day's mean temperature
            cls = phase_from_share(None, (high + low) / 2)
        else:
            cls = None
    else:
        cls = sky_class(cloud)
    return {"class": cls, "cloud_pct": None if cloud is None else int(round(cloud)),
            "sources": len(clouds)}
