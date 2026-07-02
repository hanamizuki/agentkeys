#!/usr/bin/env bash
# install.sh — deploy agentkeys CLI to ~/.agentkeys/ and symlink onto PATH.
#
# Idempotent: re-running with an existing ~/.agentkeys/config preserves
# previous answers as defaults. Pass --noninteractive (or -y) to accept all
# defaults without prompting — useful for CI / scripted bootstrap on new
# machines.
#
# What this does:
#   1. rsync this repo (minus dev-only files) into the install dir
#   2. write a config file pointing at your encrypted-vault directory
#   3. symlink the dispatcher onto PATH
#
# The repo (where you edit code) stays untouched. The deploy dir is what
# `agentkeys` actually runs from — you must re-run install.sh after editing
# the repo to update the deployed copy.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect a sensible default bin directory for the symlink.
detect_bin_dir() {
  if [ "$(uname -s)" = "Darwin" ]; then
    if [ "$(uname -m)" = "arm64" ]; then
      echo "/opt/homebrew/bin"
    else
      echo "/usr/local/bin"
    fi
  else
    # Linux: prefer ~/.local/bin (no sudo), fall back to /usr/local/bin
    if [ -d "$HOME/.local/bin" ]; then
      echo "$HOME/.local/bin"
    else
      echo "/usr/local/bin"
    fi
  fi
}

# Hard-coded defaults; overridden by env vars, then by existing config (if
# present), then by user input.
DEFAULT_VAULT="${AGENTKEYS_VAULT_PATH:-$HOME/keyvault}"
DEFAULT_INSTALL_DIR="${AGENTKEYS_INSTALL_DIR:-$HOME/.agentkeys}"
DEFAULT_BIN_LINK="${AGENTKEYS_BIN_LINK:-$(detect_bin_dir)/agentkeys}"

noninteractive=0
for arg in "$@"; do
  case "$arg" in
    --noninteractive|-y) noninteractive=1 ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--noninteractive]

Deploy agentkeys to \$HOME/.agentkeys (or wherever you pick), write a
config file pointing at your vault, and symlink the CLI onto PATH.

Re-running picks up the previous config as defaults so you can hit enter.

OPTIONS:
  -y, --noninteractive   Accept all defaults without prompting
  -h, --help             Show this help

ENV OVERRIDES (for --noninteractive / CI):
  AGENTKEYS_VAULT_PATH   Vault directory (default: ~/keyvault)
  AGENTKEYS_INSTALL_DIR  CLI install directory (default: ~/.agentkeys)
  AGENTKEYS_BIN_LINK     Symlink path (default: auto-detected)

REQUIRES: rsync (preinstalled on macOS / most Linux)
EOF
      exit 0
      ;;
  esac
done

# If an existing config is present, surface previous answers as defaults.
existing_cfg="$DEFAULT_INSTALL_DIR/config"
if [ -f "$existing_cfg" ]; then
  echo "Found existing config: $existing_cfg"
  prev_vault="$(grep -E '^[[:space:]]*AGENTKEYS_KEYVAULT=' "$existing_cfg" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$prev_vault" ] && DEFAULT_VAULT="$prev_vault"
  echo "  (using previous values as defaults — hit enter to keep)"
  echo
fi

prompt() {
  local label="$1" default="$2" varname="$3"
  if [ "$noninteractive" = "1" ]; then
    printf -v "$varname" '%s' "$default"
    echo "$label: $default"
    return
  fi
  local ans
  read -r -p "$label [$default]: " ans
  printf -v "$varname" '%s' "${ans:-$default}"
}

echo "══════════════════════════════════════════════"
echo "agentkeys install"
echo "══════════════════════════════════════════════"
echo
echo "Repo source: $REPO"
echo

prompt "Vault path (encrypted secrets dir)" "$DEFAULT_VAULT"        vault_path
prompt "CLI install dir"                     "$DEFAULT_INSTALL_DIR" install_dir
prompt "Symlink agentkeys onto PATH at"      "$DEFAULT_BIN_LINK"    bin_link

# Expand leading tilde (read doesn't do it for us)
vault_path="${vault_path/#\~/$HOME}"
install_dir="${install_dir/#\~/$HOME}"
bin_link="${bin_link/#\~/$HOME}"

echo
echo "Plan:"
echo "  1. rsync $REPO/  →  $install_dir/  (exclude docs, tests, examples, .git)"
echo "  2. write $install_dir/config        (AGENTKEYS_KEYVAULT=$vault_path)"
echo "  3. symlink $bin_link  →  $install_dir/agentkeys"
echo

if [ "$noninteractive" = "0" ]; then
  read -r -p "Proceed? [Y/n] " ans
  case "${ans:-y}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "✗ rsync not found. Install it first (brew install rsync / apt install rsync)." >&2
  exit 1
fi

# 1. Sync runtime files. Excludes: docs (read on GitHub), dev-only dirs,
# install.sh itself (lives in the repo, not the install dir).
mkdir -p "$install_dir"
rsync -a --delete \
  --exclude='.git' \
  --exclude='.gitignore' \
  --exclude='install.sh' \
  --exclude='uninstall.sh' \
  --exclude='tests' \
  --exclude='examples' \
  --exclude='SPEC.md' \
  --exclude='ADAPTERS.md' \
  --exclude='CHANGELOG.md' \
  --exclude='LICENSE' \
  --exclude='README.md' \
  --exclude='config' \
  "$REPO/" "$install_dir/"
echo "✓ Synced runtime → $install_dir"

# 2. Write config (only AGENTKEYS_KEYVAULT for now; extend as needed).
# chmod 600 because the vault path can be sensitive info on shared machines.
cat > "$install_dir/config" <<EOF
# agentkeys config — written by install.sh
# Re-run install.sh to update values. Manual edits are preserved on re-run
# as long as 'AGENTKEYS_KEYVAULT=' is still present and parseable.

AGENTKEYS_KEYVAULT=$vault_path
EOF
chmod 600 "$install_dir/config"
echo "✓ Wrote $install_dir/config"

# 3. PATH symlink. Skip cleanly if dir doesn't exist or isn't writable so the
# user can finish manually rather than have us sudo behind their back.
bin_dir="$(dirname "$bin_link")"
if [ ! -d "$bin_dir" ]; then
  echo "⚠ $bin_dir does not exist — skipping symlink."
  echo "   Either create it, or symlink manually:"
  echo "     ln -sfn $install_dir/agentkeys /your/preferred/path"
elif [ ! -w "$bin_dir" ]; then
  echo "⚠ $bin_dir is not writable — skipping symlink."
  echo "   Symlink manually with sudo, or pick a writable PATH dir:"
  echo "     sudo ln -sfn $install_dir/agentkeys $bin_link"
else
  ln -sfn "$install_dir/agentkeys" "$bin_link"
  echo "✓ Symlinked $bin_link → $install_dir/agentkeys"
fi

echo
echo "══════════════════════════════════════════════"
echo "Done."
echo "══════════════════════════════════════════════"
echo
echo "Verify:  agentkeys version"
echo "         agentkeys status"
echo
if [ ! -d "$vault_path" ]; then
  echo "Note: vault path $vault_path does not exist yet."
  echo "      Run 'agentkeys init $vault_path' to bootstrap a fresh vault, or"
  echo "      clone an existing vault to that path."
elif [ ! -f "$vault_path/.sops.yaml" ]; then
  echo "Note: $vault_path exists but lacks .sops.yaml — vault is not initialized."
  echo "      Run 'agentkeys init $vault_path' (will refuse if dir is non-empty)."
fi
