#!/usr/bin/env bash
# agentkeys add-recipient <machine-name> [pubkey-or-file]
#
# Register a machine's age pubkey to the keyvault. Updates .sops.yaml to
# include the recipient and re-encrypts any existing yaml files.
set -euo pipefail

# shellcheck source=lib/common.sh
source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/common.sh"

usage() {
  cat <<EOF
Usage: agentkeys add-recipient <machine-name> [pubkey-or-file]

Register a machine's age pubkey to the keyvault.

If pubkey is not provided, derives from the current machine's age key
(\$AGE_KEY_FILE or ~/.age/key.txt by default).

ARGUMENTS:
  <machine-name>     Alphanumeric/dash/underscore identifier (e.g. "laptop")
  [pubkey-or-file]   age1... string OR path to a file containing the pubkey

EFFECTS:
  1. Writes pubkey to <keyvault>/recipients/<machine-name>.age.pub
  2. Updates .sops.yaml creation_rules to include this recipient
  3. Re-encrypts existing yaml files (sops updatekeys)
  4. Commits the change

EXAMPLES:
  # On this machine, using ~/.age/key.txt
  agentkeys add-recipient laptop

  # With a pubkey string
  agentkeys add-recipient server-1 age1abc...

  # With a pubkey file
  agentkeys add-recipient server-2 /tmp/server-2.age.pub
EOF
}

machine="${1:-}"
pubkey_input="${2:-}"

case "$machine" in
  ""|-h|--help|help) usage; exit 0 ;;
esac

