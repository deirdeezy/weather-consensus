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


EMPTY = {"type": "FeatureCollection", "features": []}


def fake_get(payload, minute=EMPTY):
    """Answers the hourly query with `payload` and the minute query with `minute`."""
    calls = []

    def get(url, log=print):
        calls.append(url)
        return copy.deepcopy(minute if "_is-minutely_obs-value=true" in url else payload)
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


def test_two_requests_per_place_reach_back_13_hours_after_06_utc(tmp_path):
    early = int(dt.datetime(2026, 11, 25, 7, 17, tzinfo=dt.timezone.utc).timestamp())
    get = fake_get(FIXTURE)
    obs.fetch_now(PLACE, tmp_path, now=early, get=get, echo=quiet)
    assert len(get.calls) == 2
    assert "_is-minutely_obs-value=false" in get.calls[0] and "limit=100" in get.calls[0]
    assert "_is-minutely_obs-value=true" in get.calls[1]
    assert all("datetime=2026-11-24T18%3A17%3A00Z" in u for u in get.calls)


def test_minute_query_asks_for_the_newest_record_only():
    url = obs.minute_query_url("1064324", obs.day_start(FETCHED))
    assert "_is-minutely_obs-value=true" in url
    assert "sortby=-date_tm-value" in url and "limit=1&" in url
    assert "clim_id-value=1064324" in url and "properties=" in url


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


# --- current values from the minute record -----------------------------------
# Real answers, Kitimat Forest Ave, fetched 26 Nov 2026 01:07:44 UTC with
# obs.query_url and obs.minute_query_url. The hourly answer has no 22:00 UTC
# record: the station sent nothing from 21:25 to 22:04 UTC on 25 Nov (Datamart
# minute files), so that hour never came. The "as-of" minute answers are the
# same query with the datetime range closed at 21:50 and 22:21 UTC: what a run
# at those times would have seen.

def fixture(name):
    return json.loads((ROOT / "tests" / "fixtures" / name).read_text())


HOURLY_0107 = fixture("swob-kitimat-2026-11-26T0107Z.json")
MINUTE_0107 = fixture("swob-kitimat-2026-11-26T0107Z-minute.json")
MINUTE_2221 = fixture("swob-kitimat-minute-as-of-2026-11-25T2221Z.json")
MINUTE_2150 = fixture("swob-kitimat-minute-as-of-2026-11-25T2150Z.json")
AT_0107 = int(dt.datetime(2026, 11, 26, 1, 7, 44, tzinfo=dt.timezone.utc).timestamp())


def at(h, m, day=25):
    return int(dt.datetime(2026, 11, day, h, m, tzinfo=dt.timezone.utc).timestamp())


def hourly_until(payload, when):
    """The hourly answer as a run at `when` would have had it."""
    out = copy.deepcopy(payload)
    out["features"] = [f for f in out["features"]
                       if f["properties"]["date_tm-value"] <= obs.iso(when).replace("Z", ".000Z")]
    return out


def first(payload):
    return payload["features"][0]["properties"]


def test_saved_minute_records_have_no_flag_on_dew_point_wind_or_gust():
    for m in (MINUTE_0107, MINUTE_2221, MINUTE_2150):
        p = first(m)
        assert p["_is-minutely_obs-value"] is True
        assert p["air_temp-qa"] == 100 and p["rel_hum-qa"] == 100
        for key in ("dwpt_temp", obs.WIND, obs.WIND10, obs.GUST):
            assert p.get(key) is not None and p.get(f"{key}-qa") is None, key


def test_newer_minute_record_gives_temp_and_humidity_the_hourly_one_the_rest(tmp_path):
    b = obs.fetch_now(PLACE, tmp_path, now=AT_0107, get=fake_get(HOURLY_0107, MINUTE_0107), echo=quiet)
    m, h = first(MINUTE_0107), props(HOURLY_0107)[-1]
    assert m["date_tm-value"] == "2026-11-26T01:07:00.000Z" and h["date_tm-value"] == "2026-11-26T01:00:00.000Z"
    assert b["observed_at"] == "2026-11-26T01:07:00Z"
    assert b["values_from"] == {"minute_at": "2026-11-26T01:07:00Z", "hourly_at": "2026-11-26T01:00:00Z",
                                "temp": "minute", "dew_point": "hourly", "humidity": "minute",
                                "wind": "hourly", "gust": "hourly"}
    assert list(b["values_from"])[2:] == ["temp", "dew_point", "humidity", "wind", "gust"]
    assert b["temp"] == m["air_temp"] and b["humidity"] == round(m["rel_hum"])
    # No flag on the minute dew point, wind and gust: the hourly values, not blanks.
    assert b["dew_point"] == h["dwpt_temp"] is not None
    assert b["wind_kmh"] == h[obs.WIND] is not None
    assert b["gust_kmh"] == h[obs.GUST] is not None
    # Pressure, tendency and the last hour's precipitation: always the hourly record.
    assert b["pressure_kpa"] == round(h["mslp"] / 10, 2)
    assert b["pressure_tendency"] == obs.tendency(h["pres_tend_char_pst3hrs"], h["pres_tend_amt_pst3hrs"])
    assert b["precip_1h_mm"] == h["pcpn_amt_pst1hr"]


