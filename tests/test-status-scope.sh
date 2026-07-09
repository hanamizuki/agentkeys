#!/usr/bin/env bash
# `agentkeys status` shows this machine's decrypt scope: which vault files
# the local age key can actually decrypt — so an operator can eyeball a
# scope-limited machine and confirm it only reaches its intended subset.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/vault-fixture.sh"
fixture_require_tools
fixture_new
trap 'rm -rf "$FIXTURE_HOME"' EXIT

fail=0
# <<< not `printf | grep -q`: under pipefail, grep -q exiting at an early
# match SIGPIPEs printf on large inputs (this file asserts on ~120KB of
# status output) and flips a FOUND string into a false FAIL.
has() { grep -qF "$3" <<< "$2" || { echo "FAIL: $1 — missing [$3]"; fail=1; }; }
hasnt() { grep -qF "$3" <<< "$2" && { echo "FAIL: $1 — unexpected [$3]"; fail=1; }; }

VAULT="$FIXTURE_HOME/v"
export AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt"
fixture_keygen core >/dev/null; EDGE="$(fixture_keygen edge)"

bash "$REPO/agentkeys" init "$VAULT" >/dev/null 2>&1
AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" add-recipient core >/dev/null 2>&1
( cd "$VAULT"
  echo '{"BOBA_KEY":"b"}' > agents/boba.yaml; echo '{"MOJO_KEY":"m"}' > agents/mojo.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/boba.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/mojo.yaml
  git add -A && git commit -q -m seed )
AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" \
  add-recipient edge "$EDGE" --scope agents/boba.yaml >/dev/null 2>&1

# Scoped machine: sees ONLY its subset, marked ✓.
out_edge="$(AGE_KEY_FILE="$FIXTURE_HOME/keys/edge.txt" AGENTKEYS_KEYVAULT="$VAULT" \
  bash "$REPO/agentkeys" status 2>&1)" || { echo "FAIL: status as edge exited non-zero"; fail=1; }
has   "edge status has a scope section" "$out_edge" "decrypt scope"
has   "edge sees boba"                  "$out_edge" "✓ agents/boba.yaml"
hasnt "edge does not see mojo"          "$out_edge" "✓ agents/mojo.yaml"

# Full-scope machine: sees everything.
out_core="$(AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
  bash "$REPO/agentkeys" status 2>&1)" || { echo "FAIL: status as core exited non-zero"; fail=1; }
has "core sees boba" "$out_core" "✓ agents/boba.yaml"
has "core sees mojo" "$out_core" "✓ agents/mojo.yaml"

# A key that decrypts nothing says so (instead of an empty section).
fixture_keygen stranger >/dev/null
out_stranger="$(AGE_KEY_FILE="$FIXTURE_HOME/keys/stranger.txt" AGENTKEYS_KEYVAULT="$VAULT" \
  bash "$REPO/agentkeys" status 2>&1)" || { echo "FAIL: status as stranger exited non-zero"; fail=1; }
has "stranger told it decrypts nothing" "$out_stranger" "decrypts nothing"

# A plaintext yaml in the vault is NOT "out of this machine's scope" — it is
# readable by everyone. The scope section must flag it loudly, not silently
# omit it (an operator would read the omission as "this machine can't touch
# that file").
echo 'PLAIN: oops' > "$VAULT/agents/plain.yaml"
out_plain="$(AGE_KEY_FILE="$FIXTURE_HOME/keys/edge.txt" AGENTKEYS_KEYVAULT="$VAULT" \
  bash "$REPO/agentkeys" status 2>&1)" || { echo "FAIL: status with a plaintext yaml exited non-zero"; fail=1; }
has "plaintext flagged in the scope section" "$out_plain" "NOT sops-encrypted"
has "plaintext line names the file"          "$out_plain" "agents/plain.yaml"
rm -f "$VAULT/agents/plain.yaml"

# STALE with >20 pending commits must not kill status mid-output: the old
# `git log | head -20` let head exit early, git log took SIGPIPE (141), and
# pipefail+set -e aborted before the recipients/scope sections printed.
SECRETS="$FIXTURE_HOME/.secrets-stale"
AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
  bash "$REPO/agentkeys" sync --no-pull --secrets-dir "$SECRETS" >/dev/null 2>&1
# Long one-line subjects: the pending list must exceed the pipe buffer so the
# producer is still writing when a truncating consumer exits — that is the
# regression condition (small histories fit one write and never trip it).
long="$(printf 'x%.0s' $(seq 1 6000))"
( cd "$VAULT" && for i in $(seq 1 30); do git commit -q --allow-empty -m "filler $i $long"; done )
out_stale="$(AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" AGENTKEYS_KEYVAULT="$VAULT" \
  bash "$REPO/agentkeys" status --secrets-dir "$SECRETS" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: stale status with >20 pending commits exited rc=$rc"; fail=1; }
has "stale status still reaches the scope section" "$out_stale" "decrypt scope"
has "stale status shows pending commits"           "$out_stale" "Pending commits:"

[ "$fail" -eq 0 ] && echo "PASS: status-scope" || exit 1
