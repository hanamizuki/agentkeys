# Changelog

All notable changes to **agentkeys** follow the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.
Versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added — per-path recipient scope (2026-07-08/09)

- `.agentkeys-scopes.yaml` (vault root, plaintext): source of truth mapping
  each machine to `all` or an exact list of decryptable paths.
- `scripts/lib/scope.sh`: deterministic `.sops.yaml` generator (per-file
  recipient sets, files/ rules first, sorted output), entry-state snapshot
  rollback for every scope mutation, and a fail-closed enumeration layer
  (unreadable/malformed pubkeys, unknown/omitted manifest machines,
  interrupted vault scans, and shared-key scope divergence all abort
  loudly instead of silently shrinking a recipient set).
- `agentkeys scope show|set|regen`: inspect / change decrypt scope.
- `agentkeys add-recipient <m> --scope all|path,path`: register a machine
  with a decrypt scope; regenerates `.sops.yaml` from the manifest
  (idempotent — adding a machine no longer reverts existing per-path
  layering to simple mode).
- `agentkeys sync` skips files this machine is not a recipient of (was:
  aborted on the first undecryptable file), records a `skipped` count in
  `.sync-state`, and validates post-pull that the local key is a
  registered recipient (an unregistered or unreadable key fails loudly
  instead of skipping the whole vault into an "ok" empty cache). A
  committed plaintext yaml still aborts the sync.
- `agentkeys status` shows this machine's decrypt scope and the skipped
  count.
- `agentkeys init` seeds an empty `.agentkeys-scopes.yaml`.
- Test harness: `tests/lib/vault-fixture.sh` + `tests/run-all.sh` (8 test
  files, throwaway-vault fixtures, mutation-tested assertions).

### Fixed — pre-scope bugs caught while building it

- `add-recipient` now `cd`s into the keyvault before `sops updatekeys`,
  fixing a config-not-found rollback when the keyvault is a sub-directory
  of the invocation cwd.
- `find_keyvault_root` canonicalizes to the physical path: a trailing
  slash or symlinked `AGENTKEYS_KEYVAULT` used to desync the file scan
  from the vault root, silently skipping re-encryption (a revocation
  could report success without re-keying anything).
- `status` no longer dies mid-output (exit 141, recipients section lost)
  on a stale vault whose pending list exceeds 20 commits: `git log |
  head -20` let head's early exit SIGPIPE git log under pipefail; git's
  own `-20` replaces the pipe.

### Fixed — Day 3 post-Codex-review (2026-05-16)

Day 3 patch was iterated through **10 rounds of `codex review --uncommitted`** until clean ("no discrete bugs"). 15 distinct issues caught and fixed across the bash CLI; this section is the consolidated changelog.

**Round 1 — sync correctness + commit hygiene** (1 P1 + 2 P2)
- **P1 `cmd-sync.sh` Type B path traversal**: service consumer keys (e.g. `services/langfuse.yaml: agent-a: <token>`) were used directly as a path component (`$staging/<svc>/<consumer>.token`) without validation. A poisoned commit with consumer name `../../.zshenv` or `.zshenv` could write outside the staging dir. Added `validate_path_component()` for `/`, `..`, and leading `.` patterns, applied to both the services-yaml filename and every consumer key.
- **P2 `cmd-add-recipient.sh` `git add -u` sweep**: previously used `git add -u` after `sops updatekeys`, which would sweep in any other tracked-but-modified file in the keyvault working tree into the recipient commit. Now tracks the exact list of files `sops updatekeys` succeeded on and stages only those.
- **P2 `cmd-sync.sh` jq tab-separated iteration**: the `jq -r '"\(.key)\t\(.value)"'` pattern used across 5 iterations would silently split on newline characters embedded in values, truncating tokens and bypassing the after-the-fact newline guards. Replaced with `validate_kv_values` (runs in main shell so its `die` actually aborts — first attempt embedded the validation inside the `< <(...)` process substitution, which silently swallowed errors in the subshell) plus per-line JSON iteration via `iter_kv`.

