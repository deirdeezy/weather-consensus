"""Certainty: the chance the day's high lands within 2 deg C of our number.

Model: error ~ Normal(0, sigma), sigma = SIGMA_PER_MAE x recent consensus MAE
at that lead, widened gently when sources disagree more than usual.

Evidence (Kitimat pilot, Jan to Oct 2026, leads 1 to 7, highs):
- With the disagreement term: said 73% on average, came true 74%.
  Days rated 70 to 80% came true 76%.
- 1.25 is slightly cautious (says 2 to 5 points less than happens at
  leads 1 to 3). 1.15 to 1.2 fit a little better in-sample; kept 1.25
  because cautious is the safer direction and the gain was tiny.
- Disagreement exponent 0.25: small improvement (Brier highs 0.1796 to
  0.1792, lows 0.1427 to 0.1388). Exponent 0.5 made highs worse.
- Limitation: within a lead day, Certainty barely beats a fixed per-lead
  rate. It is honest on average but does not yet pick out shaky days well.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

TOLERANCE_C = 2.0
SIGMA_PER_MAE = 1.25
SPREAD_EXP = 0.25
TIERS = ((0.75, "High"), (0.50, "Medium"), (0.0, "Low"))


def certainty(mae: pd.Series, spread: pd.Series | None = None,
              spread_ref: pd.Series | None = None) -> pd.Series:
    sigma = SIGMA_PER_MAE * mae
    if spread is not None and spread_ref is not None:
        ratio = (spread / spread_ref).where(spread_ref > 0)
        sigma = sigma * ratio.fillna(1.0).pow(SPREAD_EXP)
    z = TOLERANCE_C / (sigma * math.sqrt(2))
    return z.map(lambda v: math.erf(v) if np.isfinite(v) and v > 0 else np.nan)


def tier(p: float) -> str:
    for threshold, name in TIERS:
        if p >= threshold:
            return name
    return "Low"
