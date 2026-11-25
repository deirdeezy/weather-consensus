"""obs.py: the "now" block from ECCC real-time SWOB, the station rule, refusals."""
import copy
import datetime as dt
import io
import json
import sys
import urllib.error
from pathlib import Path

import jsonschema
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from wxc import obs  # noqa: E402
from wxc import publish as pb  # noqa: E402

SCHEMA = json.loads((ROOT / "docs" / "place-v1.schema.json").read_text())
# Real answer for Kitimat Forest Ave (ECCC swob-realtime, hourly records
# 06 to 21 UTC on 25 Nov 2026), fetched at 21:40:57 UTC with obs.query_url.
FIXTURE = json.loads((ROOT / "tests" / "fixtures" / "swob-kitimat-2026-11-25T2140Z.json").read_text())
FETCHED = int(dt.datetime(2026, 11, 25, 21, 40, 57, tzinfo=dt.timezone.utc).timestamp())
STATION = {"network": "ECCC", "climate_id": "1064324", "name": "Kitimat Forest Ave"}
PLACE = {"id": "kitimat", "name": "Kitimat", "lat": 54.0536, "lon": -128.6336, "elevation_m": 98,
         "timezone": "America/Vancouver", "status": "stage1", "obs_station": STATION,
         "truth": {"network": "ECCC", "climate_id": "1064324", "station": "Kitimat Forest Ave"}}


def quiet(*a):
    pass


def fake_get(payload):
    calls = []

    def get(url, log=print):
        calls.append(url)
        return copy.deepcopy(payload)
    get.calls = calls
    return get


def props(payload=FIXTURE):
    return [f["properties"] for f in payload["features"]]


def strict(schema):
    s = copy.deepcopy(schema)

    def walk(node):
        if isinstance(node, dict):
            if node.get("type") == "object" and "properties" in node:
                node["additionalProperties"] = False
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(s)
    return s


# --- parsing the real answer ------------------------------------------------

def test_real_answer_gives_the_newest_hourly_record(tmp_path):
    b = obs.fetch_now(PLACE, tmp_path, now=FETCHED, get=fake_get(FIXTURE), echo=quiet)
    newest = props()[-1]
    assert b["observed_at"] == "2026-11-25T21:00:00Z"
    assert b["fetched_at"] == "2026-11-25T21:40:57Z"
    assert b["temp"] == newest["air_temp"]
    assert b["dew_point"] == newest["dwpt_temp"]
    assert b["humidity"] == round(newest["rel_hum"])
    assert b["wind_kmh"] == newest[obs.WIND]
    assert b["gust_kmh"] == newest[obs.GUST]
    assert b["pressure_kpa"] == round(newest["mslp"] / 10, 2)
    assert b["precip_1h_mm"] == newest["pcpn_amt_pst1hr"]
    assert b["station"] == {"network": "ECCC", "id": "1064324", "name": "Kitimat Forest Ave",
                            "distance_km": 2.0}
    assert json.loads((tmp_path / "kitimat" / "now.json").read_text()) == b


def test_so_far_values_cover_only_the_climate_day_from_06_utc(tmp_path):
    b = obs.fetch_now(PLACE, tmp_path, now=FETCHED, get=fake_get(FIXTURE), echo=quiet)
    day = [p for p in props() if p["date_tm-value"] > "2026-11-25T06:00:00.000Z"]  # 07 to 21 UTC
    assert b["so_far_since"] == "2026-11-25T06:00:00Z"
    assert b["so_far_hours"] == len(day) == 15
    assert b["high_so_far"] == max(p["max_air_temp_pst1hr"] for p in day)
    assert b["low_so_far"] == min(p["min_air_temp_pst1hr"] for p in day)
    assert b["precip_so_far_mm"] == round(sum(p["pcpn_amt_pst1hr"] for p in day), 1)
    # The 06 UTC record covers 05 to 06 UTC, the day before: left out.
    first = props()[0]
    assert first["date_tm-value"].startswith("2026-11-25T06:00")


def test_query_asks_for_hourly_records_since_06_utc_with_few_fields():
    url = obs.query_url("1064324", obs.day_start(FETCHED))
    assert "clim_id-value=1064324" in url
    assert "_is-minutely_obs-value=false" in url
    assert "datetime=2026-11-25T06%3A00%3A00Z%2F.." in url
    assert "properties=" in url


def test_one_request_per_place_reaches_back_13_hours_after_06_utc(tmp_path):
    early = int(dt.datetime(2026, 11, 25, 7, 17, tzinfo=dt.timezone.utc).timestamp())
    get = fake_get(FIXTURE)
    obs.fetch_now(PLACE, tmp_path, now=early, get=get, echo=quiet)
    assert len(get.calls) == 1
    assert "datetime=2026-11-24T18%3A17%3A00Z" in get.calls[0]


