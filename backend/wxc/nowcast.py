"""Current condition, the "now" log and its nightly scores (owner decision, 28 Nov 2026).

"Now" comes from measurements first. The station's values stay as they are
(backend/wxc/obs.py). The current condition:
- precipitation falling now and its phase: measured (obs.precip_now: weighing
  gauge, tipping bucket, wet-bulb);
- cloud: the forecast's current hour until there is an observed cloud
  source (GOES, docs/research/HOURLY_AND_CONDITIONS.md);
- class: rain, snow or mixed when precipitation falls; otherwise clear (cloud
  under 30%), partly cloudy (30 to 70%) or cloudy (over 70%).
`basis` in the published block says, for every value, "measured" or
"forecast". The app does not show it yet. When the station's minute records
are missing, precipitation and phase also come from the forecast, and
`basis` says so.

Forecast values here are provisional (method MEDIAN_V0): the median of the
sources' newest runs, raw (no habit fix, no weights). On the research data
(Single Runs, 00 UTC, leads 5 to 12 h, Jun to Nov 2026) the median beat the
mean for temperature (0.79 vs 0.86 deg C average miss, 800 hours) and for
cloud against GOES (8.3 vs 11.2 points, 60 times, small sample). Wet = at
least half the sources forecast 0.2 mm or more in the hour (the same as the
median at 0.2 mm). Phase: snow if the median snow share (snowfall in cm / 0.7
= water mm, over precipitation) of the wet sources is 0.8 or more, rain if
0.2 or less, mixed between. A source counts when its run is at most 24 h older
than the newest run (the place file's rule).

The log (data/store/<place>/now_log.jsonl, one line per publish): what "now"
said and the first STRIP_HOURS hours of a shadow hourly strip, with each
source's values, so a better method can be scored on the same record later.
Nothing from the strip is published. score() matches the log to the station's
saved hourly records (backend/wxc/swob_archive.py) nightly: temperature miss by
hours ahead, and rain-or-snow yes or no. Results go to live_now.csv and
now_scores.json, not to the place file or scores.json.
"""
from __future__ import annotations

import datetime as dt
import json
import math
import statistics
from pathlib import Path

import pandas as pd

from . import swob_archive as sa
from .refresh import EXTRA_DIR, _write_json, iso, load_state

METHOD = "median_v0"
STRIP_HOURS = 6
LATE_RUN_H = 24      # as publish.LATE_RUN_H
WET_MM = 0.2         # an hour is wet at 0.2 mm or more (as the research)
CLEAR_MAX, PARTLY_MAX = 30, 70  # cloud % class bounds
NOW_LOG = "now_log.jsonl"
SCORES = "now_scores.json"
LIVE_CSV = "live_now.csv"
EXTRA_LOOKBACK_DAYS = 2


# --- the sources' hourly values ------------------------------------------------

def _hourly(rec: dict) -> dict:
    return (rec.get("response") or {}).get("hourly") or {}


def _series(h: dict, var: str) -> dict:
    """{UTC hour string 'YYYY-MM-DDTHH:00': value} for one variable."""
    out = {}
    for t, v in zip(h.get("time", []), h.get(var, []) or []):
        if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v):
            out[t[:13] + ":00"] = float(v)
    return out


def newest_extra(store: Path, place_id: str, source: str, now: int) -> dict | None:
    """The newest saved extra-variable pull of a source fetched at or before now."""
    t = dt.datetime.fromtimestamp(now, dt.timezone.utc)
    for k in range(EXTRA_LOOKBACK_DAYS + 1):
        day = (t - dt.timedelta(days=k)).strftime("%Y-%m-%d")
        files = sorted((store / place_id / EXTRA_DIR / day).glob(f"*Z_{source}.json"), reverse=True)
        for f in files:
            try:
                rec = json.loads(f.read_text())
            except Exception:
                continue
            if rec.get("fetched_at", "") <= iso(now):
                return rec
    return None


