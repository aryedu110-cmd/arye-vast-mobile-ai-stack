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


def extract_balance(payload: dict) -> Decimal:
    """Accept both current Vast API naming and the legacy field."""
    value = payload.get("balance", payload.get("credit"))
    if value is None:
        raise KeyError("balance")
    return Decimal(str(value))


def stop(reason: str) -> None:
    subprocess.run(["/opt/arye-production/self_stop.sh", reason], check=False, timeout=120)
    raise SystemExit(0)


def decimal_setting(name: str, *, default: str | None = None) -> Decimal:
    value = os.environ.get(name, default)
    if value is None:
        raise SystemExit(f"{name.lower()}_required")
    try:
        parsed = Decimal(value)
    except InvalidOperation:
        raise SystemExit(f"valid_{name.lower()}_required") from None
    if not parsed.is_finite() or parsed < 0:
        raise SystemExit(f"valid_{name.lower()}_required")
    return parsed


def estimated_credit(starting: Decimal, hourly_rate: Decimal, elapsed_seconds: float, bandwidth_reserve: Decimal) -> Decimal:
    runtime_cost = hourly_rate * Decimal(str(elapsed_seconds)) / Decimal("3600")
    return starting - bandwidth_reserve - runtime_cost


def write_status(payload: dict[str, object]) -> None:
    temporary = STATE_DIR / "balance-status.json.tmp"
    temporary.write_text(json.dumps(payload) + "\n", encoding="utf-8")
    os.replace(temporary, STATE_DIR / "balance-status.json")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-once", action="store_true")
    args = parser.parse_args()
    # Vast's injected CONTAINER_API_KEY can stop its own instance but is not
    # authorized to read account credit. Use a separately supplied read token
    # when available; otherwise enforce a conservative, pre-approved budget.
    token = os.environ.get("VAST_BALANCE_API_KEY", "").strip()
    threshold = decimal_setting("BALANCE_STOP_USD")
    starting = decimal_setting("APPROVED_STARTING_BALANCE_USD") if not token else Decimal("0")
    hourly_rate = decimal_setting("INSTANCE_HOURLY_RATE_USD") if not token else Decimal("0")
    bandwidth_reserve = decimal_setting("BANDWIDTH_RESERVE_USD", default="1.50") if not token else Decimal("0")
    if threshold <= 0 or INTERVAL < 30 or MAX_FAILURES < 1:
        raise SystemExit("invalid_balance_watchdog_settings")
    if not token and (starting <= 0 or hourly_rate <= 0):
        raise SystemExit("valid_static_budget_inputs_required")
    if not token and estimated_credit(starting, hourly_rate, 0, bandwidth_reserve) <= threshold:
        raise SystemExit("insufficient_approved_starting_budget")
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not token:
        started = time.monotonic()
        while True:
            elapsed = time.monotonic() - started
            credit = estimated_credit(starting, hourly_rate, elapsed, bandwidth_reserve)
            write_status({"ok": True, "mode": "conservative_static_budget", "estimated_credit_usd": str(credit), "stop_threshold_usd": str(threshold), "bandwidth_reserve_usd": str(bandwidth_reserve), "checked_at": int(time.time())})
            if credit <= threshold:
                stop("estimated_balance_reserve_reached")
            if args.check_once:
                return
            time.sleep(INTERVAL)

    failures = 0
    while True:
        request = urllib.request.Request(
            "https://console.vast.ai/api/v0/users/current/",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                payload = json.load(response)
            credit = extract_balance(payload)
            failures = 0
            write_status({"ok": True, "mode": "live_vast_balance", "credit_usd": str(credit), "stop_threshold_usd": str(threshold), "checked_at": int(time.time())})
            if credit <= threshold:
                stop("balance_reserve_reached")
            if args.check_once:
                return
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError, InvalidOperation, json.JSONDecodeError) as exc:
            failures += 1
            (STATE_DIR / "balance-status.json").write_text(json.dumps({"ok": False, "consecutive_failures": failures, "checked_at": int(time.time()), "error_type": type(exc).__name__}) + "\n", encoding="utf-8")
            if failures >= MAX_FAILURES:
                if args.check_once:
                    raise SystemExit("balance_monitor_unavailable") from None
                stop("balance_monitor_unavailable")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
