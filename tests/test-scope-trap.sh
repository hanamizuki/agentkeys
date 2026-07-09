#!/usr/bin/env bash
# shellcheck disable=SC2034  # transaction globals here are read by lib/scope.sh
# EXIT-trap safety net: any unexpected death between _scope_begin and
# _scope_end (set -e, die, environment failure) must restore the entry
# snapshot. Two layers:
#   unit — _scope_exit_trap's flag table (SCOPE_SNAP_READY / SCOPE_COMMITTED)
#   integration — AGENTKEYS_FAULT=post-updatekeys aborts scope set mid-apply
#     (post-mutation, pre-commit: the widest damage window) and the vault
#     must come back byte-identical.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/vault-fixture.sh"
fixture_require_tools
fixture_new
trap 'rm -rf "$FIXTURE_HOME"' EXIT
# NOT sourcing common.sh — it sets -euo pipefail on whoever sources it. Stub
# the loggers the lib expects instead (same pattern as the other tests).
info() { :; }; warn() { echo "$@" >&2; }; die() { echo "$@" >&2; exit 1; }
source "$REPO/scripts/lib/scope.sh"

fail=0
ck() { [ "$2" = "$3" ] || { echo "FAIL: $1 — expected [$3] got [$2]"; fail=1; }; }

# ---------- unit: _scope_exit_trap flag table ----------
# Tiny git work tree — the handler only moves bytes, no sops needed.
UV="$FIXTURE_HOME/unit"
mkdir -p "$UV"
git -C "$UV" init -q
echo entry-a > "$UV/a.yaml"

# 1. No open transaction → no-op, rc 0.
SCOPE_SNAP_DIR=""
_scope_exit_trap; ck "no-op rc with no open transaction" "$?" "0"
ck "no-op leaves files alone" "$(cat "$UV/a.yaml")" "entry-a"

# 2. SNAP_READY=0 (begin died mid-snapshot): paths lists a.yaml but data/ has
# no copy. Restoring would take the rm-branch and DELETE the original — the
# handler must NOT restore from an incomplete snapshot.
SCOPE_SNAP_DIR="$(mktemp -d)"
SCOPE_SNAP_VAULT="$UV"
SCOPE_SNAP_READY=0
SCOPE_COMMITTED=0
printf '%s\n' "a.yaml" > "$SCOPE_SNAP_DIR/paths"
_scope_exit_trap 2>/dev/null
[ -f "$UV/a.yaml" ] || { echo "FAIL: READY=0 restore deleted a file the snapshot never copied"; fail=1; }
ck "READY=0 leaves file content alone" "$(cat "$UV/a.yaml" 2>/dev/null)" "entry-a"

# 3. READY=1, COMMITTED=0 (death mid-transaction) → full restore: a mutated
# file returns to its entry bytes, a file created after begin is deleted,
# and the snapshot dir is cleaned up.
_scope_begin "$UV"
snap_dir="$SCOPE_SNAP_DIR"
echo mutated > "$UV/a.yaml"
echo generated > "$UV/.sops.yaml"   # absent at entry → restore must delete it
_scope_exit_trap 2>/dev/null
ck "mid-transaction death restores entry bytes" "$(cat "$UV/a.yaml")" "entry-a"
[ ! -f "$UV/.sops.yaml" ] || { echo "FAIL: file created after begin survived the restore"; fail=1; }
[ ! -d "$snap_dir" ] || { echo "FAIL: snapshot dir not cleaned up after restore"; fail=1; }

# 4. COMMITTED=1 (death between commit and _scope_end) → the tree already IS
# the committed state: cleanup only, restore nothing.
_scope_begin "$UV"
snap_dir="$SCOPE_SNAP_DIR"
echo committed > "$UV/a.yaml"
SCOPE_COMMITTED=1
_scope_exit_trap 2>/dev/null
ck "COMMITTED=1 keeps the new state" "$(cat "$UV/a.yaml")" "committed"
[ ! -d "$snap_dir" ] || { echo "FAIL: snapshot dir not cleaned up after committed exit"; fail=1; }
SCOPE_SNAP_DIR=""; SCOPE_SNAP_READY=0; SCOPE_COMMITTED=0

