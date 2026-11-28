"""Current condition from measurements first, the "now" log and its nightly
scores (owner decision, 28 Nov 2026). backend/wxc/obs.py precip_now and
backend/wxc/nowcast.py."""
import copy
import datetime as dt
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from wxc import nowcast as nc  # noqa: E402
from wxc import obs  # noqa: E402
from wxc import refresh as rf  # noqa: E402
from wxc import swob_archive as sa  # noqa: E402

T0 = dt.datetime(2026, 11, 28, 4, 40, tzinfo=dt.timezone.utc)
NOW = int(T0.timestamp())


def minute(t: dt.datetime, gauge=0.0, gauge_flag=1, tip=0.0, wb=5.0, air=6.0):
    return {"date_tm-value": t.strftime("%Y-%m-%dT%H:%M:00.000Z"), "_is-minutely_obs-value": True,
            "pcpn_amt_pst10mts": gauge, "pcpn_amt_pst10mts-data_flag-value": gauge_flag,
            "rnfl_amt_pst1mt": tip, "rnfl_amt_pst1mt-qa": 100,
            "wetblb_temp": wb, "wetblb_temp-data_flag-value": 1, "air_temp": air, "air_temp-qa": 100}


def minutes(n=15, end=T0, **kw):
    return [minute(end - dt.timedelta(minutes=k), **kw) for k in range(n)]


# --- precipitating now, measured -------------------------------------------------

def test_dry_gauge_and_bucket_mean_not_falling():
    p = obs.precip_now(minutes(), None, NOW)
    assert p["falling"] is False and p["phase"] is None
    assert p["gauge_10min_mm"] == 0.0 and p["rain_gauge_10min_mm"] == 0.0


def test_gauge_0_1_mm_in_10_minutes_means_falling():
    recs = minutes()
    recs[0]["pcpn_amt_pst10mts"] = 0.1
    p = obs.precip_now(recs, None, NOW)
    assert p["falling"] is True and p["phase"] == "rain"  # wet-bulb 5 deg C


def test_one_bucket_tip_in_the_last_10_minutes_means_falling():
    recs = minutes()
    recs[4]["rnfl_amt_pst1mt"] = 0.2
    p = obs.precip_now(recs, None, NOW)
    assert p["falling"] is True and p["rain_gauge_10min_mm"] == 0.2


def test_a_tip_older_than_10_minutes_does_not_count():
    recs = minutes()
    recs[12]["rnfl_amt_pst1mt"] = 0.2
    assert obs.precip_now(recs, None, NOW)["falling"] is False


def test_incomplete_gauge_value_is_not_used():
    recs = minutes()
    recs[0].update({"pcpn_amt_pst10mts": 0.5, "pcpn_amt_pst10mts-data_flag-value": 4})
    p = obs.precip_now(recs, None, NOW)
    assert p["gauge_10min_mm"] is None and p["falling"] is False  # the bucket still says dry


def test_neither_gauge_readable_is_unknown_not_dry():
    recs = minutes(n=3)
    recs[0]["pcpn_amt_pst10mts-data_flag-value"] = 4
    p = obs.precip_now(recs, None, NOW)
    assert p["falling"] is None and p["rain_gauge_10min_mm"] is None


def test_no_minute_record_in_the_last_20_minutes_gives_no_precip_now():
    old = minutes(end=T0 - dt.timedelta(minutes=25))
    assert obs.precip_now(old, None, NOW) is None
    assert obs.precip_now([], None, NOW) is None


@pytest.mark.parametrize("wb, air, tip, want", [
    (2.0, 3.0, 0.0, "rain"), (0.5, 1.0, 0.0, "snow"), (0.4, 0.5, 0.2, "mixed"),
    (1.0, 2.0, 0.0, "mixed"), (1.0, 2.0, 0.2, "rain"),
    (None, 5.0, 0.0, "rain"), (None, -1.0, 0.0, "snow"), (None, 2.0, 0.0, None)])
def test_phase_from_wet_bulb_then_air_temperature(wb, air, tip, want):
    assert obs.phase_of(wb, air, tip >= 0.2) == want


def test_wet_bulb_falls_back_to_the_hourly_record():
    recs = minutes(gauge=0.3)
    for r in recs:
        r.pop("wetblb_temp")
    p = obs.precip_now(recs, {"wetblb_temp": 0.2, "wetblb_temp-data_flag-value": 1}, NOW)
    assert p["wet_bulb"] == 0.2 and p["wet_bulb_from"] == "hourly" and p["phase"] == "snow"