def load_sources(store: Path, place_id: str, pool: list[str], now: int) -> dict:
    """{source: {"run_unix", "temp", "precip", "cloud", "snowfall", "rh",
    "wind", "wind_dir"}} from the newest saved main pull (state.json); the
    variables a main pull lacks (pulls before 28 Nov 2026 had temperature
    and precipitation only) come from the newest extra pull."""
    state = load_state(store, place_id)
    out = {}
    for m in pool:
        s = state.get(m)
        if not s:
            continue
        try:
            rec = json.loads((store / s["file"]).read_text())
        except Exception:
            continue
        runs = s.get("runs") or {}
        h = _hourly(rec)
        src = {"run_unix": max(runs.values()) if runs else s["fetched_unix"],
               "temp": _series(h, "temperature_2m"), "precip": _series(h, "precipitation")}
        extra = None
        for key, var in EXTRA_SERIES.items():
            src[key] = _series(h, var)
            if not src[key]:
                if extra is None:
                    extra = newest_extra(store, place_id, m, now) or {}
                src[key] = _series(_hourly(extra), var)
        out[m] = src
    newest = max((s["run_unix"] for s in out.values()), default=None)
    return {m: s for m, s in out.items() if newest - s["run_unix"] <= LATE_RUN_H * 3600}


EXTRA_SERIES = {"cloud": "cloud_cover", "snowfall": "snowfall", "rh": "relative_humidity_2m",
                "wind": "wind_speed_10m", "wind_dir": "wind_direction_10m"}


