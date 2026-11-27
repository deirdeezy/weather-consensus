"""Shadow collection (27 Nov 2026): the station's hourly SWOB archive, the
extra hourly variables saved with each model pull, and Open-Meteo pacing.
Nothing here may change the place file or the scores."""
import copy
import datetime as dt
import io
import json
import sys
import threading
import time
import urllib.error
from email.message import Message
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from wxc import openmeteo as om  # noqa: E402
from wxc import refresh as rf  # noqa: E402
from wxc import score as sc  # noqa: E402
from wxc import swob_archive as sa  # noqa: E402

FULL = json.loads((ROOT / "tests" / "fixtures" / "swob-kitimat-hourly-all-fields-2026-11-27T12-17Z.json").read_text())
PLACE = {"id": "kitimat", "lat": 54.0536, "lon": -128.6336, "elevation_m": 98,
         "obs_station": {"network": "ECCC", "climate_id": "1064324", "name": "Kitimat Forest Ave"}}
# 27 Nov 2026 17:20 UTC: the fixture holds the hourly records 12:00 to 17:00 UTC.
NOW = int(dt.datetime(2026, 11, 27, 17, 20, tzinfo=dt.timezone.utc).timestamp())


def feats(hours=None):
    fs = copy.deepcopy(FULL["features"])
    if hours is not None:
        fs = [f for f in fs if int(f["properties"]["date_tm-value"][11:13]) in hours]
    return fs


class SwobAPI:
    """Answers archive queries with the records at or after `datetime=`."""

    def __init__(self, records, refuse=False):
        self.records, self.refuse, self.urls = records, refuse, []

    def __call__(self, url, log=print):
        self.urls.append(url)
        if self.refuse:
            log("limit", "try 1/4: HTTP 429")
            raise RuntimeError("no answer after 4 tries: HTTP 429")
        q = dict(p.split("=", 1) for p in url.split("?", 1)[1].split("&"))
        since = q["datetime"].split("%2F")[0].replace("%3A", ":")
        off, lim = int(q.get("offset", 0)), int(q["limit"])
        rows = [f for f in self.records if f["properties"]["date_tm-value"][:19] >= since[:19]]
        return {"features": rows[off:off + lim]}


def asked_from(url):
    return url.split("datetime=")[1].split("%2F")[0].replace("%3A", ":")


def run_archive(tmp_path, api, now=NOW):
    return sa.archive(PLACE, tmp_path, now=now, get=api, echo=lambda *a: None)


def month_lines(tmp_path, month="2026-11"):
    p = tmp_path / "kitimat" / "swob" / f"hourly-{month}.jsonl"
    return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []


# --- SWOB archive: nothing lost, compact --------------------------------------

def test_saved_record_rebuilds_exactly_what_eccc_sent(tmp_path):
    run_archive(tmp_path, SwobAPI(feats()))
    fields = sa.load_fields(tmp_path, "kitimat")
    lines = month_lines(tmp_path)
    assert len(lines) == 6
    for f, rec in zip(FULL["features"], lines):
        props, geom = sa.expand(rec, fields)
        assert props == f["properties"] and geom == f["geometry"]


def test_every_field_is_kept_including_gusts_rain_sensor_and_snow_depth(tmp_path):
    run_archive(tmp_path, SwobAPI(feats()))
    props, _ = sa.expand(month_lines(tmp_path)[-1], sa.load_fields(tmp_path, "kitimat"))
    for k in ("max_wnd_spd_10m_pst1hr", "rnfl_amt_pst1hr", "pcpn_amt_pst1hr", "avg_snw_dpth_pst5mts",
              "avg_snw_dpth_pst5mts_1", "wetblb_temp", "max_wnd_spd_10m_pst1hr-qa"):
        assert k in props
    assert len(props) == len(FULL["features"][-1]["properties"])


def test_lines_are_compact_units_and_station_names_kept_once(tmp_path):
    run_archive(tmp_path, SwobAPI(feats()))
    raw = len(json.dumps(FULL["features"][0]["properties"], separators=(",", ":")))
    line = (tmp_path / "kitimat" / "swob" / "hourly-2026-11.jsonl").read_text().splitlines()[0]
    assert len(line) < 0.6 * raw
    assert "-uom" not in line and "KITIMAT FOREST AVE" not in line
    const = sa.load_fields(tmp_path, "kitimat")["const"]
    assert const["air_temp-uom"] == "°C" and const["stn_nam-value"] == "KITIMAT FOREST AVE"


