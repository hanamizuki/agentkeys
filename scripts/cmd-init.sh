#!/usr/bin/env bash
# agentkeys init <path>
#
# Initialize a new keyvault repo with the canonical structure.
set -euo pipefail

# shellcheck source=lib/common.sh
source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/common.sh"
# scope.sh provides SCOPES_FILE_NAME (single source of truth for the manifest
# filename) — seed an empty manifest below so a fresh vault is scope-ready.
source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/scope.sh"

usage() {
  cat <<EOF
Usage: agentkeys init <path>

Initialize a new keyvault repo at <path>.

Creates the canonical structure:
  <path>/
    .sops.yaml      Encryption rules (template)
    .gitignore      Prevent plaintext leakage
    README.md       Repo overview
    shared/         Type A — cross-consumer defaults
    agents/         Type A — per-consumer envs
    services/       Type B — enumeration services
    files/          Type C — file manifests
    recipients/     Per-machine age pubkeys
    scripts/        Optional repo-local scripts

Then runs 'git init' and creates an initial commit.

Next step: agentkeys add-recipient <this-machine-name>
EOF
}

path="${1:-}"

case "$path" in
  ""|-h|--help|help)
    usage
    exit 0
    ;;
esac

check_deps
path="$(expand_path "$path")"

# Refuse to init a non-empty directory
if [ -e "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
  die "Path exists and is not empty: $path
Refusing to init. If this is an existing keyvault, you don't need init.
If you want to start fresh, remove the directory first."
fi

info "Initializing keyvault at $path"
mkdir -p "$path"/{shared,agents,services,files,recipients,scripts}

# Git won't track empty directories — but find_keyvault_root() requires the
# canonical layout (recipients/, shared/) to exist, so a fresh `git clone`
# of this skeleton would otherwise lose those dirs and subsequent
# `agentkeys add-recipient` / `sync` / `status` would all fail with
# "Not inside a keyvault repo". Drop a placeholder .gitkeep in each.
for d in shared agents services files recipients scripts; do
  : > "$path/$d/.gitkeep"
done

cat > "$path/.sops.yaml" <<'EOF'
# .sops.yaml — encryption rules for this keyvault repo
#
# As machines are registered (via `agentkeys add-recipient`), entries are
# added to creation_rules below.
#
# Rule: each yaml file should list ≥ 3 write recipients so emergency
# recovery is possible if 2 machines are unreachable.

creation_rules: []
EOF

cat > "$path/$SCOPES_FILE_NAME" <<'EOF'
# .agentkeys-scopes.yaml — per-path recipient scope (source of truth).
#
# Each recipient maps to its decrypt scope:
#   <machine>: all            → may decrypt every file in the vault
#   <machine>:                → may decrypt ONLY the listed exact paths
#     - agents/<name>.yaml
#     - shared/<group>.yaml
#
# agentkeys reads this + the vault file list to GENERATE .sops.yaml.
# Edit here, then run: agentkeys scope regen
# Machines are added with their scope by: agentkeys add-recipient <m> [--scope ...]
version: 1
recipients: {}
EOF

cat > "$path/.gitignore" <<'EOF'
# Prevent plaintext leakage
secrets/
.secrets/
*.env
*.env.local
*.env.*

# OS / editor noise
.DS_Store
*.swp
*.swo

# Explicit exceptions
!*.example
!recipients/*.age.pub
!.sops.yaml
!.agentkeys-scopes.yaml
!README.md
!.gitignore
EOF

cat > "$path/README.md" <<'EOF'
# keyvault

Personal secret vault. Managed with [agentkeys](https://github.com/).

## Structure

```
shared/        Type A — cross-consumer defaults (encrypted)
agents/        Type A — per-consumer envs (encrypted)
services/      Type B — enumeration services (encrypted)
files/         Type C — file manifests (encrypted)
recipients/    Per-machine age pubkeys (plain — safe to commit)
.sops.yaml     Encryption rules
```

## Quick reference

| Action | Command |
|---|---|
| Sync from remote | `agentkeys sync` |
| Edit a secret | `agentkeys edit shared/<group>` |
| Rotate one key | `agentkeys rotate <KEY_NAME>` |
| Check stale state | `agentkeys status` |
| Add new machine | `agentkeys add-recipient <name>` |
EOF

# Init git
cd "$path"
git init -q
git add .
git commit -q -m "init keyvault skeleton (agentkeys init)"

info "✓ Keyvault initialized at $path"
info ""
info "Next steps:"
info "  1. Generate age key (if not yet):"
info "       mkdir -p ~/.age && age-keygen -o ~/.age/key.txt && chmod 600 ~/.age/key.txt"
info "  2. Register this machine:"
info "       agentkeys add-recipient <this-machine-name>"
info "  3. (Optional) Set up remote:"
info "       cd $path && git remote add origin <repo-url>"
