#!/usr/bin/env bash
# Smoke test: init → add-recipient → encrypt → sync → verify roundtrip.
# Runs in an isolated HOME — no side effects on the host system.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT

export HOME="$FAKE_HOME"
export GIT_AUTHOR_NAME="test" GIT_COMMITTER_NAME="test"
export GIT_AUTHOR_EMAIL="test@test" GIT_COMMITTER_EMAIL="test@test"

# Dependencies
for cmd in sops age age-keygen git jq yq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "SKIP: $cmd not installed"; exit 0; }
done

VAULT="$FAKE_HOME/test-vault"

# 1. Generate age key
mkdir -p "$FAKE_HOME/.age"
age-keygen -o "$FAKE_HOME/.age/key.txt" 2>/dev/null
chmod 600 "$FAKE_HOME/.age/key.txt"

# 2. Init vault
bash "$REPO/agentkeys" init "$VAULT" >/dev/null 2>&1

# 3. Add recipient
AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" add-recipient test-machine >/dev/null 2>&1

# 4. Create and encrypt a secret (must cd into vault so sops finds .sops.yaml)
(
  cd "$VAULT"
  echo '{"API_KEY": "sk-test-roundtrip", "OTHER_KEY": "value-two"}' > shared/test.yaml
  sops -e -i shared/test.yaml 2>/dev/null
  git add shared/test.yaml && git commit -q -m "add test secret"
)

# 5. Sync
SECRETS="$FAKE_HOME/.secrets"
AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" sync --no-pull --secrets-dir "$SECRETS" >/dev/null 2>&1

# 6. Verify
assert_eq() { [ "$2" = "$3" ] || { echo "FAIL: $1 — expected '$3', got '$2'"; exit 1; }; }

# .env file exists and contains the keys
assert_eq "shared env exists" "$(test -f "$SECRETS/shared/test.env" && echo yes)" "yes"
assert_eq "API_KEY value" "$(grep '^API_KEY=' "$SECRETS/shared/test.env" | sed "s/^API_KEY=//;s/^'//;s/'$//")" "sk-test-roundtrip"
assert_eq "OTHER_KEY value" "$(grep '^OTHER_KEY=' "$SECRETS/shared/test.env" | sed "s/^OTHER_KEY=//;s/^'//;s/'$//")" "value-two"

# .sync-state exists and is valid JSON with status ok
assert_eq "sync-state exists" "$(test -f "$SECRETS/.sync-state" && echo yes)" "yes"
assert_eq "sync status" "$(jq -r .status "$SECRETS/.sync-state")" "ok"
assert_eq "files written" "$(jq -r .files_written "$SECRETS/.sync-state")" "1"

# status command works
STATUS_EXIT=0
AGENTKEYS_KEYVAULT="$VAULT" bash "$REPO/agentkeys" status --secrets-dir "$SECRETS" --json >/dev/null 2>&1 || STATUS_EXIT=$?
assert_eq "status exit code" "$STATUS_EXIT" "0"

echo "PASS: roundtrip test"
