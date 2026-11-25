import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from wxc import certainty as cert  # noqa: E402
from wxc import consensus as cs  # noqa: E402
from wxc.daily import hourly_to_daily  # noqa: E402


def test_guardrails_sum_to_one_and_respect_limits():
    w = pd.DataFrame([[0.9, 0.05, 0.03, 0.02, np.nan], [0.2, 0.2, 0.2, 0.2, 0.2]],
                     columns=list("abcde"))
    g = cs.apply_guardrails(w, floor=0.02, cap=0.35)
    assert np.allclose(g.sum(axis=1), 1.0)
    assert (g.max(axis=1) <= 0.35 + 1e-9).all()
    assert np.isnan(g.loc[0, "e"])  # missing source stays missing


def test_identical_sources_give_that_value():
    dates = pd.date_range("2026-01-01", periods=120).date
    truth = pd.Series(np.sin(np.arange(120) / 9) * 5, index=dates)
    F = pd.DataFrame({m: truth + 1.0 for m in "abc"})  # all 1 deg warm
    out = cs.temperature_consensus(F, truth, lead=1)
    late = out.consensus.dropna().iloc[-30:]
    assert np.allclose(late, truth.loc[late.index], atol=1e-9)  # habit fix removes the +1


def test_certainty_falls_as_error_grows():
    p = cert.certainty(pd.Series([0.5, 1.0, 2.0, 4.0]))
    assert p.is_monotonic_decreasing
    assert 0 < p.iloc[-1] < p.iloc[0] < 1


def test_certainty_tiers():
    assert cert.tier(0.80) == "High" and cert.tier(0.60) == "Medium" and cert.tier(0.30) == "Low"


def test_daily_needs_22_hours():
    times = pd.date_range("2026-01-01T06:00", periods=48, freq="h")
    temp = [float(i) for i in range(48)]
    temp[30] = None
    d = hourly_to_daily(times, temp, offset_h=-6)
    assert len(d) == 2 and d.tmax.notna().all()
    temp2 = list(temp)
    for i in range(24, 27):
        temp2[i] = None
    d2 = hourly_to_daily(times, temp2, offset_h=-6)
    assert d2.tmax.isna().sum() == 1


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
