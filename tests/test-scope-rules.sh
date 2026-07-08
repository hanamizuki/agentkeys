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
ck "empty vault lists nothing" "$(scope_list_encrypted_files "$VAULT")" ""

# Add encrypted files: boba (both), mojo (core only), a shared, a files/ manifest.
# NB: scope_list order is plain whole-vault dictionary sort — the "files/ rules
# come first" property lives in emit_sops_rules (asserted at the emit layer below).
touch "$VAULT/agents/boba.yaml" "$VAULT/agents/mojo.yaml" \
      "$VAULT/shared/model.yaml" "$VAULT/files/certs.yaml"
listed="$(scope_list_encrypted_files "$VAULT")"
has "lists files/ manifests" "$listed" "files/certs.yaml"
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

# --- emit order: files/ rules precede the others (sops uses the FIRST matching
# creation_rule, and files/ rules carry encrypted_regex while also matching a
# bare \.yaml$ pattern — so this order is load-bearing, not cosmetic).
first_files_rule="$(printf '%s\n' "$rules" | grep -nF "files/certs" | head -1 | cut -d: -f1)"
first_other_rule="$(printf '%s\n' "$rules" | grep -nF "agents/boba" | head -1 | cut -d: -f1)"
[ -n "$first_files_rule" ] && [ -n "$first_other_rule" ] && [ "$first_files_rule" -lt "$first_other_rule" ] \
  || { echo "FAIL: files/ exact rule must precede other exact rules (got files=$first_files_rule other=$first_other_rule)"; fail=1; }
files_fb_line="$(printf '%s\n' "$rules" | grep -nF '^files/.*\.yaml$' | head -1 | cut -d: -f1)"
generic_fb_line="$(printf '%s\n' "$rules" | grep -nF "path_regex: '\\.yaml\$'" | head -1 | cut -d: -f1)"
[ -n "$files_fb_line" ] && [ -n "$generic_fb_line" ] && [ "$files_fb_line" -lt "$generic_fb_line" ] \
  || { echo "FAIL: files/ fallback must precede the generic fallback (got files=$files_fb_line generic=$generic_fb_line)"; fail=1; }

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

# --- review fix (Finding 3, r4): emit stays valid YAML for quoted filenames ---
ck "yaml single-quote doubling" "$(_yaml_sq "a'b")" "'a''b'"
touch "$VAULT/agents/wei'rd.yaml"
if emit_sops_rules "$VAULT" | yq -o json '.' >/dev/null 2>&1; then :; else
  echo "FAIL: emit produced invalid YAML for a quoted filename"; fail=1
fi
rm -f "$VAULT/agents/wei'rd.yaml"

# --- review fix (Finding B): a NEW file is still encryptable via fallback ---
# manifest here is core=all, edge=[boba]; fallback grants "all" machines (core).
emit_sops_rules "$VAULT" > "$VAULT/.sops.yaml"
sops_yaml="$(cat "$VAULT/.sops.yaml")"
has "generic fallback rule" "$sops_yaml" "path_regex: '\\.yaml\$'"
has "files fallback rule"   "$sops_yaml" "path_regex: '^files/.*\\.yaml\$'"
echo '{"NEW":"v"}' > "$VAULT/shared/brandnew.yaml"   # not in any exact rule
if (cd "$VAULT" && SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/core.txt" sops -e -i shared/brandnew.yaml 2>/dev/null); then
  : # encrypted via fallback — good
else
  echo "FAIL: new file should encrypt via fallback rule"; fail=1
fi
# edge (scoped away) must NOT be able to decrypt the new file
[ "$(SOPS_AGE_KEY_FILE="$FIXTURE_HOME/keys/edge.txt" sops -d "$VAULT/shared/brandnew.yaml" >/dev/null 2>&1 && echo OK || echo DENIED)" = "DENIED" ] \
  || { echo "FAIL: scoped machine should be fail-closed on new file"; fail=1; }
rm -f "$VAULT/shared/brandnew.yaml"

# --- review fix (r7-1 + r8): scope_list scans the WHOLE vault ---
# Nested dirs AND non-standard top-level dirs must be listed (else a scope
# change would skip re-encrypting them, leaving a revoked key able to decrypt);
# the CLI-managed metadata files and recipients/ must be excluded.
mkdir -p "$VAULT/agents/nested" "$VAULT/misc"
touch "$VAULT/agents/nested/deep.yaml" "$VAULT/misc/foo.yaml" "$VAULT/recipients/decoy.yaml"
listed_all="$(scope_list_encrypted_files "$VAULT")"
has   "scope_list includes nested file"       "$listed_all" "agents/nested/deep.yaml"
has   "scope_list includes non-standard dir"  "$listed_all" "misc/foo.yaml"
hasnt "scope_list excludes .sops.yaml"        "$listed_all" ".sops.yaml"
hasnt "scope_list excludes scopes manifest"   "$listed_all" "$SCOPES_FILE_NAME"
hasnt "scope_list excludes recipients/"       "$listed_all" "recipients/decoy.yaml"
rm -rf "$VAULT/agents/nested" "$VAULT/misc"
rm -f "$VAULT/recipients/decoy.yaml"

# --- review fix (r7-2): a malformed manifest fails closed ---
cp "$VAULT/$SCOPES_FILE_NAME" "$FIXTURE_HOME/scopes.bak"
printf 'version: 1\nrecipientz:\n  core: all\n' > "$VAULT/$SCOPES_FILE_NAME"   # typo'd key
if scope_load_manifest "$VAULT" >/dev/null 2>&1; then
  echo "FAIL: malformed manifest should fail closed"; fail=1
fi
cp "$FIXTURE_HOME/scopes.bak" "$VAULT/$SCOPES_FILE_NAME"

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
