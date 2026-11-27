"""Track record in the published file (Consensus tab, steps 2 and 3).

The numbers must be the ones the weights and habit fixes come from (archive),
or our own saved forecasts (live), each labelled, never mixed; live misses only
once enough days are in. Nothing here may change the consensus itself."""
import datetime as dt
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
sys.path.insert(0, str(ROOT / "tests"))

from wxc import consensus as cs  # noqa: E402
from wxc import publish as pb  # noqa: E402
from wxc import score as sc  # noqa: E402
import test_publish as tp  # noqa: E402
import test_score as ts  # noqa: E402


@pytest.fixture(autouse=True)
def no_pacing(monkeypatch):
    monkeypatch.setattr(sc.hz, "PACE_S", 0)


# --- consensus.py: the added stats ------------------------------------------

def test_raw_miss_and_day_counts_match_a_hand_count():
    F, obs = ts._random_history()
    lead, issue = 3, F.index[220]
    st = cs.temperature_stats(F, obs, lead, issue)
    # errors for target dates issue-60 .. issue-1 (the window, every lead)
    window = [issue - dt.timedelta(days=k) for k in range(1, 61)]
    E = F.sub(obs, axis=0).loc[window]
    assert st["days"]["b"] == E["b"].notna().sum() < 60  # "b" is sometimes late
    assert st["days"]["a"] == 60
    assert st["mae"]["b"] == pytest.approx(E["b"].abs().mean(), abs=1e-12)
    bias_window = window[:30]
    assert st["bias_days"]["a"] == 30
    assert st["habit_fix"]["a"] == pytest.approx(F.sub(obs, axis=0).loc[bias_window, "a"].mean())
    assert st["consensus_days"] == 60


def test_added_stats_leave_the_blend_alone():
    F, obs = ts._random_history()
    issue = F.index[230]
    st = cs.temperature_stats(F, obs, 2, issue)
    tc = cs.temperature_consensus(F, obs, 2)
    T = issue + dt.timedelta(days=2)
    assert cs.blend(F.loc[T], st["habit_fix"], st["mse"])[0] == pytest.approx(tc.consensus.loc[T], abs=1e-9)


def test_rain_stats_have_consensus_miss_and_counts():
    F, obs = ts._random_history()
    F, obs = F.clip(lower=0), obs.clip(lower=0)
    issue = F.index[220]
    st = cs.precip_stats(F, obs, 1, issue)
    pc = cs.precip_consensus(*cs._as_of_frame(F, obs, issue, 1)[:2], 1)
    window = [issue - dt.timedelta(days=k) for k in range(1, 61)]
    assert st["consensus_mae"] == pytest.approx((pc.consensus - obs).loc[window].abs().mean())
    assert st["consensus_days"] == 60 and st["days"]["a"] == 60


def test_too_few_days_gives_no_miss_but_still_a_count():
    F, obs = ts._random_history(n=40)
    F2 = F.copy()
    F2.iloc[:, 3] = np.nan
    F2.iloc[10:25, 3] = 1.0  # "d": 15 days
    st = cs.temperature_stats(F2, obs, 1, F.index[25])
    assert st["days"]["d"] == 15 and np.isnan(st["mae"]["d"])
    assert st["days"]["a"] == 25 and not np.isnan(st["mae"]["a"])  # days before the issue date


# --- score.py: scores.json ----------------------------------------------------

def test_scores_json_has_track_record_fields_and_windows(tmp_path):
    s = ts.run(tmp_path)["scores"]
    assert s["format"] == sc.SCORES_FORMAT == 2
    assert s["windows"] == {"miss": {"from": "2026-09-26", "to": "2026-11-24", "days": 60},
                            "bias": {"from": "2026-10-26", "to": "2026-11-24", "days": 30}}
    hi = s["leads"]["1"]["tmax"]
    assert hi["consensus_days"] == 60 and hi["consensus_mae"] is not None
    st = hi["sources"]["steady"]
    assert st["days"] == 60 and st["bias_days"] == 30
    # raw miss is about the habit (1.0) plus a little noise, larger than the
    # spread left after the habit fix
    assert st["mae"] == pytest.approx(1.0, abs=0.2) and st["mse"] < st["mae"] ** 2
    rain = s["leads"]["1"]["pcp"]
    assert rain["consensus_days"] == 60 and rain["sources"]["wild"]["days"] == 60


