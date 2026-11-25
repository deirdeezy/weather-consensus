"""Nightly scoring with fake downloads (no network)."""
import datetime as dt
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from wxc import consensus as cs  # noqa: E402
from wxc import score as sc  # noqa: E402

ISSUE = dt.date(2026, 11, 25)
START = ISSUE - dt.timedelta(days=sc.HISTORY_DAYS)
DAYS = [START + dt.timedelta(days=i) for i in range(sc.HISTORY_DAYS + 16)]
PLACE = {"id": "kitimat", "lat": 54.05, "lon": -128.63, "elevation_m": 98,
         "truth": {"climate_id": "1064324"}}
CFG = {"deterministic_pool": ["steady", "middle", "wild"]}
TRUTH = {d: 5 + 6 * np.sin(i / 20) for i, d in enumerate(DAYS)}
HABIT = {"steady": 1.0, "middle": 0.0, "wild": -2.0}
NOISE = {"steady": 0.3, "middle": 1.0, "wild": 2.0}


def hourly_series(model, rng):
    """Hourly UTC times on the climate day; daily max = truth + habit + noise."""
    times, vals = [], {L: [] for L in sc.LEADS}
    for d in DAYS:
        day_err = {L: HABIT[model] + rng.normal(0, NOISE[model]) for L in sc.LEADS}
        for k in range(24):
            t = dt.datetime.combine(d, dt.time(6)) + dt.timedelta(hours=k)
            times.append(t.strftime("%Y-%m-%dT%H:%M"))
            for L in sc.LEADS:
                vals[L].append(TRUTH[d] + day_err[L] - 0.2 * k)
    return times, vals


def prev_payload(model):
    rng = np.random.default_rng(len(model))
    times, vals = hourly_series(model, rng)
    h = {"time": times}
    for L in sc.LEADS:
        h[f"temperature_2m_previous_day{L}"] = vals[L]
        h[f"precipitation_previous_day{L}"] = [0.1] * len(times)
    return {"hourly": h}


def obs_payload(*_):
    feats = [{"properties": {"LOCAL_DATE": f"{d} 00:00:00", "MAX_TEMPERATURE": TRUTH[d],
                             "MIN_TEMPERATURE": TRUTH[d] - 4.6, "TOTAL_PRECIPITATION": 2.4}}
             for d in DAYS if d < ISSUE]
    return {"type": "FeatureCollection", "features": feats}


def fake_get(url, tries=8, log=print):
    model = url.split("models=")[1].split("&")[0]
    return prev_payload(model)


def run(tmp_path, get=fake_get, fetch_obs=obs_payload):
    return sc.score(PLACE, CFG, tmp_path, issue=ISSUE, get=get, fetch_obs=fetch_obs,
                    echo=lambda *a: None)


def test_scores_find_habits_and_favour_the_steady_source(tmp_path):
    s = run(tmp_path)["scores"]
    d1 = s["leads"]["1"]["tmax"]
    assert d1["sources"]["steady"]["habit_fix"] == pytest.approx(1.0, abs=0.15)
    assert d1["sources"]["wild"]["habit_fix"] == pytest.approx(-2.0, abs=0.8)
    w = {m: v["weight"] for m, v in d1["sources"].items()}
    assert w["steady"] == pytest.approx(cs.CAP) and w["wild"] < w["middle"] and sum(w.values()) == pytest.approx(1.0, abs=1e-3)
    assert s["obs_through"] == "2026-11-24" and s["sources_missing"] == []
    assert json.loads((tmp_path / "kitimat" / "scores.json").read_text())["issue_date"] == "2026-11-25"


def test_failed_download_uses_saved_copy_and_is_logged(tmp_path):
    run(tmp_path)

    def refuse(url, tries=8, log=print):
        raise RuntimeError("open-meteo error: limit")

    s = run(tmp_path, get=refuse)["scores"]
    assert s["sources_missing"] == []  # saved copies used
    kinds = [json.loads(x)["kind"] for x in (tmp_path / "refusals.jsonl").read_text().splitlines()]
    assert kinds == ["error", "used_stale"] * 3


