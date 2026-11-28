"""Beta hourly forecast, 3-hour blocks, today and each day's condition
(28 Nov 2026). backend/wxc/hourly.py and its place in publish.build."""
import datetime as dt
import json
import math
import sys
from pathlib import Path

import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
sys.path.insert(0, str(ROOT / "tests"))

from wxc import hourly as hr  # noqa: E402
from wxc import openmeteo as om  # noqa: E402
from wxc import publish as pb  # noqa: E402

T0 = dt.datetime(2026, 11, 28, 4, 40)
NOW = int(T0.replace(tzinfo=dt.timezone.utc).timestamp())
ISSUE = dt.date(2026, 11, 27)  # 04:40 UTC is still the 27 Nov climate day


def series(fn, hours=range(-30, 140)):
    base = T0.replace(minute=0)
    return {(base + dt.timedelta(hours=h)).strftime("%Y-%m-%dT%H:00"): fn(base + dt.timedelta(hours=h))
            for h in hours}


def source(temp=5.0, precip=0.0, cloud=50.0, snow=0.0, rh=90.0, wind=10.0, wdir=180.0):
    c = lambda x: (lambda t: x(t) if callable(x) else x)  # noqa: E731
    return {"run_unix": NOW - 6 * 3600, "temp": series(c(temp)), "precip": series(c(precip)),
            "cloud": series(c(cloud)), "snowfall": series(c(snow)), "rh": series(c(rh)),
            "wind": series(c(wind)), "wind_dir": series(c(wdir))}


def scores(mse=None):
    mse = mse or {"a": 1.0, "b": 1.0, "c": 1.0}
    leads = {}
    for L in range(1, 15):
        leads[str(L)] = {"tmax": {"sources": {m: {"habit_fix": 0.0, "mse": v} for m, v in mse.items()}},
                         "tmin": {"sources": {m: {"habit_fix": 0.0, "mse": v} for m, v in mse.items()}},
                         "pcp": {"sources": {m: {"mae": 1.0} for m in mse}}}
    return {"leads": leads}


# --- feels like (ECCC rules) ------------------------------------------------------

def test_wind_chill_at_zero_or_below_with_wind_5_kmh_or_more():
    assert hr.feels_like(0.0, 5.0, 80) == pytest.approx(hr.wind_chill(0.0, 5.0))
    assert hr.feels_like(-10.0, 20.0, 80) == pytest.approx(-17.9, abs=0.1)  # ECCC table value
    assert hr.feels_like(0.5, 30.0, 80) == 0.5
    assert hr.feels_like(-5.0, 4.9, 80) == -5.0


def test_humidex_uses_the_forecast_threshold_of_25():
    assert hr.feels_like(24.0, 5.0, 90) == 24.0
    assert hr.feels_like(30.0, 5.0, 70) == pytest.approx(hr.humidex(30.0, hr.dew_point(30.0, 70)))
    assert hr.feels_like(30.0, 5.0, 70) > 35


def test_dew_point_from_humidity():
    assert hr.dew_point(20.0, 100) == pytest.approx(20.0, abs=0.01)
    assert hr.dew_point(20.0, 50) == pytest.approx(9.3, abs=0.1)


# --- blends -------------------------------------------------------------------------

def test_temperature_uses_the_hourly_habit_fix_by_hour_of_day():
    srcs = {"a": source(temp=5.0), "b": source(temp=7.0)}
    h = {"sources": {"a": {"1": {"bias": [1.0] * 24, "n": [30] * 24}},
                     "b": {"1": {"bias": [-1.0] * 24, "n": [30] * 24}}}}
    t = T0.replace(minute=0) + dt.timedelta(hours=2)
    v = hr.blend_temp(srcs, t.strftime("%Y-%m-%dT%H:00"), t, 1, scores({"a": 1.0, "b": 1.0}), h)
    assert v == pytest.approx(6.0)  # (5 - 1 + 7 + 1) / 2


