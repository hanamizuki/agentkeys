# Agent Platform Adapters

> How to integrate this secret management system with specific agent platforms.

The core spec (`SPEC.md`) is platform-agnostic: it stores encrypted secrets and decrypts them to `~/.secrets/` on each machine. But **how a specific agent platform consumes those decrypted secrets** varies — some read from `.env` files, some require runtime resolvers, some load on session start.

This document defines the **adapter pattern** and provides reference implementations for popular platforms.

---

## 1. Why adapters exist

Different platforms have different secret ingestion mechanisms:

| Platform | Native secret mechanism | Refresh model |
|---|---|---|
| OpenClaw | `SecretRef` with `env`/`file`/`exec` source | Hot reload via `openclaw gateway reload` |
| Hermes (Nous Research) | `<profile>/.env` file loaded at startup | Full gateway restart required |
| Claude Code | `settings.json` `env` field OR `SessionStart` hook | New session OR hook re-runs |
| Codex CLI | `~/.codex/auth.json` (OAuth) + env vars | OAuth refresh; env on next invocation |
| Generic daemons | `.env` file or process environment | Restart |

An **adapter** is the glue that:
1. Reads decrypted secrets from `~/.secrets/`
2. Delivers them into the platform's expected location/format
3. Triggers the platform's refresh mechanism after rotations

---

## 2. Adapter interface

Conceptually, every adapter implements:

```
AdapterInterface:
    name: string                                  # "openclaw", "hermes", "claude-code", ...
    consumer_id: string                           # the agent / profile / session this adapter targets
    
    # Called by sync.sh after decryption
    deliver(secret_path: Path) -> Result          # write/inject secrets into platform's expected location
    
    # Called after rotation
    refresh_signal() -> Result                    # tell the platform to pick up new values
    
    # Called by keyvault status
    health_check() -> {status, last_refresh, error?}
```

In practice, an adapter is typically a small shell script or config snippet — there's no formal framework, just convention. Reference implementations below.

---

## 3. Reference: OpenClaw adapter

