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

# Test-only fault injection: AGENTKEYS_FAULT=<point> aborts execution at the
# named point the way an unexpected environment failure under set -e would
# (immediate exit, no cleanup), so tests can prove the EXIT-trap safety net
# actually restores the entry snapshot. Never set outside tests.
_scope_faultpoint() {
  if [ "${AGENTKEYS_FAULT:-}" = "$1" ]; then exit 97; fi
}

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

# A scope path must stay inside the vault: relative, with no empty, '.' or
# '..' segments. Ruled paths are later resolved as "$keyvault/<path>" and fed
# to sops updatekeys — a traversal path would let a hand-edited manifest (or
# a --scope typo) rewrite files OUTSIDE the vault, beyond the entry-state
# snapshot's protection. Pure parameter expansion: no globbing on user input.
_scope_path_ok() {
  local p="$1" seg rest
  [ -n "$p" ] || return 1
  case "$p" in /*) return 1 ;; esac
  rest="$p/"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"; rest="${rest#*/}"
    case "$seg" in ''|'.'|'..') return 1 ;; esac
  done
  return 0
}

# Validate a comma-separated --scope / scope-set spec ("all" or path list);
# dies on a vault-escaping path OR an empty component (trailing comma,
# blank-only spec). Empty components are a hard error, not a skip: they are
# almost always a truncated path list, and tolerating them let the write
# loop's skip branch return non-zero under set -e AFTER the manifest was
# rewritten — a half-applied scope change. Callers run this BEFORE writing.
scope_spec_validate() {
  local spec="$1" p
  [ "$spec" = "all" ] && return 0
  [ -n "$spec" ] || die "Empty scope spec — use 'all' or a comma-separated path list"
  # Literal comma check FIRST: bash field splitting DROPS an empty field
  # after a trailing delimiter, so 'a.yaml,' would otherwise sail through
  # the loop below as just ['a.yaml'] — a truncated path list accepted
  # silently. Leading/doubled commas are the same typo family.
  case "$spec" in
    ,*|*,|*,,*) die "Empty scope path component in '$spec' (leading, trailing or doubled comma)" ;;
  esac
  local -a _sv_paths=()
  IFS=',' read -r -a _sv_paths <<< "$spec"
  for p in "${_sv_paths[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [ -n "$p" ] || die "Empty scope path component in '$spec' (blank between commas?)"
    _scope_path_ok "$p" || die "Invalid scope path '$p' — must stay inside the vault (relative, no '..', '.' or empty segments)"
  done
}

