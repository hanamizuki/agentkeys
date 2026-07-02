# agentkeys

> Opinionated sops + age workflow for multi-machine cron / daemon / AI agent secret management.

**agentkeys** wraps [sops](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) into an opinionated secret orchestration CLI — built for solo devs running multi-machine cron jobs, daemons, and AI agents, or small teams who want self-hosted secret management with an audit trail and no SaaS lock-in.

## Why this exists

Anyone running AI agents, cron jobs, or multi-machine daemons hits the same trap:

```
$ cat my-app.json
{
  "env": {
    "API_KEY": "sk-xxx-PLAINTEXT-AND-IN-GIT",
    "BOT_TOKEN": "yyy-WHOOPS-COMMITTED"
  }
}
```

Or:

```
~/.zshenv  → 70 exports, inherited by every process tree
~/profiles/agent-a/.env  → duplicate copy
~/profiles/agent-b/.env  → another duplicate
~/Library/...  → yet another copy scattered around
```

agentkeys converges the sprawl into a single system:

- 🔐 **Single source of truth** — sops-encrypted git repo
- 📐 **4-Type taxonomy** — shared vs per-agent vs file-shaped vs per-machine sovereignty
- 🔀 **Composition** — shared defaults + per-agent overrides; rotate once, propagate everywhere
- 🔄 **Auto sync** — launchd / systemd cron pulls + decrypts every 30 min
- 🔌 **Agent adapters** — integrates with OpenClaw, Hermes, Claude Code, or any tool that reads `.env`
- 🛡 **Security hardening** — cosign-verified binaries, pre-commit gitleaks, quarterly rotation, offline fallback

## 30-second demo

```bash
$ agentkeys rotate OPENAI_API_KEY

→ Affected: shared/model-providers.yaml
→ Affected agents: agent-a, agent-b, agent-c, agent-d (4 machines)
→ Open editor… [vim opens decrypted yaml]
→ Save → re-encrypt → commit → push
→ Triggering sync on remote machines… ✓ ✓ ✓
→ Reloading agent gateways… ✓ ✓
→ Done in 18s. Old key still valid—revoke on provider when ready.
```

## How it compares

| Tool | Where agentkeys differs |
|---|---|
| Raw [sops](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) | 4-Type taxonomy, composition rules, rotation playbook, agent adapters |
| [chezmoi](https://www.chezmoi.io/) | Focused on secrets (not dotfiles), fine-grained recipients + cross-machine sync |
| [git-crypt](https://github.com/AGWA/git-crypt) | sops selective field encryption + multiple recipients + fine-grained access |
| [HashiCorp Vault](https://www.vaultproject.io/) | No daemon, no cloud account, pure local + git |
| 1Password / Doppler / Infisical | No vendor lock-in, no subscription, works offline |

## Status

⚠ **Alpha — dogfooding stage.** Battle-tested on 5 machines over 6 weeks, but not yet recommended for production use by others. See [`CHANGELOG.md`](CHANGELOG.md) for detailed progress.

### Commands

| Command | Status |
|---|---|
| `agentkeys init <path>` | ✅ Implemented |
| `agentkeys add-recipient <name>` | ✅ Implemented |
| `agentkeys edit <path>` | ✅ Implemented |
| `agentkeys sync` | ✅ Implemented |
| `agentkeys status` | ✅ Implemented |
| `agentkeys rotate <key>` | ✅ Implemented |

### Verified end-to-end

- sops + age encryption round-trip (encrypt → decrypt → match)
- `.sops.yaml` rules auto-applied (recipients picked up from `recipients/`)
- `sops filestatus` reports encrypted state
- 12+ adversarial test cases (path traversal, newline injection, normalize collisions, bash 3.2 re-exec)

### Roadmap

- [ ] `GETTING_STARTED.md` — 15-minute walkthrough
- [ ] `examples/` — single-laptop, multi-machine, AI-agent-stack setups
- [ ] Cross-platform CI (macOS + Linux)
- [ ] SECURITY.md + CONTRIBUTING.md
- [ ] Docs site

## Quick start

### Prerequisites

- bash 4+ (macOS: `brew install bash`; most Linux distros ship 4+)
- [sops](https://github.com/getsops/sops), [age](https://github.com/FiloSottile/age), git, jq, [yq](https://github.com/mikefarah/yq)

```bash
# macOS
brew install sops age jq yq

# Linux (example — use your package manager)
# See each project's install docs for the latest instructions.
```

### Install

```bash
git clone https://github.com/<TBD>/agentkeys.git
cd agentkeys
bash install.sh
```

### First vault

```bash
# 1. Create a vault
agentkeys init ~/keyvault

# 2. Generate an age key (if you don't have one)
mkdir -p ~/.age && age-keygen -o ~/.age/key.txt && chmod 600 ~/.age/key.txt

# 3. Register this machine
cd ~/keyvault
agentkeys add-recipient laptop

# 4. Add a secret
agentkeys edit shared/api-keys
# → editor opens; add your keys as YAML, save & quit

# 5. Decrypt to ~/.secrets/
agentkeys sync

# 6. Verify
agentkeys status
cat ~/.secrets/shared/api-keys.env
```

## Architecture

See [`SPEC.md`](SPEC.md) for the full specification — 4-Type taxonomy, composition rules, sync flow, rotation playbooks, and security hardening.

## Adapters

See [`ADAPTERS.md`](ADAPTERS.md) for integrating with specific agent platforms (OpenClaw, Hermes, Claude Code, generic `.env`).

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

Built on top of:
- [getsops/sops](https://github.com/getsops/sops) — encrypted secrets management
- [FiloSottile/age](https://github.com/FiloSottile/age) — modern file encryption
- [sigstore/cosign](https://github.com/sigstore/cosign) — binary supply-chain verification
