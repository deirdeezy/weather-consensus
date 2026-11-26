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
- Previous Runs: PREVIOUS_RUNS. Docs https://open-meteo.com/en/docs/previous-runs-api
  "_previous_day1 is the value that was predicted 24 hours before valid time
  ... up to day 7." Most models archived from January 2024.
- Single Runs: SINGLE_RUNS. Docs https://open-meteo.com/en/docs/single-runs-api
  The full run for one initialisation time (&run=YYYY-MM-DDTHH:MM). "Most
  models are archived from 2nd of April 2026." No ensembles (checked live).
- Rate-limit refusals (https://github.com/open-meteo/open-meteo/blob/main/docs/api-rate-limiting.md
  and Sources/App/Helper/Vapor/RateLimiter.swift, checked 26 Nov 2026): HTTP 429
  with reason "Minutely ...", "Hourly ..." or "Daily API request limit
  exceeded", plus a Retry-After header in seconds. Usage "is generally shared
  by requests from the same public IP address", so a GitHub runner can be
  refused when other users of its address used the quota. Only the minutely
  limit can clear within our retry waits; get_json gives up at once on the
  others (the 25 Nov 19:37 UTC nightly run spent 26 minutes retrying a daily
  refusal 8 times per call).
- Usage headers (checked live 26 Nov 2026): counted calls answer with
  X-RateLimit-Cost (weighted calls this request used), X-RateLimit-Remaining,
  X-RateLimit-Limit and X-RateLimit-Window (seconds). Metadata files carry
  none (they are not counted). get_json prints them for every counted call
  (note_usage) so the job log shows our own cost and how much of the
  address's quota was left: a low Remaining on a fresh runner means other
  users of that address. Only host, path and model are printed, never the
  query string.
- Ensemble history: none. Past ensemble runs are not served by Single Runs or
  the Ensemble API (checked live 24 Nov 2026); the Ensemble Mean API keeps a
  best-estimate series, not forecasts by lead.
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
CREDIT = "Weather data by Open-Meteo.com (CC BY 4.0)"


def meta_url(path: str, ensemble: bool = False) -> str:
    """Model-update metadata URL. Ensemble models live on the ensemble-api host."""
    return META.format(host="ensemble-api" if ensemble else "api", path=path)


class LimitRefused(RuntimeError):
    """No try succeeded. limit is True when the last try was a rate-limit
    refusal (the address hit its limit), False for network failures."""

    def __init__(self, msg: str, limit: bool = False):
        super().__init__(msg)
        self.limit = limit


def is_limit(e: BaseException) -> bool:
    """True when e is a rate-limit refusal (not a network failure or an
    answer such as "run not available")."""
    return isinstance(e, LimitRefused) and e.limit


USAGE_HEADERS = ("X-RateLimit-Cost", "X-RateLimit-Remaining", "X-RateLimit-Limit", "X-RateLimit-Window")
usage: list[dict] = []  # one entry per counted call in this process
echo = print


def _what(url: str) -> str:
    """Host, path and model of a call: nothing else from the query string."""
    u = urllib.parse.urlparse(url)
    models = urllib.parse.parse_qs(u.query).get("models", [""])[0]
    return f"{u.hostname}{u.path}" + (f" {models}" if models else "")


def note_usage(url: str, headers) -> dict | None:
    """Record and print Open-Meteo's usage headers for one call, if present."""
    if headers is None or headers.get("X-RateLimit-Cost") is None:
        return None
    rec = {"call": _what(url), **{h[len("X-RateLimit-"):].lower(): headers.get(h) for h in USAGE_HEADERS}}
    usage.append(rec)
    echo(f"  open-meteo  cost {rec['cost']}  remaining {rec['remaining']} of {rec['limit']}"
         f" per {rec['window']} s  {rec['call']}")
    return rec


