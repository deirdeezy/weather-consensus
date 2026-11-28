"""Publish: the latest Consensus for one place as a small public JSON file.

Inputs (all under data/store/<place>/):
- scores.json (nightly, backend/wxc/score.py): habit fixes and errors per
  source, lead and variable, as known on its issue date.
- state.json and the raw pulls it points to (hourly, backend/wxc/refresh.py):
  the newest run of every deterministic source.
- history/normal_records_<id>.json: the 1991 to 2020 normal (days 8 to 14).
- now.json (hourly, backend/wxc/obs.py): the latest station observation, for
  places with an approved station only. Published in "now" as is, plus
  "condition" and "basis" (backend/wxc/nowcast.py: measured first, the
  forecast's current hour only for cloud).
- data/backtest/<place>.json (in the repo, backend/scripts/backtest.py): the
  backtest numbers, published as their own file public/backtest/<place>.json
  (they change only when the backtest is run again); the place file carries
  a small pointer, "backtest_file" (path, SHA-256, bytes).

Also appends to data/store/<place>/now_log.jsonl what "now" said and a
shadow 6-hour strip (backend/wxc/nowcast.py; not published). Also writes
data/store/<place>/consensus_log.jsonl: one line per issue date
with what we published (our own live record, scored nightly by score.py),
and appends to issue_ledger.jsonl what was published at two fixed issue
times a day (the first publish from 13:00 UTC and from 01:00 UTC): values,
weights and each source's run time, so the live record can be scored at a
fixed lead time as well as at the last publish of the day.

Output: public/<place>.json, described in docs/JSON_SCHEMA.md and checked
against docs/place-v1.schema.json by the tests.

Method: the same code the backtest checks (consensus.blend, certainty.certainty)
with the rules in docs/ALGORITHM.md. Day N is the ECCC climate day N days
after the issue date (lead N), as in the backtest. Ensembles get no weight.

Nothing local goes into the file: no paths, no URLs we called, no machine
names. Only place data from config/places.json, forecast numbers and credits.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import math
import time
from pathlib import Path

import numpy as np
import pandas as pd

from . import certainty as cert
from . import consensus as cs
from . import eccc
from . import horizon as hz
from . import nowcast, obs
from .daily import CLIMATE_DAY_OFFSET_H
from .refresh import _write_json, iso, load_state, refusal_logger
from .score import ALL_LEADS, LEDGER, LIVE_MIN_DAYS, NORMAL, _daily_from_pull

SCHEMA_VERSION = 1
STALE_AFTER_H = 6     # no new pull for this long: stale (CLAUDE.md, reliability)
LATE_RUN_H = 24       # a source whose newest run is this much older than the
                      # newest run of any source is late: its share goes to the rest
NORMAL_LABEL = "1991 to 2020 normal"
OPEN_METEO = {"text": "Weather data by Open-Meteo.com",
              "licence": "CC BY 4.0",
              "url": "https://open-meteo.com/",
              "licence_url": "https://creativecommons.org/licenses/by/4.0/"}
ECCC = {"text": eccc.CREDIT,
        "licence": "ECCC Data Servers End-use Licence",
        "url": "https://eccc-msc.github.io/open-data/licence/readme_en/",
        "licence_url": "https://eccc-msc.github.io/open-data/licence/readme_en/"}


def issue_date_at(now: int) -> dt.date:
    t = dt.datetime.fromtimestamp(now, dt.timezone.utc)
    return (t + dt.timedelta(hours=CLIMATE_DAY_OFFSET_H)).date()


def _r(x, nd: int):
    if x is None:
        return None
    x = float(x)
    return None if math.isnan(x) or math.isinf(x) else round(x, nd)


def _pct(p):
    p = _r(p, 6)
    return None if p is None else int(round(100 * p))


# --- inputs from the store ----------------------------------------------------

def load_pulls(store: Path, place_id: str, pool: list[str], log=None) -> dict:
    """Newest saved pull of every deterministic source: daily values, run and
    fetch time (Unix seconds)."""
    state = load_state(store, place_id)
    out = {}
    for m in pool:
        s = state.get(m)
        if not s:
            continue
        try:
            rec = json.loads((store / s["file"]).read_text())
            daily = _daily_from_pull(rec)
        except Exception as e:
            if log:
                log(m, "publish", f"saved pull unreadable: {e}")
            continue
        if daily is None:
            continue
        runs = s.get("runs") or {}
        out[m] = {"daily": daily, "run_unix": max(runs.values()) if runs else s["fetched_unix"],
                  "fetched_unix": s["fetched_unix"]}
    return out


def load_normal(store: Path, place: dict) -> pd.DataFrame | None:
    cid = (place.get("normal") or {}).get("climate_id")
    path = store / place["id"] / "history" / f"normal_records_{cid}.json"
    if not cid or not path.exists():
        return None
    return hz.daily_normal(json.loads(path.read_text()))


# --- the forecast -----------------------------------------------------------

def _stats(scores: dict, lead: int, var: str) -> dict:
    return (scores.get("leads", {}).get(str(lead)) or {}).get(var, {}).get("sources", {})


def _temperature(F: pd.Series, st: dict):
    hf = pd.Series({m: v.get("habit_fix") for m, v in st.items()}, dtype=float)
    mse = pd.Series({m: v.get("mse") for m, v in st.items()}, dtype=float)
    F = F[[m for m in F.index if m in st]]
    return cs.blend(F, hf, mse)


def _precip(F: pd.Series, st: dict):
    """Inverse-MAE weighted amount among sources present (no guardrails),
    as consensus.precip_consensus. Returns the amount and the shares used."""
    mae = pd.Series({m: v.get("mae") for m, v in st.items()}, dtype=float)
    F = F[[m for m in F.index if m in st]].dropna()
    w = (1.0 / mae.reindex(F.index)).replace([np.inf, -np.inf], np.nan).dropna()
    if w.empty:
        return float("nan"), w
    return float((F[w.index] * w).sum() / w.sum()), w / w.sum()


def build(place: dict, cfg: dict, scores: dict, pulls: dict, normal: pd.DataFrame | None,
          now: int, now_block: dict | None = None, backtest: dict | None = None,
          used_out: dict | None = None) -> dict:
    """The public document for one place. Pure: no reading or writing.
    used_out, if given, gets the weights used per lead and variable (for the
    issue ledger)."""
    pool = cfg["deterministic_pool"]
    issue = issue_date_at(now)
    newest_run = max((p["run_unix"] for p in pulls.values()), default=None)
    used = {m: p for m, p in pulls.items()
            if newest_run is not None and newest_run - p["run_unix"] <= LATE_RUN_H * 3600}
    fresh = max((p["fetched_unix"] for p in pulls.values()), default=None)
    stale = fresh is None or now - fresh > STALE_AFTER_H * 3600

    targets = [issue + dt.timedelta(days=L) for L in ALL_LEADS]
    N = hz.normal_for(normal, targets) if normal is not None else None
    labels = cfg.get("labels", {})
    shown = set()
    used_weights = {}
    days = []
    for L, T in zip(ALL_LEADS, targets):
        row = {}
        for var in ("tmax", "tmin", "pcp"):
            row[var] = pd.Series({m: p["daily"][var].get(T, np.nan) if var in p["daily"] else np.nan
                                  for m, p in used.items()}, dtype=float)
        hi, spread, w = _temperature(_with_normal(row["tmax"], N, T, "tmax", L), _stats(scores, L, "tmax"))
        lo, _, w_lo = _temperature(_with_normal(row["tmin"], N, T, "tmin", L), _stats(scores, L, "tmin"))
        mm, w_pcp = _precip(_with_normal(row["pcp"], N, T, "pcp", L, hz.PCP_NORMAL_FROM_LEAD),
                            _stats(scores, L, "pcp"))
        used_weights[L] = {"tmax": w, "tmin": w_lo, "pcp": w_pcp}
        models_pcp = row["pcp"].dropna()
        pop = float((models_pcp >= cs.WET_MM).mean()) if len(models_pcp) else float("nan")
        if N is not None and L >= hz.POP_MIX_FROM_LEAD and not math.isnan(pop):
            pop = (pop + float(N.at[T, "wet_share"])) / 2

        # Certainty is about the high: no high, no Certainty (review finding 3).
        c = None
        if not math.isnan(hi):
            st = (scores.get("leads", {}).get(str(L)) or {}).get("tmax", {})
            p = cert.certainty(pd.Series([st.get("consensus_mae")], dtype=float),
                               pd.Series([spread], dtype=float),
                               pd.Series([st.get("spread_ref")], dtype=float)).iloc[0]
            c = _pct(p)
        weights = sorted(((m, _r(x, 3)) for m, x in w.dropna().items()), key=lambda t: -t[1])
        shown.update(m for m, _ in weights)
        days.append({
            "day": L,
            "date": T.isoformat(),
            "high": _r(hi, 1),
            "low": _r(lo, 1),
            "precip_mm": _r(max(mm, 0.0), 1) if not math.isnan(mm) else None,
            "precip_chance": _pct(pop),
            "certainty": c,
            "tier": None if c is None else cert.tier(c / 100),
            "weights": [{"id": m, "weight": x} for m, x in weights],
            "source_counts": {"high": int(w.notna().sum()), "low": int(w_lo.notna().sum()),
                              "precip": int(w_pcp.notna().sum())},
        })

    truth = place.get("truth")
    sources = [{"id": m, "label": labels.get(m, m)} for m in pool if m in shown]
    if NORMAL in shown:
        sources.append({"id": NORMAL, "label": NORMAL_LABEL})
    doc = {
        "schema_version": SCHEMA_VERSION,
        "place": {
            "id": place["id"],
            "name": place["name"],
            "lat": place["lat"],
            "lon": place["lon"],
            "elevation_m": place.get("elevation_m"),
            "timezone": place.get("timezone"),
            "truth_station": None if not truth else {
                "network": truth.get("network"), "id": truth.get("climate_id"),
                "name": truth.get("station")},
            "consensus_only": not truth,
        },
        "issued_at": iso(now),
        "issue_date": issue.isoformat(),
        "newest_run_at": iso(newest_run) if newest_run is not None else None,
        "fresh_data_at": iso(fresh) if fresh is not None else None,
        "stale": stale,
        "stale_after_hours": STALE_AFTER_H,
        "weights_as_of": scores.get("issue_date"),
        "scores_computed_at": scores.get("computed_at"),
        "units": {"temperature": "degC", "precipitation": "mm", "chance": "percent"},
        "sources": sources,
        "days": days,
        "credits": [OPEN_METEO, ECCC],
    }
    if used_out is not None:
        used_out.update(used_weights)
    record = track_record(scores, used_weights, [s["id"] for s in sources])
    if record:
        doc["track_record"] = record
    if backtest:  # data/backtest/<place>.json, written by backend/scripts/backtest.py
        doc["backtest_file"] = backtest_pointer(place["id"], backtest_bytes(backtest))
    if now_block:  # only for a place with an approved station (backend/wxc/obs.py)
        doc["now"] = now_block
    return doc


def _live_consensus(summary: dict | None, leads: list[int]) -> list | None:
    """Our own published consensus scored nightly (score.consensus_summary),
    shaped like archive.consensus. None before the first nightly with the log."""
    if summary is None:
        return None
    out = []
    for L in leads:
        x = summary.get(str(L)) or {}
        e = {"lead": L}
        for name in ("high", "low", "rain"):
            v = x.get(name) or {}
            e[name] = {"miss": _r(v.get("mae"), 2), "days": v.get("days", 0)}
        out.append(e)
    return out


# --- the backtest card --------------------------------------------------------

def load_backtest(results_dir: Path | None, place_id: str) -> dict | None:
    """The year-long test's numbers for a place, if backtest.py has written them."""
    path = results_dir / f"{place_id}.json" if results_dir else None
    if not path or not path.exists():
        return None
    r = json.loads(path.read_text())
    return r if r.get("place") == place_id and r.get("basis") == "backtest" else None


