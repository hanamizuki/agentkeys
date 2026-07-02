#!/usr/bin/env bash
# agentkeys rotate <KEY_NAME>
#
# End-to-end secret rotation for a single Type A key. Searches shared/ and
# agents/ for which file holds the key, opens an editor on it, commits the
# re-encrypted file, optionally pushes, and re-runs sync so this machine
# picks up the new value immediately.
#
# Out of scope for MVP: revoking on the provider side (manual step) and
# reloading downstream daemons (caller can run `launchctl kickstart …` or
# `openclaw restart`, etc., after this completes).
set -euo pipefail

# shellcheck source=lib/common.sh
source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/common.sh"

usage() {
  cat <<EOF
Usage: agentkeys rotate <KEY_NAME> [--no-push] [--no-sync]

End-to-end rotation for a Type A secret (shared/ or agents/).

ARGUMENTS:
  <KEY_NAME>    UPPER_SNAKE_CASE env-var name (e.g. KIMI_API_KEY)

OPTIONS:
  --no-push     Don't offer to push after commit
  --no-sync     Skip the post-commit local sync
  -h, --help

FLOW:
  1. Search shared/*.yaml + agents/*.yaml for KEY_NAME
  2. If found in multiple files, prompt to pick one
  3. Open sops editor on that file
  4. Verify encryption, commit, optionally push
  5. Run 'agentkeys sync' on this machine

NOT done by this command (do these yourself afterward):
  - Revoke OLD key on the provider once new key is confirmed
  - Reload daemons / gateways that hold the value in memory
  - Write audit log entry

ENV:
  AGENTKEYS_KEYVAULT  Override keyvault location
  AGE_KEY_FILE        Age private key (default: ~/.age/key.txt)
EOF
}

# ---------- arg parsing ----------

key_name=""
no_push=0
no_sync=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    --no-push)      no_push=1; shift ;;
    --no-sync)      no_sync=1; shift ;;
    -*)             die "Unknown option: $1" ;;
    *)
      if [ -z "$key_name" ]; then
        key_name="$1"; shift
      else
        die "Unexpected positional arg: $1"
      fi ;;
  esac
done

[ -n "$key_name" ] || { usage; exit 1; }

# Validate KEY_NAME format — refuse anything that wouldn't be a safe env var
if ! [[ "$key_name" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
  die "KEY_NAME should be UPPER_SNAKE_CASE (got: '$key_name')"
fi

check_deps

keyvault="$(find_keyvault_root)" || die "Not inside a keyvault repo"
info "Using keyvault: $keyvault"
cd "$keyvault"

export SOPS_AGE_KEY_FILE="$(age_key_file)"
[ -f "$SOPS_AGE_KEY_FILE" ] || die "Age private key not found: $SOPS_AGE_KEY_FILE"

# ---------- 1. Locate the key ----------

info "Searching for $key_name in shared/ and agents/…"

matches=()
shopt -s nullglob
candidates=( shared/*.yaml agents/*.yaml )
shopt -u nullglob

for f in "${candidates[@]}"; do
  # Skip non-existent (nullglob should have filtered, but defensive)
  [ -f "$f" ] || continue
  if sops -d "$f" 2>/dev/null | yq -e ".${key_name} // null | . != null" >/dev/null 2>&1; then
    matches+=("$f")
  fi
done

if [ "${#matches[@]}" -eq 0 ]; then
  die "Key $key_name not found in any shared/ or agents/ yaml.
Hint: list keys with: sops -d shared/*.yaml agents/*.yaml | yq 'keys[]'"
fi

# ---------- 2. Pick target ----------

target=""
if [ "${#matches[@]}" -eq 1 ]; then
  target="${matches[0]}"
  info "Found in: $target"
else
  info "Key $key_name appears in ${#matches[@]} files:"
  i=1
  for m in "${matches[@]}"; do
    echo "  $i) $m" >&2
    i=$((i+1))
  done
  read -r -p "Which to rotate? [1-${#matches[@]}] " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#matches[@]}" ]; then
    die "Invalid choice: $choice"
  fi
  target="${matches[$((choice-1))]}"
  info "Rotating: $target"
fi

# ---------- 3. Edit ----------

info "Opening $target in sops… (edit the $key_name value, save & quit)"
sops_rc=0
sops "$target" || sops_rc=$?

if [ "$sops_rc" -eq 200 ]; then
  info "No changes made — rotation aborted."
  exit 0
elif [ "$sops_rc" -ne 0 ]; then
  die "sops exited with code $sops_rc"
fi

# ---------- 4. Verify + commit ----------

if ! sops filestatus "$target" 2>/dev/null | grep -q '"encrypted":[[:space:]]*true'; then
  die "$target is not encrypted after edit. Check .sops.yaml creation_rules."
fi

if [ -n "$(git status --porcelain -- "$target" 2>/dev/null)" ]; then
  git add -- "$target"
  git commit -q -m "rotate $key_name in $target"
  info "✓ Committed: rotate $key_name"
else
  info "(file unchanged after sops re-encrypt — nothing to commit)"
  exit 0
fi

# ---------- 5. Push (optional) ----------

if [ "$no_push" = "0" ] && git remote 2>/dev/null | grep -q .; then
  if confirm "Push rotation commit to remote?" y; then
    if git push --quiet; then
      info "✓ Pushed"
    else
      warn "Push failed. Run 'git push' manually when ready."
    fi
  else
    info "Skipped push. Run 'git push' manually before other machines can sync."
  fi
fi

# ---------- 6. Sync on this machine ----------

if [ "$no_sync" = "0" ]; then
  info "Running 'agentkeys sync' to refresh local ~/.secrets/…"
  if [ -n "${AGENTKEYS_DIR:-}" ] && [ -x "$AGENTKEYS_DIR/agentkeys" ]; then
    "$AGENTKEYS_DIR/agentkeys" sync --no-pull
  else
    # Fallback: invoke our sibling cmd-sync.sh directly
    bash "$(dirname "${BASH_SOURCE[0]}")/cmd-sync.sh" --no-pull
  fi
fi

# ---------- 7. Next-steps reminder ----------

cat <<EOF

═══ ROTATION COMPLETE — manual follow-up needed ═══

  1. This machine has the new value in ~/.secrets/ now.
  2. Other machines will pick up at next sync cron tick, OR run:
       agentkeys sync   (on each remote machine)
  3. RELOAD any daemons / gateways holding the old value in memory:
       e.g. launchctl kickstart -k …, openclaw restart, etc.
  4. REVOKE the OLD $key_name on the provider once you've verified the
     new value works.
  5. Consider writing an audit-log entry

EOF