def test_without_an_hourly_fix_the_daily_fix_is_used():
    srcs = {"a": source(temp=5.0)}
    sc = scores({"a": 1.0})
    for L in sc["leads"].values():
        L["tmax"]["sources"]["a"]["habit_fix"] = 2.0
        L["tmin"]["sources"]["a"]["habit_fix"] = 0.0
    t = T0.replace(minute=0)
    assert hr.blend_temp(srcs, t.strftime("%Y-%m-%dT%H:00"), t, 1, sc, {}) == pytest.approx(4.0)


def test_weights_follow_the_daily_error():
    srcs = {"a": source(temp=0.0), **{k: source(temp=10.0) for k in "bcde"}}
    t = T0.replace(minute=0)
    v = hr.blend_temp(srcs, t.strftime("%Y-%m-%dT%H:00"), t, 1,
                      scores({"a": 1.0, "b": 4.0, "c": 4.0, "d": 4.0, "e": 4.0}), {})
    assert v == pytest.approx(6.5, abs=0.01)  # a capped at 35%; equal weights would give 8


def test_chance_is_the_wet_share_and_condition_follows_it():
    srcs = {"a": source(precip=0.5), "b": source(precip=0.4), "c": source(precip=0.0, cloud=10)}
    v = hr.hour_values(srcs, T0.replace(minute=0), ISSUE, scores(), {})
    assert v["chance"] == pytest.approx(2 / 3)
    assert hr.condition_of(v["chance"], v["snow_share"], v["temp"], v["cloud"]) == "rain"


def test_snow_share_makes_it_snow():
    srcs = {k: source(temp=-2.0, precip=1.0, snow=0.7) for k in "abc"}
    v = hr.hour_values(srcs, T0.replace(minute=0), ISSUE, scores(), {})
    assert v["snow_share"] == pytest.approx(1.0)
    assert hr.condition_of(v["chance"], v["snow_share"], v["temp"], v["cloud"]) == "snow"


def test_dry_hours_take_their_sky_from_the_median_cloud():
    for cloud, want in ((10, "clear"), (50, "partly"), (90, "cloudy")):
        srcs = {"a": source(cloud=cloud), "b": source(cloud=cloud), "c": source(cloud=100)}
        v = hr.hour_values(srcs, T0.replace(minute=0), ISSUE, scores(), {})
        assert hr.condition_of(v["chance"], v["snow_share"], v["temp"], v["cloud"]) == want


def test_wind_direction_is_the_vector_average():
    assert hr.vector_dir([350, 10], [10, 10]) == 0
    assert hr.vector_dir([90, 270], [10, 10]) is None


# --- the published blocks ------------------------------------------------------------

def build(now_block=None, srcs=None):
    srcs = srcs or {k: source() for k in "abc"}
    return hr.build(srcs, scores(), {}, NOW, ISSUE, now_block, [])


def test_48_hours_from_the_current_hour_then_16_blocks_of_3_hours_to_96():
    b = build()
    assert len(b["hourly"]) == 48 and b["hourly"][0]["time"] == "2026-11-28T04:00:00Z"
    assert b["hourly"][-1]["time"] == "2026-11-30T03:00:00Z"
    assert len(b["blocks"]) == 16 and b["blocks"][0]["time"] == "2026-11-30T04:00:00Z"
    assert b["blocks"][-1]["time"] == "2026-12-02T01:00:00Z"  # 93 h after the first hour
    e = b["hourly"][0]
    assert set(e) == set(hr.FIELDS) and e["condition"] == "partly" and e["precip_chance"] == 0


def test_block_precipitation_is_the_total_and_chance_the_wet_share():
    srcs = {"a": source(precip=0.1), "b": source(precip=0.1), "c": source(precip=0.0)}
    blk = build(srcs=srcs)["blocks"][0]
    assert blk["precip_chance"] == 67  # 0.3 mm over 3 hours in a and b
    assert blk["precip_mm"] == pytest.approx(0.2, abs=0.05)


