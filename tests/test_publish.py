"""publish.py: the public file matches the schema, flags stale data, leaks nothing local."""
import copy
import datetime as dt
import json
import sys
from pathlib import Path

import jsonschema
import numpy as np
import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from wxc import consensus as cs  # noqa: E402
from wxc import publish as pb  # noqa: E402
from wxc.refresh import _write_json  # noqa: E402

SCHEMA = json.loads((ROOT / "docs" / "place-v1.schema.json").read_text())
POOL = ["steady", "middle", "short"]
CFG = {"deterministic_pool": POOL, "labels": {"steady": "Steady model", "middle": "Middle model"}}
PLACE = {"id": "testplace", "name": "Test Place", "lat": 54.05, "lon": -128.63, "elevation_m": 98,
         "timezone": "America/Vancouver", "status": "stage1",
         "truth": {"network": "ECCC", "climate_id": "1064324", "station": "Test Station"}}
NOW = int(dt.datetime(2026, 11, 25, 12, 0, tzinfo=dt.timezone.utc).timestamp())  # climate day 25 Nov
RUN = NOW - 6 * 3600
OFFSET = {"steady": 1.0, "middle": -1.0, "short": 0.0}
DAYS = {"steady": 16, "middle": 16, "short": 5}  # "short" stops early, like Meteo-France


def strict(schema):
    """The contract allows unknown fields; for our own output, forbid them so the
    schema and the file cannot drift apart."""
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


def validate(doc, schema=SCHEMA):
    jsonschema.validate(doc, schema, format_checker=jsonschema.FormatChecker())


def pull(model, fetched=NOW - 3600):
    start = dt.datetime(2026, 11, 25)
    times, temp, pcp = [], [], []
    for k in range(24 * DAYS[model]):
        t = start + dt.timedelta(hours=k)
        times.append(t.strftime("%Y-%m-%dT%H:%M"))
        temp.append(5 + OFFSET[model] + 3 * np.sin(k / 24 * 2 * np.pi))
        pcp.append(0.02 if model != "middle" else 0.0)  # 0.48 mm a day: never wet
    return {"source": model, "kind": "deterministic", "place": PLACE["id"],
            "fetched_at": pb.iso(fetched), "runs": {model: pb.iso(RUN)},
            "url": "https://api.open-meteo.com/v1/forecast?models=" + model,
            "response": {"hourly": {"time": times, "temperature_2m": temp, "precipitation": pcp}}}


def scores():
    leads = {}
    for L in range(1, 15):
        src = {"steady": {"habit_fix": 0.5, "mse": 0.5}, "middle": {"habit_fix": -0.5, "mse": 2.0},
               "short": {"habit_fix": 0.0, "mse": 1.0}, "normal": {"habit_fix": 0.0, "mse": 4.0}}
        leads[str(L)] = {
            "tmax": {"consensus_mae": 1.0 + 0.1 * L, "spread_ref": 0.5, "sources": src},
            "tmin": {"consensus_mae": 1.0, "spread_ref": 0.5, "sources": src},
            "pcp": {"sources": {m: {"mae": 1.0} for m in src}}}
    return {"issue_date": "2026-11-25", "leads": leads}


def make_store(tmp_path, fetched=NOW - 3600, run=RUN):
    store = tmp_path / "store"
    state = {}
    for m in POOL:
        rec = pull(m, fetched)
        rel = f"{PLACE['id']}/2026-11-25/{m}.json"
        _write_json(store / rel, rec)
        state[m] = {"runs": {m: run}, "fetched_unix": fetched, "fetched_at": pb.iso(fetched),
                    "file": rel}
    _write_json(store / PLACE["id"] / "state.json", state)
    _write_json(store / PLACE["id"] / "scores.json", scores())
    return store


def run_publish(tmp_path, **kw):
    store = make_store(tmp_path, **kw)
    out = tmp_path / "public"
    doc = pb.publish(PLACE, CFG, store, out, now=NOW, echo=lambda *a: None)
    return doc, (out / f"{PLACE['id']}.json").read_text()