def test_minute_value_with_a_passed_flag_is_used():
    m = {**first(MINUTE_0107), "dwpt_temp-qa": 100, f"{obs.WIND}-qa": 100, f"{obs.GUST}-qa": 100}
    b = obs.build_now(props(HOURLY_0107), None, PLACE, STATION, AT_0107, m)
    assert {k: b["values_from"][k] for k in ("dew_point", "wind", "gust")} == \
        {"dew_point": "minute", "wind": "minute", "gust": "minute"}
    assert b["dew_point"] == m["dwpt_temp"] and b["wind_kmh"] == m[obs.WIND] and b["gust_kmh"] == m[obs.GUST]
    assert b["wind_dir_deg"] == round(m[obs.WIND_DIR]) % 360


def test_minute_value_that_failed_its_check_falls_back_to_the_hourly_one():
    m = {**first(MINUTE_0107), "air_temp-qa": 0, "rel_hum-qa": 10}
    b = obs.build_now(props(HOURLY_0107), None, PLACE, STATION, AT_0107, m)
    h = props(HOURLY_0107)[-1]
    assert b["temp"] == h["air_temp"] and b["humidity"] == round(h["rel_hum"])
    assert set(b["values_from"].values()) == {"hourly", "2026-11-26T01:00:00Z", None}
    assert b["observed_at"] == "2026-11-26T01:00:00Z"  # nothing came from the minute record


def test_minute_record_no_newer_than_the_hourly_one_is_not_used():
    same = {**first(MINUTE_0107), "date_tm-value": "2026-11-26T01:00:00.000Z", "air_temp": 30.0}
    b = obs.build_now(props(HOURLY_0107), None, PLACE, STATION, AT_0107, same)
    assert b["observed_at"] == "2026-11-26T01:00:00Z" and b["temp"] != 30.0
    assert b["values_from"]["minute_at"] is None and b["values_from"]["temp"] == "hourly"


def test_station_gap_a_run_at_22_21_shows_the_minute_record_and_the_21_00_hour(tmp_path):
    when = at(22, 21)
    hourly = hourly_until(HOURLY_0107, when)
    assert props(hourly)[-1]["date_tm-value"] == "2026-11-25T21:00:00.000Z"  # 22:00 never came
    b = obs.fetch_now(PLACE, tmp_path, now=when, get=fake_get(hourly, MINUTE_2221), echo=quiet)
    assert b["observed_at"] == "2026-11-25T22:21:00Z"
    assert b["values_from"]["hourly_at"] == "2026-11-25T21:00:00Z"
    assert b["temp"] == first(MINUTE_2221)["air_temp"]
    assert b["wind_kmh"] == props(hourly)[-1][obs.WIND]
    assert b["so_far_hours"] == 15 and b["precip_so_far_mm"] is not None


def test_station_gap_a_run_inside_the_gap_shows_the_last_minute_before_it(tmp_path):
    when = at(21, 50)
    b = obs.fetch_now(PLACE, tmp_path, now=when, get=fake_get(hourly_until(HOURLY_0107, when), MINUTE_2150),
                      echo=quiet)
    assert b["observed_at"] == "2026-11-25T21:24:00Z"  # station silent from 21:25
    assert b["values_from"]["temp"] == "minute"


def test_station_gap_a_missing_hour_leaves_no_precip_total(tmp_path):
    b = obs.fetch_now(PLACE, tmp_path, now=AT_0107, get=fake_get(HOURLY_0107, MINUTE_0107), echo=quiet)
    times = [p["date_tm-value"][11:16] for p in props(HOURLY_0107)]
    assert "22:00" not in times and "23:00" in times
    assert b["so_far_hours"] == 18  # 07 to 01 UTC is 19 hours, one missing
    assert b["precip_so_far_mm"] is None
    assert b["high_so_far"] is not None and b["low_so_far"] is not None


def test_refused_minute_request_still_publishes_from_hourly_records(tmp_path):
    def get(url, log=print):
        if "_is-minutely_obs-value=true" in url:
            log("limit", "try 1/4: HTTP 429")
            raise RuntimeError("no answer after 4 tries: HTTP 429")
        return copy.deepcopy(HOURLY_0107)

    b = obs.fetch_now(PLACE, tmp_path, now=AT_0107, get=get, echo=quiet)
    assert b["observed_at"] == "2026-11-26T01:00:00Z" and b["values_from"]["minute_at"] is None
    recs = [json.loads(x) for x in (tmp_path / "refusals.jsonl").read_text().splitlines()]
    assert [r["kind"] for r in recs] == ["limit", "gave_up"]
    assert all("minute record" in r["detail"] for r in recs)


@pytest.mark.parametrize("change", [{"clim_id-value": "1068134"}, {"data_pvdr-value": "NAV CANADA"},
                                    {"_is-minutely_obs-value": False}])
def test_minute_record_from_another_station_or_provider_is_ignored(tmp_path, change):
    m = copy.deepcopy(MINUTE_0107)
    m["features"][0]["properties"].update(change)
    b = obs.fetch_now(PLACE, tmp_path, now=AT_0107, get=fake_get(HOURLY_0107, m), echo=quiet)
    assert b["observed_at"] == "2026-11-26T01:00:00Z"


def test_published_block_with_minute_values_matches_the_schema(tmp_path):
    b = obs.fetch_now(PLACE, tmp_path, now=AT_0107, get=fake_get(HOURLY_0107, MINUTE_0107), echo=quiet)
    doc = _doc(b)
    jsonschema.validate(doc, strict(SCHEMA), format_checker=jsonschema.FormatChecker())
    assert doc["now"]["values_from"]["temp"] == "minute"