def now_block(temp=8.0, high=9.0, low=3.0, observed="2026-11-28T04:40:00Z"):
    return {"temp": temp, "observed_at": observed, "high_so_far": high, "low_so_far": low,
            "so_far_since": "2026-11-27T06:00:00Z", "precip_so_far_mm": 2.0}


def test_first_hours_are_nudged_toward_the_observation_and_fade():
    b = build(now_block(temp=8.0))  # forecast 5.0 everywhere: offset +3
    temps = [h["temp"] for h in b["hourly"]]
    assert temps[0] == pytest.approx(8.0, abs=0.01)
    assert temps[6] == pytest.approx(5.0 + 3 * math.exp(-(6 - 40 / 60) / 6), abs=0.05)
    assert temps[30] == pytest.approx(5.0, abs=0.05)
    assert b["nudge"]["offset"] == pytest.approx(3.0)


def test_today_takes_the_observed_high_and_low_with_the_rest_of_the_day():
    t = build(now_block(temp=5.0, high=9.0, low=3.0))["today"]
    assert t["date"] == "2026-11-27" and t["hours"] == {"from": "2026-11-27T06:00:00Z", "to": "2026-11-28T06:00:00Z"}
    assert (t["high"], t["high_from"], t["low"], t["low_from"]) == (9.0, "observed", 3.0, "observed")
    assert t["precip_so_far_mm"] == 2.0 and t["verified"] is False


def test_today_without_the_station_is_forecast_only():
    t = build(None)["today"]
    assert t["high_from"] == "forecast" and t["precip_so_far_mm"] is None


def test_day_condition_summarizes_the_climate_day():
    srcs = {k: source(cloud=lambda t: 100 if 6 <= t.hour < 18 else 0) for k in "abc"}
    d = hr.day_condition(srcs, dt.date(2026, 11, 29), 0, 5.0, 1.0)
    assert d["class"] == "partly" and d["cloud_pct"] == 50 and d["sources"] == 3
    wet = hr.day_condition({k: source(precip=0.2, snow=0.0) for k in "abc"}, dt.date(2026, 11, 29), 80, 5.0, 1.0)
    assert wet["class"] == "rain"


def test_day_condition_without_snowfall_uses_the_mean_temperature():
    srcs = {k: source(precip=0.2) for k in "abc"}
    for s in srcs.values():
        s["snowfall"] = {}
    assert hr.day_condition(srcs, dt.date(2026, 11, 29), 80, 1.0, -3.0)["class"] == "snow"
    assert hr.day_condition(srcs, dt.date(2026, 11, 29), 80, 6.0, 2.0)["class"] == "rain"
    assert hr.day_condition(srcs, dt.date(2026, 11, 29), 80, 3.0, -1.0)["class"] == "mixed"


# --- the nightly habit fix -------------------------------------------------------------

def test_hourly_habit_uses_30_verified_days_per_utc_hour():
    issue = dt.date(2026, 11, 28)
    times, vals = [], []
    t = dt.datetime(2026, 10, 1)
    while t < dt.datetime(2026, 11, 29):
        times.append(t.strftime("%Y-%m-%dT%H:%M"))
        vals.append(6.0 if t.hour == 12 else 5.0)
        t += dt.timedelta(hours=1)
    prev = {"a": {"hourly": {"time": times, "temperature_2m_previous_day1": vals}}}
    truth = pd.Series({x[:13] + ":00": 5.0 for x in times}, dtype=float)
    # a target that is not yet verified at issue time must not count
    truth[f"{issue.isoformat()}T12:00"] = -50.0
    out = hr.hourly_habit(prev, truth, issue, ["a"])
    cell = out["a"]["1"]
    assert cell["bias"][12] == 1.0 and cell["bias"][3] == 0.0
    assert cell["n"][12] == 30


