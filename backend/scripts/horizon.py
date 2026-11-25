"""Horizon test: days 1 to 14, deterministic sources plus the 1991 to 2020 normal.

Run from the repo root (after score.py or the backfill has saved Single Runs):
    uv run python backend/scripts/horizon.py

Reads:
- data/store/kitimat/single/<model>/<date>.json  (Open-Meteo Single Runs, 00 UTC,
  from 2 Apr 2026; see backend/wxc/horizon.py)
- data/cache/daily_1064324.json                    (ECCC Kitimat Forest Ave, truth)
- data/cache/clim_1991/2001/2011.json             (ECCC Kitimat Townsite 1991 to 2020)

Variants per lead (same habit fix, weights and guardrails as days 1 to 7):
  det        deterministic sources only
  det+normal deterministic sources plus the normal as one more source
  ecmwf      ECMWF IFS alone
  best       the single model with the lowest miss at that lead, picked with
             hindsight on the scored days (an upper bound for "one model")
  equal      plain average of the deterministic sources
  normal     the normal alone, with its own 30-day habit fix
Certainty is checked per lead: what it said vs how often the high landed
within 2 deg C. Ensembles are not in this test: Open-Meteo keeps no history of
past ensemble runs (see backend/wxc/horizon.py).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from wxc import certainty as cert  # noqa: E402
from wxc import consensus as cs  # noqa: E402
from wxc import horizon as hz  # noqa: E402
from wxc.eccc import parse_daily  # noqa: E402

CACHE = ROOT / "data" / "cache"
STORE = ROOT / "data" / "store"
POOL = json.loads((ROOT / "config" / "sources.json").read_text())["deterministic_pool"]
EVAL_FROM = pd.Timestamp("2026-07-01").date()  # 3 months of warm-up from 2 Apr
LEADS = range(1, 15)


def load():
    obs = parse_daily(json.loads((CACHE / "daily_1064324.json").read_text()))
    normal = hz.daily_normal([json.loads((CACHE / f"clim_{y}.json").read_text()) for y in (1991, 2001, 2011)])
    models = {m: hz.single_runs_daily(STORE, "kitimat", m) for m in POOL}
    start = min(min(d.index.min() for d in m.values()) for m in models.values() if m)
    dates = pd.Index(pd.date_range(start, obs.index.max(), freq="D").date)
    return obs.reindex(dates), normal, models, dates


def frame(models, lead, var, dates):
    cols = {m: d[lead][var] for m, d in models.items() if lead in d and var in d[lead]}
    return pd.DataFrame(cols).reindex(dates)


def run():
    obs, normal, models, dates = load()
    N = hz.normal_for(normal, dates)
    rows, calib = [], []
    for var in ("tmax", "tmin"):
        o = obs[var]
        for lead in LEADS:
            F = frame(models, lead, var, dates)
            Fn = F.assign(normal=N[var])
            det = cs.temperature_consensus(F, o, lead)
            dn = cs.temperature_consensus(Fn, o, lead)
            nbias = cs._trailing(N[var] - o, lead, cs.BIAS_DAYS, 10)
            r = {"var": var, "lead": lead, "sources": int(F.notna().any().sum())}
            ev = pd.DataFrame({"o": o, "det": det.consensus, "det+normal": dn.consensus,
                               "ecmwf": F.get("ecmwf_ifs"), "equal": F.mean(axis=1),
                               "normal": N[var] - nbias})
            singles = F.add_prefix("m_")
            ev = ev.join(singles)
            for name, tc in (("det", det), ("det+normal", dn)):
                mae = cs.consensus_trailing_mae(tc.consensus, o, lead)
                ev[f"p_{name}"] = cert.certainty(mae, tc.spread, cs.spread_reference(tc.spread, lead))
            ev["w_normal"] = dn["w_normal"]
            ev = ev[ev.index >= EVAL_FROM].dropna(subset=["o", "det", "det+normal", "normal",
                                                          "p_det", "p_det+normal"])
            r["n"] = len(ev)
            for k in ("det", "det+normal", "ecmwf", "equal", "normal"):
                r[k] = (ev[k] - ev.o).abs().mean()
            r["normal_weight"] = ev.w_normal.mean()
            single = {c[2:]: (ev[c] - ev.o).abs().mean() for c in singles if ev[c].notna().mean() > 0.8}
            r["best_model"] = min(single, key=single.get) if single else None
            r["best"] = single.get(r["best_model"]) if single else np.nan
            for name in ("det", "det+normal"):
                hit = ((ev[name] - ev.o).abs() < cert.TOLERANCE_C).astype(float)
                r[f"said_{name}"], r[f"true_{name}"] = ev[f"p_{name}"].mean(), hit.mean()
                calib.append(pd.DataFrame({"var": var, "variant": name, "lead": lead,
                                           "p": ev[f"p_{name}"], "hit": hit}))
            rows.append(r)

    prow = []
    o = obs["pcp"]
    wet = (o >= cs.WET_MM).astype(float).where(o.notna())
    for lead in LEADS:
        F = frame(models, lead, "pcp", dates)
        det = cs.precip_consensus(F, o, lead)
        dn = cs.precip_consensus(F.assign(normal=N["pcp"]), o, lead)
        ev = pd.DataFrame({"o": o, "wet": wet, "det": det.consensus, "det+normal": dn.consensus,
                           "pop_sources": det["pop"], "pop_normal": N["wet_share"]})
        ev["pop_mix"] = (ev.pop_sources + ev.pop_normal) / 2
        ev = ev[ev.index >= EVAL_FROM].dropna()
        r = {"lead": lead, "n": len(ev)}
        for k in ("det", "det+normal"):
            r[f"mm_{k}"] = (ev[k] - ev.o).abs().mean()
        for k in ("pop_sources", "pop_normal", "pop_mix"):
            r[f"brier_{k}"] = ((ev[k] - ev.wet) ** 2).mean()
        prow.append(r)
    P = pd.DataFrame(prow)

    R = pd.DataFrame(rows)
    pd.set_option("display.width", 220)
    print(f"Average miss in deg C, scored {EVAL_FROM} to {obs.dropna(how='all').index.max()}, "
          f"Kitimat Forest Ave. History: Open-Meteo Single Runs (00 UTC) from 2 Apr 2026.\n")
    for var in ("tmax", "tmin"):
        print("==", var)
        cols = ["lead", "n", "sources", "det", "det+normal", "best", "best_model", "ecmwf", "equal",
                "normal", "normal_weight", "said_det+normal", "true_det+normal"]
        print(R[R["var"] == var][cols].round(3).to_string(index=False), "\n")
    print("== pcp: amount miss in mm, chance of precipitation Brier (lower is better)")
    print(P.round(3).to_string(index=False), "\n")
    A = pd.concat(calib)
    for name in ("det", "det+normal"):
        a = A[(A["var"] == "tmax") & (A.variant == name)]
        t = a.groupby(pd.cut(a.p, [0, .5, .6, .7, .8, .9, 1.0]), observed=True).agg(
            days=("hit", "size"), said=("p", "mean"), came_true=("hit", "mean"))
        brier = ((a.p - a.hit) ** 2).mean()
        print(f"Certainty reliability, tmax, {name}, leads 1 to 14 (Brier {brier:.4f})\n",
              t.round(3).to_string(), "\n")
    out = ROOT / "data" / "horizon_scores.csv"
    R.to_csv(out, index=False)
    print("saved", out.relative_to(ROOT))


if __name__ == "__main__":
    run()
