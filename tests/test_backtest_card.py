"""The backtest block ("Tested on real Kitimat weather" card) and our own
consensus log (one line a day, scored nightly like the sources)."""
import datetime as dt
import json
import sys
from pathlib import Path

import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
sys.path.insert(0, str(ROOT / "tests"))

from wxc import publish as pb  # noqa: E402
from wxc import score as sc  # noqa: E402
import test_publish as tp  # noqa: E402
import test_track_record as tt  # noqa: E402

RESULTS = ROOT / "data" / "backtest" / "kitimat.json"
CACHE = ROOT / "data" / "cache" / "prev" / "ecmwf_ifs.json"


# --- the results file ---------------------------------------------------------

def test_results_file_is_committed_and_labelled():
    r = json.loads(RESULTS.read_text())
    assert r["basis"] == "backtest" and r["place"] == "kitimat"
    assert r["method"]["past_data_only"] is True
    assert r["scored_from"] == "2026-01-01" and r["scored_to"] == "2026-10-30"
    assert r["baseline"] == "ecmwf_ifs"
    assert [x["lead"] for x in r["leads"]] == list(range(1, 8))
    d1 = r["leads"][0]
    # the numbers docs/ALGORITHM.md reports from the same script
    assert (d1["high"]["consensus"], d1["high"]["baseline"]) == (1.004, 1.424)
    assert (d1["low"]["consensus"], d1["low"]["baseline"]) == (1.008, 1.475)
    assert d1["high"]["days"] == 285
    assert d1["rain"]["brier_chance"] == 0.092


@pytest.mark.skipif(not CACHE.exists(), reason="pilot cache absent")
def test_results_file_matches_a_fresh_backtest(tmp_path, monkeypatch, capsys):
    sys.path.insert(0, str(ROOT / "backend" / "scripts"))
    import backtest
    monkeypatch.setattr(backtest, "ROOT", tmp_path)  # the CSV goes to tmp too
    (tmp_path / "data").mkdir()
    monkeypatch.setattr(backtest, "RESULTS", tmp_path / "data" / "kitimat.json")
    backtest.scores()
    assert json.loads((tmp_path / "data" / "kitimat.json").read_text()) == json.loads(RESULTS.read_text())


# --- the published block -------------------------------------------------------

def test_block_is_published_as_written_and_matches_the_schema(tmp_path):
    results = json.loads(RESULTS.read_text())
    (tmp_path / "testplace.json").write_text(json.dumps({**results, "place": "testplace"}))
    bt = pb.load_backtest(tmp_path, "testplace")
    doc = pb.build(tp.PLACE, tp.CFG, tp.scores(), tt.pulls(), None, tp.NOW, backtest=bt)
    tp.validate(doc, tp.strict(tp.SCHEMA))
    b = doc["backtest"]
    assert b["basis"] == "backtest" and b["leads"] == results["leads"]
    assert b["scored_from"] == "2026-01-01" and b["method"]["past_data_only"] is True
    assert "script" not in b["method"] and "place" not in b


def test_no_results_or_another_place_means_no_block(tmp_path):
    assert pb.load_backtest(None, "kitimat") is None
    assert pb.load_backtest(tmp_path, "kitimat") is None
    (tmp_path / "terrace.json").write_text(json.dumps({**json.loads(RESULTS.read_text())}))
    assert pb.load_backtest(tmp_path, "terrace") is None  # the file says kitimat
    doc = pb.build(tp.PLACE, tp.CFG, tp.scores(), tt.pulls(), None, tp.NOW)
    assert "backtest" not in doc


def test_published_kitimat_file_carries_the_block(tmp_path):
    store = tp.make_store(tmp_path)
    place = {**tp.PLACE, "id": "kitimat"}
    for f in (store / tp.PLACE["id"]).rglob("*"):
        if f.is_file():
            t = store / "kitimat" / f.relative_to(store / tp.PLACE["id"])
            t.parent.mkdir(parents=True, exist_ok=True)
            t.write_text(f.read_text().replace(f'"{tp.PLACE["id"]}/', '"kitimat/'))
    doc = pb.publish(place, tp.CFG, store, tmp_path / "public", now=tp.NOW, echo=lambda *a: None,
                     backtest_dir=RESULTS.parent)
    text = (tmp_path / "public" / "kitimat.json").read_text()
    assert doc["backtest"]["leads"][0]["high"]["consensus"] == 1.004
    assert "backend/scripts" not in text and "data/backtest" not in text


# --- our own consensus log ------------------------------------------------------

