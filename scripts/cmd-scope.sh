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

# Regenerate .sops.yaml (atomic + guarded), warn on any <3-recipient rule,
# re-encrypt every currently-encrypted file, commit .sops.yaml + manifest.
# Never `git add -u`. Aborts before commit if a file can't be re-encrypted.
_scope_apply() {
  local msg="$1"
  local -a touched=()
  # Restore manifest, .sops.yaml, and any already-updatekeyed files to HEAD on
  # failure so a partial/broadened state can't be left in (and accidentally
  # committed from) the working tree. A freshly-seeded manifest (absent in
  # HEAD) is removed rather than checked out.
  _scope_rollback() {
    git checkout HEAD -- .sops.yaml 2>/dev/null || true
    if git cat-file -e "HEAD:$SCOPES_FILE_NAME" 2>/dev/null; then
      git checkout HEAD -- "$SCOPES_FILE_NAME" 2>/dev/null || true
    else
      rm -f "$keyvault/$SCOPES_FILE_NAME"
    fi
    [ ${#touched[@]} -gt 0 ] && git checkout HEAD -- "${touched[@]}" 2>/dev/null || true
  }
  if ! emit_sops_rules "$keyvault" > "$keyvault/.sops.yaml.tmp"; then
    rm -f "$keyvault/.sops.yaml.tmp"; _scope_rollback
    die "Refusing to write .sops.yaml — see error above (fix $SCOPES_FILE_NAME)."
  fi
  mv "$keyvault/.sops.yaml.tmp" "$keyvault/.sops.yaml"
  local thin
  thin="$(awk -F': ' '/^    age:/{n=gsub(/,/,",",$2)+1; if(n<3) print n}' "$keyvault/.sops.yaml" | head -1 || true)"
  [ -n "$thin" ] && warn "⚠ A generated rule has < 3 recipients — emergency recovery at risk (spec §7)."
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$keyvault/$f" ] || continue
    if sops filestatus "$keyvault/$f" 2>/dev/null | grep -q '"encrypted":[[:space:]]*true'; then
      if sops updatekeys -y "$keyvault/$f" >/dev/null 2>&1; then touched+=("$f")
      else _scope_rollback; die "sops updatekeys failed for $f — are you on a machine that can decrypt everything? Rolled back, no commit."; fi
    fi
  done < <(scope_all_ruled_paths "$keyvault")
  local -a paths=(.sops.yaml "$SCOPES_FILE_NAME")
  [ ${#touched[@]} -gt 0 ] && paths+=("${touched[@]}")
  git add -- "${paths[@]}"
  # No-op (re-setting the same scope, or regen right after add-recipient):
  # nothing staged among our paths → vault already in the desired state.
  if git diff --cached --quiet -- "${paths[@]}"; then
    info "✓ $msg (already up to date)"
    return 0
  fi
  # Pathspec commit so unrelated staged changes in the shared working tree are
  # never swept into a scope commit.
  git commit -q -m "$msg" -- "${paths[@]}"
  info "✓ $msg (re-encrypted ${#touched[@]} file(s))"
}

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
  set)
    export SOPS_AGE_KEY_FILE="$(age_key_file)"
    [ -f "$SOPS_AGE_KEY_FILE" ] || die "Age private key not found: $SOPS_AGE_KEY_FILE"
    machine="${1:-}"; spec="${2:-}"
    [ -n "$machine" ] && [ -n "$spec" ] || die "Usage: agentkeys scope set <machine> <all|path,path,...>"
    [ -f "$keyvault/recipients/$machine.age.pub" ] || die "Unknown machine '$machine' (no recipients/$machine.age.pub)"
    _scope_ensure_manifest
    if [ "$spec" = "all" ]; then
      yq -i ".recipients.\"$machine\" = \"all\"" "$keyvault/$SCOPES_FILE_NAME"
    else
      yq -i ".recipients.\"$machine\" = []" "$keyvault/$SCOPES_FILE_NAME"
      IFS=',' read -r -a _paths <<< "$spec"
      for p in "${_paths[@]}"; do
        # Shell-safe trim (xargs would mangle quotes/backslashes) + pass the
        # literal path to yq via env, never embedded in the expression.
        p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
        [ -n "$p" ] && p="$p" yq -i ".recipients.\"$machine\" += [strenv(p)]" "$keyvault/$SCOPES_FILE_NAME"
      done
    fi
    _scope_apply "scope: set $machine = $spec"
    ;;
  regen)
    export SOPS_AGE_KEY_FILE="$(age_key_file)"
    [ -f "$SOPS_AGE_KEY_FILE" ] || die "Age private key not found: $SOPS_AGE_KEY_FILE"
    [ -f "$keyvault/$SCOPES_FILE_NAME" ] || die "No $SCOPES_FILE_NAME to regen from"
    _scope_apply "scope: regenerate .sops.yaml from manifest"
    ;;
  *) usage >&2; exit 1 ;;
esac