# Write <machine>'s scope into the manifest: "all" or comma-separated exact
# paths (shell-safe trimmed — xargs would mangle quotes/backslashes — and
# passed to yq via strenv, never embedded in the expression). The machine
# name is validated by both callers (add-recipient regex / scope set
# recipient-file check), so it is safe inside the yq path literal.
scope_manifest_set_machine() {
  local manifest="$1" machine="$2" spec="$3" p
  if [ "$spec" = "all" ]; then
    yq -i ".recipients.\"$machine\" = \"all\"" "$manifest"
    return 0
  fi
  yq -i ".recipients.\"$machine\" = []" "$manifest"
  local -a _sm_paths=()
  IFS=',' read -r -a _sm_paths <<< "$spec"
  for p in "${_sm_paths[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [ -n "$p" ] && p="$p" yq -i ".recipients.\"$machine\" += [strenv(p)]" "$manifest"
  done
  # Empty components are rejected by scope_spec_validate before we're called;
  # this keeps a (hypothetical) skipped last component from turning the
  # function's status non-zero and killing the caller under set -e.
  return 0
}

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
    [ -n "$f" ] || continue
    # Respect the vault's gitignore (init ignores secrets/, .secrets/): a
    # local plaintext yaml must not shape committed .sops.yaml rules, and
    # could deadlock every scope change via the zero-recipient guard. Outside
    # a git work tree check-ignore exits 128 → nothing is filtered.
    if git -C "$keyvault" check-ignore -q "$f" 2>/dev/null; then continue; fi
    printf '%s\n' "$f"
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
    # `recipients:` key, a value that isn't "all"/a path list, or a path that
    # escapes the vault. Rejecting here (the single load point) covers hand
    # edits that never went through scope set / add-recipient validation.
    local json
    if ! json="$(yq -o json '.' "$p" 2>/dev/null)"; then
      printf 'agentkeys: %s is not valid YAML\n' "$SCOPES_FILE_NAME" >&2
      return 1
    fi
    if ! printf '%s' "$json" | jq -e '
        (.recipients | type) == "object"
        and (.recipients | to_entries | all(
          .value == "all"
          or ((.value | type) == "array" and (.value | all(
            type == "string" and length > 0
            and (startswith("/") | not)
            and (split("/") | all(. != "" and . != "." and . != ".."))
          )))
        ))
      ' >/dev/null 2>&1; then
      printf 'agentkeys: %s malformed — .recipients must map each machine to "all" or a list of vault-relative paths (no "..", "." or absolute paths)\n' "$SCOPES_FILE_NAME" >&2
      return 1
    fi
    # A manifest that EXISTS but omits a registered recipient fails closed:
    # the machine would otherwise silently default to "all" and the next
    # regen would re-encrypt the whole vault to its key (a hand edit or merge
    # that loses a line must not turn into a grant-all). Only a MISSING
    # manifest file synthesizes all-"all" (legacy-vault upgrade, below).
    local missing
    missing="$(scope_read_recipients "$keyvault" | cut -f1 | LC_ALL=C sort | jq -R -s \
      --argjson have "$(printf '%s' "$json" | jq '.recipients | keys')" \
      -r 'split("\n") | map(select(length > 0)) | . - $have | join(", ")')"
    if [ -n "$missing" ]; then
      printf 'agentkeys: %s omits registered recipient(s): %s — list each machine explicitly, or delete the file to reset every machine to "all"\n' "$SCOPES_FILE_NAME" "$missing" >&2
      return 1
    fi
    # Reject scope paths git ignores (init ignores secrets/, .secrets/): an
    # ignored file is never committed or synced, so it is not a vault secret
    # — and updatekeys-then-git-add on one would abort AFTER re-keying it.
    # Outside a git work tree check-ignore exits 128 → nothing is rejected.
    local ip
    while IFS= read -r ip; do
      [ -n "$ip" ] || continue
      if git -C "$keyvault" check-ignore -q "$ip" 2>/dev/null; then
        printf 'agentkeys: %s lists gitignored path %s — ignored files are not vault secrets\n' "$SCOPES_FILE_NAME" "$ip" >&2
        return 1
      fi
    done < <(printf '%s' "$json" | jq -r '.recipients[] | select(type=="array") | .[]')
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
# scope value: "all" → yes; array → exact-path membership (fail-closed on
# paths not listed — new files are NOT auto-granted to scoped machines);
# absent → DENY. The loader already rejects a manifest that omits a
# registered machine; this default is defense in depth for direct callers —
# an unknown name must never widen to the whole vault.
scope_machine_allows() {
  local mj="$1" machine="$2" path="$3"
  printf '%s' "$mj" | jq -e --arg m "$machine" --arg p "$path" '
      .recipients[$m] as $v
      | ($v == "all") or ((($v | type) == "array") and ($v | index($p) != null))
    ' >/dev/null 2>&1 && echo 1 || echo 0
}

# ---------- entry-state snapshot / restore ----------
# A failed apply must put the working tree back EXACTLY as it was when the
# command started — NOT back to HEAD. The manifest is caller input ('scope
# regen' is documented as "run after hand-editing it", so it may carry
# uncommitted hand-edits), and encrypted files may be untracked; both are
# invisible to a checkout-HEAD rollback. So: snapshot every file an apply may
# write BEFORE the caller mutates anything, restore that snapshot on failure.

# Transaction state, set/reset by _scope_begin / _scope_end and read by
# _scope_exit_trap. SNAP_DIR non-empty = a transaction is open.
SCOPE_SNAP_DIR=""
SCOPE_SNAP_VAULT=""
SCOPE_SNAP_READY=0     # 1 only once the entry snapshot is COMPLETE
SCOPE_COMMITTED=0      # 1 once scope_apply's git commit has landed

# _scope_begin <keyvault> [extra vault-relative paths...]
# Snapshot .sops.yaml + the manifest + every encrypted-eligible yaml on disk
# (+ extras, e.g. the recipient pubkey add-recipient is about to write). A
# path absent at entry is recorded so restore deletes it.
_scope_begin() {
  local keyvault="$1"; shift
  SCOPE_SNAP_READY=0
  SCOPE_COMMITTED=0
  SCOPE_SNAP_VAULT="$keyvault"
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
  # Only now is restoring safe: a snapshot that died mid-copy would make
  # _scope_restore_entry's absent-in-data branch DELETE the original files.
  SCOPE_SNAP_READY=1
}

