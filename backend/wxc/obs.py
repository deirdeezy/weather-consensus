"""Latest station observation per place ("now" block), from ECCC real-time SWOB.

Source: MSC GeoMet OGC API, collection swob-realtime (checked live 25 Nov 2026):
https://api.weather.gc.ca/collections/swob-realtime
Surface weather observations from ECCC and partner networks, last 30 days.
One record per minute and one per hour per station; `_is-minutely_obs-value`
tells them apart.

Station rule (owner decision, 25 Nov 2026): a place shows observations only
from a station it approves in config/places.json (`obs_station`), that is run
by ECCC itself (SWOB `data_pvdr-value` "MSC", so no NAV CANADA or partner
station), and that lies within MAX_KM of the place. Places without one get no
"now" block.

Two requests per place per hour:
1. Every hourly record since the start of the current climate day (06 UTC, as
   scoring uses) or the last 13 hours, whichever is longer. The records after
   06 UTC give the observed high, low and precipitation so far. Chosen over
   keeping a running high and low in the store: nothing to get out of step
   after a missed hour or a late record, and a missed hour is recovered by the
   next run. With `properties` the answer is about 6 KB (109 KB without).
2. The newest minute record (limit 1, about 4.5 KB). Hourly records post 0 to
   6 minutes after the hour (Datamart file times, 25 Nov 2026), so without it
   "now" is up to about 70 minutes old when the job runs.

Current values (owner rule, 26 Nov 2026): temp, dew point, humidity, wind and
gust come from whichever record is newer, the minute or the hourly one. A
minute value is used only if its SWOB quality flag is there and passed (100).
Minute records carry no flag on dew point, wind or gust (checked on 200
records, 25 and 26 Nov 2026), so those fall back to the newest hourly record
rather than going blank. Pressure, tendency and the last hour's precipitation
always come from the hourly record. `values_from` in the block says which
record each value came from and when that record was observed. If the minute
request fails, the block is built from hourly records alone, as before.

Usage policy (https://eccc-msc.github.io/open-data/usage-policy/readme_en,
checked 25 Nov 2026): add a meaningful User-Agent; ask only for data we use;
no no-cache headers; contact MSC above 86,400 requests a day (we make 48).
Licence: ECCC Data Server End-use Licence (same credit as the daily data,
backend/wxc/eccc.py); it must not be used in a way that suggests official
status or endorsement (section 5).

Output: data/store/<place>/now.json, the block publish.py puts in the file.
It is replaced only by a good answer, so after a refusal the last block stays
and its `observed_at` shows its age (the app dims it after 3 h and hides the
values after 12 h).
"""
from __future__ import annotations

import datetime as dt
import json
import math
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from .daily import CLIMATE_DAY_OFFSET_H
from .refresh import _write_json, iso, refusal_logger

URL = "https://api.weather.gc.ca/collections/swob-realtime/items"
USER_AGENT = "weather-consensus/0.1 (+https://github.com/deirdeezy/weather-consensus)"
SOURCE = "ECCC SWOB real-time (MSC GeoMet swob-realtime)"
MAX_KM = 10.0           # owner rule: a station within about 10 km of the place
ECCC_PROVIDER = "MSC"   # SWOB data provider for ECCC's own stations
LOOKBACK_H = 13         # always look this far back for the newest record
TRIES = 4
QA_GOOD = 100           # SWOB quality flag for a value that passed checks

# Record fields we read (each also asks for its "-qa" flag where SWOB has one).
WIND, WIND_DIR = "avg_wnd_spd_10m_pst2mts", "avg_wnd_dir_10m_pst2mts"
WIND10, WIND_DIR10 = "avg_wnd_spd_10m_pst10mts", "avg_wnd_dir_10m_pst10mts"
GUST = "max_wnd_spd_10m_pst10mts"
VALUES = ["air_temp", "dwpt_temp", "rel_hum", WIND, WIND_DIR, WIND10, WIND_DIR10, GUST,
          "mslp", "pres_tend_char_pst3hrs", "pres_tend_amt_pst3hrs", "pcpn_amt_pst1hr",
          "max_air_temp_pst1hr", "min_air_temp_pst1hr"]