def usage_summary() -> str:
    """One line: counted calls, total weighted cost, lowest Remaining seen."""
    if not usage:
        return "Open-Meteo: no counted calls"
    cost = sum(float(u["cost"] or 0) for u in usage)
    low = min(usage, key=lambda u: float(u["remaining"] or 0))
    return (f"Open-Meteo: {len(usage)} counted calls, weighted cost {cost:.1f}, lowest remaining "
            f"{low['remaining']} of {low['limit']} per {low['window']} s")


RETRY_AFTER_MAX_S = 120  # a refusal that asks for a longer wait is not retried


def _wait_too_long(reason: str, retry_after) -> bool:
    """True for a refusal our retries cannot outwait: the hourly or daily
    limit, or a Retry-After longer than RETRY_AFTER_MAX_S."""
    r = reason.lower()
    if r.startswith(("daily", "hourly", "monthly")):
        return True
    try:
        return float(retry_after) > RETRY_AFTER_MAX_S
    except (TypeError, ValueError):
        return False


def get_json(url: str, tries: int = 8, log=print, sleep=time.sleep) -> dict:
    """GET with retries. Raises LimitRefused if no try succeeds.

    log(kind, detail) is called for every failed try; kind is "limit" (rate
    limit refusal) or "network" (no usable answer: reset, timeout, bad HTTP).
    """
    last, limited = None, False
    for k in range(tries):
        retry_after = None
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                note_usage(url, getattr(r, "headers", None))
                data = json.load(r)
        except urllib.error.HTTPError as e:
            note_usage(url, e.headers)
            retry_after = e.headers.get("Retry-After") if e.headers else None
            try:
                data = json.loads(e.read())
            except Exception:
                data = None
                last = f"HTTP {e.code}"
        except Exception as e:  # network reset, timeout
            last = e
            data = None
        if data is not None and data.get("error") and "limit" in str(data.get("reason", "")).lower():
            last, limited = data.get("reason"), True
            log("limit", f"try {k + 1}/{tries}: {last}")
            if _wait_too_long(str(last), retry_after):
                break  # retrying for a minute or two cannot help
            sleep(4 + 2 * k)
            continue
        if data is None:
            limited = False
            log("network", f"try {k + 1}/{tries}: {last}")
            sleep(3 + 2 * k)
            continue
        if data.get("error"):
            raise RuntimeError(f"open-meteo error: {data.get('reason')}")
        return data
    raise LimitRefused(str(last), limit=limited)


def previous_runs_url(lat, lon, elevation, model, start, end, leads=range(1, 8),
                      variables=("temperature_2m", "precipitation")) -> str:
    hourly = [f"{v}_previous_day{L}" for v in variables for L in leads]
    q = dict(latitude=lat, longitude=lon, elevation=elevation, hourly=",".join(hourly),
             models=model, start_date=start, end_date=end, timezone="GMT")
    return PREVIOUS_RUNS + "?" + urllib.parse.urlencode(q)


def forecast_url(lat, lon, elevation, model, forecast_days=16,
                 variables=("temperature_2m", "precipitation")) -> str:
    """Latest run of one deterministic model (live forecast API)."""
    q = dict(latitude=lat, longitude=lon, elevation=elevation, hourly=",".join(variables),
             models=model, forecast_days=forecast_days, timezone="GMT")
    return FORECAST + "?" + urllib.parse.urlencode(q)


def ensemble_url(lat, lon, elevation, model, forecast_days=16,
                 variables=("temperature_2m", "precipitation")) -> str:
    """Latest run of one ensemble, every member (Ensemble API)."""
    q = dict(latitude=lat, longitude=lon, elevation=elevation, hourly=",".join(variables),
             models=model, forecast_days=forecast_days, timezone="GMT")
    return ENSEMBLE + "?" + urllib.parse.urlencode(q)


def single_run_url(lat, lon, elevation, model, run_iso, forecast_days=16,
                   variables=("temperature_2m", "precipitation")) -> str:
    q = dict(latitude=lat, longitude=lon, elevation=elevation, hourly=",".join(variables),
             models=model, run=run_iso, forecast_days=forecast_days, timezone="GMT")
    return SINGLE_RUNS + "?" + urllib.parse.urlencode(q)
