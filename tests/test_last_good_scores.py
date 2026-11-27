"""Review finding 2 (27 Nov 2026): new nightly scores are a candidate.

Before: an empty download cache (the Actions cache holds the Previous Runs
copies) plus refused downloads made score() write a scores.json with only
leads 8 to 14 over good scores; score.py then crashed on the day 1 line;
nightly.sh still published and saved; the next hourly publish showed all
seven near-term highs missing with stale=false.

Now the candidate replaces scores.json only if days 1 to 7 have usable highs
and lows; otherwise the last good scores stay, the reasons are recorded, the
run fails, and the hourly publish keeps the near-term highs and says when the
scores in use were computed. No network: fake downloads from test_score.
"""
import datetime as dt
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
sys.path.insert(0, str(ROOT / "backend" / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

from wxc import openmeteo as om  # noqa: E402
from wxc import publish as pb  # noqa: E402
from wxc import score as sc  # noqa: E402
from wxc.refresh import _write_json  # noqa: E402
import missing  # noqa: E402
import score as score_script  # noqa: E402
import test_score as ts  # noqa: E402

D1 = ts.ISSUE                         # 25 Nov 2026: a healthy night
D2 = ts.ISSUE + dt.timedelta(days=1)  # 26 Nov 2026: the cache is gone
PLACE = {**ts.PLACE, "name": "Kitimat", "truth": {"network": "ECCC", "climate_id": "1064324",
                                                   "station": "Kitimat Forest Ave"}}
POOL = ts.CFG["deterministic_pool"]
CFG = {"deterministic_pool": POOL, "labels": {}}
DAILY = "Daily API request limit exceeded. Please try again tomorrow."


def at(day: dt.date, hour: int, minute: int = 0) -> int:
    return int(dt.datetime(day.year, day.month, day.day, hour, minute, tzinfo=dt.timezone.utc).timestamp())


def truth(d: dt.date) -> float:
    return 5 + 6 * np.sin((d - ts.START).days / 20)


def single_run_payload(url: str) -> dict:
    """A 16-day 00 UTC run with each model's habit, so days 8 to 14 get stats."""
    model = url.split("models=")[1].split("&")[0]
    run = dt.date.fromisoformat(url.split("run=")[1][:10])
    rng = np.random.default_rng(run.toordinal() + len(model))
    times, temp = [], []
    for k in range(24 * 16):
        t = dt.datetime.combine(run, dt.time(0)) + dt.timedelta(hours=k)
        d = (t - dt.timedelta(hours=6)).date()
        times.append(t.strftime("%Y-%m-%dT%H:%M"))
        temp.append(truth(d) + ts.HABIT[model] + rng.normal(0, ts.NOISE[model]) - 0.2 * ((k - 6) % 24))
    return {"hourly": {"time": times, "temperature_2m": temp, "precipitation": [0.1] * len(times)}}


def good_get(url, tries=8, log=print):
    return single_run_payload(url) if "single-runs" in url else ts.prev_payload(url.split("models=")[1].split("&")[0])


def refusing(models=None, single_too=True):
    """Downloads from a refused address: the named Previous Runs (all if None),
    and every Single Run if single_too, refused for the daily limit."""
    def get(url, tries=8, log=print):
        model = url.split("models=")[1].split("&")[0]
        single = "single-runs" in url
        if (single and single_too) or (not single and (models is None or model in models)):
            raise om.LimitRefused(DAILY, limit=True)
        return good_get(url)
    return get


@pytest.fixture(autouse=True)
def quiet(monkeypatch):
    monkeypatch.setattr(sc.hz, "PACE_S", 0)
    monkeypatch.setattr(om, "echo", lambda *a: None)
    monkeypatch.setattr(sc.hz, "utc_today", lambda: D2)


def nightly(store, issue, now, get=good_get):
    return sc.score(PLACE, CFG, store, issue=issue, get=get, fetch_obs=ts.obs_payload,
                    fetch_normal=lambda cid: [], echo=lambda *a: None, now=now)


def empty_the_cache(store):
    """A new runner whose Actions cache was evicted: no saved Previous Runs."""
    for f in (store / "kitimat" / "history").glob("prev_*.json"):
        f.unlink()


def add_pulls(store, now):
    """The hourly refresh's newest saved run of each source (16 days)."""
    state = {}
    run = now - 6 * 3600
    for i, m in enumerate(POOL):
        start = dt.datetime.fromtimestamp(now, dt.timezone.utc).replace(hour=0, minute=0, tzinfo=None)
        times = [(start + dt.timedelta(hours=k)).strftime("%Y-%m-%dT%H:%M") for k in range(24 * 16)]
        temp = [5 + i + 3 * np.sin(k / 24 * 2 * np.pi) for k in range(len(times))]
        rec = {"source": m, "kind": "deterministic", "place": "kitimat", "fetched_at": pb.iso(now - 600),
               "runs": {m: pb.iso(run)}, "response": {"hourly": {"time": times, "temperature_2m": temp,
                                                                  "precipitation": [0.1] * len(times)}}}
        rel = f"kitimat/{pb.iso(now)[:10]}/{m}.json"
        _write_json(store / rel, rec)
        state[m] = {"runs": {m: run}, "fetched_unix": now - 600, "fetched_at": pb.iso(now - 600), "file": rel}
    _write_json(store / "kitimat" / "state.json", state)


def hourly(store, tmp_path, now):
    add_pulls(store, now)
    return pb.publish(PLACE, CFG, store, tmp_path / "public", now=now, echo=lambda *a: None)


def scores_json(store):
    return json.loads((store / "kitimat" / "scores.json").read_text())


def near_term_highs(doc):
    return [d["high"] for d in doc["days"] if d["day"] <= 7]


# --- the gate ----------------------------------------------------------------

def test_a_healthy_candidate_is_usable(tmp_path):
    s = nightly(tmp_path, D1, at(D1, 9, 52))["scores"]
    assert sc.why_unusable(s) == []
    assert {str(L) for L in range(8, 15)} <= set(s["leads"])  # Single Runs gave days 8 to 14


def test_only_days_8_to_14_is_not_usable(tmp_path):
    s = nightly(tmp_path, D1, at(D1, 9, 52))["scores"]
    for L in range(1, 8):
        del s["leads"][str(L)]
    assert sc.why_unusable(s) == ["days 1 to 7: no stats"]


def test_a_lead_without_any_habit_fix_or_without_a_consensus_miss_is_not_usable(tmp_path):
    s = nightly(tmp_path, D1, at(D1, 9, 52))["scores"]
    for st in s["leads"]["3"]["tmin"]["sources"].values():
        st["habit_fix"] = None
    s["leads"]["5"]["tmax"]["consensus_mae"] = None
    assert sc.why_unusable(s) == ["day 3: tmin: no source with a habit fix and an error",
                                  "day 5: tmax: no recent consensus miss"]


# --- the replay: healthy, empty cache, partial refusal, total refusal, recovery --

def test_replay_keeps_the_last_good_scores_and_the_hourly_keeps_its_highs(tmp_path):
    store = tmp_path / "store"

    # 25 Nov 09:52 UTC: healthy.
    nightly(store, D1, at(D1, 9, 52))
    good = scores_json(store)
    assert good["computed_at"] == "2026-11-25T09:52:00Z"
    doc = hourly(store, tmp_path, at(D1, 10, 10))
    assert all(h is not None for h in near_term_highs(doc))
    assert doc["scores_computed_at"] == "2026-11-25T09:52:00Z"

    # 26 Nov 09:52 UTC: the cache is gone and one Previous Runs call is refused
    # (nothing saved to fall back on). Two sources still give days 1 to 7: promoted.
    empty_the_cache(store)
    r = nightly(store, D2, at(D2, 9, 52), get=refusing(models=["wild"], single_too=False))
    partial = scores_json(store)
    assert partial["computed_at"] == "2026-11-26T09:52:00Z" and partial["sources_missing"] == ["wild"]
    assert r["scores"]["issue_date"] == D2.isoformat()
    assert [x["source"] for x in sc.limit_losses(store, "kitimat", D2)] == ["wild"]  # the retry job runs
    assert not (store / "kitimat" / sc.REJECTED).exists()

    # 26 Nov 15:52 UTC: a new runner, cache gone again, every Open-Meteo call refused.
    # Only the saved Single Runs are left: the candidate has days 8 to 14 only.
    empty_the_cache(store)
    with pytest.raises(sc.ScoresRejected) as e:
        nightly(store, D2, at(D2, 15, 52), get=refusing())
    assert "days 1 to 7: no stats" in str(e.value)
    assert scores_json(store) == partial  # the last good scores, untouched
    rej = json.loads((store / "kitimat" / sc.REJECTED).read_text())
    assert rej["issue_date"] == "2026-11-26" and rej["why"] == ["days 1 to 7: no stats"]
    assert rej["kept"] == {"issue_date": "2026-11-26", "computed_at": "2026-11-26T09:52:00Z"}
    assert rej["leads"] == list(range(8, 15))
    log = [json.loads(x) for x in (store / "refusals.jsonl").read_text().splitlines()]
    assert log[-1]["kind"] == "scores_rejected"
    # A later nightly tries again, and the retry job is started and fails if it is still refused.
    assert not sc.already_scored(store, "kitimat", D2)
    assert {x["download"] for x in sc.limit_losses(store, "kitimat", D2)} == {"previous_runs"}

    # 26 Nov 16:10 UTC: the next hourly publish keeps the near-term highs and the true score age.
    doc = hourly(store, tmp_path, at(D2, 16, 10))
    assert all(h is not None for h in near_term_highs(doc))
    assert all(d["certainty"] is not None for d in doc["days"] if d["day"] <= 7)
    assert doc["scores_computed_at"] == "2026-11-26T09:52:00Z" and doc["weights_as_of"] == "2026-11-26"
    assert doc["stale"] is False

    # 26 Nov 16:30 UTC: recovery on a working address.
    nightly(store, D2, at(D2, 16, 30))
    assert scores_json(store)["computed_at"] == "2026-11-26T16:30:00Z"
    assert scores_json(store)["sources_missing"] == []
    assert not (store / "kitimat" / sc.REJECTED).exists()
    assert scores_json(store)["downloads_stale"] == [] and sc.limit_losses(store, "kitimat", D2) == []
    assert sc.rejection(store, "kitimat", D2) is None
    doc = hourly(store, tmp_path, at(D2, 17, 10))
    assert all(h is not None for h in near_term_highs(doc))
    assert doc["scores_computed_at"] == "2026-11-26T16:30:00Z"


def test_rejection_with_nothing_earlier_keeps_nothing(tmp_path):
    with pytest.raises(sc.ScoresRejected) as e:
        nightly(tmp_path, D1, at(D1, 9, 52), get=refusing())
    assert "no earlier scores to keep" in str(e.value)
    assert not (tmp_path / "kitimat" / "scores.json").exists()


def test_missing_reports_a_rejected_candidates_limit_losses(tmp_path, monkeypatch, capsys):
    nightly(tmp_path, D1, at(D1, 9, 52))
    empty_the_cache(tmp_path)
    with pytest.raises(sc.ScoresRejected):
        nightly(tmp_path, D2, at(D2, 9, 52), get=refusing())
    out = tmp_path / "gh_output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    argv = ["--issue", D2.isoformat(), "--store", str(tmp_path)]
    assert missing.main(argv) == 0
    assert out.read_text() == "om_refused=true\n"
    assert missing.main(argv + ["--fail-on-limit"]) == 1
    capsys.readouterr()
    assert missing.main(argv + ["--status"]) == 3
    assert capsys.readouterr().out == "" and out.read_text() == "om_refused=true\n" * 2


# --- the job log line that crashed -------------------------------------------

def test_summary_lines_survive_scores_without_day_1(tmp_path):
    s = nightly(tmp_path, D1, at(D1, 9, 52))["scores"]
    full = score_script.summary_lines(s)
    assert any(x.startswith("day 1 tmax: consensus recent miss") for x in full)
    del s["leads"]["1"]
    lines = score_script.summary_lines(s)
    assert "day 1 tmax: no stats" in lines and "day 1 tmin: no stats" in lines
    assert score_script.summary_lines({}) == ["issue date None, station data through None",
                                              "sources with history 0", "day 1 tmax: no stats",
                                              "day 1 tmin: no stats"]


# --- nightly.sh: who fails the run --------------------------------------------

def run_nightly_sh(tmp_path, score_rc: int, has_limit: bool, retry_on_limit: str) -> int:
    """nightly.sh with stand-ins for uv, the scripts and save_data.sh: only its
    exit logic is under test."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    (bin_dir / "uv").write_text(f"""#!/usr/bin/env bash
case "$*" in
  *score.py*) exit {score_rc} ;;
  *missing.py*--status*) exit {3 if has_limit else 0} ;;
  *) exit 0 ;;
