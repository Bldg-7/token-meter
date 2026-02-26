#!/usr/bin/env bash
set -euo pipefail

# check_idle_budget.sh
# Samples CPU and RSS usage for a running process over a window and verifies average against thresholds.
# Usage (positional args):
#   $0 [process_name] [duration_seconds] [sample_interval_seconds] [max_avg_cpu_percent] [max_avg_rss_mb]
# Defaults:
#   process_name: TokenMeter
#   duration_seconds: 60
#   sample_interval_seconds: 1
#   max_avg_cpu_percent: 50
#   max_avg_rss_mb: 500
# Exit codes:
#   0 - pass
#   1 - budget breach
#   2 - runtime/usage error
#
process_name="${1:-TokenMeter}"
duration="${2:-60}"
interval="${3:-1}"
max_cpu="${4:-50}"
max_rss_mb="${5:-500}"

#!/bin/bash
#######################################
# Basic validation
#######################################
if ! [[ "$duration" =~ ^[0-9]+$ && "$interval" =~ ^[0-9]+$ && "$duration" -ge 0 && "$interval" -gt 0 ]]; then
  echo "Error: duration and interval must be positive integers." >&2
  exit 2
fi

#######################################
# Internal helpers
#######################################
get_pids() {
  # Collect PIDs by exact command name match using common macOS ps fields.
  local pids
  pids=$(ps -axo pid,comm | awk -v name="$process_name" '$2==name {print $1}')
  if [ -n "$pids" ]; then
    echo "$pids"
    return 0
  fi
  # If not found by exact command name, do not fall back to command-line matching to avoid
  # false positives from shell wrappers or arguments. Still return success so the caller can
  # handle the not-found path explicitly and exit with code 2.
  echo ""
  return 0
}

elapsed=0
samples=0
sum_cpu=0
sum_rss=0

while [ "$elapsed" -lt "$duration" ]; do
  pids=$(get_pids)
  if [ -z "$pids" ]; then
    echo "Error: process '$process_name' not found for sampling at sample $samples." >&2
    exit 2
  fi

  local_cpu_sum=0
  local_rss_sum=0
  local_count=0

  for pid in $pids; do
    cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | awk '{print $1+0}')
    rss_kb=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{print $1+0}')
    if [ -n "$cpu" ] && [ -n "$rss_kb" ]; then
      local_cpu_sum=$(awk "BEGIN{printf \"%.3f\", ${local_cpu_sum}+${cpu}}")
      local_rss_sum=$(awk "BEGIN{printf \"%.0f\", ${local_rss_sum}+${rss_kb}}")
      local_count=$((local_count+1))
    fi
  done

  if [ "$local_count" -gt 0 ]; then
    avg_cpu=$(awk "BEGIN{printf \"%.3f\", ${local_cpu_sum}/${local_count}}")
    avg_rss_mb=$(awk "BEGIN{printf \"%.2f\", ${local_rss_sum}/1024/${local_count}}")
  else
    avg_cpu=0
    avg_rss_mb=0
  fi

  sum_cpu=$(awk "BEGIN{printf \"%.3f\", ${sum_cpu}+${avg_cpu}}")
  sum_rss=$(awk "BEGIN{printf \"%.2f\", ${sum_rss}+${avg_rss_mb}}")
  samples=$((samples+1))
  elapsed=$((samples * interval))

  if [ "$elapsed" -lt "$duration" ]; then
    sleep "$interval" &
    wait $!
  fi
done

if [ "$samples" -gt 0 ]; then
  avg_cpu_final=$(awk "BEGIN{printf \"%.3f\", ${sum_cpu}/${samples}}")
  avg_rss_final=$(awk "BEGIN{printf \"%.2f\", ${sum_rss}/${samples}}")
else
  avg_cpu_final=0
  avg_rss_final=0
fi

cpu_breach=$(awk -v a="$avg_cpu_final" -v b="$max_cpu" 'BEGIN{print (a>b)?1:0}')
rss_breach=$(awk -v a="$avg_rss_final" -v b="$max_rss_mb" 'BEGIN{print (a>b)?1:0}')

if [ "$cpu_breach" -eq 1 ] || [ "$rss_breach" -eq 1 ]; then
  verdict="BREACH"
  exit_code=1
else
  verdict="PASS"
  exit_code=0
fi

printf "Process: %s | Samples: %d | Avg CPU: %.3f%% | Avg RSS: %.2f MB | Thresholds -> CPU<=%s%%, RSS<=%sMB | Verdict: %s\n" \
  "$process_name" "$samples" "$avg_cpu_final" "$avg_rss_final" "$max_cpu" "$max_rss_mb" "$verdict"

exit "$exit_code"
