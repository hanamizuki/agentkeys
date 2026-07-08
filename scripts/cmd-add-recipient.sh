#!/usr/bin/env bash
# agentkeys add-recipient <machine-name> [pubkey-or-file]
#
# Register a machine's age pubkey to the keyvault. Updates .sops.yaml to
# include the recipient and re-encrypts any existing yaml files.
set -euo pipefail

# shellcheck source=lib/common.sh
source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/common.sh"
source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/scope.sh"

usage() {
  cat <<EOF
Usage: agentkeys add-recipient <machine-name> [pubkey-or-file]

Register a machine's age pubkey to the keyvault.

If pubkey is not provided, derives from the current machine's age key
(\$AGE_KEY_FILE or ~/.age/key.txt by default).

ARGUMENTS:
  <machine-name>     Alphanumeric/dash/underscore identifier (e.g. "laptop")
  [pubkey-or-file]   age1... string OR path to a file containing the pubkey

OPTIONS:
  --scope all|path,path,...   Decrypt scope for this machine (default: all).
                              Exact vault-relative paths, comma-separated.

EFFECTS:
  1. Writes pubkey to <keyvault>/recipients/<machine-name>.age.pub
  2. Records the machine's scope in .agentkeys-scopes.yaml
  3. Regenerates .sops.yaml from the manifest (preserves existing per-path
     scoping — does NOT revert to simple all-recipient mode)
  4. Re-encrypts existing yaml files (sops updatekeys)
  5. Commits the change

EXAMPLES:
  # On this machine, using ~/.age/key.txt
  agentkeys add-recipient laptop

  # With a pubkey string
  agentkeys add-recipient server-1 age1abc...

  # With a pubkey file
  agentkeys add-recipient server-2 /tmp/server-2.age.pub
EOF
}

machine=""; pubkey_input=""; scope_spec="all"; scope_explicit=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    --scope) [ $# -ge 2 ] || die "--scope needs a value (all | path,path,...)"; scope_spec="$2"; scope_explicit=1; shift 2 ;;
    -*) die "Unknown option: $1" ;;
    *) if [ -z "$machine" ]; then machine="$1"; elif [ -z "$pubkey_input" ]; then pubkey_input="$1"; else die "Unexpected arg: $1"; fi; shift ;;
  esac
done
[ -n "$machine" ] || { usage; exit 0; }

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
    # A same-pubkey re-run is a no-op ONLY when no explicit scope was
    # requested. Any explicit --scope (including 'all', a widen request on a
    # scoped machine) is a scope-change ask — don't silently succeed while
    # leaving access unchanged; point at scope set.
    if [ "$scope_explicit" = "1" ]; then
      die "Recipient $machine already registered. To change its scope, run: agentkeys scope set $machine $scope_spec"
    fi
    info "Recipient $machine already registered with same pubkey. No-op."
    exit 0
  fi
  warn "Recipient $machine exists with different pubkey:"
  warn "  existing: $existing"
  warn "  new:      $pubkey"
  confirm "Overwrite?" || die "Aborted"
fi

# Snapshot the vault's entry state BEFORE writing anything — on any failure,
# scope_apply restores exactly this state: the pubkey file we're about to
# write, a manifest we may seed below, and every on-disk encrypted file
# (tracked or not). No half-onboarded vault, no destroyed hand-edits.
_scope_begin "$keyvault" "recipients/$machine.age.pub"

echo "$pubkey" > "$recipient_file"
info "✓ Wrote $recipient_file"

# Record this machine's scope in the manifest (source of truth). Seed it from
# current recipients first on a pre-scope vault, so behavior matches the old
# simple mode before we layer in this machine. Regeneration PRESERVES existing
# per-path scoping — adding a machine must never silently revert the vault to
# simple all-recipient mode.
scopes_path="$keyvault/$SCOPES_FILE_NAME"
if [ ! -f "$scopes_path" ]; then
  scope_load_manifest "$keyvault" | yq -P '.' > "$scopes_path"
  info "Seeded $SCOPES_FILE_NAME (existing recipients = all — simple-mode equivalent)"
fi
if [ "$scope_spec" = "all" ]; then
  yq -i ".recipients.\"$machine\" = \"all\"" "$scopes_path"
else
  yq -i ".recipients.\"$machine\" = []" "$scopes_path"
  IFS=',' read -r -a _paths <<< "$scope_spec"
  for p in "${_paths[@]}"; do
    # Shell-safe trim (not xargs) + pass the literal path to yq via env.
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [ -n "$p" ] && p="$p" yq -i ".recipients.\"$machine\" += [strenv(p)]" "$scopes_path"
  done
fi

# The shared write path (lib/scope.sh): regenerate .sops.yaml from the
# manifest, re-encrypt every ruled file, commit with an exact pathspec. Dies
# after restoring the entry snapshot if anything fails.
unique_keys="$(cat "$keyvault"/recipients/*.age.pub | LC_ALL=C sort -u | grep -c '^age1')"
scope_apply "$keyvault" "add recipient: $machine

Pubkey: $pubkey
Total recipients: $unique_keys" "recipients/$machine.age.pub"

info ""
info "Recipients registered:"
for f in "$keyvault"/recipients/*.age.pub; do
  info "  - $(basename "$f" .age.pub)"
done

# Warn if < 3 unique keys (spec §7) — duplicate pubkeys across machines add
# no recovery redundancy, so count keys, not machine names.
if [ "$unique_keys" -lt 3 ]; then
  warn ""
  warn "⚠ Only $unique_keys unique recipient key(s). Spec recommends ≥3 for emergency recovery."
  warn "  Add more with: agentkeys add-recipient <name>"
fi
