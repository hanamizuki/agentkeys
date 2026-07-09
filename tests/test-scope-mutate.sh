#!/usr/bin/env bash
# scope set/regen: change a machine's scope + sops updatekeys, verify the
# scoped machine loses access to out-of-scope files and regen widens it back.
# Runs updatekeys as a full-scope key (core).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/vault-fixture.sh"
fixture_require_tools
fixture_new
trap 'rm -rf "$FIXTURE_HOME"' EXIT
source "$REPO/scripts/lib/scope.sh"

fail=0
ck() { [ "$2" = "$3" ] || { echo "FAIL: $1 — expected [$3] got [$2]"; fail=1; }; }
probe() { (cd "$VAULT" && SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/$1.txt" sops -d "$2" >/dev/null 2>&1) && echo OK || echo DENIED; }

VAULT="$FIXTURE_HOME/v"
mkdir -p "$VAULT"/{shared,agents,services,files,recipients}
CORE="$(fixture_keygen core)"; EDGE="$(fixture_keygen edge)"; THIRD="$(fixture_keygen third)"
printf '%s\n' "$CORE"  > "$VAULT/recipients/core.age.pub"
printf '%s\n' "$EDGE"  > "$VAULT/recipients/edge.age.pub"
printf '%s\n' "$THIRD" > "$VAULT/recipients/third.age.pub"
cat > "$VAULT/$SCOPES_FILE_NAME" <<YAML
version: 1
recipients:
  core: all
  edge: all
  third: all
YAML
emit_sops_rules "$VAULT" > "$VAULT/.sops.yaml"
( cd "$VAULT"
  git init -q
  echo '{"K":"b"}' > agents/boba.yaml; echo '{"K":"m"}' > agents/mojo.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/boba.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/mojo.yaml
  git add -A && git commit -q -m seed )

ck "edge reads mojo (before)" "$(probe edge agents/mojo.yaml)" "OK"

# scope set edge → boba only, run as core (full scope)
( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge agents/boba.yaml ) >/dev/null 2>&1 \
  || { echo "FAIL: scope set errored"; fail=1; }
ck "edge reads boba (after set)"  "$(probe edge agents/boba.yaml)" "OK"
ck "edge DENIED mojo (after set)" "$(probe edge agents/mojo.yaml)" "DENIED"
ck "core still reads mojo"        "$(probe core agents/mojo.yaml)" "OK"
ck "manifest records edge scope"  "$(yq -o json '.recipients.edge' "$VAULT/$SCOPES_FILE_NAME" | jq -c .)" '["agents/boba.yaml"]'

# scope regen after a hand-edit widening edge back to all
( cd "$VAULT"
  yq -i '.recipients.edge = "all"' "$SCOPES_FILE_NAME"
  AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope regen ) >/dev/null 2>&1 \
  || { echo "FAIL: scope regen errored"; fail=1; }
ck "edge reads mojo again (regen)" "$(probe edge agents/mojo.yaml)" "OK"

# --- review fix (Finding 2, r4): failed updatekeys rolls back to a clean tree ---
# Narrow edge to boba and commit a clean baseline.
( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge agents/boba.yaml ) >/dev/null 2>&1
before="$(cd "$VAULT" && git status --porcelain)"
# Attempt 'scope set edge all' AS edge — edge can't decrypt mojo, so updatekeys
# must fail and roll back, leaving the working tree exactly as before.
( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/edge.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge all ) >/dev/null 2>&1
after="$(cd "$VAULT" && git status --porcelain)"
ck "failed updatekeys leaves clean tree" "$after" "$before"
ck "manifest still boba after rollback" "$(yq -o json '.recipients.edge' "$VAULT/$SCOPES_FILE_NAME" | jq -c .)" '["agents/boba.yaml"]'

# --- rollback must preserve pre-existing UNCOMMITTED manifest hand-edits ---
# 'scope regen' is documented as "run after hand-editing the manifest", so the
# manifest is caller INPUT: a failed apply must restore the tree to its ENTRY
# state, not to HEAD (checkout HEAD would destroy the operator's hand-edit
# along with the command's own changes).
printf '# operator note: keep me\n' >> "$VAULT/$SCOPES_FILE_NAME"
( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/edge.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge all ) >/dev/null 2>&1 \
  && { echo "FAIL: scope set as edge should still fail here"; fail=1; }
grep -q 'operator note: keep me' "$VAULT/$SCOPES_FILE_NAME" \
  || { echo "FAIL: failed apply destroyed an uncommitted manifest hand-edit"; fail=1; }
ck "hand-edited manifest keeps entry scope after failed set" \
  "$(yq -o json '.recipients.edge' "$VAULT/$SCOPES_FILE_NAME" | jq -c .)" '["agents/boba.yaml"]'
git -C "$VAULT" checkout -- "$SCOPES_FILE_NAME" 2>/dev/null || true

# --- review fix (r6-2): a no-op regen succeeds (was: set -e on "nothing to commit") ---
if ( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope regen ) >/dev/null 2>&1; then :; else
  echo "FAIL: no-op regen should succeed (exit 0)"; fail=1
fi

# --- review fix (r6-3): scope commit uses pathspec, doesn't sweep unrelated staged ---
( cd "$VAULT"
  echo x > unrelated.txt; git add unrelated.txt
  AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge all >/dev/null 2>&1
  git diff --cached --name-only | grep -qx unrelated.txt && echo STAGED || echo GONE ) > "$FIXTURE_HOME/p3"
ck "unrelated staged not swept into scope commit" "$(cat "$FIXTURE_HOME/p3")" "STAGED"

# --- review fix (r7-3): scope-path trimming strips spaces without xargs mangling ---
( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge " agents/boba.yaml , agents/mojo.yaml " ) >/dev/null 2>&1
ck "spaces trimmed in scope paths" "$(yq -o json '.recipients.edge' "$VAULT/$SCOPES_FILE_NAME" | jq -c .)" '["agents/boba.yaml","agents/mojo.yaml"]'

# --- review fix (r10-1): an EMPTY spec component (trailing comma, blank-only
# spec) is rejected up front — it used to slip past validation, then kill the
# caller under set -e AFTER yq rewrote the manifest but BEFORE scope_apply
# could re-encrypt or roll back: manifest changed, files still on the old
# recipients, no restore. Must fail BEFORE any mutation.
manifest_before="$(cat "$VAULT/$SCOPES_FILE_NAME")"
if ( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge "agents/boba.yaml," ) >/dev/null 2>&1; then
  echo "FAIL: trailing-comma scope spec should exit non-zero"; fail=1
fi
ck "manifest untouched after rejected trailing comma" "$(cat "$VAULT/$SCOPES_FILE_NAME")" "$manifest_before"
if ( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge " , " ) >/dev/null 2>&1; then
  echo "FAIL: blank-only scope spec should exit non-zero"; fail=1
fi
ck "manifest untouched after rejected blank spec" "$(cat "$VAULT/$SCOPES_FILE_NAME")" "$manifest_before"

# --- review fix (r10-2): space-separated paths are a hard error, not a
# silent partial grant — 'scope set edge a.yaml b.yaml' used to commit a
# scope of just a.yaml while reporting success.
if ( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge agents/boba.yaml agents/mojo.yaml ) >/dev/null 2>&1; then
  echo "FAIL: space-separated scope paths should exit non-zero"; fail=1
fi
ck "manifest untouched after rejected extra args" "$(cat "$VAULT/$SCOPES_FILE_NAME")" "$manifest_before"
if ( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope regen leftover ) >/dev/null 2>&1; then
  echo "FAIL: scope regen with extra args should exit non-zero"; fail=1
fi

# --- review fix (r11-2, P2): a scope path git IGNORES is rejected before any
# mutation — an ignored file is not a vault secret (never committed/synced),
# and updatekeys-then-git-add on one used to abort AFTER re-keying it, outside
# the rollback path, stranding a half-applied scope change.
( cd "$VAULT"
  printf 'secrets/\n' > .gitignore
  mkdir -p secrets
  echo '{"P":"t"}' > secrets/hidden.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i secrets/hidden.yaml )
manifest_before="$(cat "$VAULT/$SCOPES_FILE_NAME")"
hidden_before="$(fixture_hash "$VAULT/secrets/hidden.yaml")"
if ( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge agents/boba.yaml,secrets/hidden.yaml ) >/dev/null 2>&1; then
  echo "FAIL: scope set naming a gitignored path should exit non-zero"; fail=1
fi
ck "manifest restored after rejected ignored path" "$(cat "$VAULT/$SCOPES_FILE_NAME")" "$manifest_before"
ck "ignored file untouched after rejected set" "$(fixture_hash "$VAULT/secrets/hidden.yaml")" "$hidden_before"
rm -rf "$VAULT/secrets" "$VAULT/.gitignore"

# --- review fix (r12-1, P1): git pathspec metacharacters in vault filenames
# are staged/committed as LITERALS. 'agents/a[1].yaml' used to be read as an
# fnmatch glob: the literal file was silently left out of the scope commit
# while the unrelated bystander 'agents/a1.yaml' (plaintext!) was swept in.
( cd "$VAULT"
  echo '{"K":"lit"}' > 'agents/a[1].yaml'
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i 'agents/a[1].yaml'
  echo 'plaintext bystander' > agents/a1.yaml )
( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge 'agents/boba.yaml,agents/a[1].yaml' ) >/dev/null 2>&1 \
  || { echo "FAIL: scope set granting a bracket-named file errored"; fail=1; }
( cd "$VAULT" && git show --name-only --pretty=format: HEAD ) > "$FIXTURE_HOME/last_commit_files"
grep -qxF 'agents/a[1].yaml' "$FIXTURE_HOME/last_commit_files" \
  || { echo "FAIL: literal bracket-named file missing from the scope commit"; fail=1; }
grep -qxF 'agents/a1.yaml' "$FIXTURE_HOME/last_commit_files" \
  && { echo "FAIL: unrelated plaintext bystander swept into the scope commit"; fail=1; }
ck "bystander still untracked" "$(cd "$VAULT" && git status --porcelain -- agents/a1.yaml)" "?? agents/a1.yaml"

# --- review fix (r13/P1-1): a TRAILING SLASH on AGENTKEYS_KEYVAULT must not
# corrupt the scope change. find_keyvault_root used to return the raw value;
# scope_list_encrypted_files strips "$keyvault/" TEXTUALLY off find output,
# so 'vault//' never matched 'vault/…': paths stayed absolute, the metadata
# exclusions missed, .sops.yaml gained absolute-path rules, real files were
# skipped by updatekeys — and the revocation this scope set asks for
# (dropping agents/a[1].yaml from edge) silently did not happen, rc=0.
( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT/" \
    bash "$REPO/agentkeys" scope set edge agents/boba.yaml ) >/dev/null 2>&1 \
  || { echo "FAIL: scope set with trailing-slash keyvault errored"; fail=1; }
# NB: can't grep -F for $FIXTURE_HOME — regex atoms escape '.' (tmp\.xxx).
# The invariant: no generated path_regex may anchor on an ABSOLUTE path.
ck "no absolute paths leak into .sops.yaml" "$(grep -cE "path_regex: '\^\(/" "$VAULT/.sops.yaml")" "0"
ck "kept grant survives trailing-slash set"  "$(probe edge agents/boba.yaml)" "OK"
ck "revocation applies despite trailing slash" "$(probe edge 'agents/a[1].yaml')" "DENIED"
ck "unrelated file intact after trailing-slash set" "$(probe core agents/mojo.yaml)" "OK"

# --- review fix (r13/P2): a SYMLINK vault path must resolve to the physical
# dir. find does not recurse into a bare symlink operand (-P default), so a
# logically-canonicalized symlink keyvault made scope_list_encrypted_files
# come back EMPTY: files not listed in any manifest array lost their exact
# rules, and a revocation (drop a path from a machine) skipped updatekeys on
# the dropped file — old recipient kept access, rc=0.
( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge 'agents/boba.yaml,agents/a[1].yaml' ) >/dev/null 2>&1
ck "grant before symlink revoke" "$(probe edge 'agents/a[1].yaml')" "OK"
ln -s "$VAULT" "$FIXTURE_HOME/vlink"
( cd "$FIXTURE_HOME" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$FIXTURE_HOME/vlink" \
    bash "$REPO/agentkeys" scope set edge agents/boba.yaml ) >/dev/null 2>&1 \
  || { echo "FAIL: scope set via symlink keyvault errored"; fail=1; }
ck "revocation applies via symlink keyvault" "$(probe edge 'agents/a[1].yaml')" "DENIED"
ck "kept grant survives symlink revoke" "$(probe edge agents/boba.yaml)" "OK"
ck "unlisted file keeps its exact rule (find recursed)" \
  "$(grep -c 'agents/mojo' "$VAULT/.sops.yaml")" "1"

[ "$fail" -eq 0 ] && echo "PASS: scope-mutate" || exit 1
