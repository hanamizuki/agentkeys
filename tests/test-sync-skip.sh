#!/usr/bin/env bash
# A scope-limited machine's sync must materialize ONLY its in-scope files and
# SKIP (not die on) out-of-scope files.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/vault-fixture.sh"
fixture_require_tools
fixture_new
trap 'rm -rf "$FIXTURE_HOME"' EXIT

fail=0
has() { printf '%s' "$2" | grep -qF "$3" || { echo "FAIL: $1 — missing [$3]"; fail=1; }; }

VAULT="$FIXTURE_HOME/v"
export AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt"
fixture_keygen core >/dev/null; EDGE="$(fixture_keygen edge)"

bash "$REPO/agentkeys" init "$VAULT" >/dev/null 2>&1
AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" add-recipient core >/dev/null 2>&1
# Two agent files; edge scoped to boba only.
( cd "$VAULT"
  echo '{"BOBA_KEY":"b"}' > agents/boba.yaml; echo '{"MOJO_KEY":"m"}' > agents/mojo.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/boba.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/mojo.yaml
  git add -A && git commit -q -m seed )
AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" \
  add-recipient edge "$EDGE" --scope agents/boba.yaml >/dev/null 2>&1

# Sync AS edge → must succeed (exit 0), materialize boba, skip mojo.
SECRETS="$FIXTURE_HOME/.secrets-edge"
out="$(AGE_KEY_FILE="$FIXTURE_HOME/keys/edge.txt" AGENTKEYS_KEYVAULT="$VAULT" \
  bash "$REPO/agentkeys" sync --no-pull --secrets-dir "$SECRETS" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: edge sync died (rc=$rc) instead of skipping"; printf '%s\n' "$out"; fail=1; }
has "edge sync skipped mojo (log)" "$out" "Skipping agents/mojo.yaml"
[ -f "$SECRETS/agents/boba.env" ]  || { echo "FAIL: boba.env not materialized"; fail=1; }
[ -f "$SECRETS/agents/mojo.env" ]  && { echo "FAIL: mojo.env should NOT exist for edge"; fail=1; }
has "sync-state ok" "$(jq -r .status "$SECRETS/.sync-state" 2>/dev/null)" "ok"
has "sync-state counts a skip" "$(jq -r '.breakdown.skipped' "$SECRETS/.sync-state" 2>/dev/null)" "1"

# Sanity: core (all) still materializes BOTH.
SECRETS2="$FIXTURE_HOME/.secrets-core"
AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
  bash "$REPO/agentkeys" sync --no-pull --secrets-dir "$SECRETS2" >/dev/null 2>&1
[ -f "$SECRETS2/agents/mojo.env" ] || { echo "FAIL: core should materialize mojo"; fail=1; }

# The skip path must only engage for a key that IS a registered recipient:
# an unregistered key (no vault file lists it) must fail the sync up front —
# silently skipping everything would publish an OK state with an empty
# secrets dir, where the first sops -d used to fail loudly.
fixture_keygen stranger >/dev/null
SECRETS3="$FIXTURE_HOME/.secrets-stranger"
if AGE_KEY_FILE="$FIXTURE_HOME/keys/stranger.txt" AGENTKEYS_KEYVAULT="$VAULT" \
  bash "$REPO/agentkeys" sync --no-pull --secrets-dir "$SECRETS3" >/dev/null 2>&1; then
  echo "FAIL: sync with an unregistered key should die, not skip everything"; fail=1
fi

# ...same when the identity file's '# public key:' line was stripped: sops
# itself can still decrypt with it, but the skip logic cannot resolve the
# local pubkey, so every file would look out-of-scope. Fail loudly instead.
sed '/^# public key:/d' "$FIXTURE_HOME/keys/edge.txt" > "$FIXTURE_HOME/keys/edge-stripped.txt"
chmod 600 "$FIXTURE_HOME/keys/edge-stripped.txt"
if AGE_KEY_FILE="$FIXTURE_HOME/keys/edge-stripped.txt" AGENTKEYS_KEYVAULT="$VAULT" \
  bash "$REPO/agentkeys" sync --no-pull --secrets-dir "$SECRETS3" >/dev/null 2>&1; then
  echo "FAIL: sync with an unresolvable local pubkey should die, not skip everything"; fail=1
fi

# A file with NO sops recipients at all is not "out of scope" — it is
# plaintext sitting in the vault (an incident, not a scope decision). The
# skip path must not mask it: sync keeps dying loudly, exactly as it did
# before machine_can_decrypt existed.
echo 'PLAIN: oops' > "$VAULT/agents/plain.yaml"
if AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
  bash "$REPO/agentkeys" sync --no-pull --secrets-dir "$SECRETS2" >/dev/null 2>&1; then
  echo "FAIL: sync should die on a committed plaintext yaml, not skip it"; fail=1
fi
rm -f "$VAULT/agents/plain.yaml"

[ "$fail" -eq 0 ] && echo "PASS: sync-skip" || exit 1