# Validate machine name
if ! [[ "$machine" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  die "Invalid machine name: $machine (alphanumeric, dash, underscore only)"
fi

check_deps

# Find keyvault root
keyvault="$(find_keyvault_root)" || die "Not inside a keyvault repo (run 'agentkeys init <path>' first, or cd into one)"
info "Using keyvault: $keyvault"

# Export SOPS_AGE_KEY_FILE so the `sops updatekeys` step below can decrypt
# existing files. Without this, sops falls back to its default lookup
# (~/.config/sops/age/keys.txt etc.) and updatekeys silently fails for any
# vault encrypted with a key stored elsewhere — which triggers our rollback
# even on perfectly healthy onboarding.
if [ -f "$(age_key_file)" ]; then
  export SOPS_AGE_KEY_FILE="$(age_key_file)"
fi

# Resolve pubkey
if [ -z "$pubkey_input" ]; then
  pubkey="$(age_pubkey)"
  info "Derived from $(age_key_file)"
elif [[ "$pubkey_input" == age1* ]]; then
  pubkey="$pubkey_input"
elif [ -f "$pubkey_input" ]; then
  pubkey="$(grep -E "^age1" "$pubkey_input" | head -1 || true)"
  [ -z "$pubkey" ] && die "No age pubkey (age1...) found in $pubkey_input"
else
  die "pubkey arg is neither age1... nor an existing file: $pubkey_input"
fi

# Validate pubkey format (age1 + base32-like)
if ! [[ "$pubkey" =~ ^age1[a-z0-9]+$ ]]; then
  die "Invalid age pubkey format: $pubkey"
fi

# Save pubkey file
recipient_file="$keyvault/recipients/$machine.age.pub"
if [ -f "$recipient_file" ]; then
  existing="$(cat "$recipient_file")"
  if [ "$existing" = "$pubkey" ]; then
    info "Recipient $machine already registered with same pubkey. No-op."
    exit 0
  fi
  warn "Recipient $machine exists with different pubkey:"
  warn "  existing: $existing"
  warn "  new:      $pubkey"
  confirm "Overwrite?" || die "Aborted"
fi

echo "$pubkey" > "$recipient_file"
info "✓ Wrote $recipient_file"

# Collect all recipients
all_pubkeys=()
for f in "$keyvault"/recipients/*.age.pub; do
  [ -f "$f" ] && all_pubkeys+=("$(cat "$f")")
done

# Dedup + sort
mapfile -t all_pubkeys < <(printf "%s\n" "${all_pubkeys[@]}" | sort -u)

age_csv="$(IFS=,; echo "${all_pubkeys[*]}")"

# Rewrite .sops.yaml
cat > "$keyvault/.sops.yaml" <<EOF
# .sops.yaml — encryption rules for this keyvault repo
#
# Managed by 'agentkeys add-recipient'. Don't edit by hand unless you know
# what you're doing — use 'agentkeys add-recipient <machine>' instead.
#
# Current mode: simple (all recipients can decrypt all files).
# Future: per-file recipient differentiation for finer access control.

creation_rules:
  # Type C file manifests: encrypt only content field (paths/modes visible for audit)
  - path_regex: '^files/.*\.yaml\$'
    encrypted_regex: '^(content)\$'
    age: $age_csv

  # Everything else: encrypt all values
  - path_regex: '\.yaml\$'
    age: $age_csv
EOF

info "✓ Updated .sops.yaml with ${#all_pubkeys[@]} recipient(s)"

# Re-encrypt existing encrypted files. Track exactly which files we touched
# so the commit only contains our changes — never use `git add -u` here,
# which would sweep in any other tracked modifications the user happened to
# have in the working tree (a real risk because cron / parallel sessions
# can leave the keyvault dirty).
#
# If any updatekeys fails (file unreadable, this machine isn't in the prior
# recipient list, sops config drift, etc.) we abort and roll back .sops.yaml
# + the new recipient pubkey. Partial onboarding silently committed would
# leave the new machine unable to decrypt some files but the .sops.yaml
# claiming it can — a half-baked vault state that's hard to spot until the
# new machine actually tries to read those secrets.
encrypted_count=0
re_encrypted_files=()
failed_files=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    *"/.sops.yaml"|*"/recipients/"*) continue ;;
  esac
  if sops filestatus "$f" 2>/dev/null | grep -q '"encrypted":\s*true'; then
    info "  Re-encrypting $(realpath --relative-to="$keyvault" "$f" 2>/dev/null || echo "$f")"
    if sops updatekeys -y "$f" 2>/dev/null; then
      encrypted_count=$((encrypted_count + 1))
      re_encrypted_files+=("$f")
    else
      failed_files+=("$f")
    fi
  fi
done < <(find "$keyvault" -type f -name "*.yaml" 2>/dev/null)

if [ ${#failed_files[@]} -gt 0 ]; then
  err "sops updatekeys failed for ${#failed_files[@]} file(s):"
  for f in "${failed_files[@]}"; do
    err "  - $(realpath --relative-to="$keyvault" "$f" 2>/dev/null || echo "$f")"
  done
  err ""
  err "Rolling back to keep the vault consistent: restoring .sops.yaml and"
  err "removing recipients/$machine.age.pub. Any files already re-encrypted"
  err "in this run will also be restored from HEAD."
  # Restore .sops.yaml from HEAD if it's tracked (true after `init` did its
  # initial commit). Worst case: it's not tracked and we can't restore — but
  # that only happens on a fresh init before first add-recipient, where
  # there's nothing to re-encrypt anyway.
  if git -C "$keyvault" cat-file -e HEAD:.sops.yaml 2>/dev/null; then
    git -C "$keyvault" checkout HEAD -- .sops.yaml
  fi
  # Recipient file: if it existed in HEAD (i.e. we OVERWROTE an existing
  # pubkey for this machine), restore the previous version. If it was brand
  # new in this run, just delete it.
  rel_recipient="${recipient_file#$keyvault/}"
  if git -C "$keyvault" cat-file -e "HEAD:$rel_recipient" 2>/dev/null; then
    git -C "$keyvault" checkout HEAD -- "$rel_recipient"
  else
    rm -f "$recipient_file"
  fi
  for f in "${re_encrypted_files[@]}"; do
    rel="${f#$keyvault/}"
    if git -C "$keyvault" cat-file -e "HEAD:$rel" 2>/dev/null; then
      git -C "$keyvault" checkout HEAD -- "$rel"
    fi
  done
  die "Recipient onboarding aborted — vault state restored."
fi

[ "$encrypted_count" -gt 0 ] && info "✓ Re-encrypted $encrypted_count file(s)"

# Commit — stage only the exact files we wrote/changed. Never `git add
# recipients/` (whole dir): if another session left an untracked or modified
# pubkey for a different machine, that would be swept into this commit.
cd "$keyvault"
git add -- "recipients/$machine.age.pub" .sops.yaml
if [ ${#re_encrypted_files[@]} -gt 0 ]; then
  git add -- "${re_encrypted_files[@]}"
fi
git commit -q -m "add recipient: $machine

Pubkey: $pubkey
Total recipients: ${#all_pubkeys[@]}"

info "✓ Committed"
info ""
info "Recipients registered (${#all_pubkeys[@]}):"
for f in "$keyvault"/recipients/*.age.pub; do
  name="$(basename "$f" .age.pub)"
  info "  - $name"
done

# Warn if < 3 (per spec §7)
if [ "${#all_pubkeys[@]}" -lt 3 ]; then
  warn ""
  warn "⚠ Only ${#all_pubkeys[@]} recipient(s). Spec recommends ≥3 for emergency recovery."
  warn "  Add more with: agentkeys add-recipient <name>"
fi
