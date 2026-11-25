"""refresh.py logic with a fake Open-Meteo (no network)."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from wxc import openmeteo as om  # noqa: E402
from wxc import refresh as rf  # noqa: E402

PLACE = {"id": "kitimat", "lat": 54.05, "lon": -128.63, "elevation_m": 98}
CFG = {
    "deterministic_pool": ["ecmwf_ifs", "gfs_seamless"],
    "meta_paths": {"ecmwf_ifs": ["ecmwf_ifs"], "gfs_seamless": ["ncep_gfs013", "ncep_rrfs_north_america"]},
    "ensembles": {"_note": "x", "ncep_gefs05": {"meta_path": "ncep_gefs05"}},
}
NOW = 1_800_000_000
RUN = NOW - 6 * 3600


class FakeAPI:
    """Serves metadata from a dict and forecasts as {'hourly': ...}."""

    def __init__(self, meta, refuse=()):
        self.meta, self.refuse, self.pulls = meta, set(refuse), []

    def __call__(self, url, tries=8, log=print):
        if "/static/meta.json" in url:
            path = url.split("/data/")[1].split("/")[0]
            if self.meta.get(path) is None:
                raise om.LimitRefused("metadata down")
            return self.meta[path]
        model = url.split("models=")[1].split("&")[0]
        self.pulls.append(model)
        if model in self.refuse:
            log("limit", "try 1/8: Minutely API request limit exceeded")
            raise om.LimitRefused("Minutely API request limit exceeded")
        return {"hourly": {"time": [], "model": model}}


def meta(init, avail):
    return {"last_run_initialisation_time": init, "last_run_availability_time": avail}


def all_meta(init=RUN, avail=NOW - 3600):
    return {p: meta(init, avail) for p in
            ["ecmwf_ifs", "ncep_gfs013", "ncep_rrfs_north_america", "ncep_gefs05"]}


def run(tmp_path, api, now=NOW):
    return rf.refresh(PLACE, CFG, tmp_path, now=now, get=api, echo=lambda *a: None)


def test_first_run_pulls_everything_and_saves_raw(tmp_path):
    api = FakeAPI(all_meta())
    r = run(tmp_path, api)
    assert r["pulled"] == ["ecmwf_ifs", "gfs_seamless", "ncep_gefs05"] and not r["failed"]
    saved = json.loads(next((tmp_path / "kitimat").glob("*/*_ncep_gefs05.json")).read_text())
    assert saved["response"]["hourly"]["model"] == "ncep_gefs05"
    assert saved["credit"] == om.CREDIT and "ensemble-api" in saved["url"]


def test_same_run_is_not_pulled_twice(tmp_path):
    api = FakeAPI(all_meta())
    run(tmp_path, api)
    r = run(tmp_path, api, now=NOW + 3600)
    assert r["new"] == [] and api.pulls == ["ecmwf_ifs", "gfs_seamless", "ncep_gefs05"]


def test_new_run_in_any_seamless_path_triggers_pull(tmp_path):
    api = FakeAPI(all_meta())
    run(tmp_path, api)
    api.meta["ncep_rrfs_north_america"] = meta(RUN + 3600, NOW)
    r = run(tmp_path, api, now=NOW + 3600)
    assert r["pulled"] == ["gfs_seamless"]


def test_waits_10_minutes_after_availability(tmp_path):
    api = FakeAPI(all_meta(avail=NOW - 300))  # posted 5 minutes ago
    assert run(tmp_path, api)["new"] == []
    assert len(run(tmp_path, api, now=NOW + 301)["new"]) == 3


def test_refusal_is_logged_and_retried_next_hour(tmp_path):
    api = FakeAPI(all_meta(), refuse={"ecmwf_ifs"})
    r = run(tmp_path, api)
    assert r["failed"] == ["ecmwf_ifs"]
    log = [json.loads(x) for x in (tmp_path / "refusals.jsonl").read_text().splitlines()]
    assert [x["kind"] for x in log] == ["limit", "gave_up"]
    assert all(x["source"] == "ecmwf_ifs" and x["place"] == "kitimat" for x in log)
    api.refuse.clear()
    assert run(tmp_path, api, now=NOW + 3600)["pulled"] == ["ecmwf_ifs"]


def test_metadata_outage_falls_back_after_6_hours(tmp_path):
    api = FakeAPI(all_meta())
    run(tmp_path, api)
    api.meta["ecmwf_ifs"] = None  # metadata down for this source only
    assert run(tmp_path, api, now=NOW + 5 * 3600)["new"] == []
    assert run(tmp_path, api, now=NOW + 6 * 3600)["new"] == ["ecmwf_ifs"]
    kinds = [json.loads(x)["kind"] for x in (tmp_path / "refusals.jsonl").read_text().splitlines()]
    assert kinds == ["meta", "meta"]


def test_get_json_logs_every_failed_try(monkeypatch):
    calls = []

    def boom(url, timeout):
        raise TimeoutError("timed out")

    monkeypatch.setattr(om.urllib.request, "urlopen", boom)
    try:
        om.get_json("https://example.invalid", tries=3, log=lambda k, d: calls.append(k), sleep=lambda s: None)
    except om.LimitRefused:
        pass
    assert calls == ["network"] * 3


def test_live_calls_use_current_ids_but_store_under_pilot_keys(tmp_path):
    cfg = {**CFG, "docs_ids": {"gfs_seamless": "ncep_gfs_seamless"}}
    api = FakeAPI(all_meta())
    rf.refresh(PLACE, cfg, tmp_path, now=NOW, get=api, echo=lambda *a: None)
    assert api.pulls == ["ecmwf_ifs", "ncep_gfs_seamless", "ncep_gefs05"]
    saved = next((tmp_path / "kitimat").glob("*/*_gfs_seamless.json"))
    rec = json.loads(saved.read_text())
    assert rec["source"] == "gfs_seamless" and rec["api_model"] == "ncep_gfs_seamless"
    state = json.loads((tmp_path / "kitimat" / "state.json").read_text())
    assert "gfs_seamless" in state and "ncep_gfs_seamless" not in state


def test_real_config_maps_the_three_renamed_ids():
    cfg = json.loads((Path(__file__).resolve().parents[1] / "config" / "sources.json").read_text())
    ids = {s.id: s.api_model for s in rf.sources_from_config(cfg)}
    assert ids["gfs_seamless"] == "ncep_gfs_seamless"
    assert ids["gem_seamless"] == "cmc_gem_seamless"
    assert ids["icon_seamless"] == "dwd_icon_seamless"
    assert ids["ecmwf_ifs"] == "ecmwf_ifs"
