#!/usr/bin/env python3
"""Stop the instance before Vast credit reaches the approved reserve."""
from __future__ import annotations

import json
import argparse
import os
import subprocess
import time
import urllib.error
import urllib.request
from decimal import Decimal, InvalidOperation
from pathlib import Path

STATE_DIR = Path(os.environ.get("ARYE_STATE_DIR", "/workspace/arye-production/state"))
INTERVAL = int(os.environ.get("BALANCE_POLL_SECONDS", "60"))
MAX_FAILURES = int(os.environ.get("BALANCE_MAX_FAILURES", "3"))


def stop(reason: str) -> None:
    subprocess.run(["/opt/arye-production/self_stop.sh", reason], check=False, timeout=120)
    raise SystemExit(0)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-once", action="store_true")
    args = parser.parse_args()
    token = os.environ.get("VAST_BALANCE_API_KEY") or os.environ.get("CONTAINER_API_KEY")
    if not token:
        raise SystemExit("balance_api_key_missing")
    try:
        threshold = Decimal(os.environ["BALANCE_STOP_USD"])
    except (KeyError, InvalidOperation):
        raise SystemExit("valid_balance_stop_usd_required") from None
    if threshold <= 0 or INTERVAL < 30 or MAX_FAILURES < 1:
        raise SystemExit("invalid_balance_watchdog_settings")
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    failures = 0
    while True:
        request = urllib.request.Request(
            "https://console.vast.ai/api/v0/users/current/",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                payload = json.load(response)
            credit = Decimal(str(payload["credit"]))
            failures = 0
            temporary = STATE_DIR / "balance-status.json.tmp"
            temporary.write_text(json.dumps({"ok": True, "credit_usd": str(credit), "stop_threshold_usd": str(threshold), "checked_at": int(time.time())}) + "\n", encoding="utf-8")
            os.replace(temporary, STATE_DIR / "balance-status.json")
            if credit <= threshold:
                stop("balance_reserve_reached")
            if args.check_once:
                return
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError, json.JSONDecodeError) as exc:
            failures += 1
            (STATE_DIR / "balance-status.json").write_text(json.dumps({"ok": False, "consecutive_failures": failures, "checked_at": int(time.time()), "error_type": type(exc).__name__}) + "\n", encoding="utf-8")
            if failures >= MAX_FAILURES:
                if args.check_once:
                    raise SystemExit("balance_monitor_unavailable") from None
                stop("balance_monitor_unavailable")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
