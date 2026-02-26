#!/usr/bin/env python3

import argparse
import dataclasses
import hashlib
import json
import os
import re
import sys
import tempfile
from typing import Iterable, List, Sequence, Tuple


@dataclasses.dataclass(frozen=True)
class Pattern:
    pattern_id: str
    regex: re.Pattern


PATTERNS: List[Pattern] = [
    Pattern("aws_access_key_id_akia", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    Pattern("aws_access_key_id_asia", re.compile(r"\bASIA[0-9A-Z]{16}\b")),
    Pattern("github_token_ghp", re.compile(r"\bghp_[A-Za-z0-9]{36}\b")),
    Pattern("github_token_gho", re.compile(r"\bgho_[A-Za-z0-9]{36}\b")),
    Pattern("github_token_ghu", re.compile(r"\bghu_[A-Za-z0-9]{36}\b")),
    Pattern("github_token_ghs", re.compile(r"\bghs_[A-Za-z0-9]{36}\b")),
    Pattern("github_pat", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{80,120}\b")),
    Pattern("gitlab_pat", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}\b")),
    Pattern("slack_token_xox", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{10,}\b")),
    Pattern("slack_token_xapp", re.compile(r"\bxapp-[0-9A-Za-z-]{10,}\b")),
    Pattern("stripe_secret_key", re.compile(r"\bsk_(live|test)_[0-9a-zA-Z]{20,}\b")),
    Pattern(
        "stripe_restricted_key", re.compile(r"\brk_(live|test)_[0-9a-zA-Z]{20,}\b")
    ),
    Pattern("google_api_key", re.compile(r"\bAIza[0-9A-Za-z\-_]{35}\b")),
    Pattern("twilio_secret", re.compile(r"\bSK[0-9a-fA-F]{32}\b")),
    Pattern("twilio_account_sid", re.compile(r"\bAC[0-9a-fA-F]{32}\b")),
    Pattern(
        "generic_assignment",
        re.compile(
            r"(?i)\b(password|passwd|pwd|secret|api[_-]?key|access[_-]?token)\b\s*[:=]\s*['\"][^'\"\n]{8,}['\"]"
        ),
    ),
]

PRIVATE_KEY_BEGIN_PATTERNS: List[str] = [
    "-----BEGIN PRIVATE KEY-----",
    "-----BEGIN RSA PRIVATE KEY-----",
    "-----BEGIN EC PRIVATE KEY-----",
    "-----BEGIN DSA PRIVATE KEY-----",
    "-----BEGIN OPENSSH PRIVATE KEY-----",
]


@dataclasses.dataclass(frozen=True)
class Finding:
    file_path: str
    line: int
    pattern_id: str
    match_preview: str
    match_len: int
    finding_id: str


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def preview(value: str) -> str:
    v = value.strip()
    if len(v) <= 8:
        return "<redacted>"
    return f"{v[:4]}...{v[-4:]}"


def load_allowlist(path: str) -> Tuple[List[str], set]:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    exclude = [str(x) for x in data.get("exclude_dir_prefixes", [])]
    allowed = set(str(x) for x in data.get("allowlisted_finding_ids", []))
    return exclude, allowed


def is_excluded(rel_path: str, exclude_dir_prefixes: Sequence[str]) -> bool:
    normalized = rel_path.replace("\\", "/")
    for prefix in exclude_dir_prefixes:
        if normalized.startswith(prefix):
            return True
    return False


def iter_files(
    paths: Sequence[str], exclude_dir_prefixes: Sequence[str]
) -> Iterable[Tuple[str, str]]:
    cwd = os.getcwd()

    def rel(p: str) -> str:
        try:
            return os.path.relpath(p, cwd)
        except Exception:
            return p

    for p in paths:
        if not os.path.exists(p):
            continue
        if os.path.isfile(p):
            rp = rel(p)
            if not is_excluded(rp, exclude_dir_prefixes):
                yield p, rp
            continue

        for root, dirs, files in os.walk(p):
            rp_root = rel(root)
            if is_excluded(rp_root + "/", exclude_dir_prefixes):
                dirs[:] = []
                continue

            dirs[:] = [
                d
                for d in dirs
                if not is_excluded(
                    rel(os.path.join(root, d)) + "/", exclude_dir_prefixes
                )
            ]
            for name in files:
                full = os.path.join(root, name)
                rp = rel(full)
                if is_excluded(rp, exclude_dir_prefixes):
                    continue
                yield full, rp


def scan_text(rel_path: str, text: str) -> List[Finding]:
    findings: List[Finding] = []
    lines = text.splitlines()

    for idx, line in enumerate(lines, start=1):
        for begin in PRIVATE_KEY_BEGIN_PATTERNS:
            if begin in line:
                fid = sha256_hex(f"{rel_path}:{idx}:{begin}")
                findings.append(
                    Finding(
                        file_path=rel_path,
                        line=idx,
                        pattern_id="private_key_block",
                        match_preview=preview(begin),
                        match_len=len(begin),
                        finding_id=fid,
                    )
                )

        for pat in PATTERNS:
            for m in pat.regex.finditer(line):
                match = m.group(0)
                fid = sha256_hex(f"{rel_path}:{idx}:{match}")
                findings.append(
                    Finding(
                        file_path=rel_path,
                        line=idx,
                        pattern_id=pat.pattern_id,
                        match_preview=preview(match),
                        match_len=len(match),
                        finding_id=fid,
                    )
                )

    return findings


def scan_paths(paths: Sequence[str], allowlist_path: str) -> List[Finding]:
    exclude_dir_prefixes, allowed = load_allowlist(allowlist_path)
    out: List[Finding] = []

    for full, rel_path in iter_files(paths, exclude_dir_prefixes):
        try:
            with open(full, "rb") as f:
                raw = f.read()
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                continue
        except Exception:
            continue

        for finding in scan_text(rel_path, text):
            if finding.finding_id in allowed:
                continue
            out.append(finding)

    return out


def cmd_self_check(allowlist: str) -> int:
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "sample.ndjson")
        fake = "ghp_" + ("a" * 36)
        with open(p, "w", encoding="utf-8") as f:
            f.write(json.dumps({"message": f"Authorization: Bearer {fake}"}) + "\n")

        findings = scan_paths([p], allowlist)
        if not findings:
            print("[secret-scan] self-check FAIL: expected a finding")
            return 1
        for fd in findings:
            if fake in fd.match_preview:
                print("[secret-scan] self-check FAIL: preview leaked full token")
                return 1
        print("[secret-scan] self-check OK")
        return 0


def main(argv: Sequence[str]) -> int:
    ap = argparse.ArgumentParser(prog="secret_scan.py")
    ap.add_argument(
        "paths", nargs="*", default=["dist"], help="Files or directories to scan"
    )
    ap.add_argument(
        "--allowlist",
        default=os.path.join("scripts", "hardening", "secret_scan_allowlist.json"),
        help="Allowlist JSON path",
    )
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args(list(argv))

    if not os.path.exists(args.allowlist):
        print(f"Error: allowlist not found: {args.allowlist}", file=sys.stderr)
        return 2

    if args.self_check:
        return cmd_self_check(args.allowlist)

    findings = scan_paths(args.paths, args.allowlist)
    if not findings:
        print("[secret-scan] OK")
        return 0

    print(f"[secret-scan] FAIL findings={len(findings)}")
    for f in findings[:200]:
        print(
            f"{f.file_path}:{f.line}: {f.pattern_id} id={f.finding_id} len={f.match_len} preview={f.match_preview}"
        )
    if len(findings) > 200:
        print(f"[secret-scan] (truncated, total findings={len(findings)})")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
