#!/usr/bin/env python3

import argparse
import os
import re
import sys
from dataclasses import dataclass
from typing import List, Optional, Sequence


@dataclass(frozen=True)
class Check:
    file_path: str
    name: str
    pattern: str
    expected: str


CHECKS: List[Check] = [
    Check(
        file_path=os.path.join("TokenMeter", "Settings", "AppSettings.swift"),
        name="default_refresh_interval_sec",
        pattern=r"refreshIntervalSec:\s*Int\s*=\s*(\d+)",
        expected="60",
    ),
    Check(
        file_path=os.path.join("TokenMeter", "Orchestration", "AppRuntime.swift"),
        name="runtime_timeout_ns",
        pattern=r"let\s+timeoutNs:\s*UInt64\s*=\s*([0-9]+)\s*\*\s*1_000_000_000",
        expected="2",
    ),
    Check(
        file_path=os.path.join(
            "TokenMeter", "Orchestration", "CollectionOrchestrator.swift"
        ),
        name="default_backoff_base_seconds",
        pattern=r"CollectionBackoffPolicy\(baseNanoseconds:\s*([0-9]+)\s*\*\s*1_000_000_000",
        expected="2",
    ),
    Check(
        file_path=os.path.join(
            "TokenMeter", "Orchestration", "CollectionOrchestrator.swift"
        ),
        name="default_backoff_max_minutes",
        pattern=r"maxNanoseconds:\s*([0-9]+)\s*\*\s*60\s*\*\s*1_000_000_000",
        expected="5",
    ),
    Check(
        file_path=os.path.join("TokenMeter", "Diagnostics", "DiagnosticsStore.swift"),
        name="diagnostics_default_max_events_per_provider",
        pattern=r"init\(\s*\n\s*maxEventsPerProvider:\s*Int\s*=\s*(\d+)",
        expected="1000",
    ),
]


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def run_check(check: Check, repo_root: str) -> Optional[str]:
    abs_path = os.path.join(repo_root, check.file_path)
    if not os.path.exists(abs_path):
        return f"missing file: {check.file_path}"
    text = read_text(abs_path)
    m = re.search(check.pattern, text, flags=re.MULTILINE)
    if not m:
        return f"pattern not found: {check.name} ({check.file_path})"
    got = m.group(1)
    if got != check.expected:
        return f"{check.name} expected {check.expected} got {got} ({check.file_path})"
    return None


def main(argv: Sequence[str]) -> int:
    ap = argparse.ArgumentParser(prog="validate_runtime_tuning.py")
    ap.add_argument("--repo-root", default=os.getcwd())
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args(list(argv))

    failures: List[str] = []
    for c in CHECKS:
        err = run_check(c, args.repo_root)
        if err:
            failures.append(err)

    if failures:
        print(f"[tuning] FAIL count={len(failures)}")
        for f in failures:
            print(f"[tuning] {f}")
        return 1

    if args.self_check:
        print("[tuning] self-check OK")
    else:
        print("[tuning] OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