def test_now_block_values_are_unchanged_and_gain_precip_now(tmp_path):
    fixture = json.loads((ROOT / "tests" / "fixtures" / "swob-kitimat-2026-11-25T2140Z.json").read_text())
    place = {"id": "kitimat", "lat": 54.0536, "lon": -128.6336,
             "obs_station": {"network": "ECCC", "climate_id": "1064324", "name": "Kitimat Forest Ave"}}
    now = int(dt.datetime(2026, 11, 25, 21, 40, tzinfo=dt.timezone.utc).timestamp())
    feats = [f["properties"] for f in fixture["features"]]
    before = obs.build_now(feats, fixture["features"][-1]["geometry"], place, place["obs_station"], now)
    m = minute(dt.datetime(2026, 11, 25, 21, 39, tzinfo=dt.timezone.utc), gauge=0.2)
    m.update({"clim_id-value": "1064324", "data_pvdr-value": "MSC"})
    after = obs.build_now(feats, fixture["features"][-1]["geometry"], place, place["obs_station"], now,
                          None, [m])
    assert {k: v for k, v in after.items() if k != "precip_now"} == \
           {k: v for k, v in before.items() if k != "precip_now"}
    assert after["precip_now"]["falling"] is True


# --- forecast fill and the condition ---------------------------------------------------

def src(temp, precip, cloud, snow=0.0, run=NOW - 6 * 3600, hours=range(0, 12)):
    base = T0.replace(minute=0)
    keys = [(base + dt.timedelta(hours=h)).strftime("%Y-%m-%dT%H:00") for h in hours]
    return {"run_unix": run, "temp": {k: temp for k in keys}, "precip": {k: precip for k in keys},
            "cloud": {k: cloud for k in keys}, "snowfall": {k: snow for k in keys}}


SOURCES = {"a": src(5.0, 0.0, 20), "b": src(6.0, 0.0, 90), "c": src(9.0, 0.5, 95)}


def test_forecast_hour_takes_the_median_of_the_sources():
    fc = nc.forecast_hour(SOURCES, (T0.replace(minute=0) + dt.timedelta(hours=1)).strftime("%Y-%m-%dT%H:00"))
    assert fc["temp"] == 6.0 and fc["cloud"] == 90 and fc["chance"] == 33 and fc["wet"] is False


def test_snow_share_sets_the_forecast_phase():
    s = {k: src(-1.0, 1.0, 100, snow=0.7) for k in "abc"}  # 0.7 cm = 1 mm water
    fc = nc.forecast_hour(s, T0.replace(minute=0).strftime("%Y-%m-%dT%H:00"))
    assert fc["wet"] is True and fc["phase"] == "snow"


def block(falling=False, phase=None):
    return {"temp": 5.7, "humidity": 91, "precip_1h_mm": 0.0, "dew_point": None,
            "precip_now": {"observed_at": "2026-11-28T04:40:00Z", "falling": falling, "phase": phase}}


def test_dry_now_takes_its_sky_from_the_forecast_and_says_so():
    out = nc.with_condition(block(), SOURCES, NOW)
    c, b = out["condition"], out["basis"]
    assert c["class"] == "cloudy" and c["falling"] is False and c["cloud_pct"] == 90
    assert b["falling"] == "measured" and b["cloud_pct"] == "forecast" and b["condition"] == "forecast"
    assert b["temp"] == "measured" and "dew_point" not in b  # null values have no basis


def test_measured_rain_wins_over_a_dry_forecast():
    out = nc.with_condition(block(True, "snow"), SOURCES, NOW)
    assert out["condition"]["class"] == "snow"
    assert out["basis"]["condition"] == "measured" and out["basis"]["phase"] == "measured"


def test_missing_station_minutes_fall_back_to_the_forecast_and_say_so():
    wet = {k: src(5.0, 1.0, 100) for k in "abc"}
    b = block()
    b["precip_now"] = None
    out = nc.with_condition(b, wet, NOW)
    assert out["condition"]["class"] == "rain"
    assert out["basis"]["falling"] == "forecast" and out["basis"]["phase"] == "forecast"


def test_condition_adds_fields_and_changes_none():
    b = block()
    out = nc.with_condition(b, SOURCES, NOW)
    assert {k: v for k, v in out.items() if k not in ("condition", "basis")} == b


def test_no_forecast_and_dry_leaves_the_class_unknown():
    out = nc.with_condition(block(), {}, NOW)
    assert out["condition"]["class"] is None and out["basis"]["falling"] == "measured"


def test_a_late_source_is_left_out(tmp_path):
    store = tmp_path
    state = {}
    for m, run in (("a", NOW - 6 * 3600), ("b", NOW - 40 * 3600)):
        rel = f"kitimat/2026-11-28/{m}.json"
        rf._write_json(store / rel, {"response": {"hourly": {"time": ["2026-11-28T05:00"],
                                                             "temperature_2m": [1.0], "precipitation": [0.0]}}})
        state[m] = {"runs": {m: run}, "fetched_unix": NOW - 3600, "file": rel}
    rf._write_json(store / "kitimat" / "state.json", state)
    assert list(nc.load_sources(store, "kitimat", ["a", "b"], NOW)) == ["a"]


def test_newest_extra_pull_fetched_by_now_is_used(tmp_path):
    for hhmm, cloud in (("0110", 10), ("0410", 50), ("0510", 99)):
        rf._write_json(tmp_path / "kitimat" / "hourly" / "2026-11-28" / f"{hhmm}00Z_a.json",
                       {"fetched_at": f"2026-11-28T{hhmm[:2]}:{hhmm[2:]}:00Z",
                        "response": {"hourly": {"time": ["2026-11-28T05:00"], "cloud_cover": [cloud]}}})
    rec = nc.newest_extra(tmp_path, "kitimat", "a", NOW)
    assert rec["response"]["hourly"]["cloud_cover"] == [50]