def normal_table():
    return pd.DataFrame({"tmax": 3.0, "tmin": -2.0, "pcp": 5.0, "wet_share": 0.6, "n": 900},
                        index=range(1, 367))


# --- schema -----------------------------------------------------------------

def test_published_file_matches_the_schema(tmp_path):
    doc, text = run_publish(tmp_path)
    on_disk = json.loads(text)
    assert on_disk == doc
    validate(on_disk)
    validate(on_disk, strict(SCHEMA))  # every field we write is in the schema
    assert [d["day"] for d in doc["days"]] == list(range(1, 15))
    assert doc["days"][0]["date"] == "2026-11-26"
    assert doc["schema_version"] == 1
    assert doc["units"] == {"temperature": "degC", "precipitation": "mm", "chance": "percent"}


def test_file_with_the_normal_matches_the_schema():
    pulls = {m: {"daily": pb._daily_from_pull(pull(m)), "run_unix": RUN, "fetched_unix": NOW - 3600}
             for m in POOL}
    doc = pb.build(PLACE, CFG, scores(), pulls, normal_table(), NOW)
    validate(doc, strict(SCHEMA))
    assert {"id": "normal", "label": pb.NORMAL_LABEL} in doc["sources"]


def test_schema_accepts_a_field_added_later():
    """An older app's schema must not reject a newer file with extra fields."""
    pulls = {m: {"daily": pb._daily_from_pull(pull(m)), "run_unix": RUN, "fetched_unix": NOW}
             for m in POOL}
    doc = pb.build(PLACE, CFG, scores(), pulls, None, NOW)
    doc["wind_kmh"] = 12
    doc["place"]["radar"] = "x"
    doc["days"][0]["gust_kmh"] = 40
    doc["days"][0]["weights"][0]["colour"] = "#fff"
    validate(doc)


def test_file_is_compact_and_small(tmp_path):
    _, text = run_publish(tmp_path)
    assert "\n" not in text and ": " not in text
    assert len(text) < 12_000


def test_place_without_station_is_consensus_only():
    place = {**PLACE, "truth": None}
    pulls = {m: {"daily": pb._daily_from_pull(pull(m)), "run_unix": RUN, "fetched_unix": NOW}
             for m in POOL}
    doc = pb.build(place, CFG, scores(), pulls, None, NOW)
    validate(doc, strict(SCHEMA))
    assert doc["place"]["consensus_only"] is True and doc["place"]["truth_station"] is None


# --- stale ------------------------------------------------------------------

def test_fresh_data_is_not_stale(tmp_path):
    doc, _ = run_publish(tmp_path, fetched=NOW - 5 * 3600)
    assert doc["stale"] is False
    assert doc["fresh_data_at"] == pb.iso(NOW - 5 * 3600)


def test_no_new_pull_for_6_hours_sets_stale(tmp_path):
    doc, text = run_publish(tmp_path, fetched=NOW - 7 * 3600, run=NOW - 12 * 3600)
    assert doc["stale"] is True
    assert json.loads(text)["stale"] is True
    assert doc["newest_run_at"] == pb.iso(NOW - 12 * 3600)
    assert doc["stale_after_hours"] == 6
    validate(doc, strict(SCHEMA))


# --- nothing local ----------------------------------------------------------

def test_no_local_paths_or_call_urls_in_the_file(tmp_path):
    _, text = run_publish(tmp_path)
    for bad in (str(Path.home()), str(tmp_path), "/Users/", "/home/", "data/store", "state.json",
                "api.open-meteo.com", ".json"):
        assert bad not in text, bad
    assert "Weather data by Open-Meteo.com" in text and "CC BY 4.0" in text
    assert "Environment and Climate Change Canada" in text


# --- the numbers ------------------------------------------------------------