def test_a_constant_field_that_changes_is_kept_inline(tmp_path):
    run_archive(tmp_path, SwobAPI(feats({12})))
    later = feats({13})
    later[0]["properties"]["air_temp-uom"] = "K"
    run_archive(tmp_path, SwobAPI(later))
    fields = sa.load_fields(tmp_path, "kitimat")
    rec = month_lines(tmp_path)[1]
    assert rec["v"]["air_temp-uom"] == "K"
    assert sa.expand(rec, fields)[0] == later[0]["properties"]
    assert sa.expand(month_lines(tmp_path)[0], fields)[0]["air_temp-uom"] == "°C"


def test_a_constant_field_first_seen_later_is_not_added_to_older_records(tmp_path):
    early, late = feats({12}), feats({13})
    early[0]["properties"].pop("max_wnd_spd_10m_pst1hr-uom")  # e.g. a gust element that only some hours carry
    run_archive(tmp_path, SwobAPI(early + late))
    fields = sa.load_fields(tmp_path, "kitimat")
    first, second = month_lines(tmp_path)
    assert sa.expand(first, fields)[0] == early[0]["properties"]
    assert sa.expand(second, fields)[0] == late[0]["properties"]
    assert first["c"] != second["c"]


def test_same_answer_twice_changes_nothing(tmp_path):
    run_archive(tmp_path, SwobAPI(feats()))
    path = tmp_path / "kitimat" / "swob" / "hourly-2026-11.jsonl"
    before = path.read_bytes()
    r = run_archive(tmp_path, SwobAPI(feats()), now=NOW + 60)
    assert r["added"] == 0 and r["changed"] == 0 and path.read_bytes() == before


def test_a_record_sent_again_with_new_content_replaces_the_line(tmp_path):
    run_archive(tmp_path, SwobAPI(feats()))
    fixed = feats({17})
    fixed[0]["properties"]["air_temp"] = 99.9
    r = run_archive(tmp_path, SwobAPI(fixed), now=NOW + 60)
    assert r["changed"] == 1 and len(month_lines(tmp_path)) == 6
    assert month_lines(tmp_path)[-1]["v"]["air_temp"] == 99.9


def test_minute_records_other_stations_and_partner_networks_are_not_saved(tmp_path):
    fs = feats()
    fs[0]["properties"]["_is-minutely_obs-value"] = True
    fs[1]["properties"]["clim_id-value"] = "1068134"
    fs[2]["properties"]["data_pvdr-value"] = "NAV CANADA"
    r = run_archive(tmp_path, SwobAPI(fs))
    assert r["received"] == 6 and r["kept"] == 3
    assert [x["t"][11:13] for x in month_lines(tmp_path)] == ["15", "16", "17"]


def test_records_go_to_their_own_month_file(tmp_path):
    fs = feats({12, 13})
    fs[0]["properties"]["date_tm-value"] = "2026-10-31T23:00:00.000Z"
    fs[1]["properties"]["date_tm-value"] = "2026-11-01T00:00:00.000Z"
    run_archive(tmp_path, SwobAPI(fs), now=int(dt.datetime(2026, 11, 1, 0, 20, tzinfo=dt.timezone.utc).timestamp()))
    assert [r["t"] for r in month_lines(tmp_path, "2026-10")] == ["2026-10-31T23:00:00Z"]
    assert [r["t"] for r in month_lines(tmp_path, "2026-11")] == ["2026-11-01T00:00:00Z"]


def test_place_without_station_makes_no_request(tmp_path):
    api = SwobAPI(feats())
    assert sa.archive({"id": "terrace"}, tmp_path, now=NOW, get=api) is None and api.urls == []


# --- SWOB archive: what to ask for, refusals and missing hours -----------------

def test_first_run_asks_back_29_days_for_every_field(tmp_path):
    api = SwobAPI(feats())
    run_archive(tmp_path, api)
    assert asked_from(api.urls[0]) == "2026-10-29T17:00:00Z"
    assert "properties=" not in api.urls[0] and "_is-minutely_obs-value=false" in api.urls[0]