OpenClaw has **native** secret management via [`SecretRef`](https://github.com/openclaw/openclaw/blob/main/docs/gateway/secrets.md). Best practice: use OpenClaw's `exec` source pointing to a resolver script that reads from `~/.secrets/`.

### Configuration

```json5
// openclaw.json
{
  "models": {
    "providers": {
      "openrouter": {
        "apiKey": {
          "source": "exec",
          "provider": "default",
          "id": "OPENROUTER_API_KEY"
        }
      }
    }
  },
  "channels": {
    "telegram": {
      "token": {
        "source": "exec",
        "provider": "default",
        "id": "TELEGRAM_BOT_TOKEN"
      }
    }
  }
  // env block: keep only non-secret feature flags
}
```

### Resolver script

```bash
#!/bin/bash
# $AGENTKEYS_KEYVAULT/adapters/openclaw-resolver.sh
# Called by OpenClaw via stdin/stdout JSON protocol

read -r request
key=$(echo "$request" | jq -r '.id')

# Look up in composed env files
for envfile in ~/.secrets/agents/*.env ~/.secrets/shared/*.env; do
  value=$(grep "^${key}=" "$envfile" | head -1 | cut -d= -f2-)
  if [ -n "$value" ]; then
    jq -n --arg v "$value" '{value: $v}'
    exit 0
  fi
done

jq -n '{error: "not found"}'
exit 1
```

Register in OpenClaw config:

```json5
{
  "secrets": {
    "providers": {
      "default": {
        "type": "exec",
        "command": "$AGENTKEYS_KEYVAULT/adapters/openclaw-resolver.sh"
      }
    }
  }
}
```

### Refresh

```bash
openclaw gateway restart   # Restarts the launchd/systemd service; resolvers re-run on startup
```

OpenClaw resolves SecretRefs at gateway startup and caches the result in memory.
There is no in-place hot reload — `restart` cycles the service (sub-second on
local launchd) and the next start re-invokes each resolver, picking up the
new value from `~/.secrets/`.

### Why this is the best option for OpenClaw

- ✅ Secrets stay out of `openclaw.json`'s `env` block (which is in git) — they
  live in `~/.secrets/` (chmod 700, gitignored) and only land in the gateway's
  memory at SecretRef resolution time
- ✅ Audit trail via OpenClaw's secret access log
- ✅ Subprocess doesn't inherit gateway env unless explicitly passed via
  SecretRef in that subprocess's spec
- ⚠ The cached value is **plaintext in the gateway process memory** until
  restart; rotation requires `openclaw gateway restart` so a fresh resolver
  call picks up the new secret. There is no hot-reload subcommand.

---

## 4. Reference: Hermes adapter

Hermes loads its profile `.env` file once at startup (`hermes_cli/env_loader.py:load_hermes_dotenv()`). No runtime resolver. Strategy: write a composed env file at sync time, restart gateway after rotation.

### Setup

`sync.sh` writes `~/.secrets/agents/<profile>.env` (composed from shared + per-agent yaml). Hermes profile's `.env` is a **symlink** to it:

```bash
ln -s ~/.secrets/agents/<profile>.env ~/.hermes/profiles/<profile>/.env
```

Or alternatively, the launchd/systemd unit wraps Hermes with `sops exec-env`:

```xml
<!-- ~/Library/LaunchAgents/ai.hermes.gateway-<profile>.plist -->
<key>ProgramArguments</key>
<array>
    <string>/usr/local/bin/sops</string>
    <string>exec-env</string>
    <string>$AGENTKEYS_KEYVAULT/agents/<profile>.yaml</string>
    <string>hermes</string>
    <string>--profile</string>
    <string><profile></string>
    <string>run</string>
</array>
```

The `sops exec-env` approach is more secure (no plaintext file ever written) but less convenient for inspection.

### Refresh

```bash
launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway-<profile>     # macOS
# or
systemctl --user restart hermes-gateway-<profile>                    # Linux
```

⚠ This **restarts the gateway** — brief inbound message loss (5-30s). Schedule rotations during low-traffic windows.

### Caveats

- Hermes inline shell skill (`!`cmd``) inherits the gateway's full `os.environ` — any secret loaded is exposed to subprocesses
- Hermes' `sandbox` tools have a built-in blocklist for provider credentials; third-party API keys need explicit `required_environment_variables:` in skill frontmatter to be passed through

---

## 5. Reference: Claude Code adapter

Claude Code has no native vault but supports a `SessionStart` hook that can inject env via `CLAUDE_ENV_FILE`.

### Hook setup

`~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$AGENTKEYS_KEYVAULT/adapters/claude-code-loader.sh"
          }
        ]
      }
    ]
  }
}
```

### Loader script

```bash
#!/bin/bash
# $AGENTKEYS_KEYVAULT/adapters/claude-code-loader.sh
# Writes a temp env file, points CLAUDE_ENV_FILE at it

PROFILE_NAME="${CLAUDE_PROFILE:-default}"
TMPFILE=$(mktemp -t claude-env.XXXXXX)
chmod 600 "$TMPFILE"

# Pull from composed env for this user's profile, or fall back to shared
if [ -f ~/.secrets/agents/"$PROFILE_NAME".env ]; then
  cat ~/.secrets/agents/"$PROFILE_NAME".env > "$TMPFILE"
else
  cat ~/.secrets/shared/*.env > "$TMPFILE"
fi

echo "CLAUDE_ENV_FILE=$TMPFILE"
```

### Refresh

Open a new Claude Code session — the hook re-runs.

For interactive sessions that want fresh secrets without restart, the user can manually re-source:

```bash
source $CLAUDE_ENV_FILE
```

---

## 6. Reference: Generic adapter (`.env` only)

For any platform/tool that just reads a `.env` file (most Heroku-style apps, dotenv libraries, docker-compose), no adapter needed beyond sync.

```bash
# In your app's startup
source ~/.secrets/agents/<my-app>.env
exec ./my-app
```

Or with `sops exec-env` (no plaintext file):

```bash
sops exec-env $AGENTKEYS_KEYVAULT/agents/<my-app>.yaml -- ./my-app
```

Or symlink:

```bash
ln -s ~/.secrets/agents/<my-app>.env /path/to/app/.env
```

---

## 7. Writing your own adapter

To support a new platform, document these 4 things in your adapter:

| Question | What to specify |
|---|---|
| **Where does the platform expect secrets?** | env var, file path, runtime resolver, etc. |
| **When are secrets loaded?** | At startup, on demand, cached, etc. |
| **How to refresh after rotation?** | Restart, hot reload, manual re-source, etc. |
| **What's the blast radius of inheritance?** | Subprocess env propagation, sandbox isolation, etc. |

### Template

```bash
#!/bin/bash
# $AGENTKEYS_KEYVAULT/adapters/<platform>-adapter.sh
# Adapter for <platform-name>

# Deliver: called after each sync
deliver() {
    # Read from ~/.secrets/agents/<consumer>.env (or wherever the right composed env is)
    # Write/inject into the platform's expected location
    # Examples:
    #   - cp ~/.secrets/agents/<consumer>.env /platform/expected/path/.env
    #   - register secrets with platform's API
}

# Refresh: called after rotation to signal pickup
refresh() {
    # launchctl kickstart -k ...
    # systemctl restart ...
    # platform-cli reload
}

# Health check: called by keyvault status
health() {
    # Print JSON: { "platform": "...", "last_refresh": "...", "status": "ok|error" }
}

case "${1:-help}" in
    deliver) deliver ;;
    refresh) refresh ;;
    health) health ;;
    *) echo "Usage: $0 {deliver|refresh|health}" ;;
esac
```

### Test plan

When writing an adapter, verify:
1. **Cold start**: Platform comes up with secrets correctly delivered after a fresh `sync`
2. **Rotation**: Edit a secret → push → sync → refresh → platform sees new value
3. **Subprocess isolation**: Verify which child processes inherit secrets (security audit)
4. **Failure modes**: Sync fails → platform should keep last-known-good, not crash
5. **Audit log**: Adapter actions are logged for incident response

---

## 8. Security boundaries

Adapters are **privileged code** — they read decrypted secrets and write them into platform locations. Conventions:

| Rule | Why |
|---|---|
| Adapters run with the user's permissions, not as another user | Avoid permission escalation |
| Temp files created by adapters: `chmod 600` always | Prevent same-user-other-process leak |
| Adapters do not log secret values | Logs may go to disk, indexed by tools, etc. |
| Adapters validate input from sops before writing | Defense in depth against compromised source files |
| Adapter refresh should not block on slow upstream calls | Otherwise a slow platform makes rotation hang |

---

## 9. Adapter registry (community)

| Platform | Adapter | Maintainer | Status |
|---|---|---|---|
| OpenClaw | (this repo) | core | reference |
| Hermes (Nous Research) | (this repo) | core | reference |
| Claude Code | (this repo) | core | reference |
| Generic `.env` | (this repo) | core | reference |
| systemd service | — | wanted | help wanted |
| Docker Compose | — | wanted | help wanted |
| Kubernetes (k3s/k0s personal cluster) | — | wanted | help wanted |
| Codex CLI | — | wanted | help wanted |

Contributions welcome — see `CONTRIBUTING.md`.
