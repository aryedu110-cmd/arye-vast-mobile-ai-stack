#!/usr/bin/env python3
"""Record the human content/continuity decision without regenerating a shot."""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("job_id")
    parser.add_argument("decision", choices=("accept", "reject"))
    parser.add_argument("--notes", required=True)
    parser.add_argument("--ledger", type=Path, default=Path(os.environ.get("ARYE_STATE_DIR", "/workspace/arye-production/state")) / "queue-ledger.json")
    args = parser.parse_args()
    if len(args.notes) > 4000:
        raise SystemExit("review_notes_too_long")
    ledger = json.loads(args.ledger.read_text(encoding="utf-8"))
    job = ledger.get("jobs", {}).get(args.job_id)
    if not job:
        raise SystemExit("job_not_found")
    if job.get("status") != "machine_qc_passed":
        raise SystemExit("job_not_awaiting_manual_qc")
    job["status"] = "accepted_manual_qc" if args.decision == "accept" else "rejected_content"
    job["manual_review"] = {"decision": args.decision, "notes": args.notes, "at": int(time.time())}
    temporary = args.ledger.with_suffix(".tmp")
    temporary.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, args.ledger)
    print(job["status"])


if __name__ == "__main__":
    main()
