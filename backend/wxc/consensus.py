"""Consensus: habit fix, track-record weights, weighted blend, chance of precipitation.

Everything is per place, per lead day, per variable. Inputs are DataFrames
indexed by target date with one column per source (forecasts) and a Series
of station observations for the same dates.

Only information known at issue time is used: for lead L, the rolling
windows end L + 1 days before the target date.

Evidence: Kitimat pilot backtest (see docs/ALGORITHM.md). Day 1 high
average miss 1.00 deg C vs ECMWF 1.42 and equal weights 1.20.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

BIAS_DAYS = 30      # habit fix window (tested: 30)
WEIGHT_DAYS = 60    # weight window (tested 30/60/365/all: within 0.02 deg C)
FLOOR = 0.02        # weight guardrails, see docs/ALGORITHM.md for test status
CAP = 0.35
WET_MM = 1.0        # a "wet" day for chance of precipitation


def _trailing(x: pd.DataFrame | pd.Series, lead: int, days: int, min_periods: int):
    return x.shift(lead + 1).rolling(days, min_periods=min_periods).mean()


def apply_guardrails(w: pd.DataFrame, floor: float = FLOOR, cap: float = CAP,
                     iters: int = 50) -> pd.DataFrame:
    """Clip each row's weights to [floor, cap] among available sources and renormalise."""
    w = w.div(w.sum(axis=1), axis=0)
    for _ in range(iters):
        clipped = w.clip(lower=floor, upper=cap)
        clipped = clipped.div(clipped.sum(axis=1), axis=0)
        if np.nanmax(np.abs((clipped - w).to_numpy(dtype=float)), initial=0.0) < 1e-9:
            return clipped
        w = clipped
    return w


def temperature_consensus(F: pd.DataFrame, obs: pd.Series, lead: int,
                          guardrails: bool = True) -> pd.DataFrame:
    """Bias-corrected, inverse-MSE weighted consensus for tmax or tmin.

    Returns columns: consensus, spread (weighted std of corrected sources),
    n_sources, plus one weight column per source prefixed 'w_'.
    """
    E = F.sub(obs, axis=0)  # forecast minus observed
    bias = _trailing(E, lead, BIAS_DAYS, 10)
    mse = _trailing((E - bias).pow(2), lead, WEIGHT_DAYS, 20)
    Fbc = F - bias
    w = (1.0 / mse).where(Fbc.notna())
    w = w.div(w.sum(axis=1), axis=0)
    if guardrails:
        w = apply_guardrails(w)
    has = w.notna().any(axis=1)
    cons = (Fbc * w).sum(axis=1).where(has)
    spread = np.sqrt((w * Fbc.sub(cons, axis=0).pow(2)).sum(axis=1)).where(has)
    out = pd.DataFrame({"consensus": cons, "spread": spread, "n_sources": w.notna().sum(axis=1)})
    return out.join(w.add_prefix("w_"))


def precip_consensus(F: pd.DataFrame, obs: pd.Series, lead: int) -> pd.DataFrame:
    """Inverse-MAE weighted precipitation amount and chance of a wet day."""
    E = F.sub(obs, axis=0)
    mae = _trailing(E.abs(), lead, WEIGHT_DAYS, 20)
    w = (1.0 / mae).where(F.notna())
    has = w.notna().any(axis=1)
    amount = ((F * w).sum(axis=1) / w.sum(axis=1)).where(has)
    pop = ((F >= WET_MM).sum(axis=1) / F.notna().sum(axis=1)).where(F.notna().any(axis=1))
    return pd.DataFrame({"consensus": amount, "pop": pop, "n_sources": F.notna().sum(axis=1)})


def consensus_trailing_mae(cons: pd.Series, obs: pd.Series, lead: int) -> pd.Series:
    """Recent average miss of the consensus itself at this lead (input to Certainty)."""
    return _trailing((cons - obs).abs(), lead, WEIGHT_DAYS, 20)


def spread_reference(spread: pd.Series, lead: int) -> pd.Series:
    """Typical source disagreement over the last 60 days at this lead."""
    return _trailing(spread, lead, WEIGHT_DAYS, 20)
