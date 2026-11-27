"""Backtest the consensus on cached history (Kitimat pilot data).

Run from the repo root:
    uv run python backend/scripts/backtest.py            # scores + Certainty check
    uv run python backend/scripts/backtest.py --align    # climate-day offset check

Reads data/cache/prev/*.json (Open-Meteo Previous Runs) and
data/cache/daily_1064324.json (ECCC Kitimat Forest Ave). Scores 2026-01-01 on;
Nov and Dec 2025 warm up the rolling windows. Expected day 1 high: about 1.00.
Any change to the algorithm must be run through this script before shipping.

Also writes data/backtest/kitimat.json (committed): the numbers the app's
"Tested on real Kitimat weather" card shows, published as `backtest` in the
place file by publish.py. Only numbers this script computes go in it.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from wxc import certainty as cert  # noqa: E402
from wxc import consensus as cs  # noqa: E402
from wxc.daily import previous_runs_daily  # noqa: E402
from wxc.eccc import parse_daily  # noqa: E402

CACHE = ROOT / "data" / "cache"
POOL = json.loads((ROOT / "config" / "sources.json").read_text())["deterministic_pool"]
EVAL_FROM = pd.Timestamp("2026-01-01").date()
RESULTS = ROOT / "data" / "backtest" / "kitimat.json"
STATION = {"network": "ECCC", "id": "1064324", "name": "Kitimat Forest Ave"}
BASELINE = "ecmwf_ifs"


def load(offset_h: int = -6):
    obs = parse_daily(json.loads((CACHE / "daily_1064324.json").read_text()))
    models = {m: previous_runs_daily(json.loads((CACHE / "prev" / f"{m}.json").read_text()), offset_h)
              for m in POOL}
    return obs, models


def frame(models, lead, var, dates):
    return pd.DataFrame({m: d[lead][var] for m, d in models.items() if lead in d}).reindex(dates)


def scores():
    obs, models = load()
    dates = pd.Index(sorted(obs.index))
    rows, calib, scored = [], [], []
    for var in ("tmax", "tmin", "pcp"):
        for lead in range(1, 8):
            F = frame(models, lead, var, dates)
            o = obs[var].reindex(dates)
            r = {"var": var, "lead": lead}
            if var == "pcp":
                pc = cs.precip_consensus(F, o, lead)
                ev = pd.DataFrame({"o": o, "c": pc.consensus, "e": F["ecmwf_ifs"], "pop": pc["pop"]})
                ev = ev[ev.index >= EVAL_FROM].dropna()
                wet = (ev.o >= cs.WET_MM).astype(float)
                r.update(n=len(ev), consensus=(ev.c - ev.o).abs().mean(), ecmwf=(ev.e - ev.o).abs().mean(),
                         brier_pop=((ev["pop"] - wet) ** 2).mean(),
                         brier_climatology=((wet.mean() - wet) ** 2).mean())
            else:
                tc = cs.temperature_consensus(F, o, lead, guardrails=True)
                tn = cs.temperature_consensus(F, o, lead, guardrails=False)
                mae = cs.consensus_trailing_mae(tc.consensus, o, lead)
                p = cert.certainty(mae, tc.spread, cs.spread_reference(tc.spread, lead))
                ev = pd.DataFrame({"o": o, "c": tc.consensus, "c_nog": tn.consensus, "e": F["ecmwf_ifs"],
                                   "eqw": F.mean(axis=1), "p": p})
                ev = ev[ev.index >= EVAL_FROM].dropna()
                r.update(n=len(ev), consensus=(ev.c - ev.o).abs().mean(),
                         no_guardrails=(ev.c_nog - ev.o).abs().mean(),
                         ecmwf=(ev.e - ev.o).abs().mean(), equal_weights=(ev.eqw - ev.o).abs().mean())
                hit = ((ev.c - ev.o).abs() < cert.TOLERANCE_C).astype(float)
                r.update(certainty_said=ev.p.mean(), came_true=hit.mean())
                calib.append(pd.DataFrame({"var": var, "p": ev.p, "hit": hit}))
            scored.extend(ev.index)
            rows.append(r)
    R = pd.DataFrame(rows)
    pd.set_option("display.width", 220)
    print("Average miss (deg C; precip mm), scored", EVAL_FROM, "on\n")
    for var in ("tmax", "tmin", "pcp"):
        print("==", var)
        print(R[R["var"] == var].drop(columns="var").dropna(axis=1, how="all").round(3).to_string(index=False), "\n")
    A = pd.concat(calib)
    for var in ("tmax", "tmin"):
        a = A[A["var"] == var]
        t = a.groupby(pd.cut(a.p, [0, .5, .6, .7, .8, .9, 1.0]), observed=True).agg(
            days=("hit", "size"), said=("p", "mean"), came_true=("hit", "mean"))
        print(f"Certainty reliability, {var}, leads 1 to 7\n", t.round(3).to_string(), "\n")
    out = ROOT / "data" / "backtest_scores.csv"
    R.to_csv(out, index=False)
    print("saved", out.relative_to(ROOT))
    write_results(R, min(scored), max(scored), models[BASELINE][1].dropna(how="all").index.min())
    print("saved", RESULTS.relative_to(ROOT))


def results(R: pd.DataFrame, first, last, warmup_from) -> dict:
    """The card's numbers, straight from the score table (deg C and mm, 3 decimals)."""
    def num(x):
        return None if pd.isna(x) else round(float(x), 3)

    def row(var, lead):
        return R[(R["var"] == var) & (R["lead"] == lead)].iloc[0]

    leads = []
    for lead in sorted(R["lead"].unique()):
        e = {"lead": int(lead)}
        for name, var in (("high", "tmax"), ("low", "tmin")):
            r = row(var, lead)
            e[name] = {"consensus": num(r.consensus), "baseline": num(r.ecmwf),
                       "equal_weights": num(r.equal_weights), "days": int(r.n)}
        r = row("pcp", lead)
        e["rain"] = {"consensus": num(r.consensus), "baseline": num(r.ecmwf), "days": int(r.n),
                     "brier_chance": num(r.brier_pop), "brier_climatology": num(r.brier_climatology)}
        leads.append(e)
    return {
        "basis": "backtest",
        "place": "kitimat",
        "station": STATION,
        "scored_from": first.isoformat(),
        "scored_to": last.isoformat(),
        "warmup_from": warmup_from.isoformat(),
        "method": {"past_data_only": True, "history": "Open-Meteo Previous Runs (archived forecasts)",
                   "habit_days": cs.BIAS_DAYS, "weight_days": cs.WEIGHT_DAYS,
                   "script": "backend/scripts/backtest.py"},
        "baseline": BASELINE,
        "leads": leads,
    }


def write_results(R, first, last, warmup_from):
    RESULTS.parent.mkdir(parents=True, exist_ok=True)
    RESULTS.write_text(json.dumps(results(R, first, last, warmup_from), indent=1) + "\n")


def align():
    for off in (-5, -6, -7, -8):
        obs, models = load(off)
        d = models["ecmwf_ifs"][1].join(obs, rsuffix="_o", how="inner").dropna()
        print(f"offset {off:+d} h  days {len(d)}  ECMWF day-1 miss: high {(d.tmax - d.tmax_o).abs().mean():.3f}"
              f"  low {(d.tmin - d.tmin_o).abs().mean():.3f}  precip {(d.pcp - d.pcp_o).abs().mean():.3f}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--align", action="store_true")
    args = ap.parse_args()
    align() if args.align else scores()
