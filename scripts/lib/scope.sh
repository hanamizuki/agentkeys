#!/usr/bin/env bash
# scope.sh — per-path recipient scope: parse the scopes manifest, compute
# each file's recipient set, and emit a deterministic .sops.yaml.
#
# Source from cmd-*.sh AFTER lib/common.sh. Depends on jq + yq (checked by
# common.sh check_deps). No python.
#
# Model: .agentkeys-scopes.yaml (plaintext, vault root) is the source of
# truth. Each recipient maps to "all" (whole vault) or an exact list of
# vault-relative paths. .sops.yaml is a pure generated artifact.

SCOPES_FILE_NAME=".agentkeys-scopes.yaml"

# Escape a vault-relative path into an anchored-alternation-safe regex atom.
# Escapes EVERY RE2 metacharacter (sops uses Go's regexp) so a filename with
# e.g. '+' or '[' maps to an exact path_regex instead of a pattern that could
# match the wrong file. '/' is literal in RE2 and left as-is.
_scope_regex_atom() {
  local s="$1" out="" i c
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '\'|'.'|'+'|'*'|'?'|'('|')'|'['|']'|'{'|'}'|'^'|'$'|'|') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# Wrap a string as a YAML single-quoted scalar, doubling any embedded single
# quote. The RE2 escape above handles regex metachars; this is the orthogonal
# YAML layer so a path_regex value containing "'" doesn't break .sops.yaml.
_yaml_sq() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }

# recipients/<machine>.age.pub → "machine<TAB>pubkey" (unsorted; callers that
# need order pipe to `LC_ALL=C sort`).
scope_read_recipients() {
  local keyvault="$1" f name pub
  shopt -s nullglob
  for f in "$keyvault"/recipients/*.age.pub; do
    name="$(basename "$f" .age.pub)"
    pub="$(grep -E '^age1' "$f" | head -1 || true)"
    [ -n "$pub" ] && printf '%s\t%s\n' "$name" "$pub"
  done
  shopt -u nullglob
}

# Every encrypted-eligible yaml in the vault as a vault-relative path, sorted.
# Scans the WHOLE vault (not just the canonical dirs) so any .yaml an operator
# created via `agentkeys edit` — nested or in a non-standard top-level dir like
# misc/ — is re-encrypted on a scope change; a dir-limited scan would leave a
# revoked recipient still able to decrypt such a file. Excludes the CLI-managed
# metadata files and recipients/ pubkeys, which are never sops-encrypted.
scope_list_encrypted_files() {
  local keyvault="$1" f
  while IFS= read -r f; do
    f="${f#"$keyvault"/}"
    case "$f" in
      .sops.yaml|"$SCOPES_FILE_NAME"|recipients/*) continue ;;
    esac
    [ -n "$f" ] && printf '%s\n' "$f"
  done < <(find "$keyvault" -type f -name '*.yaml' -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort)
  return 0
}

# Load manifest as JSON. Missing file → synthesize all-"all" from recipients
# (simple-mode equivalent; smooth upgrade from a pre-scope vault).
scope_load_manifest() {
  # NB: separate `local` statements — `local a=$1 b=$a` expands $a against the
  # OUTER scope (before the local assignment lands), which breaks under set -u
  # when a caller invokes this without an ambient $keyvault.
  local keyvault="$1"
  local p="$keyvault/$SCOPES_FILE_NAME"
  if [ -f "$p" ]; then
    # Fail closed on a malformed manifest: bad YAML, a missing/renamed
    # `recipients:` key, or a value that isn't "all"/an array would otherwise
    # let scope_machine_allows default everything to "all" and generate
    # all-recipient rules. Reject instead.
    local json
    if ! json="$(yq -o json '.' "$p" 2>/dev/null)"; then
      printf 'agentkeys: %s is not valid YAML\n' "$SCOPES_FILE_NAME" >&2
      return 1
    fi
    if ! printf '%s' "$json" | jq -e '
        (.recipients | type) == "object"
        and (.recipients | to_entries | all(.value == "all" or (.value | type == "array")))
      ' >/dev/null 2>&1; then
      printf 'agentkeys: %s malformed — .recipients must map each machine to "all" or a path list\n' "$SCOPES_FILE_NAME" >&2
      return 1
    fi
    printf '%s' "$json"
    return
  fi
  local obj='{"version":1,"recipients":{}}' name pub
  while IFS=$'\t' read -r name pub; do
    [ -n "$name" ] || continue
    obj="$(printf '%s' "$obj" | jq --arg m "$name" '.recipients[$m]="all"')"
  done < <(scope_read_recipients "$keyvault" | LC_ALL=C sort)
  printf '%s' "$obj"
}

# 1 if <machine> may decrypt <path> per manifest, else 0.
# scope value: "all" → yes; array → exact-path membership; absent → "all"
# for whole-vault default, BUT a machine present with an array is fail-closed
# on paths not listed (new files are NOT auto-granted to scoped machines).
scope_machine_allows() {
  local mj="$1" machine="$2" path="$3" val
  val="$(printf '%s' "$mj" | jq -r --arg m "$machine" '.recipients[$m] // "all"')"
  [ "$val" = "all" ] && { echo 1; return; }
  printf '%s' "$mj" | jq -e --arg m "$machine" --arg p "$path" \
    '(.recipients[$m] // []) | index($p) != null' >/dev/null 2>&1 && echo 1 || echo 0
}

# ---------- entry-state snapshot / restore ----------
# A failed apply must put the working tree back EXACTLY as it was when the
# command started — NOT back to HEAD. The manifest is caller input ('scope
# regen' is documented as "run after hand-editing it", so it may carry
# uncommitted hand-edits), and encrypted files may be untracked; both are
# invisible to a checkout-HEAD rollback. So: snapshot every file an apply may
# write BEFORE the caller mutates anything, restore that snapshot on failure.

# _scope_begin <keyvault> [extra vault-relative paths...]
# Snapshot .sops.yaml + the manifest + every encrypted-eligible yaml on disk
# (+ extras, e.g. the recipient pubkey add-recipient is about to write). A
# path absent at entry is recorded so restore deletes it.
_scope_begin() {
  local keyvault="$1"; shift
  SCOPE_SNAP_DIR="$(mktemp -d)"
  local f
  { printf '%s\n' ".sops.yaml" "$SCOPES_FILE_NAME" "$@"
    scope_list_encrypted_files "$keyvault"
  } | LC_ALL=C sort -u > "$SCOPE_SNAP_DIR/paths"
  while IFS= read -r f; do
    [ -f "$keyvault/$f" ] || continue
    mkdir -p "$SCOPE_SNAP_DIR/data/$(dirname "$f")"
    cp -p "$keyvault/$f" "$SCOPE_SNAP_DIR/data/$f"
  done < "$SCOPE_SNAP_DIR/paths"
}

# Restore every snapshotted path to its entry state (delete what didn't exist).
_scope_restore_entry() {
  local keyvault="$1" f
  [ -n "${SCOPE_SNAP_DIR:-}" ] && [ -f "$SCOPE_SNAP_DIR/paths" ] || return 0
  while IFS= read -r f; do
    if [ -f "$SCOPE_SNAP_DIR/data/$f" ]; then
      cp -p "$SCOPE_SNAP_DIR/data/$f" "$keyvault/$f"
    else
      rm -f "$keyvault/$f"
    fi
  done < "$SCOPE_SNAP_DIR/paths"
}

# Discard the snapshot (on success, or after a restore).
_scope_end() {
  [ -n "${SCOPE_SNAP_DIR:-}" ] && rm -rf "$SCOPE_SNAP_DIR"
  SCOPE_SNAP_DIR=""
}

# scope_apply <keyvault> <commit-msg> [extra commit paths...]
# THE shared write path for every scope mutation (scope set, scope regen,
# add-recipient): regenerate .sops.yaml from the manifest, re-encrypt every
# ruled on-disk file, and commit with an exact pathspec (never add -u/-A).
# Caller contract: call _scope_begin FIRST (before mutating the manifest or
# writing a pubkey), then mutate, then scope_apply. On any failure the tree
# is restored to the _scope_begin entry state and the process dies. Must run
# on a machine whose age key decrypts everything (sops updatekeys reads each
# file). Extra paths are committed along (and must be covered by the caller's
# _scope_begin extras so a failure restores them too).
scope_apply() {
  local keyvault="$1" msg="$2"; shift 2
  [ -n "${SCOPE_SNAP_DIR:-}" ] || die "internal: scope_apply called without _scope_begin"
  _scope_fail() { _scope_restore_entry "$keyvault"; _scope_end; die "$1"; }
  if ! emit_sops_rules "$keyvault" > "$keyvault/.sops.yaml.tmp"; then
    rm -f "$keyvault/.sops.yaml.tmp"
    _scope_fail "Refusing to write .sops.yaml — see error above (fix $SCOPES_FILE_NAME)."
  fi
  mv "$keyvault/.sops.yaml.tmp" "$keyvault/.sops.yaml"
  local thin
  thin="$(awk -F': ' '/^    age:/{n=gsub(/,/,",",$2)+1; if(n<3) print n}' "$keyvault/.sops.yaml" | head -1 || true)"
  [ -n "$thin" ] && warn "⚠ A generated rule has < 3 recipients — emergency recovery at risk (spec §7)."
  local f; local -a touched=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$keyvault/$f" ] || continue
    if sops filestatus "$keyvault/$f" 2>/dev/null | grep -q '"encrypted":[[:space:]]*true'; then
      # cd: sops updatekeys resolves .sops.yaml from cwd, not the file's dir.
      if ( cd "$keyvault" && sops updatekeys -y "$f" >/dev/null 2>&1 ); then
        touched+=("$f")
      else
        _scope_fail "sops updatekeys failed for $f — are you on a machine that can decrypt everything? Restored the pre-command state, no commit."
      fi
    fi
  done < <(scope_all_ruled_paths "$keyvault")
  local -a paths=(.sops.yaml "$SCOPES_FILE_NAME" "$@")
  [ ${#touched[@]} -gt 0 ] && paths+=("${touched[@]}")
  git -C "$keyvault" add -- "${paths[@]}"
  # No-op (re-setting the same scope, or regen right after add-recipient):
  # nothing staged among our paths → vault already in the desired state.
  if git -C "$keyvault" diff --cached --quiet -- "${paths[@]}"; then
    _scope_end
    info "✓ ${msg%%$'\n'*} (already up to date)"
    return 0
  fi
  git -C "$keyvault" commit -q -m "$msg" -- "${paths[@]}"
  _scope_end
  info "✓ ${msg%%$'\n'*} (re-encrypted ${#touched[@]} file(s))"
}

# Paths that get an exact rule (emit) and must be re-encrypted on a scope
# change (scope apply): existing encrypted files ∪ every exact path the
# manifest lists. Sorted & unique. Keeping emit and updatekeys on the SAME set
# is what prevents .sops.yaml claiming a grant/revocation that never reached
# the file's real recipients.
scope_all_ruled_paths() {
  local keyvault="$1" mj
  mj="$(scope_load_manifest "$keyvault")" || return 1
  { scope_list_encrypted_files "$keyvault"
    printf '%s' "$mj" | jq -r '.recipients[] | select(type=="array") | .[]'
  } | LC_ALL=C sort -u
}

# Emit full .sops.yaml to stdout. Deterministic.
emit_sops_rules() {
  local keyvault="$1"
  local mj; mj="$(scope_load_manifest "$keyvault")" || return 1

  local -a machines=(); local -A PUB=()
  local name pub
  while IFS=$'\t' read -r name pub; do
    [ -n "$name" ] || continue
    machines+=("$name"); PUB[$name]="$pub"
  done < <(scope_read_recipients "$keyvault" | LC_ALL=C sort)

  local -A FILES_GROUP=() OTHER_GROUP=()
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    local -a pubs=(); local m
    for m in "${machines[@]}"; do
      [ "$(scope_machine_allows "$mj" "$m" "$path")" = "1" ] && pubs+=("${PUB[$m]}")
    done
    # A file no machine can decrypt would emit an empty `age:` rule (unusable,
    # unencryptable). Stop loudly instead of writing a broken .sops.yaml.
    if [ ${#pubs[@]} -eq 0 ]; then
      printf 'agentkeys: no eligible recipient for %s — every machine is scoped away from it; fix %s\n' "$path" "$SCOPES_FILE_NAME" >&2
      return 1
    fi
    local csv atom
    csv="$(printf '%s\n' "${pubs[@]}" | LC_ALL=C sort | paste -sd, -)"
    atom="$(_scope_regex_atom "$path")"
    case "$path" in
      files/*) FILES_GROUP[$csv]="${FILES_GROUP[$csv]:+${FILES_GROUP[$csv]}|}$atom" ;;
      *)       OTHER_GROUP[$csv]="${OTHER_GROUP[$csv]:+${OTHER_GROUP[$csv]}|}$atom" ;;
    esac
  done < <(scope_all_ruled_paths "$keyvault")

  cat <<'HDR'
# .sops.yaml — encryption rules for this keyvault repo
#
# GENERATED by agentkeys from .agentkeys-scopes.yaml. DO NOT EDIT BY HAND.
# Change decrypt scope: edit .agentkeys-scopes.yaml, then run
#   agentkeys scope regen      (regenerate this file + sops updatekeys)
# Add a machine: agentkeys add-recipient <machine> [--scope all|path,path]
#
# Mode: per-path recipient scope. Each rule lists exactly the machines whose
# age key may decrypt the matching files.

creation_rules:
HDR

  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf "  - path_regex: %s\n" "$(_yaml_sq "^(${FILES_GROUP[$key]})\$")"
    printf "    encrypted_regex: %s\n" "$(_yaml_sq '^(content)$')"
    printf "    age: %s\n" "$key"
  done < <(printf '%s\n' "${!FILES_GROUP[@]}" | LC_ALL=C sort)

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf "  - path_regex: %s\n" "$(_yaml_sq "^(${OTHER_GROUP[$key]})\$")"
    printf "    age: %s\n" "$key"
  done < <(printf '%s\n' "${!OTHER_GROUP[@]}" | LC_ALL=C sort)

  # Fallback rules so a NEW file (not yet in any exact rule) is still
  # encryptable — granted to the "all"-scope machines only; scoped machines
  # stay fail-closed on files they were not explicitly given. The files/
  # fallback carries encrypted_regex and must precede the generic one (sops
  # uses the first matching rule). Exact rules above always win for existing
  # files; these only catch newly added ones until the next scope regen.
  local -a all_pubs=(); local m mscope
  for m in "${machines[@]}"; do
    mscope="$(printf '%s' "$mj" | jq -r --arg m "$m" '.recipients[$m] // "all"')"
    [ "$mscope" = "all" ] && all_pubs+=("${PUB[$m]}")
  done
  if [ ${#all_pubs[@]} -gt 0 ]; then
    local all_csv; all_csv="$(printf '%s\n' "${all_pubs[@]}" | LC_ALL=C sort | paste -sd, -)"
    printf "  - path_regex: '%s'\n    encrypted_regex: '%s'\n    age: %s\n" '^files/.*\.yaml$' '^(content)$' "$all_csv"
    printf "  - path_regex: '%s'\n    age: %s\n" '\.yaml$' "$all_csv"
  fi
}