def backtest_block(r: dict) -> dict:
    """As backtest.py wrote it, minus the place id and script path."""
    method = {k: v for k, v in (r.get("method") or {}).items() if k != "script"}
    return {"basis": "backtest", "station": r.get("station"), "scored_from": r["scored_from"],
            "scored_to": r["scored_to"], "warmup_from": r.get("warmup_from"), "method": method,
            "baseline": r.get("baseline"), "leads": r["leads"]}


BACKTEST_DIR = "backtest"  # public/backtest/<place>.json on Pages, next to the place files


def backtest_bytes(r: dict) -> bytes:
    """The published backtest file, byte for byte. Compact and in a fixed key
    order, so the same results always give the same bytes and the same hash."""
    return json.dumps(backtest_block(r), separators=(",", ":"), sort_keys=True).encode()


def backtest_pointer(place_id: str, data: bytes) -> dict:
    """What the place file carries instead of the block: where the file is and
    its SHA-256, so the app downloads it again only when it changed."""
    return {"path": f"{BACKTEST_DIR}/{place_id}.json", "sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data)}


# --- our own consensus, one line a day (scored nightly by score.py) -----------

CONSENSUS_LOG = "consensus_log.jsonl"


def log_line(doc: dict) -> dict:
    """One compact line: the issue date, when it was published, and per lead
    [lead, high, low, precip_mm, precip_chance, certainty] (docs/JSON_SCHEMA.md)."""
    return {"issue_date": doc["issue_date"], "issued_at": doc["issued_at"],
            "days": [[d["day"], d["high"], d["low"], d["precip_mm"], d["precip_chance"], d["certainty"]]
                     for d in doc["days"]]}


def log_consensus(store: Path, place_id: str, doc: dict) -> int:
    """Keep the last publish of each issue date (as the sources' live record
    keeps the last pull): replace today's line, keep every earlier one.
    Returns the line's size in bytes."""
    path = store / place_id / CONSENSUS_LOG
    line = json.dumps(log_line(doc), separators=(",", ":"))
    lines = path.read_text().splitlines() if path.exists() else []
    lines = [x for x in lines if x and json.loads(x).get("issue_date") != doc["issue_date"]]
    lines.append(line)
    lines.sort(key=lambda x: json.loads(x)["issue_date"])
    tmp = path.with_suffix(".tmp")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text("\n".join(lines) + "\n")
    tmp.replace(path)
    return len(line) + 1


# --- the issue ledger: what was published at two fixed times a day -----------

# Each slot opens at this UTC hour and runs until the other one opens; the first
# publish in a slot is recorded. 13:00 UTC is 05:00 in Kitimat (PST) and 01:00
# UTC is 17:00 the day before: a morning and an evening issue of one issue date.
MORNING_UTC_HOUR = 13
EVENING_UTC_HOUR = 1


def ledger_slot(now: int) -> tuple[str, str]:
    """(slot name, slot start as UTC time) for a publish at `now`."""
    t = dt.datetime.fromtimestamp(now, dt.timezone.utc)
    if t.hour >= MORNING_UTC_HOUR:
        name, day, hour = "morning", t.date(), MORNING_UTC_HOUR
    elif t.hour >= EVENING_UTC_HOUR:
        name, day, hour = "evening", t.date(), EVENING_UTC_HOUR
    else:  # after midnight, before the evening slot opens: still yesterday's morning slot
        name, day, hour = "morning", t.date() - dt.timedelta(days=1), MORNING_UTC_HOUR
    start = dt.datetime.combine(day, dt.time(hour), dt.timezone.utc)
    return name, iso(int(start.timestamp()))


def _permille(w, m):
    return None if w is None or m not in w.index or pd.isna(w[m]) else int(round(1000 * float(w[m])))


def ledger_line(doc: dict, used: dict, pulls: dict, now: int) -> dict:
    """One compact line. `src` names the sources once; `run` is each one's
    newest run time (null for the normal); each day is [lead, high, low,
    precip_mm, precip_chance, certainty, high weights, low weights, precip
    weights], the weights in thousandths in `src` order, null where a source
    had no weight. Values exactly as published."""
    slot, start = ledger_slot(now)
    ids = list(pulls)  # pool order (load_pulls)
    if any(NORMAL in w.index for u in used.values() for w in u.values() if w is not None):
        ids.append(NORMAL)
    days = []
    for d in doc["days"]:
        u = used.get(d["day"]) or {}
        days.append([d["day"], d["high"], d["low"], d["precip_mm"], d["precip_chance"], d["certainty"]]
                    + [[_permille(u.get(v), m) for m in ids] for v in ("tmax", "tmin", "pcp")])
    return {"slot": slot, "slot_start": start, "issue_date": doc["issue_date"],
            "issued_at": doc["issued_at"], "weights_as_of": doc["weights_as_of"],
            "scores_computed_at": doc.get("scores_computed_at"), "stale": doc["stale"],
            "src": ids, "run": [iso(pulls[m]["run_unix"]) if m in pulls else None for m in ids],
            "days": days}


def log_issue(store: Path, place_id: str, line: dict) -> int:
    """Append the line if its slot has no line yet (append-only: earlier lines
    are never changed). Returns the bytes added, 0 if the slot was taken."""
    path = store / place_id / LEDGER
    if path.exists():
        for x in path.read_text().splitlines():
            if x.strip() and json.loads(x).get("slot_start") == line["slot_start"]:
                return 0
    text = json.dumps(line, separators=(",", ":")) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(text)
    return len(text.encode())


# --- the track record (Consensus tab, steps 2 and 3) --------------------------

TRACK_LEADS = (1, 7, 13)  # the leads the Consensus tab shows (as its day 1, 7 and 13 bars)
VARS = (("high", "tmax"), ("low", "tmin"), ("rain", "pcp"))


def _entry(st: dict, weight, temperature: bool) -> dict:
    e = {"weight": _r(weight, 3), "miss": _r(st.get("mae"), 2), "days": st.get("days")}
    if temperature:
        e["bias"] = _r(st.get("habit_fix"), 2)
        e["bias_days"] = st.get("bias_days")
    return e


def track_record(scores: dict, used: dict, order: list[str]) -> dict | None:
    """Each source's recent miss, today's weight and habit fix at TRACK_LEADS,
    labelled by where the numbers come from:
    - archive: the nightly scoring of each source's archived forecasts (Open-
      Meteo Previous Runs, days 1 to 7; Single Runs, days 8 to 14) against the
      station; the same numbers the weights and habit fixes come from.
    - live: our own saved forecasts against the station (since 25 Nov 2026);
      a miss only once LIVE_MIN_DAYS are in, otherwise the count alone.
    Never mixed: a reader picks one. None until scores.json has the fields
    (score.py SCORES_FORMAT 2), so an older scores.json publishes no block."""
    if scores.get("format", 1) < 2 or "windows" not in scores:
        return None
    rank = {m: i for i, m in enumerate(order)}
    leads = [L for L in TRACK_LEADS if str(L) in scores.get("leads", {})]
    consensus, sources = [], []
    for L in leads:
        stats = scores["leads"][str(L)]
        c = {"lead": L}
        for name, var in VARS:
            v = stats.get(var) or {}
            c[name] = {"miss": _r(v.get("consensus_mae"), 2), "days": v.get("consensus_days")}
        consensus.append(c)
        ids = sorted({m for _, var in VARS for m in (stats.get(var) or {}).get("sources", {})},
                     key=lambda m: (rank.get(m, len(rank)), m))
        for m in ids:
            e = {"id": m, "lead": L}
            for name, var in VARS:
                st = ((stats.get(var) or {}).get("sources") or {}).get(m)
                if st is None:
                    continue
                w = (used.get(L) or {}).get(var)
                weight = None if w is None or m not in w.index or pd.isna(w[m]) else w[m]
                e[name] = _entry(st, weight, var != "pcp")
            if any(e.get(n) and (e[n]["miss"] is not None or e[n]["weight"] is not None)
                   for n, _ in VARS):
                sources.append(e)
    live = scores.get("live") or {}
    live_leads = live.get("leads") or {}
    live_sources = []
    for L in leads:
        for m, vs in sorted((live_leads.get(str(L)) or {}).get("sources", {}).items(),
                            key=lambda t: (rank.get(t[0], len(rank)), t[0])):
            e = {"id": m, "lead": L}
            for name, var in VARS:
                if var in vs:
                    e[name] = {"miss": _r(vs[var].get("mae"), 2), "days": vs[var].get("days")}
            live_sources.append(e)
    return {
        "leads": leads,
        "scored_on": scores.get("issue_date"),
        "station_through": scores.get("obs_through"),
        "archive": {
            "basis": "archive",
            "miss_window": scores["windows"]["miss"],
            "bias_window": scores["windows"]["bias"],
            "min_days": LIVE_MIN_DAYS,
            "consensus": consensus,
            "sources": sources,
        },
        "live": {
            "basis": "live",
            "since": live.get("since"),
            "window": live.get("window") or scores["windows"]["miss"],
            "min_days": live.get("min_days", LIVE_MIN_DAYS),
            "days": [{"lead": L, "days": (live_leads.get(str(L)) or {}).get("days", 0)}
                     for L in leads],
            "consensus": _live_consensus(live.get("consensus"), leads),
            "sources": live_sources,
        },
    }


def _with_normal(F: pd.Series, N, T, var: str, lead: int,
                 first: int = hz.NORMAL_FROM_LEAD) -> pd.Series:
    if N is None or lead < first:
        return F
    return pd.concat([F, pd.Series({NORMAL: N.at[T, var]}, dtype=float)])


# --- the job ----------------------------------------------------------------

def publish(place: dict, cfg: dict, store: Path, out_dir: Path, now: int | None = None,
            echo=print, backtest_dir: Path | None = None) -> dict:
    now = int(time.time() if now is None else now)
    pid = place["id"]
    log = refusal_logger(store, pid, echo)
    path = store / pid / "scores.json"
    if not path.exists():
        log("publish", "publish", "no scores.json: run score.py first")
        raise RuntimeError("no scores.json, nothing published")
    scores = json.loads(path.read_text())
    pulls = load_pulls(store, pid, cfg["deterministic_pool"], log)
    if not pulls:
        log("publish", "publish", "no saved pulls: run refresh.py first")
        raise RuntimeError("no saved pulls, nothing published")
    backtest = load_backtest(backtest_dir, pid)
    used: dict = {}
    sources = nowcast.load_sources(store, pid, cfg["deterministic_pool"], now)
    now_block = obs.load_now(store, place)
    now_pub = nowcast.with_condition(now_block, sources, now) if now_block else None
    doc = build(place, cfg, scores, pulls, load_normal(store, place), now,
                now_pub, backtest, used_out=used)
    if backtest:  # written first, so the pointer never names a file that is not there yet
        path = out_dir / BACKTEST_DIR / f"{pid}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_bytes(backtest_bytes(backtest))
        tmp.replace(path)
    _write_json(out_dir / f"{pid}.json", doc)
    log_consensus(store, pid, doc)
    log_issue(store, pid, ledger_line(doc, used, pulls, now))
    nowcast.log_now(store, pid, nowcast.log_line(now_pub, sources, now))
    return doc
