#!/usr/bin/env bash
set -euo pipefail

# Check for secret-like plaintext in diagnostic artifacts.
# - Scans targeted directories for patterns that resemble credentials
# - Exits non-zero if any match is found
#

SCRIPT_NAME="$(basename "$0")"

#######################################
# Collect search directories
#######################################
search_dirs=()
if [ "${1-}" != "" ]; then
  search_dirs+=("$1")
else
  if [ -d "dist" ]; then
    search_dirs+=("dist")
  fi
  if [ -d ".sisyphus/evidence" ]; then
    search_dirs+=(".sisyphus/evidence")
  fi
fi

# If still empty, default to current directory tree
if [ "${#search_dirs[@]}" -eq 0 ]; then
  search_dirs+=(".")
fi

#######################################
# Evidence directory (optional)
#######################################
_evidence_dir=""
if [ -n "${2-}" ]; then
  _evidence_dir="$2"
fi
if [ -n "${_evidence_dir}" ]; then
  mkdir -p "${_evidence_dir}" 2>/dev/null || true
fi

#######################################
# Patterns to detect secret-like content
#######################################
# Extended regex (grep -E). Kept free of \b and non-bracket classes: BSD grep
# on macOS and GNU grep on Linux must both parse it, and a pattern grep
# rejects would otherwise read as "no match" (see the exit-code check below).
patterns="Authorization[[:space:]]*:?[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._~+/=-]+|Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}|BEGIN( [A-Z]+)? PRIVATE KEY|AIza[A-Za-z0-9_-]{35,}|sk-ant-[A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|api[_-]?key[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._-]+|access[_-]?token[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._-]+|refresh[_-]?token[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._-]+|password[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._-]+"

matches=0
declare -a matched_files

report_file=""
if [ -n "${_evidence_dir}" ]; then
  report_file="${_evidence_dir}/check_redaction_report.txt"
fi

printf "Redaction check: scanning directories: %s\n" "${search_dirs[*]}"

# A pattern grep cannot parse, or a file it cannot read, exits 2; that must
# fail the check rather than count as "nothing found".
scanned_files=0
for dir in "${search_dirs[@]}"; do
  if [ ! -d "$dir" ]; then
    echo "FAIL: directory not found: $dir" >&2
    exit 2
  fi
  while IFS= read -r -d '' f; do
    scanned_files=$((scanned_files+1))
    set +e
    grep -I -i -E -q "$patterns" "$f"
    grep_rc=$?
    set -e
    case "$grep_rc" in
      0)
        matches=$((matches+1))
        matched_files+=("$f")
        ;;
      1)
        ;;
      *)
        echo "FAIL: grep exited $grep_rc on $f (invalid pattern or unreadable file)" >&2
        exit 2
        ;;
    esac
  done < <(find "$dir" -type f -print0)
done

printf "Redaction check: scanned %d file(s)\n" "$scanned_files"

if [ "${matches}" -gt 0 ]; then
  echo "FAIL: Detected secret-like plaintext in ${matches} file(s)."
  for mf in "${matched_files[@]}"; do
    echo "  - ${mf}"
  done
  if [ -n "$report_file" ]; then
    printf "Matches (files):\n" > "$report_file"
    for mf in "${matched_files[@]}"; do
      printf "%s\n" "$mf" >> "$report_file"
    done
  fi
  exit 1
else
  echo "PASS: No secret-like plaintext detected."
  if [ -n "$report_file" ]; then
    echo "No matches" > "$report_file"
  fi
  exit 0
fi