**Round 2 — .env safety + add-recipient stage scope** (2 P2)
- **P2 `cmd-sync.sh` .env value quoting**: values containing `$`, backticks, spaces, `#`, `'`, or `!` would either expand or break `source ~/.secrets/agents/*.env`. Added POSIX `shell_quote()` helper using single-quote wrapping + `'\''` escape; applied to both `shared/<name>.env` and composed `agents/<name>.env` emission.
- **P2 `cmd-add-recipient.sh:156` whole-dir stage**: `git add recipients/` swept the whole directory. If another session had an untracked or modified pubkey for a different machine in there, it'd be committed too. Replaced with explicit `git add -- recipients/$machine.age.pub .sops.yaml`.

**Round 3 — JSON output, atomic onboarding, env-var names** (3 P2)
- **P2 `cmd-status.sh --json` not valid JSON**: when `.sync-error` existed, output was `state JSON` + `---ERROR---` + `error JSON` — three concatenated documents. Replaced with a single `{state, error}` object.
- **P2 `cmd-add-recipient.sh` partial onboarding**: `sops updatekeys` failures only warned and still committed, producing a vault where the new machine couldn't decrypt some files. Now fails loudly, restores `.sops.yaml` from HEAD, and removes (or restores, see round 9) the recipient pubkey.
- **P2 `cmd-sync.sh` invalid env-var key names**: shared/agent yaml keys like `foo-bar` or `1TOKEN` produced unsourceable `.env` lines. Added `validate_env_var_names()` matching `^[A-Z_][A-Z0-9_]*$`.

**Round 4 — bash 4 dependency, Type B normalize** (2 P2)
- **P2 `agentkeys` dispatcher bare `bash` exec**: cron/launchd has minimal PATH where `bash` resolves to `/bin/bash` 3.2 (no `declare -A`, no `mapfile`). Added a `BASH_VERSINFO[0] < 4` guard at the top that re-execs under a located bash 4+ (`/opt/homebrew/bin/bash`, `/usr/local/bin/bash`, etc.); subcommand dispatch uses `"$BASH"` to inherit the verified interpreter.
- **P2 `cmd-sync.sh` Type B digit-leading normalize**: `services/1password.yaml` would inject `1PASSWORD_AUTH_AGENT_A` — invalid env var name. Added explicit check that `normalize_env_name "$svc"` and consumer key produce `[A-Z_]*`.

**Round 5 — Type B normalize collisions** (1 P2)
- **P2 `cmd-sync.sh` Type B normalize collision**: consumers `foo-bar` and `foo_bar` (or services with the same shape) both normalize to `FOO_BAR`, silently overwriting one another's env injection. Added cross-service `SEEN_SVC_NORM` map + per-service `SEEN_CONSUMER_NORM` map, both fail loudly on collision.

**Round 6 — sops key env, secrets-dir safety guard** (2 P1)
- **P1 `cmd-add-recipient.sh` missing SOPS_AGE_KEY_FILE export**: when user set `AGE_KEY_FILE` (or relied on the default), `sops updatekeys` couldn't find the private key and failed every time → triggered round-3 rollback even on healthy onboarding. Now exports `SOPS_AGE_KEY_FILE` like edit/sync/rotate do.
- **P1 `cmd-sync.sh:466` catastrophic rm-rf risk**: `mv $secrets_dir → .prev.$$; mv staging → $secrets_dir; rm -rf .prev.$$` would destroy `$HOME` if `--secrets-dir $HOME` was set by typo. Added marker file `.agentkeys-managed` written into the staging dir; sync refuses to replace any non-empty directory that doesn't contain this marker. Also fixed `write_sync_error` to refuse writing `.sync-error` into a non-managed directory.

**Round 7 — clone survival, base64 portability** (2 P2)
- **P2 `cmd-init.sh` empty subdir loss on clone**: `shared/`, `recipients/` etc. were empty so Git didn't preserve them. After `git clone <keyvault>`, `find_keyvault_root()` failed because the canonical dirs were gone. Added `.gitkeep` to each subdir. Also added `.gitkeep` to the existing `keyvault/` personal skeleton.
- **P2 `cmd-sync.sh` `base64 --decode` GNU-only**: would break Type C sync on older macOS BSD `base64` (only `-D` supported). Added one-time runtime detection: `-d` if supported, else `-D`, then dies if neither.