def test_old_format_scores_are_redone(tmp_path):
    ts.run(tmp_path)
    assert sc.already_scored(tmp_path, "kitimat", ts.ISSUE)
    p = tmp_path / "kitimat" / "scores.json"
    s = json.loads(p.read_text())
    del s["format"]  # written by the code before the track record
    p.write_text(json.dumps(s))
    assert not sc.already_scored(tmp_path, "kitimat", ts.ISSUE)


def _live_rows(days, lead=1, source="steady", pulls_per_day=1):
    """live_scores rows: forecast error 2.0, except earlier pulls the same day (9.0)."""
    rows = []
    for i in range(days):
        issue = ts.ISSUE - dt.timedelta(days=lead + 1 + i)
        for k in range(pulls_per_day):
            last = k == pulls_per_day - 1
            for var in ("tmax", "tmin", "pcp"):
                rows.append({"issue_date": issue, "fetched_at": f"{issue}T{10 + k:02d}:00:00Z",
                             "source": source, "kind": "deterministic", "lead": lead,
                             "target_date": issue + dt.timedelta(days=lead), "var": var,
                             "forecast": 0.0, "obs": 0.0, "error": 2.0 if last else 9.0})
    rows.append({**rows[-1], "kind": "ensemble", "source": "ens", "error": 50.0})
    return pd.DataFrame(rows)


def test_live_summary_counts_days_and_waits_for_enough(tmp_path):
    (tmp_path / "kitimat" / "2026-11-25").mkdir(parents=True)
    few = sc.live_summary(tmp_path, "kitimat", _live_rows(5), ts.ISSUE)
    assert few["since"] == "2026-11-25" and few["min_days"] == 20
    assert few["leads"]["1"]["days"] == 5
    assert few["leads"]["1"]["sources"]["steady"]["tmax"] == {"mae": None, "days": 5}
    assert "ens" not in few["leads"]["1"]["sources"]  # ensembles have no weight: not shown
    assert few["leads"]["7"] == {"days": 0, "sources": {}}
    enough = sc.live_summary(tmp_path, "kitimat", _live_rows(20, pulls_per_day=3), ts.ISSUE)
    # one forecast per issue date: the last pull (error 2.0), not the earlier ones (9.0)
    assert enough["leads"]["1"]["sources"]["steady"]["tmax"] == {"mae": 2.0, "days": 20}


def test_live_summary_with_no_record_yet(tmp_path):
    empty = sc.live_summary(tmp_path, "kitimat", sc.live_scores(tmp_path, "kitimat", pd.DataFrame()),
                            ts.ISSUE)
    assert empty["since"] is None
    assert all(v == {"days": 0, "sources": {}} for v in empty["leads"].values())


def test_live_summary_ignores_days_outside_the_window(tmp_path):
    rows = _live_rows(70)
    s = sc.live_summary(tmp_path, "kitimat", rows, ts.ISSUE)
    assert s["leads"]["1"]["days"] == 60


# --- publish.py: the block in the file ----------------------------------------

def scores_v2():
    s = tp.scores()
    s.update(format=2, obs_through="2026-11-24", windows=sc.windows(dt.date(2026, 11, 25)))
    for L, lead in s["leads"].items():
        for var in ("tmax", "tmin", "pcp"):
            lead[var]["consensus_mae"] = lead[var].get("consensus_mae", 3.0)
            lead[var]["consensus_days"] = 59
            for m, v in lead[var]["sources"].items():
                lead[var]["sources"][m] = {**v, "mae": 1.5, "days": 59}
                if var != "pcp":
                    lead[var]["sources"][m]["bias_days"] = 29
    s["live"] = {"since": "2026-11-25", "window": s["windows"]["miss"], "min_days": 20,
                 "leads": {str(L): {"days": 0, "sources": {}} for L in range(1, 15)}}
    s["live"]["leads"]["1"] = {"days": 3, "sources": {"steady": {"tmax": {"mae": None, "days": 3}}}}
    return s


def pulls():
    return {m: {"daily": pb._daily_from_pull(tp.pull(m)), "run_unix": tp.RUN, "fetched_unix": tp.NOW}
            for m in tp.POOL}