def test_high_and_weights_equal_the_tested_blend(tmp_path):
    doc, _ = run_publish(tmp_path)
    d1 = doc["days"][0]
    T = dt.date(2026, 11, 26)
    F = pd.Series({m: pb._daily_from_pull(pull(m)).at[T, "tmax"] for m in POOL})
    st = scores()["leads"]["1"]["tmax"]["sources"]
    hf = pd.Series({m: v["habit_fix"] for m, v in st.items()})
    mse = pd.Series({m: v["mse"] for m, v in st.items()})
    cons, _, w = cs.blend(F, hf, mse)
    assert d1["high"] == round(cons, 1)
    assert {x["id"]: x["weight"] for x in d1["weights"]} == {m: round(v, 3) for m, v in w.items()}
    assert [x["weight"] for x in d1["weights"]] == sorted((x["weight"] for x in d1["weights"]), reverse=True)
    assert d1["tier"] == ("High" if d1["certainty"] >= 75 else "Medium" if d1["certainty"] >= 50 else "Low")


def test_source_whose_run_ends_drops_out_and_weights_resplit(tmp_path):
    doc, _ = run_publish(tmp_path)
    ids = lambda d: {x["id"] for x in d["weights"]}  # noqa: E731
    assert "short" in ids(doc["days"][0])
    assert "short" not in ids(doc["days"][6])
    for d in doc["days"]:
        assert sum(x["weight"] for x in d["weights"]) == pytest.approx(1, abs=0.01)


def test_late_source_gets_no_weight():
    pulls = {m: {"daily": pb._daily_from_pull(pull(m)), "run_unix": RUN, "fetched_unix": NOW}
             for m in POOL}
    pulls["middle"]["run_unix"] = RUN - (pb.LATE_RUN_H + 1) * 3600
    doc = pb.build(PLACE, CFG, scores(), pulls, None, NOW)
    assert all("middle" not in {x["id"] for x in d["weights"]} for d in doc["days"])


def test_normal_joins_from_day_8_and_mixes_into_chance_of_precip():
    pulls = {m: {"daily": pb._daily_from_pull(pull(m)), "run_unix": RUN, "fetched_unix": NOW}
             for m in POOL}
    doc = pb.build(PLACE, CFG, scores(), pulls, normal_table(), NOW)
    has_normal = [any(x["id"] == "normal" for x in d["weights"]) for d in doc["days"]]
    assert has_normal == [False] * 7 + [True] * 7
    # models forecast 0.48 or 0 mm a day: none is wet
    assert doc["days"][6]["precip_chance"] == 0
    assert doc["days"][7]["precip_chance"] == 30  # (0 + 0.6) / 2
    # amount: the normal (5 mm) joins only from day 10
    assert doc["days"][8]["precip_mm"] < 1 < doc["days"][9]["precip_mm"]


def test_missing_scores_is_logged_and_nothing_written(tmp_path):
    store = make_store(tmp_path)
    (store / PLACE["id"] / "scores.json").unlink()
    with pytest.raises(RuntimeError):
        pb.publish(PLACE, CFG, store, tmp_path / "public", now=NOW, echo=lambda *a: None)
    assert not (tmp_path / "public").exists()
    log = (store / "refusals.jsonl").read_text()
    assert "no scores.json" in log


# --- no Certainty without a high (review finding 3, 27 Nov 2026) ---------------

def _pulls():
    return {m: {"daily": pb._daily_from_pull(pull(m)), "run_unix": RUN, "fetched_unix": NOW} for m in POOL}


def test_a_day_with_no_high_has_no_certainty_and_no_tier():
    s = scores()
    s["leads"]["3"]["tmax"]["sources"] = {}  # no source has stats for day 3 highs
    assert s["leads"]["3"]["tmax"]["consensus_mae"] is not None  # before the fix: Certainty from this alone
    doc = pb.build(PLACE, CFG, s, _pulls(), None, NOW)
    d3 = doc["days"][2]
    assert d3["high"] is None and d3["certainty"] is None and d3["tier"] is None
    assert d3["low"] is not None and d3["source_counts"]["high"] == 0
    validate(doc, strict(SCHEMA))
    assert all(d["certainty"] is not None for d in doc["days"] if d["day"] != 3)


