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

# An EXPLICIT --scope all on a registered scoped machine is a widen request —
# it must be rejected too (indistinguishable intent-drop otherwise: the caller
# believes the machine was widened while nothing happened).
if add edge "$EDGE" --scope all >/dev/null 2>&1; then
  echo "FAIL: same-pubkey re-run with explicit --scope all should exit non-zero"; fail=1
fi
ck "manifest unchanged by rejected --scope all re-run" \
  "$(yq -o json '.recipients.edge' "$VAULT/$SCOPES_FILE_NAME" | jq -c .)" \
  '["agents/boba.yaml","agents/future.yaml"]'

# --- a failed add-recipient rolls EVERYTHING back, including untracked
# encrypted files. Run add-recipient AS edge (cannot decrypt mojo) → updatekeys
# fails → the new pubkey, its manifest entry, and every re-encrypted file must
# return to their entry state. agents/future.yaml is deliberately UNTRACKED
# here (never committed) — a checkout-HEAD style rollback cannot restore it.
FOURTH="$(fixture_keygen fourth)"
before_st="$(cd "$VAULT" && git status --porcelain)"
future_before="$(md5 -q "$VAULT/agents/future.yaml")"
if ( cd "$FIXTURE_HOME" && AGE_KEY_FILE="$FIXTURE_HOME/keys/edge.txt" AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" add-recipient fourth "$FOURTH" ) >/dev/null 2>&1; then
  echo "FAIL: add-recipient as a scoped machine should fail (cannot updatekeys everything)"; fail=1
fi
[ ! -f "$VAULT/recipients/fourth.age.pub" ] || { echo "FAIL: failed add left fourth.age.pub behind"; fail=1; }
ck "manifest has no fourth after failed add" \
  "$(yq -o json '.recipients.fourth // "absent"' "$VAULT/$SCOPES_FILE_NAME" | jq -c .)" '"absent"'
ck "failed add-recipient leaves tree as it was" "$(cd "$VAULT" && git status --porcelain)" "$before_st"
ck "untracked encrypted file restored after failed add" \
  "$(md5 -q "$VAULT/agents/future.yaml")" "$future_before"

# --- review fix (r9-4, P2): an INVALID existing manifest must be rejected
# BEFORE anything is written — previously yq -i died under set -e after the
# pubkey was already on disk but before scope_apply installed its rollback,
# leaving a half-onboarded vault.
printf 'version: 1\nrecipientz: broken\n' > "$VAULT/$SCOPES_FILE_NAME"
FIFTH="$(fixture_keygen fifth)"
if add fifth "$FIFTH" >/dev/null 2>&1; then
  echo "FAIL: add-recipient should reject an invalid manifest"; fail=1
fi
[ ! -f "$VAULT/recipients/fifth.age.pub" ] || { echo "FAIL: invalid-manifest add left fifth.age.pub behind"; fail=1; }
ck "invalid manifest left untouched" "$(cat "$VAULT/$SCOPES_FILE_NAME")" "$(printf 'version: 1\nrecipientz: broken\n')"
git -C "$VAULT" checkout -- "$SCOPES_FILE_NAME" 2>/dev/null || true

# --scope paths that escape the vault are rejected up front (same guard as
# the manifest validator — updatekeys must never touch files outside).
if add sixth "$(fixture_keygen sixth)" --scope ../escape.yaml >/dev/null 2>&1; then
  echo "FAIL: --scope with a vault-escaping path should exit non-zero"; fail=1
fi
[ ! -f "$VAULT/recipients/sixth.age.pub" ] || { echo "FAIL: rejected --scope path still wrote sixth.age.pub"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: add-recipient-scope" || exit 1