# ---------- unit: _scope_restore_entry is best-effort ----------
# One unreadable snapshot copy must not stop the OTHER files from being
# restored (set -e used to kill the loop at the first failing cp), and a
# partial restore must report non-zero instead of a silent success.
RV="$FIXTURE_HOME/restore"
mkdir -p "$RV"
git -C "$RV" init -q
echo entry-a > "$RV/a.yaml"
echo entry-b > "$RV/b.yaml"
_scope_begin "$RV"
rsnap="$SCOPE_SNAP_DIR"
echo mutated-a > "$RV/a.yaml"
echo mutated-b > "$RV/b.yaml"
chmod 000 "$rsnap/data/a.yaml"   # a's entry copy unreadable → its cp fails
# (i) bare call under set -e (how _scope_fail reaches it in the cmd scripts):
# the loop must push past the failing file and still restore b.
( set -euo pipefail; _scope_restore_entry "$RV" ) 2>/dev/null
ck "best-effort: b restored despite a's unreadable copy" "$(cat "$RV/b.yaml")" "entry-b"
# (ii) checked call: a partial restore must return non-zero.
if ( set -euo pipefail
     if _scope_restore_entry "$RV" 2>/dev/null; then exit 0; else exit 1; fi ); then
  echo "FAIL: partial restore should report non-zero"; fail=1
fi
# (iii) the EXIT trap must KEEP the snapshot when the restore was partial —
# data/ holds the only copy of the entry state for manual recovery.
SCOPE_SNAP_DIR="$rsnap"; SCOPE_SNAP_VAULT="$RV"; SCOPE_SNAP_READY=1; SCOPE_COMMITTED=0
_scope_exit_trap 2>/dev/null
[ -d "$rsnap" ] || { echo "FAIL: trap dropped the snapshot despite a partial restore"; fail=1; }
chmod 644 "$rsnap/data/a.yaml" 2>/dev/null
rm -rf "$rsnap"
SCOPE_SNAP_DIR=""; SCOPE_SNAP_VAULT=""; SCOPE_SNAP_READY=0; SCOPE_COMMITTED=0

# ---------- integration: abrupt death mid-apply is fully rolled back ----------
VAULT="$FIXTURE_HOME/v"
export AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt"
fixture_keygen core >/dev/null; EDGE="$(fixture_keygen edge)"
run() { ( cd "$VAULT" && AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" \
          AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" "$@" ); }

bash "$REPO/agentkeys" init "$VAULT" >/dev/null
run add-recipient core >/dev/null 2>&1 || { echo "FAIL: add core errored"; fail=1; }
run add-recipient edge "$EDGE" >/dev/null 2>&1 || { echo "FAIL: add edge errored"; fail=1; }
( cd "$VAULT"
  echo '{"K":"b"}' > agents/boba.yaml; echo '{"K":"m"}' > agents/mojo.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/boba.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/mojo.yaml
  git add -A && git commit -q -m seed )

entry_head="$(git -C "$VAULT" rev-parse HEAD)"
entry_manifest="$(fixture_hash "$VAULT/$SCOPES_FILE_NAME")"
entry_sops="$(fixture_hash "$VAULT/.sops.yaml")"
entry_boba="$(fixture_hash "$VAULT/agents/boba.yaml")"
entry_mojo="$(fixture_hash "$VAULT/agents/mojo.yaml")"
entry_st="$(cd "$VAULT" && git status --porcelain)"

# Death AFTER the manifest was rewritten, .sops.yaml regenerated and every
# ruled file re-encrypted — but BEFORE the commit. Without the safety net all
# of that stays on disk, half-applied and unrecorded.
if AGENTKEYS_FAULT=post-updatekeys run scope set edge agents/boba.yaml >/dev/null 2>&1; then
  echo "FAIL: faulted scope set should exit non-zero"; fail=1
fi
ck "manifest restored after mid-apply death"   "$(fixture_hash "$VAULT/$SCOPES_FILE_NAME")" "$entry_manifest"
ck ".sops.yaml restored after mid-apply death" "$(fixture_hash "$VAULT/.sops.yaml")" "$entry_sops"
ck "boba.yaml restored after mid-apply death"  "$(fixture_hash "$VAULT/agents/boba.yaml")" "$entry_boba"
ck "mojo.yaml restored after mid-apply death"  "$(fixture_hash "$VAULT/agents/mojo.yaml")" "$entry_mojo"
ck "HEAD unchanged after mid-apply death"      "$(git -C "$VAULT" rev-parse HEAD)" "$entry_head"
ck "work tree clean after mid-apply death"     "$(cd "$VAULT" && git status --porcelain)" "$entry_st"

# The same command without the fault still works end to end (the trap must
# not interfere with the success path).
run scope set edge agents/boba.yaml >/dev/null 2>&1 \
  || { echo "FAIL: scope set without fault errored"; fail=1; }
ck "scope set landed after clean run" \
  "$(yq -o json '.recipients.edge' "$VAULT/$SCOPES_FILE_NAME" | jq -c .)" '["agents/boba.yaml"]'

[ "$fail" -eq 0 ] && echo "PASS: scope-trap" || exit 1
