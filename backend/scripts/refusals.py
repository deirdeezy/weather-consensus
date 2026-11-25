"""Summarise the refusal log (data/store/refusals.jsonl) as Markdown.

Run from the repo root:
    uv run python backend/scripts/refusals.py                       # everything
    uv run python backend/scripts/refusals.py --since 2026-11-25T04:17:00Z

Used by the workflows for the run summary, and for the shadow-run count of
refused runs. Every failed try is one line in the log; kinds:
  limit      Open-Meteo refused the call (rate limit), retried
  network    no usable answer (reset, timeout, bad HTTP), retried
  gave_up    every retry failed: that run was not pulled this hour
  error      Open-Meteo answered with an error
  meta       model-update metadata could not be read
  used_stale a download failed and the last saved copy was used
  single_run an archived run Open-Meteo does not have
  publish    publish.py could not use something
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOG = ROOT / "data" / "store" / "refusals.jsonl"


def load(path: Path, since: str = "") -> list[dict]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("time", "") >= since:
            out.append(r)
    return out


def summary(recs: list[dict], since: str = "") -> str:
    head = f"### Refusals since {since}" if since else "### Refusals (whole log)"
    if not recs:
        return f"{head}\n\nNone.\n"
    by = Counter((r.get("kind", "?"), r.get("source", "?")) for r in recs)
    lines = [head, "", f"{len(recs)} logged.", "", "| Kind | Source | Count |", "|---|---|---|"]
    lines += [f"| {k} | {s} | {n} |" for (k, s), n in sorted(by.items())]
    last = recs[-1]
    lines += ["", f"Latest: {last.get('time')} {last.get('source')} {last.get('kind')}: "
                  f"{str(last.get('detail', ''))[:200]}", ""]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="", help="UTC time, YYYY-MM-DDTHH:MM:SSZ")
    ap.add_argument("--log", type=Path, default=LOG)
    args = ap.parse_args()
    print(summary(load(args.log, args.since), args.since))
    return 0


if __name__ == "__main__":
    sys.exit(main())
