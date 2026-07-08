#!/usr/bin/env bash
# Smoke test: init → add-recipient → encrypt → sync → verify roundtrip.
# Runs in an isolated HOME — no side effects on the host system.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/vault-fixture.sh"
fixture_require_tools
fixture_new
trap 'rm -rf "$FIXTURE_HOME"' EXIT

VAULT="$FIXTURE_HOME/test-vault"
export AGE_KEY_FILE="$FIXTURE_HOME/keys/test.txt"
fixture_keygen test >/dev/null    # active machine's key

# 2. Init vault
bash "$REPO/agentkeys" init "$VAULT" >/dev/null

# 3. Add recipient
AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" add-recipient test-machine >/dev/null

# 4. Create and encrypt a secret (must cd into vault so sops finds .sops.yaml)
(
  cd "$VAULT"
  echo '{"API_KEY": "sk-test-roundtrip", "OTHER_KEY": "value-two"}' > shared/test.yaml
  sops -e -i shared/test.yaml
  git add shared/test.yaml && git commit -q -m "add test secret"
)

# 5. Sync
SECRETS="$FIXTURE_HOME/.secrets"
AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" sync --no-pull --secrets-dir "$SECRETS" >/dev/null

# 6. Verify
assert_eq() { [ "$2" = "$3" ] || { echo "FAIL: $1 — expected '$3', got '$2'"; exit 1; }; }

# .env file exists — source it to verify values (same as how consumers use it)
[ -f "$SECRETS/shared/test.env" ] || { echo "FAIL: shared env file not found"; exit 1; }
source "$SECRETS/shared/test.env"
assert_eq "API_KEY value" "$API_KEY" "sk-test-roundtrip"
assert_eq "OTHER_KEY value" "$OTHER_KEY" "value-two"

# .sync-state exists and is valid JSON with status ok
[ -f "$SECRETS/.sync-state" ] || { echo "FAIL: .sync-state not found"; exit 1; }
assert_eq "sync status" "$(jq -r .status "$SECRETS/.sync-state")" "ok"
assert_eq "files written" "$(jq -r .files_written "$SECRETS/.sync-state")" "1"

# status command works
STATUS_EXIT=0
AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" status --secrets-dir "$SECRETS" --json >/dev/null || STATUS_EXIT=$?
assert_eq "status exit code" "$STATUS_EXIT" "0"

echo "PASS: roundtrip test"
