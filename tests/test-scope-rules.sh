#!/usr/bin/env bash
# Unit tests for scripts/lib/scope.sh emit_sops_rules + helpers.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/vault-fixture.sh"
fixture_require_tools
fixture_new
trap 'rm -rf "$FIXTURE_HOME"' EXIT
source "$REPO/scripts/lib/scope.sh"

# Build a vault by hand (no CLI yet): recipients + a few encrypted files.
VAULT="$FIXTURE_HOME/v"
mkdir -p "$VAULT"/{shared,agents,services,files,recipients}
CORE="$(fixture_keygen core)"      # scope: all
EDGE="$(fixture_keygen edge)"      # scope: only agents/boba.yaml
printf '%s\n' "$CORE" > "$VAULT/recipients/core.age.pub"
printf '%s\n' "$EDGE" > "$VAULT/recipients/edge.age.pub"

fail=0
ck() { if [ "$2" = "$3" ]; then :; else echo "FAIL: $1 — expected [$3] got [$2]"; fail=1; fi; }
has() { if printf '%s' "$2" | grep -qF "$3"; then :; else echo "FAIL: $1 — missing [$3] in:"; printf '%s\n' "$2"; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF "$3"; then echo "FAIL: $1 — unexpected [$3]"; fail=1; fi; }

# --- helpers ---
ck "list files/ first" \
  "$(scope_list_encrypted_files "$VAULT" | head -1)" \
  ""   # no files yet → empty first line; add files below and re-test ordering

# Add encrypted files: boba (both), mojo (core only), a shared, a files/ manifest.
touch "$VAULT/agents/boba.yaml" "$VAULT/agents/mojo.yaml" \
      "$VAULT/shared/model.yaml" "$VAULT/files/certs.yaml"
listed="$(scope_list_encrypted_files "$VAULT")"
ck "files/ precedes others" "$(printf '%s' "$listed" | head -1)" "files/certs.yaml"
has "lists agents" "$listed" "agents/boba.yaml"

# --- manifest: missing file → all-all ---
mj="$(scope_load_manifest "$VAULT")"
ck "missing manifest core=all" "$(printf '%s' "$mj" | jq -r '.recipients.core')" "all"
ck "missing manifest edge=all" "$(printf '%s' "$mj" | jq -r '.recipients.edge')" "all"

# --- with a real manifest: edge scoped to boba only ---
cat > "$VAULT/$SCOPES_FILE_NAME" <<YAML
version: 1
recipients:
  core: all
  edge:
    - agents/boba.yaml
YAML
mj="$(scope_load_manifest "$VAULT")"
ck "edge allowed boba"   "$(scope_machine_allows "$mj" edge agents/boba.yaml)" "1"
ck "edge denied mojo"    "$(scope_machine_allows "$mj" edge agents/mojo.yaml)" "0"
ck "core allowed mojo"   "$(scope_machine_allows "$mj" core agents/mojo.yaml)" "1"
ck "edge denied newfile" "$(scope_machine_allows "$mj" edge shared/model.yaml)" "0"  # fail-closed for scoped machines

# --- emit_sops_rules ---
rules="$(emit_sops_rules "$VAULT")"
has  "generated banner"        "$rules" "GENERATED"
has  "files/ rule anchored"    "$rules" "path_regex: '^(files/certs\\.yaml)\$'"
has  "files/ encrypted_regex"  "$rules" "encrypted_regex: '^(content)\$'"
# boba is decryptable by BOTH → its age list contains both pubkeys
bobaline="$(printf '%s' "$rules" | grep -A1 'agents/boba' | grep 'age:')"
has  "boba age has core" "$bobaline" "$CORE"
has  "boba age has edge" "$bobaline" "$EDGE"
# mojo is core-only → edge pubkey must NOT appear on mojo's rule
mojoline="$(printf '%s' "$rules" | grep -A1 'agents/mojo' | grep 'age:')"
has   "mojo age has core"  "$mojoline" "$CORE"
hasnt "mojo age lacks edge" "$mojoline" "$EDGE"

# --- determinism ---
ck "idempotent emit" "$(emit_sops_rules "$VAULT")" "$rules"

# --- scope show (read-only) via CLI ---
# scope show needs a locatable vault (find_keyvault_root wants .sops.yaml).
emit_sops_rules "$VAULT" > "$VAULT/.sops.yaml"
show_all="$(AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" scope show 2>&1)"
has "show lists core" "$show_all" "core"
has "show lists edge" "$show_all" "edge"
show_edge="$(AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" scope show edge 2>&1)"
has   "edge can read boba" "$show_edge" "agents/boba.yaml"
hasnt "edge cannot read mojo" "$show_edge" "agents/mojo.yaml"

# --- review fix (Finding 2): full RE2 escaping of path atoms ---
ck "escape plus"    "$(_scope_regex_atom 'a+b')"   'a\+b'
ck "escape bracket" "$(_scope_regex_atom '[p].y')" '\[p\]\.y'
ck "slash literal"  "$(_scope_regex_atom 'x/y')"   'x/y'

# --- review fix (Finding 1): scope show rejects unknown machine ---
if AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" scope show nonesuch >/dev/null 2>&1; then
  echo "FAIL: scope show should reject unknown machine"; fail=1
fi

# --- review fix (Finding 3): emit fails clearly on a zero-recipient file ---
# Scope BOTH machines to boba only; mojo/model/certs become undecryptable.
cat > "$VAULT/$SCOPES_FILE_NAME" <<YAML
version: 1
recipients:
  core:
    - agents/boba.yaml
  edge:
    - agents/boba.yaml
YAML
if emit_sops_rules "$VAULT" >/dev/null 2>&1; then
  echo "FAIL: emit should fail on a zero-recipient file"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS: scope-rules" || exit 1