# Restore every snapshotted path to its entry state (delete what didn't
# exist). Best-effort: one failing copy must not stop the rest of the
# restore (under set -e it used to), so collect failures, finish the loop,
# and report — non-zero means the caller must keep the snapshot dir, it
# holds the only copy of the entry state for the failed paths.
_scope_restore_entry() {
  local keyvault="$1" f failed=""
  [ -n "${SCOPE_SNAP_DIR:-}" ] && [ -f "$SCOPE_SNAP_DIR/paths" ] || return 0
  while IFS= read -r f; do
    if [ -f "$SCOPE_SNAP_DIR/data/$f" ]; then
      cp -p "$SCOPE_SNAP_DIR/data/$f" "$keyvault/$f" 2>/dev/null || failed="$failed $f"
    else
      rm -f "$keyvault/$f" 2>/dev/null || failed="$failed $f"
    fi
  done < "$SCOPE_SNAP_DIR/paths"
  if [ -n "$failed" ]; then
    warn "⚠ Could not restore:$failed — recover them manually from $SCOPE_SNAP_DIR/data/"
    return 1
  fi
  return 0
}

# Discard the snapshot (on success, or after a restore). Disarm the EXIT
# trap FIRST (clear the variables), THEN best-effort remove the dir: the old
# order let a failing rm leave the trap armed, mis-restoring a transaction
# that had already succeeded.
_scope_end() {
  local dir="${SCOPE_SNAP_DIR:-}"
  SCOPE_SNAP_DIR=""
  SCOPE_SNAP_VAULT=""
  SCOPE_SNAP_READY=0
  SCOPE_COMMITTED=0
  if [ -n "$dir" ]; then rm -rf "$dir" 2>/dev/null || true; fi
  return 0
}