def test_no_source_forecasts_the_day_means_no_high_and_no_certainty():
    pulls = _pulls()
    for p in pulls.values():  # every run ends before day 14
        p["daily"] = p["daily"][p["daily"].index < dt.date(2026, 12, 9)]
    doc = pb.build(PLACE, CFG, scores(), pulls, None, NOW)
    d14 = doc["days"][13]
    assert d14["high"] is None and d14["certainty"] is None and d14["tier"] is None
    assert d14["source_counts"] == {"high": 0, "low": 0, "precip": 0}
    validate(doc, strict(SCHEMA))


def test_schema_refuses_certainty_or_tier_without_a_high():
    doc = pb.build(PLACE, CFG, scores(), _pulls(), None, NOW)
    bad = copy.deepcopy(doc)
    bad["days"][0]["high"] = None
    with pytest.raises(jsonschema.ValidationError):
        validate(bad)
    bad["days"][0]["certainty"] = None  # tier still set
    with pytest.raises(jsonschema.ValidationError):
        validate(bad)
    bad["days"][0]["tier"] = None
    validate(bad)


def test_source_counts_match_the_weights_used():
    doc = pb.build(PLACE, CFG, scores(), _pulls(), normal_table(), NOW)
    for d in doc["days"]:
        assert d["source_counts"]["high"] == len(d["weights"])
    assert doc["days"][0]["source_counts"] == {"high": 3, "low": 3, "precip": 3}
    assert doc["days"][7]["source_counts"] == {"high": 3, "low": 3, "precip": 2}  # normal in highs and lows from day 8
    assert doc["days"][9]["source_counts"]["precip"] == 3  # and in the amount from day 10


def test_score_age_is_published(tmp_path):
    store = make_store(tmp_path)
    s = scores()
    s["computed_at"] = "2026-11-25T09:52:10Z"
    _write_json(store / PLACE["id"] / "scores.json", s)
    doc = pb.publish(PLACE, CFG, store, tmp_path / "public", now=NOW, echo=lambda *a: None)
    assert doc["scores_computed_at"] == "2026-11-25T09:52:10Z"
    validate(doc, strict(SCHEMA))
    assert pb.build(PLACE, CFG, scores(), _pulls(), None, NOW)["scores_computed_at"] is None  # older scores.json


def test_shadow_collection_files_do_not_change_the_published_file(tmp_path):
    """Extra hourly variables and the station archive (27 Nov 2026) are saved
    beside the inputs; the place file must be byte for byte the same."""
    _, plain = run_publish(tmp_path / "plain")
    store = make_store(tmp_path / "shadow")
    extra = {"source": "steady", "kind": "extra_hourly", "fetched_at": pb.iso(NOW - 3600),
             "response": {"hourly": {"time": ["2026-11-25T00:00"], "temperature_2m": [99.0],
                                     "wind_gusts_10m": [99.0]}}}
    _write_json(store / PLACE["id"] / "hourly" / "2026-11-25" / "000000Z_steady.json", extra)
    _write_json(store / PLACE["id"] / "swob" / "fields.json", {"const": {}, "sets": [[]]})
    (store / PLACE["id"] / "swob" / "hourly-2026-11.jsonl").write_text(
        '{"c":0,"t":"2026-11-25T00:00:00Z","v":{"air_temp":99.0}}\n')
    out = tmp_path / "shadow" / "public"
    pb.publish(PLACE, CFG, store, out, now=NOW, echo=lambda *a: None)
    assert (out / f"{PLACE['id']}.json").read_text() == plain


def test_every_publish_appends_one_now_log_line(tmp_path):
    """28 Nov 2026: what "now" said and the shadow 6-hour strip, every run."""
    store = make_store(tmp_path)
    for k in range(2):
        pb.publish(PLACE, CFG, store, tmp_path / "public", now=NOW + k * 3600, echo=lambda *a: None)
    lines = [json.loads(x) for x in (store / PLACE["id"] / "now_log.jsonl").read_text().splitlines()]
    assert [x["issued_at"] for x in lines] == [pb.iso(NOW), pb.iso(NOW + 3600)]
    assert all(len(x["strip"]) == 6 and x["now"] is None for x in lines)  # no station in this place
