"""Open-Meteo access with polite retries.

Free API (https://open-meteo.com/en/terms, https://open-meteo.com/en/pricing,
checked 24 Nov 2026): non-commercial use only; under 600 calls a minute,
5,000 an hour, 10,000 a day and 300,000 a month, "applied by IP addresses
and application". A call asking for more than 10 variables or more than
2 weeks of data counts as more than one (fractional: 15 variables over
2 weeks = 1.5 calls). Data licence CC BY 4.0: credit
"Weather data by Open-Meteo.com".

Endpoints (checked 24 Nov 2026):
- Live forecast: FORECAST. Docs https://open-meteo.com/en/docs
  forecast_days 0 to 16, past_days 0 to 92. Several models go in one call,
  comma separated; each comes back with the model id as a suffix,
  e.g. temperature_2m_gfs_seamless (checked live).
  The docs now name the seamless ids ncep_gfs_seamless, cmc_gem_seamless and
  dwd_icon_seamless. The pilot's short ids (gfs_seamless, gem_seamless,
  icon_seamless) still work (checked live) and we keep them so stored
  history stays under one name.
  Model id list: https://github.com/open-meteo/open-meteo-website/blob/main/src/routes/en/docs/options.ts
- Ensemble: ENSEMBLE. Docs https://open-meteo.com/en/docs/ensemble-api
  forecast_days 0 to 35. Members come back as temperature_2m (control) plus
  temperature_2m_member01 and up. Model ids:
  https://github.com/open-meteo/open-meteo-website/blob/main/src/routes/en/docs/ensemble-api/options.ts
- Model-update metadata: meta_url(). Docs https://open-meteo.com/en/docs/model-updates
  Fields: last_run_initialisation_time (run time, Unix seconds),
  last_run_availability_time (when the API serves it; Open-Meteo says wait
  10 minutes after this), update_interval_seconds, temporal_resolution_seconds.
  "API calls to the metadata API are not counted toward daily or monthly
  request limits." Metadata paths differ from API model ids; the paths per
  source are in config/sources.json. Path list:
  https://github.com/open-meteo/open-meteo-website/blob/main/src/routes/en/docs/model-updates/+page.svelte
- Previous Runs and Single Runs: confirmed in the pilot.
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

PREVIOUS_RUNS = "https://previous-runs-api.open-meteo.com/v1/forecast"
SINGLE_RUNS = "https://single-runs-api.open-meteo.com/v1/forecast"
FORECAST = "https://api.open-meteo.com/v1/forecast"
ENSEMBLE = "https://ensemble-api.open-meteo.com/v1/ensemble"
META = "https://{host}.open-meteo.com/data/{path}/static/meta.json"


def meta_url(path: str, ensemble: bool = False) -> str:
    """Model-update metadata URL. Ensemble models live on the ensemble-api host."""
    return META.format(host="ensemble-api" if ensemble else "api", path=path)


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