FIELDS = ["date_tm-value", "clim_id-value", "data_pvdr-value", "_is-minutely_obs-value"] \
    + VALUES + [f"{v}-qa" for v in VALUES]


def day_start(now: int) -> dt.datetime:
    """Start of the climate day (UTC) that `now` falls in: 06 UTC."""
    t = dt.datetime.fromtimestamp(now, dt.timezone.utc)
    d = (t + dt.timedelta(hours=CLIMATE_DAY_OFFSET_H)).date()
    return dt.datetime.combine(d, dt.time(0), dt.timezone.utc) - dt.timedelta(hours=CLIMATE_DAY_OFFSET_H)


def query_url(climate_id: str, since: dt.datetime) -> str:
    """Every hourly record since `since`, oldest first."""
    q = {"f": "json", "clim_id-value": climate_id, "_is-minutely_obs-value": "false",
         "datetime": f"{since:%Y-%m-%dT%H:%M:%SZ}/..", "sortby": "date_tm-value",
         "limit": 100, "properties": ",".join(FIELDS)}
    return URL + "?" + urllib.parse.urlencode(q)


def minute_query_url(climate_id: str, since: dt.datetime) -> str:
    """The newest minute record since `since` (one record)."""
    q = {"f": "json", "clim_id-value": climate_id, "_is-minutely_obs-value": "true",
         "datetime": f"{since:%Y-%m-%dT%H:%M:%SZ}/..", "sortby": "-date_tm-value",
         "limit": 1, "properties": ",".join(FIELDS)}
    return URL + "?" + urllib.parse.urlencode(q)


def get_json(url: str, tries: int = TRIES, log=print, sleep=time.sleep) -> dict:
    """GET with a meaningful User-Agent and retries. log(kind, detail) for each
    failed try: "limit" (HTTP 429 or 503, the server refused) or "network"."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    last = None
    for k in range(tries):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code}"
            log("limit" if e.code in (429, 503) else "network", f"try {k + 1}/{tries}: {last}")
        except Exception as e:  # reset, timeout, unreadable answer
            last = e
            log("network", f"try {k + 1}/{tries}: {e}")
        if k < tries - 1:
            sleep(5 * (k + 1))
    raise RuntimeError(f"no answer after {tries} tries: {last}")


def distance_km(lat1, lon1, lat2, lon2) -> float:
    """Great-circle distance (haversine, mean Earth radius 6371 km)."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = (math.sin((p2 - p1) / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2)
    return 2 * 6371.0 * math.asin(math.sqrt(a))


def _num(props: dict, key: str):
    """A value we trust: a finite number whose quality flag, if any, is good."""
    v = props.get(key)
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        return None
    qa = props.get(f"{key}-qa")
    if qa is not None and qa != QA_GOOD:
        return None
    return float(v)


def _num_flagged(props: dict, key: str):
    """A minute-record value we trust: as `_num`, and its quality flag must be
    there and passed. A missing flag means use the hourly value instead."""
    if props.get(f"{key}-qa") != QA_GOOD:
        return None
    return _num(props, key)


def _r(x, nd):
    return None if x is None else round(x, nd)


def _time(props: dict) -> dt.datetime | None:
    s = props.get("date_tm-value")
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
    except Exception:
        return None


def tendency(code, change_hpa) -> str | None:
    """Pressure tendency over 3 h from the WMO characteristic code (table 0200):
    0 to 3 higher than (or as high as) 3 h ago, 4 steady, 5 to 8 lower (or as
    low). A net change of 0 is steady."""
    if code is None:
        return None
    c = int(code)
    if c == 4 or change_hpa == 0:
        return "steady"
    if 0 <= c <= 3:
        return "rising"
    if 5 <= c <= 8:
        return "falling"
    return None