def test_no_station_data_means_no_new_scores(tmp_path):
    def down(*a):
        raise TimeoutError("ECCC down")

    with pytest.raises(RuntimeError):
        run(tmp_path, fetch_obs=down)
    assert not (tmp_path / "kitimat" / "scores.json").exists()


def _random_history(seed=1, n=260):
    rng = np.random.default_rng(seed)
    dates = pd.Index(pd.date_range("2026-01-01", periods=n).date)
    obs = pd.Series(rng.normal(5, 4, n), index=dates)
    F = pd.DataFrame({m: obs + b + rng.normal(0, s, n) for m, b, s in
                      [("a", 1, 0.5), ("b", -1, 1.5), ("c", 0, 1.0), ("d", 2, 3.0)]}, index=dates)
    F.iloc[::17, 1] = np.nan  # a source that is sometimes late
    return F, obs


@pytest.mark.parametrize("lead", [1, 4, 7])
def test_live_blend_matches_backtest_math(lead):
    F, obs = _random_history()
    tc = cs.temperature_consensus(F, obs, lead)
    for issue in [F.index[200], F.index[230]]:
        T = issue + dt.timedelta(days=lead)
        st = cs.temperature_stats(F, obs, lead, issue)
        c, s, _ = cs.blend(F.loc[T], st["habit_fix"], st["mse"])
        assert c == pytest.approx(tc.consensus.loc[T], abs=1e-9)
        assert s == pytest.approx(tc.spread.loc[T], abs=1e-9)


def test_stats_ignore_anything_from_issue_day_on():
    F, obs = _random_history()
    issue = F.index[220]
    a = cs.temperature_stats(F, obs, 3, issue)
    obs2 = obs.copy()
    obs2[obs2.index >= issue] += 50  # wildly different "future" truth
    b = cs.temperature_stats(F, obs2, 3, issue)
    assert np.allclose(a["mse"], b["mse"]) and a["consensus_mae"] == b["consensus_mae"]


def test_live_pull_is_scored_by_lead(tmp_path):
    day = tmp_path / "kitimat" / "2026-11-20"
    day.mkdir(parents=True)
    times = [(dt.datetime(2026, 11, 21, 6) + dt.timedelta(hours=k)).strftime("%Y-%m-%dT%H:%M")
             for k in range(48)]
    det = {"source": "steady", "kind": "deterministic", "fetched_at": "2026-11-20T09:00:00Z",
           "response": {"hourly": {"time": times, "temperature_2m": [7.0] * 48,
                                   "precipitation": [0.0] * 48}}}
    ens = {"source": "ens", "kind": "ensemble", "fetched_at": "2026-11-20T09:00:00Z",
           "response": {"hourly": {"time": times, "temperature_2m": [6.0] * 48,
                                   "temperature_2m_member01": [8.0] * 48}}}
    (day / "090000Z_steady.json").write_text(json.dumps(det))
    (day / "090000Z_ens.json").write_text(json.dumps(ens))
    obs = pd.DataFrame({"tmax": [5.0, 5.0], "tmin": [1.0, 1.0], "pcp": [0.0, 0.0]},
                       index=[dt.date(2026, 11, 21), dt.date(2026, 11, 22)])
    live = sc.live_scores(tmp_path, "kitimat", obs)
    hi = live[live["var"] == "tmax"].set_index(["source", "lead"])["error"]
    assert hi[("steady", 1)] == 2.0 and hi[("steady", 2)] == 2.0
    assert hi[("ens", 1)] == 2.0  # member average 7.0 vs 5.0


@pytest.mark.skipif(not (ROOT / "data/cache/prev/ecmwf_ifs.json").exists(), reason="pilot cache absent")
def test_pilot_history_live_equals_backtest():
    sys.path.insert(0, str(ROOT / "backend" / "scripts"))
    from backtest import frame, load
    obs, models = load()
    dates = pd.Index(sorted(obs.index))
    F, o = frame(models, 2, "tmax", dates), obs["tmax"].reindex(dates)
    tc = cs.temperature_consensus(F, o, 2)
    issue = dt.date(2026, 8, 1)
    T = issue + dt.timedelta(days=2)
    st = cs.temperature_stats(F, o, 2, issue)
    assert cs.blend(F.loc[T], st["habit_fix"], st["mse"])[0] == pytest.approx(tc.consensus.loc[T], abs=1e-9)
