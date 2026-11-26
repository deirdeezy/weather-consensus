"""Nightly runs refused by Open-Meteo for a rate limit (no network).

Covers the 25 Nov 2026 case: the 19:37 UTC nightly got "Daily API request
limit exceeded" for every Open-Meteo call, scored with saved copies, and the
23:49 UTC nightly skipped as "already scored". Now scores.json lists the stale
downloads, a later nightly rescores, the workflow's retry job is started by
om_refused, and only rate-limit losses fail the run; Single Runs Open-Meteo
does not have are expected gaps.
"""
import datetime as dt
import io
import json
import sys
import urllib.error
from email.message import Message
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
sys.path.insert(0, str(ROOT / "backend" / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

from wxc import horizon as hz  # noqa: E402
from wxc import openmeteo as om  # noqa: E402
from wxc import score as sc  # noqa: E402
import missing  # noqa: E402
from test_score import ISSUE, fake_get, obs_payload, run  # noqa: E402,F401  (no_pacing fixture below)

DAILY = "Daily API request limit exceeded. Please try again tomorrow."
GONE = "open-meteo error: The requested model run is not available."


@pytest.fixture(autouse=True)
def no_pacing(monkeypatch):
    monkeypatch.setattr(sc.hz, "PACE_S", 0)


def refused_by_open_meteo(monkeypatch, reason=DAILY):
    """get_json as on the 25 Nov 19:37 runner: every call answers HTTP 429."""
    calls = []

    def urlopen(url, timeout):
        calls.append(url)
        h = Message()
        h["Retry-After"] = "15000"
        h["X-RateLimit-Cost"] = "1.0"
        h["X-RateLimit-Remaining"] = "0.0"
        h["X-RateLimit-Limit"] = "10000.0"
        h["X-RateLimit-Window"] = "86400"
        raise urllib.error.HTTPError(url, 429, "Too Many Requests", h,
                                     io.BytesIO(json.dumps({"error": True, "reason": reason}).encode()))

    monkeypatch.setattr(om.urllib.request, "urlopen", urlopen)
    monkeypatch.setattr(om, "echo", lambda *a: None)

    def get(url, tries=8, log=print):
        return om.get_json(url, tries=tries, log=log, sleep=lambda s: None)
    return get, calls


def scores(tmp_path):
    return json.loads((tmp_path / "kitimat" / "scores.json").read_text())


def drop_saved_single_runs(tmp_path, day):
    for f in (tmp_path / "kitimat" / "single").glob(f"*/{day.isoformat()}.json"):
        f.unlink()


# --- already_scored with fresh and stale downloads ---------------------------

def test_fresh_downloads_count_as_scored(tmp_path):
    run(tmp_path)
    assert scores(tmp_path)["downloads_stale"] == []
    assert sc.already_scored(tmp_path, "kitimat", ISSUE)
    assert sc.limit_losses(tmp_path, "kitimat", ISSUE) == []


def test_stale_downloads_mean_not_scored(tmp_path, monkeypatch):
    run(tmp_path)  # saved copies exist, as from the 04:07 run
    get, _ = refused_by_open_meteo(monkeypatch)
    run(tmp_path, get=get)
    s = scores(tmp_path)
    prev = [x for x in s["downloads_stale"] if x["download"] == "previous_runs"]
    assert sorted(x["source"] for x in prev) == ["middle", "steady", "wild"]
    assert all(x["why"] == "limit" and x["used"].startswith("saved copy from") for x in prev)
    assert s["obs_through"] == "2026-11-24"  # station data was in: the old check said "scored"
    assert not sc.already_scored(tmp_path, "kitimat", ISSUE)


def test_scores_json_from_before_the_field_still_counts_as_scored(tmp_path):
    run(tmp_path)
    p = tmp_path / "kitimat" / "scores.json"
    s = json.loads(p.read_text())
    del s["downloads_stale"]
    p.write_text(json.dumps(s))
    assert sc.already_scored(tmp_path, "kitimat", ISSUE)


def test_network_failure_is_stale_but_not_a_limit_loss(tmp_path):
    run(tmp_path)

    def down(url, tries=8, log=print):
        raise om.LimitRefused("timed out", limit=False)
    run(tmp_path, get=down)
    assert {x["why"] for x in scores(tmp_path)["downloads_stale"]} == {"error"}
    assert not sc.already_scored(tmp_path, "kitimat", ISSUE)  # a later nightly retries
    assert sc.limit_losses(tmp_path, "kitimat", ISSUE) == []  # but it does not fail the run


# --- replay of 25 Nov 2026 ----------------------------------------------------

def test_replay_25_nov_the_2349_run_now_rescores(tmp_path, monkeypatch):
    # 04:07 UTC: scored with every download fresh (saved copies made).
    run(tmp_path)
    yesterday = ISSUE - dt.timedelta(days=1)
    drop_saved_single_runs(tmp_path, yesterday)  # 24 Nov's runs were not fetched yet
    # 19:37 UTC: Open-Meteo refuses every call for the daily limit.
    get, calls = refused_by_open_meteo(monkeypatch)
    run(tmp_path, get=get)
    assert len(calls) == 6  # 3 Previous Runs + 3 Single Runs, one try each (no retries)
    s = scores(tmp_path)
    single = [x for x in s["downloads_stale"] if x["download"] == "single_run"]
    assert {(x["source"], x["day"], x["why"]) for x in single} == \
        {(m, yesterday.isoformat(), "limit") for m in ("steady", "middle", "wild")}
    assert len(sc.limit_losses(tmp_path, "kitimat", ISSUE)) == 6
    # 23:49 UTC, --if-needed: before this change already_scored was True here.
    assert not sc.already_scored(tmp_path, "kitimat", ISSUE)
    monkeypatch.undo()
    monkeypatch.setattr(sc.hz, "PACE_S", 0)
    run(tmp_path)  # a fresh address: everything comes back
    assert scores(tmp_path)["downloads_stale"] == []
    assert all((tmp_path / "kitimat" / "single" / m / f"{yesterday}.json").exists()
               for m in ("steady", "middle", "wild"))
    assert sc.already_scored(tmp_path, "kitimat", ISSUE)  # the 15:52 run can skip


# --- expected Single Runs gaps --------------------------------------------------

def test_single_runs_open_meteo_does_not_have_are_not_stale(tmp_path):
    run(tmp_path)
    yesterday = ISSUE - dt.timedelta(days=1)
    drop_saved_single_runs(tmp_path, yesterday)

    def gaps(url, tries=8, log=print):
        if "single-runs" in url:
            raise RuntimeError(GONE)
        return fake_get(url)
    run(tmp_path, get=gaps)
    assert scores(tmp_path)["downloads_stale"] == []
    assert sc.already_scored(tmp_path, "kitimat", ISSUE)
    lines = [json.loads(x) for x in (tmp_path / "refusals.jsonl").read_text().splitlines()]
    assert {x["kind"] for x in lines} == {"single_run"}  # still logged, as before
    assert missing.main(["--store", str(tmp_path), "--issue", ISSUE.isoformat(), "--fail-on-limit"]) == 0


def test_single_run_limit_refusal_is_lost_not_marked_gone(tmp_path, monkeypatch):
    monkeypatch.setattr(hz, "utc_today", lambda: dt.date(2026, 11, 25))
    place = {"id": "kitimat", "lat": 54, "lon": -128, "elevation_m": 98}
    old = dt.date(2026, 11, 10)

    def get(url, log=None):
        raise om.LimitRefused(DAILY, limit=True)
    got = hz.fetch_single_runs(place, ["a"], [old], tmp_path, get=get, sleep=lambda s: None,
                               echo=lambda *a: None)
    assert got["lost"] == [{"source": "a", "day": "2026-11-10", "why": "limit"}]
    assert not (tmp_path / "kitimat" / "single" / "a" / "2026-11-10.missing").exists()


def test_gone_rule_counts_days_in_utc(tmp_path, monkeypatch):
    place = {"id": "kitimat", "lat": 54, "lon": -128, "elevation_m": 98}
    day = dt.date(2026, 11, 22)

    def get(url, log=None):
        raise RuntimeError(GONE)
    marker = tmp_path / "kitimat" / "single" / "a" / "2026-11-22.missing"
    monkeypatch.setattr(hz, "utc_today", lambda: dt.date(2026, 11, 24))  # 2 days: may still come
    hz.fetch_single_runs(place, ["a"], [day], tmp_path, get=get, sleep=lambda s: None, echo=lambda *a: None)
    assert not marker.exists()
    monkeypatch.setattr(hz, "utc_today", lambda: dt.date(2026, 11, 25))  # 3 days: not coming
    got = hz.fetch_single_runs(place, ["a"], [day], tmp_path, get=get, sleep=lambda s: None,
                               echo=lambda *a: None)
    assert marker.exists() and got["lost"] == []


def test_utc_today_is_utc(monkeypatch):
    class Clock(dt.datetime):
        @classmethod
        def now(cls, tz=None):
            # 26 Nov 03:30 UTC is still 25 Nov in Kitimat (PST, UTC-8)
            return dt.datetime(2026, 11, 26, 3, 30, tzinfo=dt.timezone.utc).astimezone(tz)
    monkeypatch.setattr(hz.dt, "datetime", Clock)
    assert hz.utc_today() == dt.date(2026, 11, 26)


# --- om_refused and failing the run (backend/scripts/missing.py) ------------

def test_om_refused_output_and_fail_on_limit(tmp_path, monkeypatch, capsys):
    out = tmp_path / "github_output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    store = tmp_path / "store"
    args = ["--store", str(store), "--issue", ISSUE.isoformat()]

    run(store)
    assert missing.main(args + ["--fail-on-limit"]) == 0
    assert out.read_text() == "om_refused=false\n"

    get, _ = refused_by_open_meteo(monkeypatch)
    run(store, get=get)
    out.write_text("")
    assert missing.main(args) == 0  # the first job reports, it does not fail
    assert out.read_text() == "om_refused=true\n"
    assert missing.main(args + ["--fail-on-limit"]) == 1  # the retry job fails the run
    assert "::error::" in capsys.readouterr().out


def test_om_refused_ignores_scores_from_another_day(tmp_path, monkeypatch):
    out = tmp_path / "github_output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    run(tmp_path)
    get, _ = refused_by_open_meteo(monkeypatch)
    run(tmp_path, get=get)
    tomorrow = (ISSUE + dt.timedelta(days=1)).isoformat()
    assert missing.main(["--store", str(tmp_path), "--issue", tomorrow, "--fail-on-limit"]) == 0
    assert out.read_text() == "om_refused=false\n"


# --- usage headers --------------------------------------------------------------

class Answer(io.BytesIO):
    def __init__(self, body, headers):
        super().__init__(json.dumps(body).encode())
        self.headers = headers

    def __enter__(self):
        return self


def test_usage_headers_are_printed_without_the_query(monkeypatch):
    h = Message()
    for k, v in (("X-RateLimit-Cost", "20.0"), ("X-RateLimit-Remaining", "580.0"),
                 ("X-RateLimit-Limit", "600.0"), ("X-RateLimit-Window", "60")):
        h[k] = v
    monkeypatch.setattr(om.urllib.request, "urlopen", lambda url, timeout: Answer({"hourly": {}}, h))
    printed = []
    monkeypatch.setattr(om, "echo", printed.append)
    monkeypatch.setattr(om, "usage", [])
    url = ("https://previous-runs-api.open-meteo.com/v1/forecast?latitude=54.05&longitude=-128.63"
           "&models=ecmwf_ifs&apikey=SECRET123&hourly=temperature_2m")
    assert om.get_json(url) == {"hourly": {}}
    assert printed == ["  open-meteo  cost 20.0  remaining 580.0 of 600.0 per 60 s  "
                       "previous-runs-api.open-meteo.com/v1/forecast ecmwf_ifs"]
    assert "SECRET123" not in om.usage_summary() and "latitude" not in printed[0]
    assert om.usage_summary() == ("Open-Meteo: 1 counted calls, weighted cost 20.0, "
                                  "lowest remaining 580.0 of 600.0 per 60 s")


def test_free_metadata_calls_print_nothing(monkeypatch):
    monkeypatch.setattr(om.urllib.request, "urlopen", lambda url, timeout: Answer({"x": 1}, Message()))
    printed = []
    monkeypatch.setattr(om, "echo", printed.append)
    monkeypatch.setattr(om, "usage", [])
    om.get_json(om.meta_url("ecmwf_ifs"))
    assert printed == [] and om.usage_summary() == "Open-Meteo: no counted calls"


def test_refusals_print_usage_and_say_limit(monkeypatch):
    printed = []
    get, _ = refused_by_open_meteo(monkeypatch)
    monkeypatch.setattr(om, "echo", printed.append)
    with pytest.raises(om.LimitRefused) as e:
        get("https://api.open-meteo.com/v1/forecast?models=gfs_seamless")
    assert e.value.limit and om.is_limit(e.value)
    assert printed == ["  open-meteo  cost 1.0  remaining 0.0 of 10000.0 per 86400 s  "
                       "api.open-meteo.com/v1/forecast gfs_seamless"]


def test_network_failures_are_not_limit_refusals(monkeypatch):
    def boom(url, timeout):
        raise TimeoutError("timed out")
    monkeypatch.setattr(om.urllib.request, "urlopen", boom)
    with pytest.raises(om.LimitRefused) as e:
        om.get_json("https://api.open-meteo.com/v1/forecast", tries=2, log=lambda k, d: None,
                    sleep=lambda s: None)
    assert not e.value.limit and not om.is_limit(e.value)


def test_refusal_lines_name_the_runner(tmp_path, monkeypatch):
    from wxc import refresh as rf
    monkeypatch.setenv("WXC_RUNNER", "AWS us-east-1 (runner setup record)")
    rf.refusal_logger(tmp_path, "kitimat", echo=lambda *a: None)("ecmwf_ifs", "limit", DAILY)
    line = json.loads((tmp_path / "refusals.jsonl").read_text())
    assert line["runner"] == "AWS us-east-1 (runner setup record)"
