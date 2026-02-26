#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Capture idle CPU/memory budget for a fixed window.

Usage:
  idle_resources.sh [--output <path>] [--warmup <sec>] [--window <sec>] [--interval <sec>] [--repeat <n>]
                    [--enforce] [--max-cpu-core <float>] [--max-rss-mb <int>] [--max-footprint-mb <int>]
                    [--self-check]

Notes:
  - CPU is delta cumulative CPU time / wall time ("core" units)
  - Memory prefers vmmap "Physical footprint" when available; falls back to ps RSS
USAGE
}

OUTPUT_PATH="dist/hardening/idle_resources.json"
WARMUP_SEC=10
WINDOW_SEC=30
INTERVAL_SEC=1
REPEAT=2
ENFORCE=0

MAX_CPU_CORE="0.02"
MAX_RSS_MB=150
MAX_FOOTPRINT_MB=250

SELF_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_PATH="$2"; shift 2;;
    --warmup)
      WARMUP_SEC="$2"; shift 2;;
    --window)
      WINDOW_SEC="$2"; shift 2;;
    --interval)
      INTERVAL_SEC="$2"; shift 2;;
    --repeat)
      REPEAT="$2"; shift 2;;
    --enforce)
      ENFORCE=1; shift 1;;
    --max-cpu-core)
      MAX_CPU_CORE="$2"; shift 2;;
    --max-rss-mb)
      MAX_RSS_MB="$2"; shift 2;;
    --max-footprint-mb)
      MAX_FOOTPRINT_MB="$2"; shift 2;;
    --self-check)
      SELF_CHECK=1; shift 1;;
    --help|-h)
      usage; exit 0;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "Error: xcrun is required" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_SW="$SCRIPT_DIR/idle_harness.swift"

if [[ ! -f "$HARNESS_SW" ]]; then
  echo "Error: missing harness source: $HARNESS_SW" >&2
  exit 1
fi

if [[ "$SELF_CHECK" == "1" ]]; then
  WARMUP_SEC=1
  WINDOW_SEC=2
  INTERVAL_SEC=1
  REPEAT=1
  OUTPUT_PATH="/tmp/tokenmeter_idle_resources_selfcheck.json"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

HARNESS_BIN="$TMP_DIR/idle_harness"

echo "[idle] Building harness"
xcrun swiftc -O -whole-module-optimization "$HARNESS_SW" -o "$HARNESS_BIN"

parse_ps_time_to_seconds() {
  python3 - <<'PY'
import re
import sys

s = sys.stdin.read().strip()
m = re.match(r"^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$", s)
if not m:
    print("0")
    sys.exit(0)

days = int(m.group(1) or 0)
hours = int(m.group(2) or 0)
mins = int(m.group(3) or 0)
secs = int(m.group(4) or 0)
total = (((days * 24 + hours) * 60 + mins) * 60) + secs
print(str(total))
PY
}

read_cpu_time_seconds() {
  local pid="$1"
  local raw
  raw="$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -z "$raw" ]]; then
    echo "0"
    return
  fi
  printf '%s' "$raw" | parse_ps_time_to_seconds
}

read_rss_kb() {
  local pid="$1"
  local raw
  raw="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -z "$raw" ]]; then
    echo "0"
    return
  fi
  echo "$raw"
}

read_footprint_kb_vmmap() {
  local pid="$1"
  if ! command -v vmmap >/dev/null 2>&1; then
    echo ""
    return
  fi

  vmmap -summary "$pid" 2>/dev/null | python3 - <<'PY'
import re
import sys

text = sys.stdin.read()
m = re.search(r"Physical footprint:\s*([0-9.]+)\s*([KMG]?)", text)
if not m:
    sys.exit(0)

val = float(m.group(1))
unit = m.group(2)
mult = 1.0
if unit == "K":
    mult = 1.0
elif unit == "M":
    mult = 1024.0
elif unit == "G":
    mult = 1024.0 * 1024.0
kb = int(val * mult)
print(str(kb))
PY
}