def hour_key(t: dt.datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:00")


def _median(xs):
    return statistics.median(xs) if xs else None


def snow_share(precip_mm, snowfall_cm):
    if precip_mm is None or snowfall_cm is None or precip_mm <= 0:
        return None
    return min(1.0, snowfall_cm / 0.7 / precip_mm)


def phase_from_share(share) -> str | None:
    if share is None:
        return None
    return "snow" if share >= 0.8 else "rain" if share <= 0.2 else "mixed"


def forecast_hour(sources: dict, key: str) -> dict:
    """Provisional forecast for one valid hour (precipitation: the hour ending then)."""
    temps = [s["temp"][key] for s in sources.values() if key in s["temp"]]
    precs = {m: s["precip"][key] for m, s in sources.items() if key in s["precip"]}
    clouds = [s["cloud"][key] for s in sources.values() if key in s["cloud"]]
    wet_src = [m for m, p in precs.items() if p >= WET_MM]
    shares = [x for m in wet_src
              if (x := snow_share(precs[m], sources[m]["snowfall"].get(key))) is not None]
    chance = len(wet_src) / len(precs) if precs else None
    wet = None if chance is None else chance >= 0.5
    return {
        "temp": None if (t := _median(temps)) is None else round(t, 1),
        "precip_mm": None if (p := _median(list(precs.values()))) is None else round(p, 1),
        "chance": None if chance is None else round(100 * chance),
        "wet": wet,
        "phase": phase_from_share(_median(shares)) if wet else None,
        "cloud": None if (c := _median(clouds)) is None else int(round(c)),
        "sources": {"temp": len(temps), "precip": len(precs), "cloud": len(clouds)},
    }


def sky_class(cloud) -> str | None:
    if cloud is None:
        return None
    return "clear" if cloud < CLEAR_MAX else "partly" if cloud <= PARTLY_MAX else "cloudy"


# --- the current condition ----------------------------------------------------

STATION_VALUES = ("temp", "dew_point", "humidity", "wind_kmh", "wind_dir_deg", "gust_kmh",
                  "pressure_kpa", "pressure_tendency", "pressure_change_3h_kpa", "precip_1h_mm",
                  "high_so_far", "low_so_far", "precip_so_far_mm")


def condition(now_block: dict, fc: dict | None) -> tuple[dict, dict]:
    """(condition, basis) for the now block. fc is forecast_hour() for the
    current hour, or None."""
    pn = now_block.get("precip_now") or {}
    fc = fc or {}
    if pn.get("falling") is not None:
        falling, falling_basis = pn["falling"], "measured"
    else:
        falling, falling_basis = fc.get("wet"), ("forecast" if fc.get("wet") is not None else None)
    phase = phase_basis = None
    if falling:
        if falling_basis == "measured" and pn.get("phase"):
            phase, phase_basis = pn["phase"], "measured"
        elif fc.get("phase"):
            phase, phase_basis = fc["phase"], "forecast"
    cloud = fc.get("cloud")
    if falling:
        cls = phase  # None if the phase is unknown
        cls_basis = phase_basis
    else:
        cls = sky_class(cloud) if falling is not None else None
        cls_basis = "forecast" if cls else None
    cond = {
        "class": cls,
        "falling": falling,
        "phase": phase,
        "cloud_pct": cloud,
        "forecast_hour": fc.get("hour"),
        "method": METHOD,
    }
    basis = {k: "measured" for k in STATION_VALUES if now_block.get(k) is not None}
    basis.update({"condition": cls_basis, "falling": falling_basis, "phase": phase_basis,
                  "cloud_pct": "forecast" if cloud is not None else None})
    return cond, {k: v for k, v in basis.items() if v is not None}


def now_forecast(sources: dict, now: int) -> dict:
    """forecast_hour() for the hour nearest `now` (cloud is instant at the
    hour; precipitation is the hour ending then)."""
    t = dt.datetime.fromtimestamp(now + 1800, dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
    fc = forecast_hour(sources, hour_key(t))
    fc["hour"] = t.strftime("%Y-%m-%dT%H:00:00Z")
    return fc


def with_condition(now_block: dict, sources: dict, now: int) -> dict:
    """A copy of the now block with "condition" and "basis" added (nothing changed)."""
    cond, basis = condition(now_block, now_forecast(sources, now) if sources else None)
    return {**now_block, "condition": cond, "basis": basis}


# --- the log -------------------------------------------------------------------

def strip(sources: dict, now: int, hours: int = STRIP_HOURS) -> list[dict]:
    base = dt.datetime.fromtimestamp(now - now % 3600, dt.timezone.utc)
    out = []
    for h in range(1, hours + 1):
        t = base + dt.timedelta(hours=h)
        key = hour_key(t)
        fc = forecast_hour(sources, key)
        fc.pop("sources")
        out.append({"h": h, "valid": t.strftime("%Y-%m-%dT%H:00:00Z"), **fc,
                    "by_source": {m: [s["temp"].get(key), s["precip"].get(key),
                                      s["snowfall"].get(key), s["cloud"].get(key)]
                                  for m, s in sorted(sources.items())}})
    return out


def published_strip(hourly: dict, sources: dict, now: int, hours: int = STRIP_HOURS) -> list[dict]:
    """The first hours of the published hourly block (hourly[1..6]: the next
    whole hours, as strip()), with each source's values alongside."""
    base = dt.datetime.fromtimestamp(now - now % 3600, dt.timezone.utc)
    idx = {t: i for i, t in enumerate(hourly.get("time", []))}
    out = []
    for h in range(1, hours + 1):
        t = base + dt.timedelta(hours=h)
        v, key = t.strftime("%Y-%m-%dT%H:00:00Z"), hour_key(t)
        i = idx.get(v)
        get = (lambda f: hourly[f][i]) if i is not None else (lambda f: None)
        cond = get("condition")
        out.append({"h": h, "valid": v, "temp": get("temp"), "precip_mm": get("precip_mm"),
                    "chance": get("precip_chance"),
                    "wet": None if cond is None else cond in ("rain", "snow", "mixed"),
                    "phase": cond if cond in ("rain", "snow", "mixed") else None,
                    "cloud": get("cloud_pct"), "condition": cond,
                    "by_source": {m: [s["temp"].get(key), s["precip"].get(key),
                                      s["snowfall"].get(key), s["cloud"].get(key)]
                                  for m, s in sorted(sources.items())}})
    return out


def log_line(now_pub: dict | None, sources: dict, now: int, published_hourly: dict | None = None) -> dict:
    """What the file said "now" and the next 6 hours. From 28 Nov 2026 the
    hours are the published hourly block (method "published_<its method>");
    before it existed, the shadow median strip (METHOD)."""
    n = now_pub or {}
    strip_ = (published_strip(published_hourly, sources, now) if published_hourly
              else strip(sources, now))
    method = f"published_{published_hourly.get('method')}" if published_hourly else METHOD
    return {
        "issued_at": iso(now), "method": method,
        "by_source_fields": ["temp", "precip_mm", "snowfall_cm", "cloud_pct"],
        "now": None if not now_pub else {
            "observed_at": n.get("observed_at"), "temp": n.get("temp"),
            "precip_1h_mm": n.get("precip_1h_mm"),
            "precip_now": n.get("precip_now"), "condition": n.get("condition"), "basis": n.get("basis")},
        "strip": strip_,
    }


def log_now(store: Path, place_id: str, line: dict) -> None:
    path = store / place_id / NOW_LOG
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(line, separators=(",", ":")) + "\n")


# --- nightly scores --------------------------------------------------------------

def truth(store: Path, place_id: str) -> pd.DataFrame:
    """Station hourly values by UTC hour from the saved SWOB records: temp,
    1 h precipitation, wet (0.2 mm or more), phase of a wet hour (wet-bulb)."""
    fields = sa.load_fields(store, place_id)
    rows = []
    for p in sorted(sa.folder(store, place_id).glob("hourly-*.jsonl")):
        for t, rec in sa.read_month(p).items():
            props, _ = sa.expand(rec, fields)
            temp = props.get("air_temp") if props.get("air_temp-qa") == 100 else None
            pcp = props.get("pcpn_amt_pst1hr")
            if props.get("pcpn_amt_pst1hr-data_flag-value") not in (None, 1):
                pcp = None
            wb = props.get("wetblb_temp")
            wet = None if not isinstance(pcp, (int, float)) else pcp >= WET_MM
            phase = None
            if wet and isinstance(wb, (int, float)):
                phase = "rain" if wb >= 2.0 else "snow" if wb <= 0.5 else "mixed"
            rows.append({"valid": t, "temp": temp, "precip": pcp, "wet": wet, "phase": phase})
    return pd.DataFrame(rows, columns=["valid", "temp", "precip", "wet", "phase"]).set_index("valid")


def _lines(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for x in path.read_text().splitlines():
        try:
            out.append(json.loads(x))
        except Exception:
            continue
    return out


def matched(store: Path, place_id: str) -> pd.DataFrame:
    """One row per logged value with the station's value next to it. Lead 0
    is the published "now": temperature against the hourly record nearest the
    issue time, falling against the hour that contains it."""
    T = truth(store, place_id)
    rows = []
    for ln in _lines(store / place_id / NOW_LOG):
        issued = dt.datetime.strptime(ln["issued_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
        n = ln.get("now")
        if n:
            near = (issued + dt.timedelta(minutes=30)).replace(minute=0, second=0).strftime("%Y-%m-%dT%H:00:00Z")
            end = (issued.replace(minute=0, second=0) + dt.timedelta(hours=1)).strftime("%Y-%m-%dT%H:00:00Z")
            cond = n.get("condition") or {}
            rows.append({"issued_at": ln["issued_at"], "lead": 0, "valid": near,
                         "temp": n.get("temp"), "obs_temp": T["temp"].get(near),
                         "wet": cond.get("falling"), "obs_wet": T["wet"].get(end),
                         "phase": cond.get("phase"), "obs_phase": T["phase"].get(end)})
        for s in ln.get("strip", []):
            v = s["valid"]
            rows.append({"issued_at": ln["issued_at"], "lead": s["h"], "valid": v,
                         "temp": s.get("temp"), "obs_temp": T["temp"].get(v),
                         "wet": s.get("wet"), "obs_wet": T["wet"].get(v),
                         "phase": s.get("phase"), "obs_phase": T["phase"].get(v)})
    cols = ["issued_at", "lead", "valid", "temp", "obs_temp", "wet", "obs_wet", "phase", "obs_phase"]
    return pd.DataFrame(rows, columns=cols)


def summary(rows: pd.DataFrame) -> list[dict]:
    out = []
    for lead in range(0, STRIP_HOURS + 1):
        x = rows[rows["lead"] == lead]
        t = x.dropna(subset=["temp", "obs_temp"])
        err = (t["temp"].astype(float) - t["obs_temp"].astype(float))
        w = x.dropna(subset=["wet", "obs_wet"])
        f, o = w["wet"].astype(bool), w["obs_wet"].astype(bool)
        p = x.dropna(subset=["phase", "obs_phase"])
        out.append({
            "lead": lead,
            "temp": {"miss": round(float(err.abs().mean()), 2) if len(err) else None,
                     "bias": round(float(err.mean()), 2) if len(err) else None, "n": int(len(err))},
            "rain_or_snow": {"hit_rate": round(float((f & o).sum() / o.sum()), 3) if o.sum() else None,
                             "false_alarm_ratio": round(float((f & ~o).sum() / f.sum()), 3) if f.sum() else None,
                             "right": round(float((f == o).mean()), 3) if len(w) else None,
                             "wet_hours": int(o.sum()), "n": int(len(w))},
            "phase": {"right": round(float((p["phase"] == p["obs_phase"]).mean()), 3) if len(p) else None,
                      "n": int(len(p))},
        })
    return out


def score(store: Path, place_id: str, now: int) -> dict | None:
    """Nightly: match the now log to the station; write live_now.csv and
    now_scores.json. None when there is no log yet."""
    rows = matched(store, place_id)
    if rows.empty:
        return None
    rows.to_csv(store / place_id / LIVE_CSV, index=False)
    lines = _lines(store / place_id / NOW_LOG)
    out = {"computed_at": iso(now), "basis": "live", "method": METHOD,
           "since": lines[0]["issued_at"] if lines else None, "issues": len(lines),
           "truth": "station hourly records (swob/), wet at 0.2 mm or more in the hour",
           "shown_in_app": False, "leads": summary(rows)}
    _write_json(store / place_id / SCORES, out)
    return out
