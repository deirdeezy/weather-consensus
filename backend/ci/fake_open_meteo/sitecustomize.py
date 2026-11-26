"""Test aid for backend/ci/local_test.sh only: a stand-in Open-Meteo refusal.

Python loads this file at start-up only when this folder is on PYTHONPATH.
With WXC_FAKE_OPEN_METEO set, Open-Meteo calls (any *.open-meteo.com host
except the free metadata files) are answered locally, without a network call:
  daily      HTTP 429 "Daily API request limit exceeded" (as on 25 Nov 2026)
  gone-runs  Single Runs answer "The requested model run is not available"
             (an expected gap); other calls go out as normal
Never set in the workflows.
"""
import io
import json
import os
import urllib.error
import urllib.request
from email.message import Message

MODE = os.environ.get("WXC_FAKE_OPEN_METEO", "")

if MODE:
    _real = urllib.request.urlopen

    def _answer(url, code, reason):
        h = Message()
        if code == 429:
            h["Retry-After"] = "15000"
        body = io.BytesIO(json.dumps({"error": True, "reason": reason}).encode())
        raise urllib.error.HTTPError(url, code, reason, h, body)

    def urlopen(url, *a, **k):
        u = url if isinstance(url, str) else url.full_url
        if ".open-meteo.com/" in u and "/static/meta.json" not in u:
            if MODE == "daily":
                _answer(u, 429, "Daily API request limit exceeded. Please try again tomorrow.")
            if MODE == "gone-runs" and "single-runs-api" in u:
                _answer(u, 400, "The requested model run is not available.")
        return _real(url, *a, **k)

    urllib.request.urlopen = urlopen
    print(f"[fake Open-Meteo: {MODE}]")