def test_day_start_is_06_utc_of_the_climate_day():
    at = lambda *a: int(dt.datetime(*a, tzinfo=dt.timezone.utc).timestamp())  # noqa: E731
    assert obs.day_start(at(2026, 11, 25, 5, 59)) == dt.datetime(2026, 11, 24, 6, tzinfo=dt.timezone.utc)
    assert obs.day_start(at(2026, 11, 25, 6, 0)) == dt.datetime(2026, 11, 25, 6, tzinfo=dt.timezone.utc)
    assert obs.day_start(at(2026, 11, 26, 2, 0)) == dt.datetime(2026, 11, 25, 6, tzinfo=dt.timezone.utc)


def test_minute_records_and_other_stations_are_ignored(tmp_path):
    payload = copy.deepcopy(FIXTURE)
    minute = copy.deepcopy(payload["features"][-1])
    minute["properties"].update({"date_tm-value": "2026-11-25T21:39:00.000Z", "air_temp": 30.0,
                                 "_is-minutely_obs-value": True})
    other = copy.deepcopy(payload["features"][-1])
    other["properties"].update({"date_tm-value": "2026-11-25T21:30:00.000Z", "clim_id-value": "1068134"})
    payload["features"] += [minute, other]
    b = obs.fetch_now(PLACE, tmp_path, now=FETCHED, get=fake_get(payload), echo=quiet)
    assert b["observed_at"] == "2026-11-25T21:00:00Z" and b["temp"] != 30.0


# --- missing and doubtful values ---------------------------------------------

def test_missing_fields_become_null():
    rec = {"date_tm-value": "2026-11-25T21:00:00.000Z"}
    b = obs.build_now([rec], {"coordinates": [-128.604077, 54.056434]}, PLACE, STATION, FETCHED)
    for k in ("temp", "dew_point", "humidity", "wind_kmh", "wind_dir_deg", "gust_kmh", "pressure_kpa",
              "pressure_tendency", "pressure_change_3h_kpa", "precip_1h_mm", "high_so_far",
              "low_so_far", "precip_so_far_mm"):
        assert b[k] is None, k
    assert b["observed_at"] == "2026-11-25T21:00:00Z"


def test_value_that_failed_quality_checks_is_dropped():
    recs = props()
    recs[-1] = {**recs[-1], "air_temp-qa": 0, "max_air_temp_pst1hr-qa": 10, "max_air_temp_pst1hr": 40.0}
    b = obs.build_now(recs, {"coordinates": [-128.604077, 54.056434]}, PLACE, STATION, FETCHED)
    assert b["temp"] is None
    assert b["high_so_far"] < 40


def test_a_missing_hour_leaves_no_precip_total_but_keeps_high_and_low():
    recs = props()
    recs[5] = {k: v for k, v in recs[5].items() if not k.startswith("pcpn_amt_pst1hr")}
    b = obs.build_now(recs, {"coordinates": [-128.604077, 54.056434]}, PLACE, STATION, FETCHED)
    assert b["precip_so_far_mm"] is None
    assert b["high_so_far"] is not None and b["low_so_far"] is not None


def test_calm_uses_the_10_minute_mean_when_the_2_minute_one_is_missing():
    rec = {"date_tm-value": "2026-11-25T21:00:00.000Z", obs.WIND10: 7.2, obs.WIND_DIR10: 360}
    b = obs.build_now([rec], None, PLACE, STATION, FETCHED)
    assert b["wind_kmh"] == 7.2 and b["wind_dir_deg"] == 0


@pytest.mark.parametrize("code,change,want", [
    (0, 0.2, "rising"), (2, 1.5, "rising"), (4, 0.0, "steady"), (8, -1.4, "falling"),
    (5, -0.3, "falling"), (1, 0.0, "steady"), (None, None, None), (9, 1.0, None)])
def test_pressure_tendency_from_the_wmo_code(code, change, want):
    assert obs.tendency(code, change) == want


# --- the station rule -------------------------------------------------------

def test_place_with_no_station_makes_no_request_and_has_no_now(tmp_path):
    place = {**PLACE}
    del place["obs_station"]
    get = fake_get(FIXTURE)
    assert obs.fetch_now(place, tmp_path, now=FETCHED, get=get, echo=quiet) is None
    assert get.calls == []
    assert not (tmp_path / place["id"] / "now.json").exists()
    assert obs.load_now(tmp_path, place) is None


def test_station_over_10_km_away_is_not_shown(tmp_path):
    far = {**PLACE, "lat": 54.4686, "lon": -128.5783}  # Terrace, about 46 km away
    assert obs.fetch_now(far, tmp_path, now=FETCHED, get=fake_get(FIXTURE), echo=quiet) is None
    assert not (tmp_path / "kitimat" / "now.json").exists()
    assert "over 10 km" in (tmp_path / "refusals.jsonl").read_text()


def test_partner_or_nav_canada_station_is_not_shown(tmp_path):
    payload = copy.deepcopy(FIXTURE)
    for f in payload["features"]:
        f["properties"]["data_pvdr-value"] = "NAV CANADA"
    assert obs.fetch_now(PLACE, tmp_path, now=FETCHED, get=fake_get(payload), echo=quiet) is None
    assert "not ECCC" in (tmp_path / "refusals.jsonl").read_text()


