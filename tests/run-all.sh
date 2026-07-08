#!/usr/bin/env bash
# run-all.sh — run every tests/test-*.sh, summarize. Exit 1 if any FAIL.
# SKIP (missing tools) is not a failure.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

pass=0 fail=0 skip=0
for t in test-*.sh; do
  [ -f "$t" ] || continue
  out="$(bash "$t" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi '^SKIP'; then
    echo "SKIP $t"; skip=$((skip+1))
  elif [ "$rc" -eq 0 ]; then
    echo "PASS $t"; pass=$((pass+1))
  else
    echo "FAIL $t"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail+1))
  fi
done
echo "──────── $pass passed, $fail failed, $skip skipped ────────"
[ "$fail" -eq 0 ]
