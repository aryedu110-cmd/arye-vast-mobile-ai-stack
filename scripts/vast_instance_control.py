#!/usr/bin/env python3
"""Safely control only the Vast instance that is running this script."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request


API_BASE = "https://console.vast.ai/api/v0"


def _instance_credentials() -> tuple[str, str]:
    instance_id = os.environ.get("CONTAINER_ID", "").strip()
    api_key = os.environ.get("CONTAINER_API_KEY", "").strip()
    if not re.fullmatch(r"[0-9]+", instance_id):
        raise RuntimeError("CONTAINER_ID is missing or invalid")
    if not api_key:
        raise RuntimeError("CONTAINER_API_KEY is missing")
    return instance_id, api_key


def _request_instance(method: str, data: dict | None = None, timeout: int = 20) -> dict:
    instance_id, api_key = _instance_credentials()
    request = urllib.request.Request(
        f"{API_BASE}/instances/{instance_id}/",
        data=json.dumps(data).encode("utf-8") if data is not None else None,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "arye-vast-mobile-ai-stack/1.2",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Vast instance request failed with HTTP {exc.code}: {body[:500]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Vast stop request could not connect: {exc.reason}") from exc

    try:
        result = json.loads(body)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Vast returned an invalid response: {body[:500]}") from exc
    if result.get("success") is not True:
        raise RuntimeError(f"Vast did not confirm the instance request: {result}")
    return result


def stop_instance(timeout: int = 20) -> dict:
    return _request_instance("PUT", {"state": "stopped"}, timeout)


def destroy_instance(confirmation_id: str, timeout: int = 20) -> dict:
    instance_id, _ = _instance_credentials()
    if confirmation_id.strip() != instance_id:
        raise RuntimeError("destroy confirmation must exactly match CONTAINER_ID")
    return _request_instance("DELETE", timeout=timeout)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["stop", "destroy"])
    parser.add_argument("--delay-seconds", type=int, default=0)
    parser.add_argument("--reason", default="unspecified")
    parser.add_argument("--confirm-instance-id", default="")
    parser.add_argument("--max-attempts", type=int, default=5)
    parser.add_argument("--retry-delay-seconds", type=int, default=30)
    args = parser.parse_args()
    if args.delay_seconds < 0:
        parser.error("--delay-seconds cannot be negative")
    if args.max_attempts < 1 or args.retry_delay_seconds < 0:
        parser.error("retry settings are invalid")

    print(
        f"Vast instance {args.action} armed: delay={args.delay_seconds}s reason={args.reason}",
        flush=True,
    )
    if args.delay_seconds:
        time.sleep(args.delay_seconds)
    for attempt in range(1, args.max_attempts + 1):
        try:
            if args.action == "destroy":
                result = destroy_instance(args.confirm_instance_id)
            else:
                result = stop_instance()
            print(
                f"Vast confirmed instance {args.action}: success={result.get('success')}",
                flush=True,
            )
            return 0
        except Exception as exc:
            print(
                f"Vast {args.action} attempt {attempt}/{args.max_attempts} failed: {exc}",
                file=sys.stderr,
                flush=True,
            )
            if attempt == args.max_attempts:
                raise
            time.sleep(args.retry_delay_seconds)
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