def test_real_config_approves_only_kitimat_forest_ave():
    places = json.loads((ROOT / "config" / "places.json").read_text())["places"]
    approved = {p["id"]: p["obs_station"] for p in places if p.get("obs_station")}
    assert approved == {"kitimat": STATION}


def test_saved_block_for_another_station_is_not_published(tmp_path):
    obs.fetch_now(PLACE, tmp_path, now=FETCHED, get=fake_get(FIXTURE), echo=quiet)
    moved = {**PLACE, "obs_station": {**STATION, "climate_id": "9999999"}}
    assert obs.load_now(tmp_path, moved) is None
    assert obs.load_now(tmp_path, PLACE)["station"]["id"] == "1064324"


# --- refusals ---------------------------------------------------------------

def test_refusal_is_logged_and_the_last_block_stays(tmp_path):
    first = obs.fetch_now(PLACE, tmp_path, now=FETCHED, get=fake_get(FIXTURE), echo=quiet)

    def refused(url, log=print):
        for k in range(obs.TRIES):
            log("limit", f"try {k + 1}/{obs.TRIES}: HTTP 429")
        raise RuntimeError("no answer after 4 tries: HTTP 429")

    assert obs.fetch_now(PLACE, tmp_path, now=FETCHED + 3600, get=refused, echo=quiet) is None
    recs = [json.loads(x) for x in (tmp_path / "refusals.jsonl").read_text().splitlines()]
    assert [r["kind"] for r in recs] == ["limit"] * obs.TRIES + ["gave_up"]
    assert {r["source"] for r in recs} == {"eccc_swob"}
    assert obs.load_now(tmp_path, PLACE) == first  # app ages it by observed_at


def test_empty_answer_is_logged_and_nothing_saved(tmp_path):
    get = fake_get({"type": "FeatureCollection", "features": []})
    assert obs.fetch_now(PLACE, tmp_path, now=FETCHED, get=get, echo=quiet) is None
    assert "no hourly record" in (tmp_path / "refusals.jsonl").read_text()


def test_get_json_retries_429_then_succeeds_and_sends_a_plain_user_agent(monkeypatch):
    seen, answers = [], [429, 503, 200]

    def urlopen(req, timeout):
        seen.append(req.get_header("User-agent"))
        code = answers.pop(0)
        if code != 200:
            raise urllib.error.HTTPError(req.full_url, code, "refused", {}, io.BytesIO(b""))
        return io.BytesIO(b'{"features": []}')

    monkeypatch.setattr(obs.urllib.request, "urlopen", urlopen)
    log = []
    out = obs.get_json("https://api.weather.gc.ca/x", log=lambda k, d: log.append(k), sleep=lambda s: None)
    assert out == {"features": []}
    assert log == ["limit", "limit"]
    assert seen == [obs.USER_AGENT] * 3
    assert "weather-consensus" in obs.USER_AGENT
    assert "github.com/deirdeezy/weather-consensus" in obs.USER_AGENT
    assert "@" not in obs.USER_AGENT and "/Users/" not in obs.USER_AGENT


def test_get_json_gives_up_after_every_try_fails(monkeypatch):
    def urlopen(req, timeout):
        raise OSError("connection reset")

    monkeypatch.setattr(obs.urllib.request, "urlopen", urlopen)
    log = []
    with pytest.raises(RuntimeError):
        obs.get_json("https://api.weather.gc.ca/x", log=lambda k, d: log.append(k), sleep=lambda s: None)
    assert log == ["network"] * obs.TRIES


# --- in the published file --------------------------------------------------

def _doc(now_block):
    from test_publish import CFG, POOL, RUN, pull, scores  # same fake store as the publish tests
    pulls = {m: {"daily": pb._daily_from_pull(pull(m)), "run_unix": RUN, "fetched_unix": FETCHED}
             for m in POOL}
    return pb.build(PLACE, CFG, scores(), pulls, None, FETCHED, now_block)


def test_published_now_block_matches_the_schema(tmp_path):
    b = obs.fetch_now(PLACE, tmp_path, now=FETCHED, get=fake_get(FIXTURE), echo=quiet)
    doc = _doc(b)
    jsonschema.validate(doc, strict(SCHEMA), format_checker=jsonschema.FormatChecker())
    assert doc["now"] == b
    assert "today" not in doc and "today" not in json.dumps(doc["now"])
    assert [d["day"] for d in doc["days"]] == list(range(1, 15))  # no day 0


def test_place_without_station_publishes_no_now_block():
    doc = _doc(None)
    assert "now" not in doc
    jsonschema.validate(doc, strict(SCHEMA))


def test_now_block_holds_no_urls_or_local_paths(tmp_path):
    b = obs.fetch_now(PLACE, tmp_path, now=FETCHED, get=fake_get(FIXTURE), echo=quiet)
    text = json.dumps(b)
    for bad in ("http", "/Users/", "/home/", str(tmp_path), ".json", ".xml"):
        assert bad not in text, bad
