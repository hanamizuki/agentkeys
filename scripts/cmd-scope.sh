#!/usr/bin/env bash
# agentkeys scope <show|set|regen>
# show  — print each machine's scope, or one machine's decryptable files.
# set   — change a machine's scope + regenerate .sops.yaml + updatekeys  (later change)
# regen — regenerate .sops.yaml from the manifest + updatekeys           (later change)
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

case "$sub" in
  show)
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
  set|regen)
    die "'scope $sub' is implemented in a later change — not available yet"
    ;;
  *) usage >&2; exit 1 ;;
esac
