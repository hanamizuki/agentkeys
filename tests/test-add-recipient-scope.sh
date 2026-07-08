#!/usr/bin/env bash
# add-recipient scope semantics: --scope, cwd-from-subdirectory (the cwd bug),
# and the CRITICAL idempotence property — adding a later machine must NOT undo
# an existing machine's per-path scope (codex P1: no silent revert to simple
# all-recipient mode). add-recipient is run on a machine that can already
# decrypt everything (core), registering the new machine's pubkey.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/vault-fixture.sh"
fixture_require_tools
fixture_new
trap 'rm -rf "$FIXTURE_HOME"' EXIT
source "$REPO/scripts/lib/scope.sh"

fail=0
has() { printf '%s' "$2" | grep -qF "$3" || { echo "FAIL: $1 — missing [$3]"; fail=1; }; }
ck() { [ "$2" = "$3" ] || { echo "FAIL: $1 — expected [$3] got [$2]"; fail=1; }; }
probe() { (cd "$VAULT" && SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/$1.txt" sops -d "$2" >/dev/null 2>&1) && echo OK || echo DENIED; }
# add-recipient always runs as core (can decrypt everything), from a foreign cwd.
add() { ( cd "$FIXTURE_HOME" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" \
          AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" add-recipient "$@" ); }

VAULT="$FIXTURE_HOME/v"
export AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt"
CORE="$(fixture_keygen core)"; EDGE="$(fixture_keygen edge)"; THIRD="$(fixture_keygen third)"

bash "$REPO/agentkeys" init "$VAULT" >/dev/null
# add core (all, default) from a sub-directory cwd — exercises the cwd fix.
add core >/dev/null 2>&1 || { echo "FAIL: add-recipient core errored (cwd bug?)"; fail=1; }

# seed two encrypted files (as core)
( cd "$VAULT"
  echo '{"K":"b"}' > agents/boba.yaml; echo '{"K":"m"}' > agents/mojo.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/boba.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/mojo.yaml
  git add -A && git commit -q -m seed )

# add edge scoped to boba only
add edge "$EDGE" --scope agents/boba.yaml >/dev/null 2>&1 \
  || { echo "FAIL: add-recipient edge --scope errored"; fail=1; }
has "manifest edge scoped" "$(cat "$VAULT/$SCOPES_FILE_NAME")" "agents/boba.yaml"
ck "edge reads boba"  "$(probe edge agents/boba.yaml)" "OK"
ck "edge DENIED mojo" "$(probe edge agents/mojo.yaml)" "DENIED"

# CRITICAL (codex P1): adding a 3rd all-machine must NOT re-grant edge on mojo.
add third "$THIRD" >/dev/null 2>&1 || { echo "FAIL: add-recipient third errored"; fail=1; }
ck "edge STILL denied mojo after 3rd add" "$(probe edge agents/mojo.yaml)" "DENIED"
ck "third (all) reads mojo"               "$(probe third agents/mojo.yaml)" "OK"
ck "manifest edge unchanged"  "$(yq -o json '.recipients.edge' "$VAULT/$SCOPES_FILE_NAME" | jq -c .)" '["agents/boba.yaml"]'

# --- review fix (r5): a manifest path works even before its file exists ---
# grant edge a not-yet-existing path, then create it — edge must decrypt it.
( cd "$FIXTURE_HOME" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" scope set edge agents/boba.yaml,agents/future.yaml ) >/dev/null 2>&1
echo '{"K":"f"}' > "$VAULT/agents/future.yaml"
( cd "$VAULT" && SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/future.yaml )
ck "edge decrypts a pre-listed future path" "$(probe edge agents/future.yaml)" "OK"

# --- review fix (r8): re-running add-recipient for a registered machine with
# --scope must FAIL loudly (a silent no-op would drop the requested scope change
# — the caller believes access was narrowed when nothing happened).
if add edge "$EDGE" --scope agents/boba.yaml >/dev/null 2>&1; then
  echo "FAIL: same-pubkey re-run with --scope should exit non-zero"; fail=1
fi
ck "manifest unchanged by rejected re-run" \
  "$(yq -o json '.recipients.edge' "$VAULT/$SCOPES_FILE_NAME" | jq -c .)" \
  '["agents/boba.yaml","agents/future.yaml"]'
# ...while a plain re-run (no --scope) stays a benign no-op.
add edge "$EDGE" >/dev/null 2>&1 || { echo "FAIL: plain same-pubkey re-run should be a no-op success"; fail=1; }
ck "manifest unchanged by plain re-run" \
  "$(yq -o json '.recipients.edge' "$VAULT/$SCOPES_FILE_NAME" | jq -c .)" \
  '["agents/boba.yaml","agents/future.yaml"]'

[ "$fail" -eq 0 ] && echo "PASS: add-recipient-scope" || exit 1
