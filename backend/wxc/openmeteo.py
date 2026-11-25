"""Open-Meteo access with polite retries.

Free API: non-commercial use, 10,000 calls a day, 5,000 an hour, 600 a
minute, counted per internet address. Credit: CC BY 4.0.
Previous Runs and Single Runs URLs are confirmed from the pilot.
TODO (stage 1): confirm the live forecast URL, the Ensemble API model ids
and the model-update metadata endpoint against current docs before use.
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

PREVIOUS_RUNS = "https://previous-runs-api.open-meteo.com/v1/forecast"
SINGLE_RUNS = "https://single-runs-api.open-meteo.com/v1/forecast"
FORECAST = "https://api.open-meteo.com/v1/forecast"  # TODO confirm in docs


class LimitRefused(RuntimeError):
    """Open-Meteo refused the call because the address hit its limit."""


def get_json(url: str, tries: int = 8, log=print) -> dict:
    """GET with retries. Raises LimitRefused if every try hits the rate limit."""
    last = None
    for k in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                data = json.load(r)
        except urllib.error.HTTPError as e:
            try:
                data = json.loads(e.read())
            except Exception:
                data = None
        except Exception as e:  # network reset, timeout
            last = e
            data = None
        if data is not None and data.get("error") and "limit" in str(data.get("reason", "")).lower():
            last = data.get("reason")
            log(f"open-meteo refused (limit), try {k + 1}/{tries}")
            time.sleep(4 + 2 * k)
            continue
        if data is None:
            time.sleep(3 + 2 * k)
            continue
        if data.get("error"):
            raise RuntimeError(f"open-meteo error: {data.get('reason')}")
        return data
    raise LimitRefused(str(last))


def previous_runs_url(lat, lon, elevation, model, start, end, leads=range(1, 8),
                      variables=("temperature_2m", "precipitation")) -> str:
    hourly = [f"{v}_previous_day{L}" for v in variables for L in leads]
    q = dict(latitude=lat, longitude=lon, elevation=elevation, hourly=",".join(hourly),
             models=model, start_date=start, end_date=end, timezone="GMT")
    return PREVIOUS_RUNS + "?" + urllib.parse.urlencode(q)


def single_run_url(lat, lon, elevation, model, run_iso, forecast_days=16,
                   variables=("temperature_2m", "precipitation")) -> str:
    q = dict(latitude=lat, longitude=lon, elevation=elevation, hourly=",".join(variables),
             models=model, run=run_iso, forecast_days=forecast_days, timezone="GMT")
    return SINGLE_RUNS + "?" + urllib.parse.urlencode(q)