def test_block_matches_schema_and_todays_weights():
    doc = pb.build(tp.PLACE, tp.CFG, scores_v2(), pulls(), tp.normal_table(), tp.NOW)
    tp.validate(doc, tp.strict(tp.SCHEMA))
    t = doc["track_record"]
    assert t["leads"] == [1, 7, 13] and t["scored_on"] == "2026-11-25"
    assert t["station_through"] == "2026-11-24"
    a = t["archive"]
    assert a["basis"] == "archive" and a["min_days"] == 20
    assert a["miss_window"] == {"from": "2026-09-26", "to": "2026-11-24", "days": 60}
    for L in (1, 7, 13):
        day = doc["days"][L - 1]
        rows = {e["id"]: e for e in a["sources"] if e["lead"] == L}
        # high weights in the track record are the day's published weights
        assert {i: e["high"]["weight"] for i, e in rows.items() if e["high"]["weight"] is not None} \
            == {w["id"]: w["weight"] for w in day["weights"]}
        for e in rows.values():
            assert e["high"]["bias"] == {"steady": 0.5, "middle": -0.5}.get(e["id"], 0.0)
            assert e["high"]["days"] == 59 and e["high"]["bias_days"] == 29
            assert set(e["rain"]) == {"weight", "miss", "days"}  # no habit fix for rain
    # a source with no run that far out has a score but no weight today
    short13 = next(e for e in a["sources"] if e["id"] == "short" and e["lead"] == 13)
    assert short13["high"]["weight"] is None and short13["high"]["miss"] == 1.5
    # the normal: weight from day 8 for highs, from day 10 for rain
    normal7 = next(e for e in a["sources"] if e["id"] == "normal" and e["lead"] == 7)
    normal13 = next(e for e in a["sources"] if e["id"] == "normal" and e["lead"] == 13)
    assert normal7["high"]["weight"] is None and normal13["high"]["weight"] > 0
    assert normal13["rain"]["weight"] > 0
    assert [c["lead"] for c in a["consensus"]] == [1, 7, 13]
    assert a["consensus"][0]["high"] == {"miss": 1.1, "days": 59}


def test_low_and_rain_weights_are_the_ones_used_today():
    doc = pb.build(tp.PLACE, tp.CFG, scores_v2(), pulls(), None, tp.NOW)
    rows = {e["id"]: e for e in doc["track_record"]["archive"]["sources"] if e["lead"] == 1}
    for name in ("low", "rain"):
        total = sum(e[name]["weight"] for e in rows.values() if e[name]["weight"] is not None)
        assert total == pytest.approx(1, abs=0.01)
    # equal rain misses: equal shares among the three sources present
    assert {e["rain"]["weight"] for i, e in rows.items() if i in tp.POOL} == {0.333}


def test_live_is_labelled_apart_and_too_few_days_has_no_miss():
    doc = pb.build(tp.PLACE, tp.CFG, scores_v2(), pulls(), None, tp.NOW)
    live = doc["track_record"]["live"]
    assert live["basis"] == "live" and live["since"] == "2026-11-25" and live["min_days"] == 20
    assert live["days"] == [{"lead": 1, "days": 3}, {"lead": 7, "days": 0}, {"lead": 13, "days": 0}]
    assert live["sources"] == [{"id": "steady", "lead": 1, "high": {"miss": None, "days": 3}}]
    assert live["consensus"] is None  # never filled from the archive


def test_older_scores_publish_no_block():
    doc = pb.build(tp.PLACE, tp.CFG, tp.scores(), pulls(), None, tp.NOW)
    assert "track_record" not in doc
    tp.validate(doc, tp.strict(tp.SCHEMA))


def test_block_changes_nothing_else():
    a = pb.build(tp.PLACE, tp.CFG, tp.scores(), pulls(), tp.normal_table(), tp.NOW)
    b = pb.build(tp.PLACE, tp.CFG, scores_v2(), pulls(), tp.normal_table(), tp.NOW)
    b.pop("track_record")
    assert a == b


def test_file_with_the_block_stays_small(tmp_path):
    store = tp.make_store(tmp_path)
    (store / tp.PLACE["id"] / "scores.json").write_text(json.dumps(scores_v2()))
    pb.publish(tp.PLACE, tp.CFG, store, tmp_path / "public", now=tp.NOW, echo=lambda *a: None)
    text = (tmp_path / "public" / f"{tp.PLACE['id']}.json").read_text()
    assert "track_record" in text and "\n" not in text and len(text) < 12_000
