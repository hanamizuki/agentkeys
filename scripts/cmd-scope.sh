#!/usr/bin/env bash
# agentkeys scope <show|set|regen>
# show  — print each machine's scope, or one machine's decryptable files.
# set   — change a machine's scope + regenerate .sops.yaml + sops updatekeys.
# regen — regenerate .sops.yaml from the manifest + sops updatekeys.
#
# set/regen run `sops updatekeys`, which must decrypt each file first — run
# them on a machine whose age key can decrypt everything (a full-scope machine).
set -euo pipefail

source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/common.sh"
source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/scope.sh"

usage() {
  cat <<EOF
Usage: agentkeys scope <show|set|regen> [args]

  scope show [machine]     Print all machines' scope, or one machine's
                           decryptable files.
  scope set <machine> <all|path,path,...>
                           Change a machine's scope, regenerate .sops.yaml,
                           and re-encrypt affected files (must run on a machine
                           that can decrypt everything).
  scope regen              Regenerate .sops.yaml from .agentkeys-scopes.yaml
                           and re-encrypt (use after hand-editing the manifest).
EOF
}

sub="${1:-}"; [ $# -gt 0 ] && shift || true
case "$sub" in
  ""|-h|--help|help) usage; exit 0 ;;
esac

check_deps
keyvault="$(find_keyvault_root)" || die "Not inside a keyvault repo"
cd "$keyvault"   # sops updatekeys resolves .sops.yaml from cwd

# Seed the manifest from current recipients (all-"all") if it's absent, so a
# pre-scope vault upgrades smoothly the first time scope is mutated.
_scope_ensure_manifest() {
  [ -f "$keyvault/$SCOPES_FILE_NAME" ] && return
  scope_load_manifest "$keyvault" | yq -P '.' > "$keyvault/$SCOPES_FILE_NAME"
  info "Seeded $SCOPES_FILE_NAME (all recipients = all)"
}

# The write path (emit + updatekeys + rollback + pathspec commit) is the
# shared scope_apply in lib/scope.sh; callers below snapshot the entry state
# with _scope_begin BEFORE mutating the manifest, so a failed apply restores
# exactly what the operator had (including uncommitted hand-edits).

case "$sub" in
  show)
    [ $# -le 1 ] || die "Unexpected argument(s): ${*:2} — usage: agentkeys scope show [machine]"
    mj="$(scope_load_manifest "$keyvault")"
    machine="${1:-}"
    if [ -z "$machine" ]; then
      if [ -f "$keyvault/$SCOPES_FILE_NAME" ]; then
        echo "Recipient scopes (source: $SCOPES_FILE_NAME):"
      else
        echo "Recipient scopes ($SCOPES_FILE_NAME MISSING — defaulting all to \"all\"):"
      fi
      while IFS=$'\t' read -r name _pub; do
        [ -n "$name" ] || continue
        val="$(printf '%s' "$mj" | jq -c --arg m "$name" '.recipients[$m] // "all"')"
        printf '  %-12s %s\n' "$name" "$val"
      done < <(scope_read_recipients "$keyvault" | LC_ALL=C sort)
    else
      # Validate the machine is a registered recipient first — otherwise
      # scope_machine_allows' absent-default of "all" would falsely report an
      # unknown/typo'd machine can decrypt everything.
      if ! scope_read_recipients "$keyvault" | cut -f1 | grep -qxF "$machine"; then
        die "Unknown machine '$machine' (not a registered recipient)"
      fi
      echo "Files decryptable by '$machine':"
      any=0
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ "$(scope_machine_allows "$mj" "$machine" "$f")" = "1" ]; then
          printf '  %s\n' "$f"; any=1
        fi
      done < <(scope_list_encrypted_files "$keyvault")
      [ "$any" = "1" ] || echo "  (none)"
    fi
    ;;
  set)
    export SOPS_AGE_KEY_FILE="$(age_key_file)"
    [ -f "$SOPS_AGE_KEY_FILE" ] || die "Age private key not found: $SOPS_AGE_KEY_FILE"
    machine="${1:-}"; spec="${2:-}"
    [ -n "$machine" ] && [ -n "$spec" ] || die "Usage: agentkeys scope set <machine> <all|path,path,...>"
    # Space-separated paths would silently grant only $2 while reporting
    # success — a partial grant the operator can't see. Hard error instead.
    [ $# -eq 2 ] || die "Unexpected argument(s): ${*:3} — separate scope paths with commas, not spaces"
    [ -f "$keyvault/recipients/$machine.age.pub" ] || die "Unknown machine '$machine' (no recipients/$machine.age.pub)"
    # Pre-flight before any write: reject an invalid manifest / an escaping
    # path while the tree is untouched (yq -i on a broken manifest would die
    # under set -e with a half-edited file and no rollback).
    scope_load_manifest "$keyvault" >/dev/null \
      || die "Fix $SCOPES_FILE_NAME before changing scope (see error above)."
    scope_spec_validate "$spec"
    _scope_begin "$keyvault"   # snapshot BEFORE we (or ensure_manifest) touch anything
    _scope_ensure_manifest
    scope_manifest_set_machine "$keyvault/$SCOPES_FILE_NAME" "$machine" "$spec"
    scope_apply "$keyvault" "scope: set $machine = $spec"
    ;;
  regen)
    [ $# -eq 0 ] || die "Unexpected argument(s): $* — usage: agentkeys scope regen"
    export SOPS_AGE_KEY_FILE="$(age_key_file)"
    [ -f "$SOPS_AGE_KEY_FILE" ] || die "Age private key not found: $SOPS_AGE_KEY_FILE"
    [ -f "$keyvault/$SCOPES_FILE_NAME" ] || die "No $SCOPES_FILE_NAME to regen from"
    _scope_begin "$keyvault"
    scope_apply "$keyvault" "scope: regenerate .sops.yaml from manifest"
    ;;
  *) usage >&2; exit 1 ;;
esac
