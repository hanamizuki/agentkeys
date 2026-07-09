#!/usr/bin/env bash
# Enumeration-layer fail-closed guarantees (P1 batch): every input the scope
# generator enumerates — recipient pubkeys, the vault file scan, manifest
# entries — must fail LOUDLY on unreadable/malformed/inconsistent state. A
# silently dropped machine or file turns the next updatekeys pass into a
# silent revocation (or leaves a revoked key able to decrypt).
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

# ---------- unit: hand-built vault, no sops needed ----------
UV="$FIXTURE_HOME/uv"
mkdir -p "$UV"/{shared,agents,recipients}
CORE="$(fixture_keygen core)"; EDGE="$(fixture_keygen edge)"
printf '%s\n' "$CORE" > "$UV/recipients/core.age.pub"
printf '%s\n' "$EDGE" > "$UV/recipients/edge.age.pub"
touch "$UV/agents/boba.yaml" "$UV/agents/mojo.yaml"
manifest_ok() {
  cat > "$UV/$SCOPES_FILE_NAME" <<YAML
version: 1
recipients:
  core: all
  edge:
    - agents/boba.yaml
YAML
}
manifest_ok

# --- (1) an UNREADABLE pubkey file fails closed: silently skipping it drops
# that machine from every generated rule → next updatekeys silently revokes.
chmod 000 "$UV/recipients/edge.age.pub"
if scope_read_recipients "$UV" >/dev/null 2>&1; then
  echo "FAIL: scope_read_recipients should fail on an unreadable pubkey"; fail=1
fi
if scope_load_manifest "$UV" >/dev/null 2>&1; then
  echo "FAIL: scope_load_manifest should fail while a pubkey is unreadable"; fail=1
fi
chmod 644 "$UV/recipients/edge.age.pub"

# --- (1b) a pubkey file with NO age1 line is malformed, not skippable.
printf 'not a key\n' > "$UV/recipients/bad.age.pub"
if scope_read_recipients "$UV" >/dev/null 2>&1; then
  echo "FAIL: scope_read_recipients should fail on a pubkey file with no age1 line"; fail=1
fi
rm -f "$UV/recipients/bad.age.pub"

# ...and the healthy vault still enumerates both machines (rc 0).
rcp="$(scope_read_recipients "$UV")" \
  || { echo "FAIL: scope_read_recipients errored on a healthy vault"; fail=1; }
ck "healthy vault lists both machines" "$(printf '%s\n' "$rcp" | cut -f1 | LC_ALL=C sort | paste -sd, -)" "core,edge"

# --- (2) a manifest naming a machine with NO recipients/<m>.age.pub fails
# closed — the other half of the missing-recipient check: a stale/typo'd
# manifest entry must surface at the load gate, not ride along as a rule for
# a key that does not exist.
cat > "$UV/$SCOPES_FILE_NAME" <<YAML
version: 1
recipients:
  core: all
  edge:
    - agents/boba.yaml
  ghost: all
YAML
if scope_load_manifest "$UV" >/dev/null 2>&1; then
  echo "FAIL: manifest naming an unregistered machine should fail closed"; fail=1
fi
manifest_ok

# --- (3) a find traversal failure fails closed: with its stderr discarded
# and its status swallowed by the pipeline, an unreadable subdirectory used
# to yield a silently INCOMPLETE file list — files missing from it simply
# skip re-encryption on a scope change (a revoked key keeps decrypting them).
mkdir -p "$UV/blocked"; touch "$UV/blocked/x.yaml"
chmod 000 "$UV/blocked"
if scope_list_encrypted_files "$UV" >/dev/null 2>&1; then
  echo "FAIL: scope_list_encrypted_files should fail when find cannot traverse"; fail=1
fi
chmod 755 "$UV/blocked"; rm -rf "$UV/blocked"
# ...healthy vault still lists (rc 0, both files).
listed="$(scope_list_encrypted_files "$UV")" \
  || { echo "FAIL: scope_list_encrypted_files errored on a healthy vault"; fail=1; }
ck "healthy vault lists both files" "$(printf '%s\n' "$listed" | paste -sd, -)" "agents/boba.yaml,agents/mojo.yaml"

# --- (4) manifest scope paths must not name the CLI-managed metadata files
# (never sops-encrypted; the file scan excludes them for the same reason).
# Hand-writing one into the manifest would rule the metadata file itself as
# a secret and feed it to updatekeys.
for meta in .sops.yaml .agentkeys-scopes.yaml recipients/core.age.pub; do
  cat > "$UV/$SCOPES_FILE_NAME" <<YAML
version: 1
recipients:
  core: all
  edge:
    - $meta
YAML
  if scope_load_manifest "$UV" >/dev/null 2>&1; then
    echo "FAIL: manifest scope path '$meta' should fail closed"; fail=1
  fi
done
manifest_ok

# --- (5) one pubkey registered under TWO machine names with DIFFERENT
# scopes fails closed: scope is machine-name keyed but decrypt capability is
# key-level — every rule listing either name carries the same key, so the
# wider scope would silently win for both.
printf '%s\n' "$EDGE" > "$UV/recipients/edgetwin.age.pub"   # same key as edge
cat > "$UV/$SCOPES_FILE_NAME" <<YAML
version: 1
recipients:
  core: all
  edge:
    - agents/boba.yaml
  edgetwin: all
YAML
if scope_load_manifest "$UV" >/dev/null 2>&1; then
  echo "FAIL: shared pubkey with divergent scopes should fail closed"; fail=1
fi
# ...but IDENTICAL scopes on a shared key stay allowed (a benign alias),
# including the same path list written in a different order.
cat > "$UV/$SCOPES_FILE_NAME" <<YAML
version: 1
recipients:
  core: all
  edge:
    - agents/boba.yaml
    - agents/mojo.yaml
  edgetwin:
    - agents/mojo.yaml
    - agents/boba.yaml