# EXIT-trap safety net. Installed by the cmd scripts (cmd-scope.sh,
# cmd-add-recipient.sh) right after sourcing this lib — NOT installed here:
# tests source this file and own their EXIT traps, and cmd-edit/cmd-sync
# carry their own. Catches any death between _scope_begin and _scope_end
# that the explicit _scope_fail guards didn't (set -e on an unguarded line,
# die from a helper, a killed subcommand) and restores the entry snapshot.
# Written as plain if-blocks: under set -e a failing && tail in a trap would
# abort the handler and clobber the script's real exit code.
_scope_exit_trap() {
  if [ -z "${SCOPE_SNAP_DIR:-}" ]; then return 0; fi   # no open transaction
  # Commit landed: the tree already IS the committed state — restoring now
  # would rewind the work tree behind HEAD. Drop the snapshot, keep the tree.
  if [ "${SCOPE_COMMITTED:-0}" = "1" ]; then
    rm -rf "$SCOPE_SNAP_DIR" 2>/dev/null || true
    SCOPE_SNAP_DIR=""
    return 0
  fi
  # Snapshot incomplete (_scope_begin itself died): nothing was mutated yet
  # (begin runs before any write), and restoring from a partial snapshot
  # would delete files whose copy never happened. Drop it, restore nothing.
  if [ "${SCOPE_SNAP_READY:-0}" != "1" ]; then
    rm -rf "$SCOPE_SNAP_DIR" 2>/dev/null || true
    SCOPE_SNAP_DIR=""
    return 0
  fi
  warn "Unexpected exit mid scope-change — restoring the entry state."
  if _scope_restore_entry "$SCOPE_SNAP_VAULT"; then
    rm -rf "$SCOPE_SNAP_DIR" 2>/dev/null || true
  else
    warn "⚠ Restore incomplete — entry snapshot kept at $SCOPE_SNAP_DIR (data/ holds the entry-state files)."
  fi
  SCOPE_SNAP_DIR=""
  return 0
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
  _scope_fail() {
    if _scope_restore_entry "$keyvault"; then
      _scope_end
    else
      # Partial restore: keep the snapshot (its data/ is the only copy of
      # the entry state) but disarm the EXIT trap — it would only re-fail.
      warn "⚠ Entry snapshot kept at $SCOPE_SNAP_DIR for manual recovery."
      SCOPE_SNAP_DIR=""
    fi
    die "$1"
  }
  if ! emit_sops_rules "$keyvault" > "$keyvault/.sops.yaml.tmp"; then
    # The cleanup itself must not out-die the rollback below (set -e).
    rm -f "$keyvault/.sops.yaml.tmp" 2>/dev/null || true
    _scope_fail "Refusing to write .sops.yaml — see error above (fix $SCOPES_FILE_NAME)."
  fi
  if ! mv "$keyvault/.sops.yaml.tmp" "$keyvault/.sops.yaml"; then
    rm -f "$keyvault/.sops.yaml.tmp" 2>/dev/null || true
    _scope_fail "Could not replace .sops.yaml — restored the pre-command state, no commit."
  fi
  local thin
  thin="$(awk -F': ' '/^    age:/{n=gsub(/,/,",",$2)+1; if(n<3) print n}' "$keyvault/.sops.yaml" | head -1 || true)"
  [ -n "$thin" ] && warn "⚠ A generated rule has < 3 recipients — emergency recovery at risk (spec §7)."
  # Compute the ruled-path list up front and CHECK it: a producer failing
  # inside `done < <(...)` is silently swallowed — fail-open, files missing
  # from the list would simply skip re-encryption while .sops.yaml already
  # claims the new rules. SCOPE_SNAP_DIR doubles as scratch space; it lives
  # exactly as long as this transaction.
  local ruled_list="$SCOPE_SNAP_DIR/ruled-paths"
  if ! scope_all_ruled_paths "$keyvault" > "$ruled_list"; then
    _scope_fail "Could not compute the ruled-path list — restored the pre-command state, no commit."
  fi
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
  done < "$ruled_list"
  _scope_faultpoint post-updatekeys
  local -a paths=(.sops.yaml "$SCOPES_FILE_NAME" "$@")
  [ ${#touched[@]} -gt 0 ] && paths+=("${touched[@]}")
  # Git pathspecs treat [], *, ? as fnmatch globs — a vault filename like
  # agents/a[1].yaml would sweep the unrelated bystander agents/a1.yaml
  # (possibly plaintext!) into the scope commit. :(literal) pins every
  # pathspec use (add / no-op check / commit / reset) to the exact names.
  local -a lit=(); local lp
  for lp in "${paths[@]}"; do lit+=(":(literal)$lp"); done
  # Staging/commit failures also restore the snapshot: unstage OUR paths
  # first (a partial add must not linger in the shared index; scoped to our
  # pathspec so unrelated staged work is untouched), then roll back.
  if ! git -C "$keyvault" add -- "${lit[@]}" 2>/dev/null; then
    git -C "$keyvault" reset -q -- "${lit[@]}" 2>/dev/null || true
    # The reset above is best-effort (|| true) — if IT failed too, a partial
    # add may linger in the shared index; say so instead of leaving it silent.
    if ! git -C "$keyvault" diff --cached --quiet -- "${lit[@]}" 2>/dev/null; then
      warn "⚠ Some scope paths are still staged (git index busy?) — run: git -C $keyvault reset -- <paths>"
    fi
    _scope_fail "git add failed for the scope change — restored the pre-command state, no commit."
  fi
  # No-op (re-setting the same scope, or regen right after add-recipient):
  # nothing staged among our paths → vault already in the desired state.
  if git -C "$keyvault" diff --cached --quiet -- "${lit[@]}"; then
    _scope_end
    info "✓ ${msg%%$'\n'*} (already up to date)"
    return 0
  fi
  if ! git -C "$keyvault" commit -q -m "$msg" -- "${lit[@]}"; then
    git -C "$keyvault" reset -q -- "${lit[@]}" 2>/dev/null || true
    if ! git -C "$keyvault" diff --cached --quiet -- "${lit[@]}" 2>/dev/null; then
      warn "⚠ Some scope paths are still staged (git index busy?) — run: git -C $keyvault reset -- <paths>"
    fi
    _scope_fail "git commit failed for the scope change — restored the pre-command state."
  fi
  # From here the commit is the truth: a death before _scope_end must NOT
  # restore the entry tree (HEAD would advance while the tree rewinds).
  SCOPE_COMMITTED=1
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
