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

# Rule/emit order: files/ first — they carry encrypted_regex and also match a
# bare \.yaml$, so their rules must precede the generic ones (sops uses the
# first matching creation_rule).
_SCOPE_DIRS=(files shared agents services)

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

# Encrypted yaml files as vault-relative paths, files/ first, each dir sorted.
scope_list_encrypted_files() {
  local keyvault="$1" d f
  for d in "${_SCOPE_DIRS[@]}"; do
    shopt -s nullglob
    local group=()
    for f in "$keyvault/$d"/*.yaml; do group+=("${f#$keyvault/}"); done
    shopt -u nullglob
    [ ${#group[@]} -gt 0 ] && printf '%s\n' "${group[@]}" | LC_ALL=C sort
  done
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
    yq -o json '.' "$p"
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

# Emit full .sops.yaml to stdout. Deterministic.
emit_sops_rules() {
  local keyvault="$1"
  local mj; mj="$(scope_load_manifest "$keyvault")"

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
  done < <(scope_list_encrypted_files "$keyvault")

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