def test_normal_run_asks_for_the_last_3_hours(tmp_path):
    run_archive(tmp_path, SwobAPI(feats()))
    api = SwobAPI(feats())
    run_archive(tmp_path, api, now=NOW + 3600)
    assert asked_from(api.urls[0]) == "2026-11-27T15:00:00Z"


def test_a_refused_request_is_logged_and_the_archive_is_untouched(tmp_path):
    run_archive(tmp_path, SwobAPI(feats({12, 13, 14})))
    path = tmp_path / "kitimat" / "swob" / "hourly-2026-11.jsonl"
    before = path.read_bytes()
    assert run_archive(tmp_path, SwobAPI([], refuse=True)) is None
    assert path.read_bytes() == before
    refusals = [json.loads(x) for x in (tmp_path / "refusals.jsonl").read_text().splitlines()]
    assert {(r["source"], r["kind"]) for r in refusals} >= {("eccc_swob_archive", "gave_up"),
                                                             ("eccc_swob_archive", "limit")}


def test_hours_missed_by_a_refused_run_are_fetched_on_a_later_run(tmp_path):
    run_archive(tmp_path, SwobAPI(feats({12, 13})), now=NOW - 4 * 3600)  # 13:20, saw 12 and 13
    run_archive(tmp_path, SwobAPI([], refuse=True), now=NOW - 3600)       # 16:20 refused
    api = SwobAPI(feats())
    run_archive(tmp_path, api, now=NOW + 2 * 3600)                        # 19:20
    assert asked_from(api.urls[0]) == "2026-11-27T14:00:00Z"              # not just the last 3 h
    assert [r["t"][11:13] for r in month_lines(tmp_path)] == ["12", "13", "14", "15", "16", "17"]


def test_a_missing_hour_inside_the_last_48_hours_is_asked_for_again(tmp_path):
    run_archive(tmp_path, SwobAPI(feats({12, 13, 15, 16, 17})))  # 14:00 not posted yet
    api = SwobAPI(feats())                                         # now it is
    r = run_archive(tmp_path, api, now=NOW + 3600)
    assert asked_from(api.urls[0]) == "2026-11-27T14:00:00Z" and r["added"] == 1
    assert len(month_lines(tmp_path)) == 6


def test_a_missing_hour_older_than_48_hours_is_left_as_a_gap(tmp_path):
    run_archive(tmp_path, SwobAPI(feats({12, 13, 15, 16, 17})))
    api = SwobAPI(feats())
    run_archive(tmp_path, api, now=NOW + 50 * 3600)
    # after a 2-day outage: from the newest saved record + 1 h; the 14:00 gap is not asked for again
    assert asked_from(api.urls[0]) == "2026-11-27T18:00:00Z"


def test_an_answer_longer_than_one_page_is_read_page_by_page(tmp_path, monkeypatch):
    monkeypatch.setattr(sa, "PAGE", 4)
    api = SwobAPI(feats())
    r = run_archive(tmp_path, api)
    assert len(api.urls) == 2 and "offset=4" in api.urls[1] and r["received"] == 6


def test_empty_answer_is_logged_and_nothing_saved(tmp_path):
    r = run_archive(tmp_path, SwobAPI([]))
    assert r["kept"] == 0 and not (tmp_path / "kitimat" / "swob").exists()
    assert "eccc_swob_archive" in (tmp_path / "refusals.jsonl").read_text()


# --- extra hourly variables with each deterministic pull -------------------------

CFG = {"deterministic_pool": ["ecmwf_ifs", "gfs_seamless"],
       "meta_paths": {"ecmwf_ifs": ["ecmwf_ifs"], "gfs_seamless": ["ncep_gfs013", "ncep_rrfs_north_america"]},
       "docs_ids": {"gfs_seamless": "ncep_gfs_seamless"},
       "ensembles": {"ncep_gefs05": {"meta_path": "ncep_gefs05"}}}
T0 = 1_800_000_000
RUN = T0 - T0 % 3600 - 6 * 3600