def test_publish_writes_one_line_per_issue_date(tmp_path):
    store = tp.make_store(tmp_path)
    out = tmp_path / "public"
    log = store / tp.PLACE["id"] / pb.CONSENSUS_LOG
    pb.publish(tp.PLACE, tp.CFG, store, out, now=tp.NOW, echo=lambda *a: None)
    first = log.read_text()
    pb.publish(tp.PLACE, tp.CFG, store, out, now=tp.NOW + 3600, echo=lambda *a: None)  # same day, later
    lines = log.read_text().splitlines()
    assert len(lines) == 1 and lines[0] != first.strip()
    rec = json.loads(lines[0])
    assert rec["issued_at"] == pb.iso(tp.NOW + 3600) and rec["issue_date"] == "2026-11-25"
    assert len(rec["days"]) == 14 and len(rec["days"][0]) == 6 and rec["days"][0][0] == 1
    pb.publish(tp.PLACE, tp.CFG, store, out, now=tp.NOW + 86400, echo=lambda *a: None)  # next day
    lines = log.read_text().splitlines()
    assert [json.loads(x)["issue_date"] for x in lines] == ["2026-11-25", "2026-11-26"]
    assert all(len(x) + 1 < 600 for x in lines)  # bytes per place per day


def _log(tmp_path, days=25, error=1.0):
    """A consensus log whose day-1 high is always `error` too warm, with a station record."""
    issue0 = dt.date(2026, 10, 1)
    lines, obs = [], {}
    for i in range(days):
        issue = issue0 + dt.timedelta(days=i)
        target = issue + dt.timedelta(days=1)
        obs[target] = {"tmax": 5.0, "tmin": 1.0, "pcp": 2.0 if i % 2 else 0.0}
        lines.append(json.dumps({"issue_date": issue.isoformat(), "issued_at": f"{issue}T23:10:00Z",
                                 "days": [[1, 5.0 + error, 0.5, 1.0, 80, 90], [2, None, None, None, None, None]]}))
    (tmp_path / "kitimat").mkdir(parents=True, exist_ok=True)
    (tmp_path / "kitimat" / sc.CONSENSUS_LOG).write_text("\n".join(lines) + "\n")
    return pd.DataFrame.from_dict(obs, orient="index"), issue0 + dt.timedelta(days=days + 1)


def test_consensus_is_scored_like_the_sources(tmp_path):
    obs, issue = _log(tmp_path, days=25)
    rows = sc.consensus_scores(tmp_path, "kitimat", obs)
    assert len(rows[rows["lead"] == 1]) == 25
    s = sc.consensus_summary(rows, issue)
    d1 = s["1"]
    assert d1["days"] == 25
    assert d1["high"] == {"mae": 1.0, "days": 25} and d1["low"] == {"mae": 0.5, "days": 25}
    assert d1["rain"]["mae"] == pytest.approx(1.0)
    # Brier: chance 0.8 every day; 12 wet days (miss 0.2), 13 dry days (miss 0.8)
    assert d1["chance"]["brier"] == pytest.approx((12 * 0.2 ** 2 + 13 * 0.8 ** 2) / 25, abs=1e-4)
    assert d1["certainty"] == {"said": 0.9, "came_true": 1.0, "days": 25}
    assert s["2"]["high"] == {"mae": None, "days": 0}  # nulls are not days


def test_too_few_consensus_days_give_counts_only(tmp_path):
    obs, issue = _log(tmp_path, days=5)
    s = sc.consensus_summary(sc.consensus_scores(tmp_path, "kitimat", obs), issue)
    assert s["1"]["high"] == {"mae": None, "days": 5}
    assert s["1"]["chance"]["brier"] is None and s["1"]["certainty"]["came_true"] is None
    assert s["7"] == {"days": 0}


def test_live_consensus_reaches_the_file():
    s = tt.scores_v2()
    s["live"]["consensus"] = {"1": {"days": 25, "high": {"mae": 1.234, "days": 25},
                                    "low": {"mae": None, "days": 5}, "rain": {"mae": 2.0, "days": 25}}}
    doc = pb.build(tp.PLACE, tp.CFG, s, tt.pulls(), None, tp.NOW)
    tp.validate(doc, tp.strict(tp.SCHEMA))
    c = doc["track_record"]["live"]["consensus"]
    assert c[0] == {"lead": 1, "high": {"miss": 1.23, "days": 25}, "low": {"miss": None, "days": 5},
                    "rain": {"miss": 2.0, "days": 25}}
    assert c[1] == {"lead": 7, "high": {"miss": None, "days": 0}, "low": {"miss": None, "days": 0},
                    "rain": {"miss": None, "days": 0}}


def test_nightly_writes_the_consensus_record(tmp_path, monkeypatch):
    import test_score as ts
    monkeypatch.setattr(sc.hz, "PACE_S", 0)
    r = ts.run(tmp_path)
    assert (tmp_path / "kitimat" / "live_consensus.csv").exists()
    assert r["scores"]["live"]["consensus"]["1"] == {"days": 0}