esac
""")
    (bin_dir / "uv").chmod(0o755)
    repo = tmp_path / "repo"
    (repo / "backend" / "ci").mkdir(parents=True, exist_ok=True)
    src = (ROOT / "backend" / "ci" / "nightly.sh").read_text()
    (repo / "backend" / "ci" / "nightly.sh").write_text(src)
    (repo / "backend" / "ci" / "runner_info.sh").write_text("")
    (repo / "backend" / "ci" / "save_data.sh").write_text("exit 0\n")
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "RETRY_ON_LIMIT": retry_on_limit,
           "GITHUB_STEP_SUMMARY": str(tmp_path / "summary")}
    return subprocess.run(["bash", "backend/ci/nightly.sh"], cwd=repo, env=env,
                          capture_output=True, text=True).returncode


@pytest.mark.parametrize("score_rc,has_limit,retry_on_limit,expected", [
    (0, False, "1", 0),  # scored
    (1, False, "1", 1),  # rejected or failed, not a rate limit: the run fails (email)
    (1, True, "1", 0),   # rate limit in the first job: the retry job decides
    (1, True, "0", 1),   # still refused in the retry job: the run fails (email)
])
def test_nightly_sh_fails_unless_the_retry_job_will_decide(tmp_path, score_rc, has_limit, retry_on_limit,
                                                           expected):
    assert run_nightly_sh(tmp_path, score_rc, has_limit, retry_on_limit) == expected
