#!/usr/bin/env bash
# vault-fixture.sh — throwaway keyvault helpers for agentkeys tests.
# Source from a test; every test runs in its own mktemp HOME so there are no
# side effects on the host. Not executable on its own.

# Resolve the agentkeys repo root (two levels up from tests/lib/).
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fixture_require_tools() {
  local cmd
  for cmd in sops age age-keygen git jq yq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "SKIP: $cmd not installed"; exit 0; }
  done
}

# Build an isolated HOME. Sets global FIXTURE_HOME + HOME + git identity.
# Caller must: trap 'rm -rf "$FIXTURE_HOME"' EXIT
fixture_new() {
  FIXTURE_HOME="$(mktemp -d)"
  export HOME="$FIXTURE_HOME"
  export GIT_AUTHOR_NAME="test" GIT_COMMITTER_NAME="test"
  export GIT_AUTHOR_EMAIL="test@test" GIT_COMMITTER_EMAIL="test@test"
  unset SOPS_AGE_KEY_FILE 2>/dev/null || true
  mkdir -p "$FIXTURE_HOME/keys"
}

# Generate an age keypair for <machine>; echo its pubkey.
fixture_keygen() {
  local machine="$1" kf="$FIXTURE_HOME/keys/$1.txt"
  age-keygen -o "$kf" 2>/dev/null
  chmod 600 "$kf"
  grep '^# public key:' "$kf" | sed 's/^# public key: //'
}

# Run agentkeys as <machine> (that machine's age key active) against $VAULT.
fixture_as() {
  local machine="$1"; shift
  AGE_KEY_FILE="$FIXTURE_HOME/keys/$machine.txt" \
  AGENTKEYS_KEYVAULT="$VAULT" \
    bash "$REPO/agentkeys" "$@"
}

# Portable content hash: md5 -q is macOS-only, md5sum is coreutils (Linux).
fixture_hash() {
  if command -v md5 >/dev/null 2>&1; then md5 -q "$1"
  else md5sum "$1" | awk '{print $1}'; fi
}
