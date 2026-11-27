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


def _trailing_count(x: pd.DataFrame | pd.Series, lead: int, days: int):
    """How many days with a value the matching _trailing window holds."""
    return x.notna().astype(float).shift(lead + 1).rolling(days, min_periods=1).sum()


def apply_guardrails(w: pd.DataFrame, floor: float = FLOOR, cap: float = CAP,
                     iters: int = 50, cap_exempt=()) -> pd.DataFrame:
    """Clip each row's weights to [floor, cap] among available sources and renormalise.
    Columns in cap_exempt keep the floor but have no cap."""
    w = w.div(w.sum(axis=1), axis=0)
    caps = pd.Series([1.0 if c in cap_exempt else cap for c in w.columns], index=w.columns)
    for _ in range(iters):
        clipped = w.clip(lower=floor, upper=caps, axis=1)
        clipped = clipped.div(clipped.sum(axis=1), axis=0)
        if np.nanmax(np.abs((clipped - w).to_numpy(dtype=float)), initial=0.0) < 1e-9:
            return clipped
        w = clipped
    return w


def temperature_consensus(F: pd.DataFrame, obs: pd.Series, lead: int,
                          guardrails: bool = True, cap_exempt=()) -> pd.DataFrame:
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
        w = apply_guardrails(w, cap_exempt=cap_exempt)
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


# --- Live use: the same numbers as above, for one issue date ----------------

def _as_of_frame(F: pd.DataFrame, obs: pd.Series, issue, lead: int):
    """Continuous daily index up to the target date; observations from the
    issue date on are hidden, so nothing unknown at issue time can leak in."""
    target = issue + pd.Timedelta(days=lead).to_pytimedelta()
    start = min(F.index.min(), obs.index.min())
    idx = pd.Index(pd.date_range(start, target, freq="D").date)
    F = F.reindex(idx)
    obs = obs.reindex(idx)
    obs = obs.where(pd.Series(idx < issue, index=idx))
    return F, obs, target


def temperature_stats(F: pd.DataFrame, obs: pd.Series, lead: int, issue) -> dict:
    """Habit fix and mean squared error per source, plus the consensus's own
    recent miss and usual disagreement, as known on the issue date for a
    forecast `lead` days ahead. Same windows as temperature_consensus."""
    F, obs, target = _as_of_frame(F, obs, issue, lead)
    E = F.sub(obs, axis=0)
    bias = _trailing(E, lead, BIAS_DAYS, 10)
    mse = _trailing((E - bias).pow(2), lead, WEIGHT_DAYS, 20)
    tc = temperature_consensus(F, obs, lead)
    ce = tc.consensus - obs
    # For the track record only (not used by the blend): the raw average miss
    # before the habit fix, and how many days each window holds.
    return {"habit_fix": bias.loc[target], "mse": mse.loc[target],
            "consensus_mae": consensus_trailing_mae(tc.consensus, obs, lead).loc[target],
            "spread_ref": spread_reference(tc.spread, lead).loc[target],
            "mae": _trailing(E.abs(), lead, WEIGHT_DAYS, 20).loc[target],
            "days": _trailing_count(E, lead, WEIGHT_DAYS).loc[target],
            "bias_days": _trailing_count(E, lead, BIAS_DAYS).loc[target],
            "consensus_days": _trailing_count(ce, lead, WEIGHT_DAYS).loc[target]}


def precip_stats(F: pd.DataFrame, obs: pd.Series, lead: int, issue) -> dict:
    """Mean absolute error per source as known on the issue date."""
    F, obs, target = _as_of_frame(F, obs, issue, lead)
    E = F.sub(obs, axis=0)
    mae = _trailing(E.abs(), lead, WEIGHT_DAYS, 20)
    ce = precip_consensus(F, obs, lead).consensus - obs
    return {"mae": mae.loc[target], "days": _trailing_count(E, lead, WEIGHT_DAYS).loc[target],
            "consensus_mae": _trailing(ce.abs(), lead, WEIGHT_DAYS, 20).loc[target],
            "consensus_days": _trailing_count(ce, lead, WEIGHT_DAYS).loc[target]}


def weights_from_error(err: pd.Series, present: pd.Series | None = None,
                       guardrails: bool = True) -> pd.Series:
    """Inverse-error weights among sources that have a forecast, with guardrails."""
    w = 1.0 / err
    if present is not None:
        w = w.where(present)
    w = w.where(np.isfinite(w))
    if w.notna().sum() == 0:
        return w
    w = w / w.sum()
    return apply_guardrails(w.to_frame().T).iloc[0] if guardrails else w


def blend(forecasts: pd.Series, habit_fix: pd.Series, mse: pd.Series,
          guardrails: bool = True) -> tuple[float, float, pd.Series]:
    """Consensus and spread for one day from today's forecasts and the stats.
    Matches temperature_consensus row by row."""
    fbc = forecasts - habit_fix.reindex(forecasts.index)
    w = weights_from_error(mse.reindex(forecasts.index), fbc.notna(), guardrails)
    if w.notna().sum() == 0:
        return float("nan"), float("nan"), w
    cons = float((fbc * w).sum())
    spread = float(np.sqrt((w * (fbc - cons).pow(2)).sum()))
    return cons, spread, w