machine_json() {
  python3 - <<'PY'
import json
import subprocess

def sh(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True).strip()
    except Exception:
        return ""

out = {
    "os": sh(["sw_vers"]),
    "uname": sh(["uname", "-a"]),
    "arch": sh(["uname", "-m"]),
    "hw_model": sh(["sysctl", "-n", "hw.model"]),
    "hw_ncpu": sh(["sysctl", "-n", "hw.ncpu"]),
    "hw_memsize": sh(["sysctl", "-n", "hw.memsize"]),
    "xcode": sh(["xcodebuild", "-version"]),
    "git": {
        "sha": sh(["git", "rev-parse", "HEAD"]),
        "describe": sh(["git", "describe", "--tags", "--always"]),
    },
}

print(json.dumps(out, sort_keys=True))
PY
}

iso_utc_now() {
  python3 - <<'PY'
import datetime
print(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z'))
PY
}

epoch_now() {
  python3 - <<'PY'
import time
print(str(time.time()))
PY
}

run_once() {
  local run_index="$1"

  "$HARNESS_BIN" &
  local pid="$!"
  if [[ -z "$pid" ]]; then
    echo "Error: failed to start harness" >&2
    exit 1
  fi

  local alive=1
  terminate_harness() {
    if [[ "$alive" == "1" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      alive=0
    fi
  }
  trap terminate_harness RETURN

  echo "[idle] Run $run_index PID=$pid warmup=${WARMUP_SEC}s window=${WINDOW_SEC}s" >&2

  sleep "$WARMUP_SEC"

  local cpu_start wall_start
  cpu_start="$(read_cpu_time_seconds "$pid")"
  wall_start="$(epoch_now)"

  local rss_kb_max footprint_kb_max
  rss_kb_max=0
  footprint_kb_max=0

  local i
  i=0
  while [[ "$i" -lt "$WINDOW_SEC" ]]; do
    local rss_kb
    rss_kb="$(read_rss_kb "$pid")"
    if [[ "$rss_kb" =~ ^[0-9]+$ ]] && [[ "$rss_kb" -gt "$rss_kb_max" ]]; then
      rss_kb_max="$rss_kb"
    fi

    local fp
    fp="$(read_footprint_kb_vmmap "$pid" || true)"
    if [[ -n "$fp" && "$fp" =~ ^[0-9]+$ ]] && [[ "$fp" -gt "$footprint_kb_max" ]]; then
      footprint_kb_max="$fp"
    fi

    sleep "$INTERVAL_SEC"
    i=$((i + INTERVAL_SEC))
    if [[ "$i" -gt "$WINDOW_SEC" ]]; then
      i="$WINDOW_SEC"
    fi
  done

  local cpu_end wall_end
  cpu_end="$(read_cpu_time_seconds "$pid")"
  wall_end="$(epoch_now)"

  terminate_harness
  trap - RETURN

  python3 - <<PY
import json

cpu_start = int(${cpu_start})
cpu_end = int(${cpu_end})
wall_start = float(${wall_start})
wall_end = float(${wall_end})

wall_s = max(0.001, wall_end - wall_start)
cpu_s = max(0, cpu_end - cpu_start)
cpu_core = cpu_s / wall_s

rss_kb_max = int(${rss_kb_max})
footprint_kb_max = int(${footprint_kb_max})

out = {
  "run_index": int(${run_index}),
  "wall_s": wall_s,
  "cpu_s": cpu_s,
  "avg_cpu_core": cpu_core,
  "rss_kb_max": rss_kb_max,
  "footprint_kb_max": footprint_kb_max if footprint_kb_max > 0 else None,
  "footprint_source": "vmmap" if footprint_kb_max > 0 else "unavailable",
}
print(json.dumps(out, sort_keys=True))
PY
}

RUNS_NDJSON="$TMP_DIR/runs.ndjson"
: >"$RUNS_NDJSON"

for ((n=1; n<=REPEAT; n++)); do
  run_once "$n" >>"$RUNS_NDJSON"
  printf '\n' >>"$RUNS_NDJSON"
done

runs_json="$(python3 - <<PY
import json
import sys

path = "$RUNS_NDJSON"
runs = []
with open(path, "r", encoding="utf-8") as f:
    for line in f.read().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            runs.append(json.loads(line))
        except Exception as e:
            sys.stderr.write("[idle] invalid JSON line in runs.ndjson\n")
            sys.stderr.write(repr(line) + "\n")
            sys.stderr.write(line.encode("utf-8", "backslashreplace").hex() + "\n")
            raise
print(json.dumps(runs, sort_keys=True))
PY
)"

report_time="$(iso_utc_now)"
machine="$(machine_json)"

MACHINE_JSON="$machine" RUNS_JSON="$runs_json" REPORT_TIME="$report_time" \
WARMUP_SEC="$WARMUP_SEC" WINDOW_SEC="$WINDOW_SEC" INTERVAL_SEC="$INTERVAL_SEC" REPEAT="$REPEAT" ENFORCE="$ENFORCE" \
MAX_CPU_CORE="$MAX_CPU_CORE" MAX_RSS_MB="$MAX_RSS_MB" MAX_FOOTPRINT_MB="$MAX_FOOTPRINT_MB" \
python3 - <<'PY' >"$OUTPUT_PATH"
import json
import os

machine = json.loads(os.environ["MACHINE_JSON"])
runs = json.loads(os.environ["RUNS_JSON"])

config = {
  "warmup_sec": int(os.environ["WARMUP_SEC"]),
  "window_sec": int(os.environ["WINDOW_SEC"]),
  "interval_sec": int(os.environ["INTERVAL_SEC"]),
  "repeat": int(os.environ["REPEAT"]),
  "mode": "enforce" if int(os.environ["ENFORCE"]) == 1 else "capture",
  "thresholds": {
    "max_cpu_core": float(os.environ["MAX_CPU_CORE"]),
    "max_rss_mb": int(os.environ["MAX_RSS_MB"]),
    "max_footprint_mb": int(os.environ["MAX_FOOTPRINT_MB"]),
  },
}

report = {
  "captured_at": os.environ["REPORT_TIME"],
  "machine": machine,
  "config": config,
  "runs": runs,
}

print(json.dumps(report, indent=2, sort_keys=True))
PY

echo "[idle] Wrote $OUTPUT_PATH"

if [[ "$ENFORCE" == "1" ]]; then
  python3 - <<PY
import json
import sys

with open("$OUTPUT_PATH", "r", encoding="utf-8") as f:
    report = json.load(f)

thr = report["config"]["thresholds"]
max_cpu = float(thr["max_cpu_core"])
max_rss_kb = int(thr["max_rss_mb"]) * 1024
max_fp_kb = int(thr["max_footprint_mb"]) * 1024

bad = []
for r in report["runs"]:
    cpu = float(r["avg_cpu_core"])
    rss = int(r["rss_kb_max"])
    fp = r.get("footprint_kb_max")

    if cpu > max_cpu:
        bad.append(("cpu", r["run_index"], cpu, max_cpu))
    if rss > max_rss_kb:
        bad.append(("rss_kb", r["run_index"], rss, max_rss_kb))
    if fp is not None and int(fp) > max_fp_kb:
        bad.append(("footprint_kb", r["run_index"], int(fp), max_fp_kb))

if bad:
    for kind, idx, got, limit in bad:
        print(f"[idle] FAIL {kind} run={idx} got={got} limit={limit}")
    sys.exit(1)

print("[idle] OK thresholds")
PY
fi

if [[ "$SELF_CHECK" == "1" ]]; then
  echo "[idle] self-check OK"
fi