**Round 8 — `shell_quote` (FALSE POSITIVE) + keyvault `.gitkeep`** (1 P2 valid, 1 invalid)
- **(invalid)** Codex claimed `shell_quote "a'b"` produced unparseable output. Direct verification in actual bash 5 (not zsh) showed correct `'a'\''b'` output and full sourceable roundtrip for all single-quote edge cases. Codex's own test script (mangled by zsh escaping) had produced misleading output. No change needed.
- **P2 `keyvault/` skeleton empty dirs**: same .gitkeep issue but in the personal vault skeleton (separate from `agentkeys init` fix). Added `.gitkeep` to all 6 subdirs.

**Round 9 — AGENTKEYS_KEYVAULT validation + rollback restore** (1 P1 + 1 P2)
- **P1 `find_keyvault_root` no shape check on env override**: `AGENTKEYS_KEYVAULT=/anywhere` was trusted blindly. Sync would treat any existing dir as an empty vault and wipe a (correctly marker-managed) `~/.secrets`. Added the same canonical-layout check (`.sops.yaml` + `recipients/` + `shared/`) to the env-override path.
- **P2 `cmd-add-recipient.sh` rollback deletes overwritten recipient**: when `add-recipient` REPLACED an existing pubkey and a later `sops updatekeys` failed, rollback unconditionally `rm -f`'d the recipient file, leaving the vault inconsistent (`.sops.yaml` restored to HEAD with the old recipient, but the pubkey file gone). Now checks `git cat-file -e HEAD:$rel_recipient` first: restore if it existed, delete if brand new.

**Round 10 — CLEAN** ✓