def test_score_writes_hourly_scores_from_saved_copies(tmp_path):
    from test_nowcast import station_archive
    station_archive(tmp_path)
    (tmp_path / "kitimat" / "history").mkdir(parents=True)
    (tmp_path / "kitimat" / "history" / "prev_a.json").write_text(json.dumps(
        {"hourly": {"time": ["2026-11-27T12:00"], "temperature_2m_previous_day1": [6.0]}}))
    r = hr.score(tmp_path, {"id": "kitimat"}, {"deterministic_pool": ["a"]}, dt.date(2026, 11, 28), NOW)
    assert r and (tmp_path / "kitimat" / hr.SCORES).exists()
    assert hr.score(tmp_path / "none", {"id": "kitimat"}, {"deterministic_pool": ["a"]}, dt.date(2026, 11, 28), NOW) is None


# --- in the published file --------------------------------------------------------------

def test_main_pull_asks_for_the_hourly_variables_at_no_extra_cost():
    url = om.forecast_url(54.05, -128.63, 98, "ecmwf_ifs", 16, variables=om.MAIN_VARIABLES)
    assert "hourly=" + "%2C".join(om.MAIN_VARIABLES) in url
    assert len(om.MAIN_VARIABLES) <= 8  # 8 / 10 x 16 / 14 < 1: still one weighted call (measured 1.0 with 7)


def test_published_file_has_the_beta_blocks_marked_unverified(tmp_path):
    import test_publish as tp
    store = tp.make_store(tmp_path)
    doc = pb.publish(tp.PLACE, tp.CFG, store, tmp_path / "public", now=tp.NOW, echo=lambda *a: None)
    assert doc["hourly"]["verified"] is False and len(doc["hourly"]["time"]) == 48
    assert all(len(doc["hourly"][f]) == 48 for f in hr.FIELDS)
    assert len(doc["blocks"]["time"]) == 16 and doc["blocks"]["step_h"] == 3
    assert doc["today"]["verified"] is False
    assert doc["verification"]["verified"] == [] and doc["verification"]["conditions_verified"] == []
    assert set(doc["verification"]["unverified"]) >= {"days.condition", "hourly", "blocks", "today"}
    assert all("condition" in d for d in doc["days"])


def test_existing_fields_are_unchanged_by_the_beta_blocks(tmp_path):
    import test_publish as tp
    store = tp.make_store(tmp_path)
    scores_ = json.loads((store / tp.PLACE["id"] / "scores.json").read_text())
    pulls = pb.load_pulls(store, tp.PLACE["id"], tp.CFG["deterministic_pool"])
    plain = pb.build(tp.PLACE, tp.CFG, scores_, pulls, None, tp.NOW)
    srcs = __import__("wxc.nowcast", fromlist=["x"]).load_sources(store, tp.PLACE["id"], tp.CFG["deterministic_pool"], tp.NOW)
    beta = pb.build(tp.PLACE, tp.CFG, scores_, pulls, None, tp.NOW, hourly_inputs={"sources": srcs})
    for k in ("today", "hourly", "blocks", "verification"):
        beta.pop(k, None)
    for d in beta["days"]:
        d.pop("condition")
    assert beta == plain


def test_now_log_records_the_published_hours_with_each_source(tmp_path):
    import test_publish as tp
    store = tp.make_store(tmp_path)
    doc = pb.publish(tp.PLACE, tp.CFG, store, tmp_path / "public", now=tp.NOW, echo=lambda *a: None)
    line = json.loads((store / tp.PLACE["id"] / "now_log.jsonl").read_text().splitlines()[-1])
    assert line["method"] == "published_beta_v1" and len(line["strip"]) == 6
    first = line["strip"][0]
    i = doc["hourly"]["time"].index(first["valid"])
    assert first["temp"] == doc["hourly"]["temp"][i] and first["condition"] == doc["hourly"]["condition"][i]
    assert set(first["by_source"]) == set(tp.CFG["deterministic_pool"])