def _wind(props: dict, num) -> tuple:
    """2-minute mean wind and direction, or the 10-minute mean if it is missing."""
    wind, wind_dir = num(props, WIND), _num(props, WIND_DIR)
    if wind is None:
        wind, wind_dir = num(props, WIND10), _num(props, WIND_DIR10)
    return wind, wind_dir


def build_now(records: list[dict], geometry: dict | None, place: dict, station: dict,
              now: int, minute: dict | None = None) -> dict | None:
    """The "now" block from hourly records (oldest first) and, if given, the
    newest minute record. None if there is no hourly record."""
    recs = [(t, p) for p in records if (t := _time(p)) is not None]
    recs.sort(key=lambda r: r[0])
    if not recs:
        return None
    t, p = recs[-1]
    start = day_start(now)
    window = [(u, q) for (u, q) in recs if start < u <= dt.datetime.fromtimestamp(now, dt.timezone.utc)]

    # Current values: the minute record when it is newer and the value has a
    # passed quality flag; otherwise the newest hourly record.
    tm = _time(minute) if minute else None
    if tm is None or tm <= t:
        minute, tm = None, None
    picked, used = {}, {}
    for name, key in (("temp", "air_temp"), ("dew_point", "dwpt_temp"), ("humidity", "rel_hum"),
                      ("gust", GUST)):
        v = _num_flagged(minute, key) if minute else None
        picked[name], used[name] = (v, "minute") if v is not None else (_num(p, key), "hourly")
    wind = _wind(minute, _num_flagged) if minute else (None, None)
    picked["wind"], used["wind"] = (wind, "minute") if wind[0] is not None else (_wind(p, _num), "hourly")
    wind, wind_dir = picked["wind"]
    in_use = "minute" in used.values()
    observed = tm if in_use else t
    mslp = _num(p, "mslp")
    change = _num(p, "pres_tend_amt_pst3hrs")

    highs = [x for _, q in window if (x := _num(q, "max_air_temp_pst1hr")) is not None]
    lows = [x for _, q in window if (x := _num(q, "min_air_temp_pst1hr")) is not None]
    rain = [_num(q, "pcpn_amt_pst1hr") for _, q in window]
    # A station gap leaves an hour with no record at all: the total would
    # undercount, so count the hours that should be there up to the newest one.
    hours_due = int((window[-1][0] - start).total_seconds() // 3600) if window else 0
    complete = len({u for u, _ in window}) >= hours_due
    lon, lat = (geometry or {}).get("coordinates", [None, None])[:2]
    return {
        "observed_at": iso(int(observed.timestamp())),
        "fetched_at": iso(now),
        "source": SOURCE,
        "station": {
            "network": station["network"], "id": station["climate_id"], "name": station["name"],
            "distance_km": None if lat is None else round(distance_km(place["lat"], place["lon"], lat, lon), 1),
        },
        "values_from": {
            "minute_at": iso(int(tm.timestamp())) if in_use else None,
            "hourly_at": iso(int(t.timestamp())),
            **{k: used[k] for k in ("temp", "dew_point", "humidity", "wind", "gust")},
        },
        "temp": _r(picked["temp"], 1),
        "dew_point": _r(picked["dew_point"], 1),
        "humidity": None if (h := picked["humidity"]) is None else int(round(h)),
        "wind_kmh": _r(wind, 1),
        "wind_dir_deg": None if wind_dir is None else int(round(wind_dir)) % 360,
        "gust_kmh": _r(picked["gust"], 1),
        "pressure_kpa": None if mslp is None else round(mslp / 10, 2),
        "pressure_tendency": tendency(_num(p, "pres_tend_char_pst3hrs"), change),
        "pressure_change_3h_kpa": None if change is None else round(change / 10, 2),
        "precip_1h_mm": _r(_num(p, "pcpn_amt_pst1hr"), 1),
        "high_so_far": _r(max(highs), 1) if highs else None,
        "low_so_far": _r(min(lows), 1) if lows else None,
        # A missing hour would undercount the total: no total then.
        "precip_so_far_mm": (round(sum(rain), 1)
                             if rain and complete and all(x is not None for x in rain) else None),
        "so_far_since": iso(int(start.timestamp())),
        "so_far_hours": len(window),
    }


def fetch_now(place: dict, store: Path, now: int | None = None, get=get_json,
              echo=print) -> dict | None:
    """Fetch and save the "now" block for one place. Returns it, or None when
    the place has no approved station or nothing usable came back (the last
    saved block, if any, is left in place)."""
    now = int(time.time() if now is None else now)
    station = place.get("obs_station")
    if not station:
        return None
    log = refusal_logger(store, place["id"], echo)
    since = min(day_start(now), dt.datetime.fromtimestamp(now - LOOKBACK_H * 3600, dt.timezone.utc))
    url = query_url(station["climate_id"], since)
    try:
        payload = get(url, log=lambda k, d: log("eccc_swob", k, d))
    except Exception as e:
        log("eccc_swob", "gave_up", e)
        return None

    feats = [f for f in payload.get("features", []) or []
             if isinstance(f, dict) and isinstance(f.get("properties"), dict)]
    feats = [f for f in feats
             if str(f["properties"].get("clim_id-value")) == station["climate_id"]
             and f["properties"].get("_is-minutely_obs-value") is not True]
    if not feats:
        log("eccc_swob", "obs", f"no hourly record for {station['climate_id']} since {since:%Y-%m-%dT%H:%MZ}")
        return None
    newest = max(feats, key=lambda f: str(f["properties"].get("date_tm-value")))
    provider = newest["properties"].get("data_pvdr-value")
    if provider != ECCC_PROVIDER:
        log("eccc_swob", "obs", f"station {station['climate_id']} provider {provider!r}, not ECCC: not shown")
        return None
    geometry = newest.get("geometry")
    minute = fetch_minute(station, since, get, log)
    block = build_now([f["properties"] for f in feats], geometry, place, station, now, minute)
    km = block["station"]["distance_km"] if block else None
    if km is None or km > MAX_KM:
        log("eccc_swob", "obs", f"station {station['climate_id']} at {km} km, over {MAX_KM:g} km: not shown")
        return None
    _write_json(store / place["id"] / "now.json", block)
    return block


def fetch_minute(station: dict, since: dt.datetime, get, log) -> dict | None:
    """Properties of the newest minute record from the station, or None. A
    refusal is logged and the block is then built from hourly records alone."""
    try:
        payload = get(minute_query_url(station["climate_id"], since),
                      log=lambda k, d: log("eccc_swob", k, f"minute record: {d}"))
    except Exception as e:
        log("eccc_swob", "gave_up", f"minute record: {e}")
        return None
    recs = [f["properties"] for f in payload.get("features", []) or []
            if isinstance(f, dict) and isinstance(f.get("properties"), dict)]
    recs = [p for p in recs
            if str(p.get("clim_id-value")) == station["climate_id"]
            and p.get("_is-minutely_obs-value") is True
            and p.get("data_pvdr-value") == ECCC_PROVIDER and _time(p) is not None]
    return max(recs, key=_time) if recs else None


def load_now(store: Path, place: dict) -> dict | None:
    """The saved block, only for a place that still approves its station."""
    if not place.get("obs_station"):
        return None
    path = store / place["id"] / "now.json"
    if not path.exists():
        return None
    try:
        block = json.loads(path.read_text())
    except Exception:
        return None
    if (block.get("station") or {}).get("id") != place["obs_station"]["climate_id"]:
        return None
    return block