class ModelAPI:
    def __init__(self, refuse_extra=()):
        self.calls, self.refuse_extra = [], set(refuse_extra)

    def __call__(self, url, tries=8, log=print):
        if "/static/meta.json" in url:
            return {"last_run_initialisation_time": RUN, "last_run_availability_time": T0 - 3600}
        model = url.split("models=")[1].split("&")[0]
        extra = "start_hour=" in url
        self.calls.append((model, extra, url))
        if extra and model in self.refuse_extra:
            log("limit", "try 1/8: Too many concurrent requests")
            raise om.LimitRefused("Too many concurrent requests", limit=True)
        hourly = {"time": ["2027-01-15T02:00"], "temperature_2m": [1.0], "precipitation": [0.0]}
        if extra:
            hourly = {"time": ["2027-01-15T02:00"], **{v: [1] for v in om.EXTRA_VARIABLES}}
        return {"hourly": hourly}


def refresh(tmp_path, api):
    return rf.refresh({k: PLACE[k] for k in ("id", "lat", "lon", "elevation_m")}, CFG, tmp_path,
                      now=T0, get=api, echo=lambda *a: None)


def test_each_deterministic_pull_saves_the_extra_variables_for_lead_0_to_144(tmp_path):
    api = ModelAPI()
    r = refresh(tmp_path, api)
    extra = [(m, u) for m, e, u in api.calls if e]
    assert [m for m, _ in extra] == ["ecmwf_ifs", "ncep_gfs_seamless"]  # no ensemble
    assert r["extra"] == ["ecmwf_ifs", "gfs_seamless"] and r["extra_failed"] == []
    url = extra[0][1]
    start = dt.datetime.fromtimestamp(RUN, dt.timezone.utc)
    end = start + dt.timedelta(hours=144)
    assert f"start_hour={start:%Y-%m-%dT%H}%3A00" in url and f"end_hour={end:%Y-%m-%dT%H}%3A00" in url
    assert "hourly=" + "%2C".join(om.EXTRA_VARIABLES) in url and "forecast_days" not in url
    saved = json.loads(next((tmp_path / "kitimat" / "hourly").glob("*/*_gfs_seamless.json")).read_text())
    assert saved["kind"] == "extra_hourly" and saved["source"] == "gfs_seamless"
    assert saved["api_model"] == "ncep_gfs_seamless" and saved["run"] == rf.iso(RUN)
    assert set(om.EXTRA_VARIABLES) <= set(saved["response"]["hourly"])


def test_extra_variables_cost_about_one_call_each():
    assert len(om.EXTRA_VARIABLES) == 11  # 1.1 weighted calls over 145 hours (measured 1.2 for 12)
    for v in ("wind_speed_10m", "wind_direction_10m", "wind_gusts_10m", "cloud_cover",
              "cloud_cover_low", "cloud_cover_mid", "cloud_cover_high", "weather_code",
              "snowfall", "relative_humidity_2m", "visibility"):
        assert v in om.EXTRA_VARIABLES


def test_extra_files_sit_outside_the_folders_scoring_reads(tmp_path):
    refresh(tmp_path, ModelAPI())
    main = sorted(p.relative_to(tmp_path / "kitimat").as_posix()
                  for p in (tmp_path / "kitimat").glob("????-??-??/*.json"))
    assert len(main) == 3 and all("extra" not in json.loads((tmp_path / "kitimat" / m).read_text())["kind"]
                                  for m in main)
    assert len(list((tmp_path / "kitimat" / "hourly").glob("*/*.json"))) == 2


def test_a_refused_extra_call_is_logged_and_the_main_pull_still_counts(tmp_path):
    r = refresh(tmp_path, ModelAPI(refuse_extra={"ecmwf_ifs"}))
    assert r["pulled"] == ["ecmwf_ifs", "gfs_seamless", "ncep_gefs05"] and r["failed"] == []
    assert r["extra_failed"] == ["ecmwf_ifs"] and r["extra"] == ["gfs_seamless"]
    state = json.loads((tmp_path / "kitimat" / "state.json").read_text())
    assert state["ecmwf_ifs"]["runs"] == {"ecmwf_ifs": RUN}
    lines = [json.loads(x) for x in (tmp_path / "refusals.jsonl").read_text().splitlines()]
    assert {(x["source"], x["kind"]) for x in lines} == {("ecmwf_ifs", "extra")}


def test_extra_pulls_do_not_change_what_scoring_reads(tmp_path):
    import pandas as pd
    refresh(tmp_path, ModelAPI())
    obs = pd.DataFrame({"tmax": [2.0], "tmin": [0.0], "pcp": [0.0]},
                       index=[dt.date(2027, 1, 15)])
    with_extra = sc.live_scores(tmp_path, "kitimat", obs)
    import shutil
    shutil.rmtree(tmp_path / "kitimat" / "hourly")
    assert with_extra.equals(sc.live_scores(tmp_path, "kitimat", obs))