YAML
scope_load_manifest "$UV" >/dev/null 2>&1 \
  || { echo "FAIL: shared pubkey with identical scopes should still load"; fail=1; }
rm -f "$UV/recipients/edgetwin.age.pub"
manifest_ok

# ---------- integration: real vault via the CLI ----------
# The unit guards above are only worth anything if a failure PROPAGATES to
# the command's exit status with the tree untouched — process substitutions
# and brace-group pipelines between here and there used to swallow it.
VAULT="$FIXTURE_HOME/v"
export AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt"

bash "$REPO/agentkeys" init "$VAULT" >/dev/null 2>&1
fixture_as core add-recipient core >/dev/null 2>&1 \
  || { echo "FAIL: add-recipient core errored"; fail=1; }
( cd "$VAULT"
  echo '{"K":"b"}' > agents/boba.yaml; echo '{"K":"m"}' > agents/mojo.yaml
  echo '{"MODEL":"x"}' > shared/model.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/boba.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i agents/mojo.yaml
  SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i shared/model.yaml
  git add -A && git commit -q -m seed )
fixture_as core add-recipient edge "$EDGE" --scope agents/boba.yaml >/dev/null 2>&1 \
  || { echo "FAIL: add-recipient edge --scope errored"; fail=1; }

snap_tree() {
  git -C "$VAULT" rev-parse HEAD
  git -C "$VAULT" status --porcelain
  fixture_hash "$VAULT/.sops.yaml"
  fixture_hash "$VAULT/agents/boba.yaml"
  fixture_hash "$VAULT/agents/mojo.yaml"
}

# (i1) unreadable pubkey → regen dies, tree untouched.
before="$(snap_tree)"
chmod 000 "$VAULT/recipients/edge.age.pub"
if fixture_as core scope regen >/dev/null 2>&1; then
  echo "FAIL: scope regen should die while a pubkey is unreadable"; fail=1
fi
chmod 644 "$VAULT/recipients/edge.age.pub"
ck "tree untouched after unreadable-pubkey regen" "$(snap_tree)" "$before"

# (i2) manifest naming an unregistered machine → regen dies; the hand-edit
# itself survives (rollback restores the ENTRY state, and the bad line IS
# the entry state — the operator fixes it, not the rollback).
( cd "$VAULT" && yq -i '.recipients.ghost = "all"' "$SCOPES_FILE_NAME" )
if fixture_as core scope regen >/dev/null 2>&1; then
  echo "FAIL: scope regen should die on a manifest naming an unregistered machine"; fail=1
fi
ck "hand-edit survives the failed regen" \
  "$(yq -r '.recipients.ghost // "absent"' "$VAULT/$SCOPES_FILE_NAME")" "all"
ck "HEAD unchanged after unknown-machine regen" \
  "$(git -C "$VAULT" rev-parse HEAD)" "$(printf '%s' "$before" | head -1)"
( cd "$VAULT" && git checkout -q -- "$SCOPES_FILE_NAME" )

# (i3) unreadable subdirectory → regen dies BEFORE any mutation (the
# _scope_begin snapshot cannot be complete), tree untouched.
mkdir -p "$VAULT/blocked"; touch "$VAULT/blocked/x.yaml"
( cd "$VAULT" && git add blocked && git commit -q -m blocked )
before="$(snap_tree)"
chmod 000 "$VAULT/blocked"
if fixture_as core scope regen >/dev/null 2>&1; then
  echo "FAIL: scope regen should die when the vault scan cannot complete"; fail=1
fi
chmod 755 "$VAULT/blocked"
ck "tree untouched after blocked-scan regen" "$(snap_tree)" "$before"
( cd "$VAULT" && git rm -q -r blocked && git commit -q -m unblock )

# (i6) sync's enumeration agrees with scope's on "what is a vault secret":
# a gitignored plaintext yaml inside shared/ is NOT a secret — the old
# per-dir glob fed it to sops -d and the whole sync died on it.
echo 'shared/local.yaml' >> "$VAULT/.gitignore"
echo 'LOCAL: plain' > "$VAULT/shared/local.yaml"
SECRETS="$FIXTURE_HOME/.secrets-core"
if ! fixture_as core sync --no-pull --secrets-dir "$SECRETS" >/dev/null 2>&1; then
  echo "FAIL: sync should skip a gitignored plaintext yaml, not die on it"; fail=1
fi
[ -f "$SECRETS/shared/model.env" ] || { echo "FAIL: sync stopped materializing shared/model.env"; fail=1; }
[ -f "$SECRETS/agents/boba.env" ]  || { echo "FAIL: sync stopped materializing agents/boba.env"; fail=1; }
[ -f "$SECRETS/shared/local.env" ] && { echo "FAIL: gitignored plaintext must not be materialized"; fail=1; }
rm -f "$VAULT/shared/local.yaml"
( cd "$VAULT" && git checkout -q -- .gitignore )

# ...and a vault secret OUTSIDE the four Type dirs must not break sync (it
# is simply not materialized — same as before, now via the shared list).
mkdir -p "$VAULT/misc"
echo '{"M":"x"}' > "$VAULT/misc/foo.yaml"
( cd "$VAULT" && SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i misc/foo.yaml )
if ! fixture_as core sync --no-pull --secrets-dir "$SECRETS" >/dev/null 2>&1; then
  echo "FAIL: sync should tolerate an encrypted file outside the Type dirs"; fail=1
fi
[ -d "$SECRETS/misc" ] && { echo "FAIL: non-Type files must not be materialized"; fail=1; }
rm -rf "$VAULT/misc"

[ "$fail" -eq 0 ] && echo "PASS: scope-enum" || exit 1