# --- the log ---------------------------------------------------------------------------

def test_strip_covers_the_next_6_whole_hours_with_each_source():
    s = nc.strip(SOURCES, NOW)
    assert [x["valid"] for x in s] == [f"2026-11-28T{h:02d}:00:00Z" for h in range(5, 11)]
    assert s[0]["by_source"]["c"] == [9.0, 0.5, 0.0, 95]


def test_publish_logs_now_and_the_strip_every_run(tmp_path):
    line = nc.log_line(nc.with_condition(block(), SOURCES, NOW), SOURCES, NOW)
    nc.log_now(tmp_path, "kitimat", line)
    nc.log_now(tmp_path, "kitimat", nc.log_line(None, SOURCES, NOW + 3600))
    lines = [json.loads(x) for x in (tmp_path / "kitimat" / nc.NOW_LOG).read_text().splitlines()]
    assert [x["issued_at"] for x in lines] == ["2026-11-28T04:40:00Z", "2026-11-28T05:40:00Z"]
    assert lines[0]["now"]["condition"]["class"] == "cloudy" and len(lines[0]["strip"]) == 6
    assert lines[1]["now"] is None


# --- nightly scores ----------------------------------------------------------------------

FULL = json.loads((ROOT / "tests" / "fixtures" / "swob-kitimat-hourly-all-fields-2026-11-27T12-17Z.json").read_text())


def station_archive(store, wet_hour=None):
    feats = copy.deepcopy(FULL["features"])
    for f in feats:
        p = f["properties"]
        p.update({"air_temp": 5.0, "air_temp-qa": 100, "pcpn_amt_pst1hr": 0.0, "wetblb_temp": 4.0})
        if wet_hour is not None and p["date_tm-value"][11:13] == f"{wet_hour:02d}":
            p["pcpn_amt_pst1hr"] = 1.0
    sa.save_records(store, "kitimat", feats)


def log_at(store, issued: dt.datetime, temp=6.0, wet_hours=(), now_temp=5.5, falling=False):
    base = issued.replace(minute=0)
    strip = [{"h": h, "valid": (base + dt.timedelta(hours=h)).strftime("%Y-%m-%dT%H:00:00Z"),
              "temp": temp, "wet": (base + dt.timedelta(hours=h)).hour in wet_hours, "phase": None}
             for h in range(1, 7)]
    nc.log_now(store, "kitimat", {"issued_at": issued.strftime("%Y-%m-%dT%H:%M:%SZ"), "strip": strip,
                                  "now": {"temp": now_temp, "condition": {"falling": falling, "phase": None}}})


def test_scores_temperature_miss_by_hours_ahead(tmp_path):
    station_archive(tmp_path)
    log_at(tmp_path, dt.datetime(2026, 11, 27, 11, 20, tzinfo=dt.timezone.utc))  # strip 12:00 to 17:00
    r = nc.score(tmp_path, "kitimat", NOW)
    by = {x["lead"]: x for x in r["leads"]}
    assert by[1]["temp"] == {"miss": 1.0, "bias": 1.0, "n": 1}
    assert all(by[h]["temp"]["n"] == 1 for h in range(1, 7))
    assert by[0]["temp"]["n"] == 0  # 11:00 is not in the saved records
    assert r["shown_in_app"] is False
    assert (tmp_path / "kitimat" / nc.LIVE_CSV).exists()


def test_scores_rain_or_snow_hits_and_false_alarms(tmp_path):
    station_archive(tmp_path, wet_hour=14)
    log_at(tmp_path, dt.datetime(2026, 11, 27, 11, 20, tzinfo=dt.timezone.utc), wet_hours=(14, 15))
    by = {x["lead"]: x for x in nc.score(tmp_path, "kitimat", NOW)["leads"]}
    assert by[3]["rain_or_snow"]["hit_rate"] == 1.0 and by[3]["rain_or_snow"]["wet_hours"] == 1
    assert by[4]["rain_or_snow"]["false_alarm_ratio"] == 1.0 and by[4]["rain_or_snow"]["right"] == 0.0


def test_now_is_scored_against_the_hour_nearest_the_issue(tmp_path):
    station_archive(tmp_path, wet_hour=13)
    log_at(tmp_path, dt.datetime(2026, 11, 27, 12, 50, tzinfo=dt.timezone.utc), now_temp=4.0, falling=True)
    lead0 = nc.score(tmp_path, "kitimat", NOW)["leads"][0]
    assert lead0["temp"]["miss"] == 1.0  # against 13:00
    assert lead0["rain_or_snow"]["hit_rate"] == 1.0  # the hour 12:00 to 13:00 was wet


def test_no_log_yet_scores_nothing(tmp_path):
    assert nc.score(tmp_path, "kitimat", NOW) is None
