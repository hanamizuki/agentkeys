#!/usr/bin/env bash
# agentkeys edit <path>
#
# sops-edit a YAML file in the keyvault. Resolves <path> relative to the
# keyvault root, auto-appends .yaml, and creates a new empty file ({}) if
# missing so first-edit flow works. After save, verifies encryption via
# `sops filestatus` and offers to commit.
set -euo pipefail

# shellcheck source=lib/common.sh
source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/common.sh"

usage() {
  cat <<EOF
Usage: agentkeys edit <path>

sops-edit a YAML file inside the keyvault. Resolves <path> relative to the
keyvault root and auto-appends .yaml if the extension is missing. Creates
a new file with empty body ({}) if it doesn't exist yet.

ARGUMENTS:
  <path>   Relative path inside keyvault, e.g. "shared/model-providers".
           ".yaml" extension is optional. Must not be absolute or contain "..".

EFFECTS:
  1. If file doesn't exist, creates <keyvault>/<path>.yaml with body '{}'
  2. Opens sops editor (\$EDITOR or vi); sops handles encryption via .sops.yaml
  3. After save, verifies encryption with 'sops filestatus'
  4. Offers to git commit the change with message 'edit <path>'

ENV:
  EDITOR            Editor for sops (default: vi)
  AGE_KEY_FILE      Age private key (default: ~/.age/key.txt).
                    Exported to SOPS_AGE_KEY_FILE so sops can decrypt.

EXAMPLES:
  agentkeys edit shared/model-providers
  agentkeys edit agents/my-agent
  agentkeys edit services/openrouter
EOF
}

path_arg="${1:-}"

case "$path_arg" in
  ""|-h|--help|help) usage; exit 0 ;;
esac

check_deps

# Reject absolute paths and ".." traversal before any work
case "$path_arg" in
  /*)   die "Path must be relative to keyvault root, got absolute: $path_arg" ;;
  *..*) die "Path must not contain '..': $path_arg" ;;
esac

keyvault="$(find_keyvault_root)" || die "Not inside a keyvault repo (run 'agentkeys init <path>' first, or cd into one)"
info "Using keyvault: $keyvault"

cd "$keyvault"

# Append .yaml if no yaml/yml extension
relpath="$path_arg"
case "$relpath" in
  *.yaml|*.yml) ;;
  *)            relpath="$relpath.yaml" ;;
esac

# Export so sops can find the age private key (only set if user overrode)
export SOPS_AGE_KEY_FILE="$(age_key_file)"
[ -f "$SOPS_AGE_KEY_FILE" ] || die "Age private key not found: $SOPS_AGE_KEY_FILE
Generate one with: mkdir -p ~/.age && age-keygen -o ~/.age/key.txt && chmod 600 ~/.age/key.txt"

# Auto-create new file with empty body so sops has something to encrypt
created=0
cleanup_placeholder() {
  # On any failure exit, if we created a placeholder file and it's still
  # plaintext (i.e. sops never got around to encrypting it), remove it so
  # we don't leak a plaintext file into the keyvault.
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$created" = "1" ] && [ -f "$relpath" ]; then
    if ! sops filestatus "$relpath" 2>/dev/null | grep -q '"encrypted":[[:space:]]*true'; then
      rm -f "$relpath"
      warn "Removed unencrypted placeholder: $relpath"
    fi
  fi
}
trap cleanup_placeholder EXIT

if [ ! -e "$relpath" ]; then
  parent="$(dirname "$relpath")"
  mkdir -p "$parent"
  echo "{}" > "$relpath"
  created=1
  info "Created new file: $relpath (empty body)"
  # Encrypt the placeholder in place so the subsequent 'sops <file>' works
  # as edit-decrypt-reencrypt. (`sops <plaintext>` silently no-ops with
  # "sops metadata not found" and exit 0 — don't rely on it.)
  sops -e -i "$relpath" || die "Failed to seed-encrypt new file: $relpath
Check .sops.yaml creation_rules cover this path."
fi

info "Opening $relpath in sops…"
# sops exit codes we care about:
#   0   = saved with changes
#   200 = "File has not changed, exiting" (user exited editor without saving)
#   *   = real failure (config, decryption, etc.)
sops_rc=0
sops "$relpath" || sops_rc=$?

if [ "$sops_rc" -eq 200 ]; then
  if [ "$created" = "1" ]; then
    rm -f "$relpath"
    info "No content added — removed placeholder $relpath."
  else
    info "No changes to $relpath."
  fi
  exit 0
elif [ "$sops_rc" -ne 0 ]; then
  die "sops exited with code $sops_rc on $relpath"
fi

# Verify encryption. sops filestatus emits {"encrypted":true|false}
status_json="$(sops filestatus "$relpath" 2>/dev/null || true)"
if ! echo "$status_json" | grep -q '"encrypted":[[:space:]]*true'; then
  die "File is not encrypted after edit: $relpath
sops filestatus: $status_json
Check .sops.yaml creation_rules cover this path."
fi

info "✓ Saved and encrypted: $relpath"

# Commit prompt — only if there's actually something to commit
if [ -z "$(git status --porcelain -- "$relpath" 2>/dev/null)" ]; then
  info "No changes to commit."
  exit 0
fi

if confirm "Commit changes to $relpath?" y; then
  git add -- "$relpath"
  git commit -q -m "edit $relpath"
  info "✓ Committed"
else
  info "Skipped commit. To commit later: cd $keyvault && git add $relpath && git commit"
fi
