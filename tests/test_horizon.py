"""Days 8 to 14 helpers: Single Runs by lead and the daily normal (no network)."""
import datetime as dt
import json
import sys
from pathlib import Path

import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from wxc import horizon as hz  # noqa: E402


def test_single_run_days_are_numbered_from_the_run_date(tmp_path):
    run = dt.date(2026, 6, 1)
    times = [(dt.datetime(2026, 6, 1) + dt.timedelta(hours=k)).strftime("%Y-%m-%dT%H:%M")
             for k in range(16 * 24)]
    temp = [10.0 + (k // 24) for k in range(16 * 24)]  # warmer each UTC day
    path = hz.single_run_path(tmp_path, "kitimat", "m", run)
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"hourly": {"time": times, "temperature_2m": temp,
                                           "precipitation": [0.0] * len(times)}}))
    d = hz.single_runs_daily(tmp_path, "kitimat", "m")
    assert set(d) == set(range(1, 15))
    assert d[1].index[0] == dt.date(2026, 6, 2) and d[14].index[0] == dt.date(2026, 6, 15)
    # climate day 2 Jun runs 06 UTC 2 Jun to 06 UTC 3 Jun: max is the 3 Jun UTC value
    assert d[1].tmax.iloc[0] == 12.0


def test_missing_runs_are_fetched_once(tmp_path):
    calls = []

    def get(url, log=None):
        calls.append(url)
        return {"hourly": {"time": [], "temperature_2m": []}}

    place = {"id": "kitimat", "lat": 54, "lon": -128, "elevation_m": 98}
    days = [dt.date(2026, 6, 1), dt.date(2026, 6, 2)]
    hz.fetch_single_runs(place, ["a", "b"], days, tmp_path, get=get, sleep=lambda s: None, echo=lambda *a: None)
    hz.fetch_single_runs(place, ["a", "b"], days, tmp_path, get=get, sleep=lambda s: None, echo=lambda *a: None)
    assert len(calls) == 4 and all("run=2026-06-0" in c and "T00%3A00" in c for c in calls)


def _records(years=(2000, 2001)):
    feats = []
    for y in years:
        for d in pd.date_range(f"{y}-01-01", f"{y}-12-31"):
            summer = 15 * (1 - abs(d.day_of_year - 196) / 182)
            feats.append({"properties": {"LOCAL_DATE": f"{d.date()} 00:00:00", "MAX_TEMPERATURE": 5 + summer,
                                         "MIN_TEMPERATURE": summer - 2, "TOTAL_PRECIPITATION": 2.0}})
    return [{"features": feats}]


def test_normal_follows_the_seasons_and_handles_leap_day():
    n = hz.daily_normal(_records(), years=(2000, 2001))
    assert n.loc[196, "tmax"] == pytest.approx(20, abs=0.5)
    assert n.loc[15, "tmax"] < 7 and n.loc[196, "wet_share"] == 1.0
    looked = hz.normal_for(n, [dt.date(2024, 2, 29), dt.date(2024, 2, 28), dt.date(2024, 3, 1)])
    assert looked.tmax.iloc[0] == looked.tmax.iloc[1]  # 29 Feb uses 28 Feb
    assert looked.tmax.iloc[2] == n.loc[60, "tmax"]   # 1 Mar is day 60 in every year


def test_runs_open_meteo_does_not_have_are_not_asked_for_again(tmp_path):
    calls = []

    def get(url, log=None):
        calls.append(url)
        raise RuntimeError("open-meteo error: The requested model run is not available.")

    place = {"id": "kitimat", "lat": 54, "lon": -128, "elevation_m": 98}
    old, recent = dt.date.today() - dt.timedelta(days=10), dt.date.today() - dt.timedelta(days=1)
    for _ in range(2):
        hz.fetch_single_runs(place, ["a"], [old, recent], tmp_path, get=get,
                             sleep=lambda s: None, echo=lambda *a: None)
    assert len(calls) == 3  # old run asked once; the recent one may still arrive
