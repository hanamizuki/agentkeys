#!/usr/bin/env bash
# agentkeys status — show last sync time, commit, staleness, errors.
#
# Reads ~/.secrets/.sync-state and ~/.secrets/.sync-error (or the dir passed
# via --secrets-dir). If a keyvault is locatable, compares the synced commit
# against the keyvault's current HEAD to flag staleness.
set -euo pipefail

# shellcheck source=lib/common.sh
source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/common.sh"

usage() {
  cat <<EOF
Usage: agentkeys status [--secrets-dir DIR] [--json]

Show the local sync state: last sync time, commit, files written, errors.

OPTIONS:
  --secrets-dir DIR   Override (default: \$AGENTKEYS_SECRETS or ~/.secrets)
  --json              Emit raw .sync-state JSON instead of pretty output
  -h, --help

ENV:
  AGENTKEYS_KEYVAULT  Override keyvault location for staleness check
  AGENTKEYS_SECRETS   Override secrets dir
EOF
}

emit_json=0
secrets_dir="${AGENTKEYS_SECRETS:-$HOME/.secrets}"
while [ $# -gt 0 ]; do
  case "$1" in
    --secrets-dir)  [ $# -ge 2 ] || die "--secrets-dir needs an argument"; secrets_dir="$2"; shift 2 ;;
    --json)         emit_json=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *)              die "Unknown arg: $1 (try: agentkeys status --help)" ;;
  esac
done

require_cmd jq

state_file="$secrets_dir/.sync-state"
error_file="$secrets_dir/.sync-error"

# --json mode: emit a single combined JSON document so cron / jq consumers
# can parse it whether or not a .sync-error exists. Shape:
#   { "state": <last sync state or null>, "error": <last error or null> }
# Exit non-zero (2) when error is present, so cron job alerts can still
# branch on exit code without parsing.
if [ "$emit_json" = "1" ]; then
  state_json="null"
  error_json="null"
  if [ -f "$state_file" ]; then
    state_json="$(cat "$state_file")"
  fi
  if [ -f "$error_file" ]; then
    error_json="$(cat "$error_file")"
  fi
  jq -n \
    --argjson s "$state_json" \
    --argjson e "$error_json" \
    '{state: $s, error: $e}'
  [ -f "$error_file" ] && exit 2 || exit 0
fi

# Locate keyvault if possible (optional — status still works without it)
keyvault=""
if vault_root="$(find_keyvault_root 2>/dev/null)"; then
  keyvault="$vault_root"
fi

echo "agentkeys status"
echo "══════════════════════════════════════════════"
echo "Keyvault:     ${keyvault:-(not found — set AGENTKEYS_KEYVAULT or cd into one)}"
echo "Secrets dir:  $secrets_dir"
echo ""

# --- last sync ---
if [ -f "$state_file" ]; then
  synced_at="$(jq -r '.synced_at // "?"' "$state_file")"
  commit_sha="$(jq -r '.commit_sha // "?"' "$state_file")"
  host="$(jq -r '.host // "?"' "$state_file")"
  files_total="$(jq -r '.files_written // 0' "$state_file")"
  status="$(jq -r '.status // "?"' "$state_file")"

  echo "Last sync"
  echo "  When:       $synced_at"
  echo "  Host:       $host"
  echo "  Commit:     ${commit_sha:0:12}"
  echo "  Status:     $status"
  echo "  Files:      $files_total"
  echo "    shared:        $(jq -r '.breakdown.shared // 0' "$state_file")"
  echo "    agents:        $(jq -r '.breakdown.agents // 0' "$state_file")"
  echo "    service tokens: $(jq -r '.breakdown.service_tokens // 0' "$state_file")"
  echo "    type-c files:  $(jq -r '.breakdown.type_c_files // 0' "$state_file")"
  echo ""

  # --- staleness check ---
  if [ -n "$keyvault" ]; then
    head_sha="$(cd "$keyvault" && git rev-parse HEAD 2>/dev/null || echo unknown)"
    if [ "$head_sha" = "$commit_sha" ]; then
      echo "✓ Up to date with keyvault HEAD."
    else
      echo "⚠ STALE — keyvault HEAD ($head_sha) differs from synced ($commit_sha)"
      if [ "$head_sha" != "unknown" ] && [ "$commit_sha" != "unknown" ]; then
        pending="$(cd "$keyvault" && git log --oneline "$commit_sha..$head_sha" 2>/dev/null | head -20)"
        if [ -n "$pending" ]; then
          echo "  Pending commits:"
          echo "$pending" | sed 's/^/    /'
        fi
      fi
      echo "  Run: agentkeys sync"
    fi
  fi
else
  echo "⚠ Never synced on this host (no $state_file)."
  echo "  Run: agentkeys sync"
fi

# --- error report ---
if [ -f "$error_file" ]; then
  echo ""
  echo "──────────────────────────────────────────────"
  echo "⚠ Last sync attempt FAILED:"
  echo "  When:       $(jq -r '.synced_at // "?"' "$error_file")"
  echo "  Error:      $(jq -r '.error // "?"' "$error_file")"
  echo "  Last good:  $(jq -r '.last_known_good // "?"' "$error_file")"
fi

# --- recipients ---
if [ -n "$keyvault" ]; then
  shopt -s nullglob
  recipients=( "$keyvault"/recipients/*.age.pub )
  shopt -u nullglob
  if [ ${#recipients[@]} -gt 0 ]; then
    echo ""
    echo "──────────────────────────────────────────────"
    echo "Recipients (${#recipients[@]} registered):"
    for f in "${recipients[@]}"; do
      name="$(basename "$f" .age.pub)"
      echo "  - $name"
    done
    if [ "${#recipients[@]}" -lt 3 ]; then
      echo "  ⚠ Less than 3 recipients — spec §7 recommends ≥3 for recovery."
    fi
  fi
fi

# Exit non-zero if there's an unresolved error file
[ -f "$error_file" ] && exit 2 || exit 0