Regression + attack-scenario smoke tests added to suite (12+ adversarial cases across rounds): consumer names with `..` / `/` / leading dot, newline in values across Type A/B, digit-leading service/consumer names, foo-bar/foo_bar normalize collisions, non-vault `AGENTKEYS_KEYVAULT` rejection, untracked `--secrets-dir` refusal, special-char values (`$`, `` ` ``, `'`, `#`, space) survive sync+source, bash 3.2 forced invocation re-execs to 4+.

### Added — Day 3 (2026-05-16)

- `agentkeys edit <path>` subcommand
  - Resolves `<path>` relative to keyvault root; auto-appends `.yaml` if extension missing
  - Auto-creates new files with empty `{}` body, seed-encrypts via `sops -e -i` (workaround for sops silently no-op'ing on plaintext input)
  - Rejects absolute paths and `..` traversal
  - Handles sops exit 200 ("File has not changed") as a clean no-op
  - Cleans up unencrypted placeholders if user exits without saving
  - Verifies encryption with `sops filestatus` after save
  - Offers to git commit with message `edit <path>`
  - Smoke-tested 7 cases on `/tmp/agentkeys-test-vault`

- `agentkeys sync [--no-pull] [--secrets-dir DIR]` subcommand
  - Pulls keyvault (unless `--no-pull`), decrypts all 4 Types into `~/.secrets/` (or `$AGENTKEYS_SECRETS`)
  - Type A (shared): writes `shared/<name>.env`, fails loudly on duplicate keys across shared files (spec §4.3)
  - Type A (agents): composes shared defaults + agent overrides (empty string skipped per §4.3) + Type B injection
  - Type B (services): writes per-consumer token files `~/.secrets/<svc>/<consumer>.token`; injects `<SVC>_AUTH_<CONSUMER>` (all) + `<SVC>_AUTH` alias to own
  - Type C (files): restores base64-decoded content with declared mode; rejects absolute paths, `..` traversal, symlink overwrites
  - Atomic swap via staging dir; writes `~/.secrets/.sync-state` JSON on success and `~/.secrets/.sync-error` on failure (with `last_known_good` preserved)
  - Smoke-tested with 4-Type vault + 3 failure paths (duplicate shared key, absolute Type C path, `..` traversal)

- `agentkeys status [--secrets-dir DIR] [--json]` subcommand
  - Reads `.sync-state` + `.sync-error`, prints last sync time, host, commit, file breakdown
  - Staleness check: compares synced commit vs `git rev-parse HEAD` of keyvault; lists pending commits when stale
  - Lists registered recipients; warns when fewer than 3 (spec §7)
  - Exits 2 when `.sync-error` present (for cron monitoring)
  - `--json` mode for programmatic consumption

- `agentkeys rotate <KEY_NAME> [--no-push] [--no-sync]` subcommand
  - Validates KEY_NAME as UPPER_SNAKE_CASE
  - Searches `shared/*.yaml` + `agents/*.yaml` for the key; when matched in multiple files, prompts interactive pick
  - Opens sops editor on the chosen file; verifies re-encryption; commits with `rotate <KEY_NAME> in <file>`
  - Offers `git push` if a remote is configured
  - Runs `agentkeys sync --no-pull` so this machine immediately picks up the new value
  - Prints next-steps reminder (reload daemons, revoke OLD key on provider, write audit-log entry)
  - Smoke-tested 6 cases (multi-match pick, single-match auto, missing key, bad KEY_NAME format, no-save abort, --help)

### Added — Day 2 (2026-05-16)

- Top-level `agentkeys` dispatcher (`agentkeys help|version|<subcommand>`)
- `scripts/lib/common.sh` — shared helpers:
  - Logging (`info` / `warn` / `err` / `die`)
  - `expand_path()` and `find_keyvault_root()` for keyvault detection
  - `check_deps()` + `require_cmd()` for dependency validation
  - `age_key_file()` / `age_pubkey()` for age key helpers
  - `confirm()` for interactive yes/no prompts
- `agentkeys init <path>` subcommand
  - Creates canonical keyvault skeleton (`shared/`, `agents/`, `services/`, `files/`, `recipients/`, `scripts/`)
  - Initializes git + commits skeleton
  - Refuses to init a non-empty directory
- `agentkeys add-recipient <name> [pubkey]` subcommand
  - Derives pubkey from current machine's `~/.age/key.txt` (or `$AGE_KEY_FILE`)
  - Accepts literal `age1...` string or path to a pubkey file
  - Validates pubkey format
  - Saves to `recipients/<name>.age.pub`
  - Rewrites `.sops.yaml` `creation_rules` to include all known recipients
  - Re-encrypts existing yaml files via `sops updatekeys` (where applicable)
  - Auto-commits with summary
  - Warns when total recipient count is < 3 (per spec §7 emergency recovery rule)

### Verified

- sops + age encryption round-trip on macOS (Apple Silicon):
  - `init` → `add-recipient` → write yaml → `sops -e -i` → `sops -d` → original recovered
- `.sops.yaml` auto-pickup of age recipients works
- `sops filestatus` correctly reports `{"encrypted": true}` for sops-encrypted yaml

### Repository scaffolding

- `SPEC.md` — full specification (4-Type taxonomy, composition rules, sync, rotation, security hardening)
- `ADAPTERS.md` — agent platform adapter interface + 4 reference implementations (OpenClaw, Hermes, Claude Code, Generic)
- `README.md` — pitch + differentiation table + status
- `LICENSE` — MIT
- `.gitignore` — standard editor/OS exclusions

### Not yet implemented

- `adapters/openclaw-resolver.sh` etc. — reference adapter scripts
- `scripts/bootstrap.sh` — one-shot installer for new machines
- Daemon-reload integration in `rotate` (currently a manual reminder)
- Quarterly age-key rotation playbook scripts
- `examples/` — worked setups
- Tests + CI

## [0.0.0] — 2026-05-16

- Initial planning + spec writing (Phase 1A-2.8 of internal roadmap)
- Strategy decision: Mode C (parallel OSS + dogfood migration)
- Project named: `agentkeys`
