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

[ "$fail" -eq 0 ] && echo "PASS: scope-mutate" || exit 1