def test_extra_window_starts_on_the_whole_run_hour():
    run = int(dt.datetime(2026, 11, 27, 6, 0, tzinfo=dt.timezone.utc).timestamp())
    assert om.extra_window(run) == ("2026-11-27T06:00", "2026-12-03T06:00")
    assert om.extra_window(run + 1799) == ("2026-11-27T06:00", "2026-12-03T06:00")


# --- pacing -------------------------------------------------------------------

class Answer(io.BytesIO):
    def __init__(self, body):
        super().__init__(json.dumps(body).encode())
        self.headers = Message()

    def __enter__(self):
        return self


@pytest.fixture
def fake_clock(monkeypatch):
    t = [1000.0]
    waits = []

    def pause(s):
        waits.append(round(s, 3))
        t[0] += s
    monkeypatch.setattr(om, "clock", lambda: t[0])
    monkeypatch.setattr(om, "pause", pause)
    monkeypatch.setattr(om, "_last_start", [float("-inf")])
    monkeypatch.setattr(om, "echo", lambda *a: None)
    return waits


def test_counted_calls_start_at_least_min_gap_apart(monkeypatch, fake_clock):
    monkeypatch.setattr(om.urllib.request, "urlopen", lambda url, timeout: Answer({"hourly": {}}))
    for _ in range(3):
        om.get_json("https://api.open-meteo.com/v1/forecast?models=x", sleep=lambda s: None)
    assert fake_clock == [om.MIN_GAP_S, om.MIN_GAP_S]


def test_metadata_files_are_not_paced(monkeypatch, fake_clock):
    monkeypatch.setattr(om.urllib.request, "urlopen", lambda url, timeout: Answer({"a": 1}))
    for _ in range(3):
        om.get_json(om.meta_url("ecmwf_ifs"), sleep=lambda s: None)
    assert fake_clock == []


def test_never_more_than_max_in_flight_calls_at_once(monkeypatch):
    monkeypatch.setattr(om, "MIN_GAP_S", 0.0)
    monkeypatch.setattr(om, "echo", lambda *a: None)
    lock, now, peak = threading.Lock(), [0], [0]

    def slow(url, timeout):
        with lock:
            now[0] += 1
            peak[0] = max(peak[0], now[0])
        time.sleep(0.05)
        with lock:
            now[0] -= 1
        return Answer({"hourly": {}})
    monkeypatch.setattr(om.urllib.request, "urlopen", slow)
    threads = [threading.Thread(target=om.get_json, args=("https://api.open-meteo.com/v1/forecast?models=x",))
               for _ in range(8)]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    assert peak[0] == om.MAX_IN_FLIGHT <= 2


def concurrent_refusal(url):
    h = Message()
    return urllib.error.HTTPError(url, 429, "Too Many Requests", h,
                                  io.BytesIO(json.dumps({"error": True, "reason": "Too many concurrent requests"}).encode()))


def test_too_many_concurrent_requests_is_retried(monkeypatch, fake_clock):
    answers = [concurrent_refusal, concurrent_refusal, None]

    def urlopen(url, timeout):
        a = answers.pop(0)
        if a:
            raise a(url)
        return Answer({"hourly": {"time": []}})
    monkeypatch.setattr(om.urllib.request, "urlopen", urlopen)
    logged, slept = [], []
    got = om.get_json("https://api.open-meteo.com/v1/forecast?models=x",
                      log=lambda k, d: logged.append((k, d)), sleep=slept.append)
    assert got == {"hourly": {"time": []}} and [k for k, _ in logged] == ["limit", "limit"]
    assert len(slept) == 2


def test_concurrent_refusal_that_never_clears_counts_as_a_limit_refusal(monkeypatch, fake_clock):
    monkeypatch.setattr(om.urllib.request, "urlopen", lambda url, timeout: (_ for _ in ()).throw(concurrent_refusal(url)))
    with pytest.raises(om.LimitRefused) as e:
        om.get_json("https://api.open-meteo.com/v1/forecast?models=x", tries=3,
                    log=lambda k, d: None, sleep=lambda s: None)
    assert om.is_limit(e.value)
