"""The issue ledger (review finding 1, 27 Nov 2026): what was published at two
fixed issue times a day, append-only, scored nightly like live_consensus."""
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


def at(y, mo, d, h, mi=10) -> int:
    return int(dt.datetime(y, mo, d, h, mi, tzinfo=dt.timezone.utc).timestamp())


@pytest.mark.parametrize("when,slot,start", [
    (at(2026, 11, 27, 13, 10), "morning", "2026-11-27T13:00:00Z"),
    (at(2026, 11, 27, 23, 59), "morning", "2026-11-27T13:00:00Z"),
    (at(2026, 11, 28, 0, 30), "morning", "2026-11-27T13:00:00Z"),  # past midnight, before 01:00
    (at(2026, 11, 28, 1, 0), "evening", "2026-11-28T01:00:00Z"),
    (at(2026, 11, 28, 12, 59), "evening", "2026-11-28T01:00:00Z"),
])
def test_slots(when, slot, start):
    assert pb.ledger_slot(when) == (slot, start)


def test_morning_and_evening_share_an_issue_date():
    # 13:10 UTC is 05:10 PST, 01:10 UTC the next day is 17:10 PST: same climate day.
    assert pb.issue_date_at(at(2026, 11, 27, 13)) == pb.issue_date_at(at(2026, 11, 28, 1))


def publish_at(store, out, now):
    return pb.publish(tp.PLACE, tp.CFG, store, out, now=now, echo=lambda *a: None)


def ledger(store):
    path = store / tp.PLACE["id"] / sc.LEDGER
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []


def test_first_publish_in_each_slot_is_recorded_once_and_never_changed(tmp_path):
    store = tp.make_store(tmp_path)
    out = tmp_path / "public"
    publish_at(store, out, at(2026, 11, 25, 11))          # evening slot of 25 Nov (opened 01:00)
    first = (store / tp.PLACE["id"] / sc.LEDGER).read_bytes()
    publish_at(store, out, at(2026, 11, 25, 12))          # same slot: not recorded
    assert (store / tp.PLACE["id"] / sc.LEDGER).read_bytes() == first
    doc = publish_at(store, out, at(2026, 11, 25, 13))    # morning: recorded
    publish_at(store, out, at(2026, 11, 25, 14))
    publish_at(store, out, at(2026, 11, 26, 1))           # next evening: recorded
    lines = ledger(store)
    assert [(x["slot"], x["slot_start"]) for x in lines] == [
        ("evening", "2026-11-25T01:00:00Z"), ("morning", "2026-11-25T13:00:00Z"),
        ("evening", "2026-11-26T01:00:00Z")]
    assert (store / tp.PLACE["id"] / sc.LEDGER).read_bytes().startswith(first)  # append-only
    morning = lines[1]
    assert morning["issued_at"] == doc["issued_at"] == "2026-11-25T13:10:00Z"
    assert morning["issue_date"] == doc["issue_date"]


def test_line_holds_the_published_values_weights_and_run_times(tmp_path):
    store = tp.make_store(tmp_path)
    doc = publish_at(store, tmp_path / "public", at(2026, 11, 25, 13))
    line = ledger(store)[0]
    assert line["src"] == tp.POOL
    assert line["run"] == [pb.iso(tp.RUN)] * len(tp.POOL)
    assert line["weights_as_of"] == doc["weights_as_of"] and line["stale"] == doc["stale"]
    for d, row in zip(doc["days"], line["days"]):
        assert row[:6] == [d["day"], d["high"], d["low"], d["precip_mm"], d["precip_chance"], d["certainty"]]
        hi = {m: w / 1000 for m, w in zip(line["src"], row[6]) if w is not None}
        assert hi == pytest.approx({x["id"]: x["weight"] for x in d["weights"]}, abs=0.0006)
        assert sum(w for w in row[7] if w is not None) == pytest.approx(1000, abs=3)  # lows
        assert len(row[8]) == len(line["src"])                                       # precip
    assert line["days"][6][6][tp.POOL.index("short")] is None  # its run ended: no weight


def test_normal_and_late_sources_are_named(tmp_path):
    pulls = {m: {"daily": pb._daily_from_pull(tp.pull(m)), "run_unix": tp.RUN, "fetched_unix": tp.NOW}
             for m in tp.POOL}
    pulls["middle"]["run_unix"] = tp.RUN - (pb.LATE_RUN_H + 1) * 3600
    used = {}
    doc = pb.build(tp.PLACE, tp.CFG, tp.scores(), pulls, tp.normal_table(), tp.NOW, used_out=used)
    line = pb.ledger_line(doc, used, pulls, tp.NOW)
    assert line["src"] == tp.POOL + ["normal"]
    assert line["run"][1] == pb.iso(tp.RUN - (pb.LATE_RUN_H + 1) * 3600) and line["run"][3] is None
    assert all(row[6][1] is None for row in line["days"])  # late: never weighted
    assert line["days"][7][6][3] is not None                # the normal from day 8


def test_ledger_is_scored_nightly_by_slot(tmp_path):
    store = tmp_path
    pid = "kitimat"
    days = pd.date_range("2026-09-01", "2026-11-24").date
    obs = pd.DataFrame({"tmax": 5.0, "tmin": 1.0, "pcp": 2.0}, index=pd.Index(days))
    path = store / pid / sc.LEDGER
    path.parent.mkdir(parents=True)
    with path.open("w") as f:
        for d in days[:-1]:
            for slot, high in (("morning", 6.0), ("evening", 5.5)):
                f.write(json.dumps({"slot": slot, "slot_start": f"{d}T13:00:00Z", "issue_date": d.isoformat(),
                                    "issued_at": f"{d}T13:10:00Z", "src": ["a"], "run": [None],
                                    "days": [[1, high, 1.0, 2.0, 100, 80, [1000], [1000], [1000]]]}) + "\n")
    rows = sc.ledger_scores(store, pid, obs)
    assert set(rows["slot"]) == {"morning", "evening"}
    out = {slot: sc.consensus_summary(rows[rows["slot"] == slot], dt.date(2026, 11, 25))
           for slot in sc.LEDGER_SLOTS}
    assert out["morning"]["1"]["high"] == {"mae": 1.0, "days": 60}
    assert out["evening"]["1"]["high"] == {"mae": 0.5, "days": 60}
    assert out["morning"]["1"]["certainty"] == {"said": 0.8, "came_true": 1.0, "days": 60}


def test_compact_size_per_day(tmp_path):
    """Two lines a day; with three sources here (live has about ten) under 2 KB each."""
    store = tp.make_store(tmp_path)
    publish_at(store, tmp_path / "public", at(2026, 11, 25, 13))
    publish_at(store, tmp_path / "public", at(2026, 11, 26, 1))
    text = (store / tp.PLACE["id"] / sc.LEDGER).read_text()
    assert len(text.splitlines()) == 2 and ": " not in text
    assert len(text.encode()) < 4_000
