"""Environment and Climate Change Canada station data (MSC GeoMet OGC API).

Endpoint confirmed from pilot responses (Nov 2026):
https://api.weather.gc.ca/collections/climate-daily/items
Licence: Environment and Climate Change Canada Data Servers End-use Licence.
"""
from __future__ import annotations

import json
import time
import urllib.parse
import urllib.request

import pandas as pd

BASE = "https://api.weather.gc.ca/collections"


def daily_url(climate_id: str, start: str, end: str, limit: int = 5000) -> str:
    q = {"f": "json", "CLIMATE_IDENTIFIER": climate_id, "datetime": f"{start}/{end}",
         "limit": limit, "sortby": "LOCAL_DATE"}
    return f"{BASE}/climate-daily/items?" + urllib.parse.urlencode(q)


def _get(url: str, tries: int = 4) -> dict:
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return json.load(r)
        except Exception:
            if attempt == tries - 1:
                raise
            time.sleep(5 * (attempt + 1))
    raise RuntimeError("unreachable")


def fetch_daily(climate_id: str, start: str, end: str) -> dict:
    """Fetch all pages; returns one GeoJSON FeatureCollection."""
    url = daily_url(climate_id, start, end)
    features: list = []
    while url:
        page = _get(url)
        features += page.get("features", [])
        url = next((l["href"] for l in page.get("links", []) if l.get("rel") == "next"), None)
    return {"type": "FeatureCollection", "features": features}


def parse_daily(payload: dict) -> pd.DataFrame:
    """Daily observations indexed by local date: tmax, tmin, pcp (deg C, mm)."""
    rows = [f["properties"] for f in payload["features"]]
    obs = pd.DataFrame(rows)
    obs["date"] = pd.to_datetime(obs["LOCAL_DATE"]).dt.date
    obs = obs.set_index("date")[["MAX_TEMPERATURE", "MIN_TEMPERATURE", "TOTAL_PRECIPITATION"]]
    obs = obs.apply(pd.to_numeric, errors="coerce")
    obs.columns = ["tmax", "tmin", "pcp"]
    return obs.sort_index()
