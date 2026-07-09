#!/usr/bin/env bash
# agentkeys sync — pull keyvault from remote, decrypt all 4 Types, materialize
# composed artifacts under ~/.secrets/ (or $AGENTKEYS_SECRETS).
#
# Types handled (per SPEC §2 / §3.3):
#   A) shared/*.yaml   → ~/.secrets/shared/<name>.env  (flat KEY=value)
#   A) agents/*.yaml   → ~/.secrets/agents/<name>.env  (shared + override + Type B injection)
#   B) services/*.yaml → ~/.secrets/<svc>/<consumer>.token  +  injection into each agent env
#   C) files/*.yaml    → ~/.secrets/<dest>  (base64-decoded, chmod from manifest)
#
# Layout is staged in a sibling directory and atomically renamed in to avoid
# torn writes.
set -euo pipefail

# shellcheck source=lib/common.sh
source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/common.sh"
# scope.sh provides scope_list_encrypted_files — the single answer to "what
# is a vault secret" shared with the scope generator. NB: sync does NOT
# install the _scope_exit_trap; it never opens a scope transaction and
# carries its own on_fail EXIT trap below.
source "${AGENTKEYS_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/lib}/scope.sh"

usage() {
  cat <<EOF
Usage: agentkeys sync [--no-pull] [--secrets-dir DIR]

Pull the keyvault and materialize ~/.secrets/ from all 4 Types.

OPTIONS:
  --no-pull              Skip 'git pull' (decrypt current local state only)
  --secrets-dir DIR      Override output dir (default: \$AGENTKEYS_SECRETS or ~/.secrets)
  -h, --help             Show this help

ENV:
  AGENTKEYS_KEYVAULT     Override keyvault location
  AGENTKEYS_SECRETS      Override output dir (~/.secrets)
  AGE_KEY_FILE           Age private key (default: ~/.age/key.txt). Exported to SOPS_AGE_KEY_FILE.

OUTPUTS (under \$AGENTKEYS_SECRETS):
  shared/<name>.env      Type A defaults
  agents/<name>.env      Type A composed (shared + override + Type B injection)
  <svc>/<consumer>.token Type B per-consumer tokens
  <type-c dest>          Type C restored files
  .sync-state            JSON metadata (commit sha, time, host, counts)
  .sync-error            Written on failure with cause + last_known_good

EXIT CODES:
  0   sync succeeded
  1   sync failed (.sync-error written if possible)
EOF
}

# ---------- arg parsing ----------

no_pull=0
secrets_dir="${AGENTKEYS_SECRETS:-$HOME/.secrets}"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pull)        no_pull=1; shift ;;
    --secrets-dir)    [ $# -ge 2 ] || die "--secrets-dir needs an argument"; secrets_dir="$2"; shift 2 ;;
    -h|--help|help)   usage; exit 0 ;;
    *)                die "Unknown arg: $1 (try: agentkeys sync --help)" ;;
  esac
done

check_deps

# Detect the right base64 decode flag for Type C content restoration.
# - GNU coreutils + macOS 13+ : `-d` works
# - Older macOS BSD base64    : only `-D` works
# `--decode` is GNU-only; using it would break Type C sync on older macOS.
if echo "" | base64 -d >/dev/null 2>&1; then
  BASE64_DECODE_FLAG="-d"
elif echo "" | base64 -D >/dev/null 2>&1; then
  BASE64_DECODE_FLAG="-D"
else
  die "Neither 'base64 -d' nor 'base64 -D' works on this system. Install GNU coreutils."
fi

keyvault="$(find_keyvault_root)" || die "Not inside a keyvault repo (cd into one, or set AGENTKEYS_KEYVAULT)"
info "Using keyvault: $keyvault"
info "Output:         $secrets_dir"

cd "$keyvault"

export SOPS_AGE_KEY_FILE="$(age_key_file)"
[ -f "$SOPS_AGE_KEY_FILE" ] || die "Age private key not found: $SOPS_AGE_KEY_FILE
Generate one with: mkdir -p ~/.age && age-keygen -o ~/.age/key.txt && chmod 600 ~/.age/key.txt"

# ---------- error reporting ----------

last_known_good=""
if [ -f "$secrets_dir/.sync-state" ]; then
  last_known_good="$(jq -r '.commit_sha // ""' "$secrets_dir/.sync-state" 2>/dev/null || echo "")"
fi

write_sync_error() {
  local reason="$1"
  # Only leave a breadcrumb inside a dir we previously managed — otherwise
  # we'd be writing into an unrelated dir the user pointed --secrets-dir at
  # by mistake, defeating the safety guard up in section 2.
  if [ -d "$secrets_dir" ] && [ -f "$secrets_dir/${AGENTKEYS_MARKER:-.agentkeys-managed}" ]; then
    cat > "$secrets_dir/.sync-error" <<EOF
{
  "synced_at": "$(date '+%Y-%m-%dT%H:%M:%S%z')",
  "host": "$(hostname -s)",
  "status": "error",
  "error": $(jq -Rn --arg s "$reason" '$s'),
  "last_known_good": "$last_known_good"
}
EOF
    chmod 600 "$secrets_dir/.sync-error" 2>/dev/null || true
  fi
}

on_fail() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    write_sync_error "${SYNC_FAIL_REASON:-script exited with code $rc}"
    # Clean up any half-built staging dir
    [ -n "${staging:-}" ] && [ -d "$staging" ] && rm -rf "$staging"
  fi
}
trap on_fail EXIT

# ---------- 1. git pull ----------

if [ "$no_pull" = "0" ]; then
  if git remote 2>/dev/null | grep -q .; then
    info "Pulling latest from remote…"
    if ! git_err="$(git pull --ff-only --quiet 2>&1)"; then
      SYNC_FAIL_REASON="git pull failed: $git_err"
      die "$SYNC_FAIL_REASON"
    fi
  else
    info "(no git remote configured — skipping pull)"
  fi
else
  info "(--no-pull: skipping git pull)"
fi

# ---------- 1b. Validate the local key against the (fresh) vault ----------
#
# The per-file skip below (machine_can_decrypt) reads "my pubkey is not
# among this file's recipients" as out-of-scope. That is only sound if this
# machine's key IS a registered recipient at all: an unregistered key, or
# an identity file whose '# public key:' line was stripped (sops decrypts
# fine without it, but the pubkey can't be resolved), would skip EVERY file
# and publish an OK state over an empty secrets dir — where the first
# sops -d used to fail loudly. Fail before any staging exists. Runs AFTER
# the pull: the normal onboarding path registers a machine upstream and
# then syncs to fetch that very registration.
if ! my_pubkey="$(age_pubkey 2>/dev/null)" || [ -z "$my_pubkey" ]; then
  SYNC_FAIL_REASON="cannot resolve this machine's age public key from $SOPS_AGE_KEY_FILE (missing '# public key:' line? regenerate or restore the identity file header)"
  die "$SYNC_FAIL_REASON"
fi
if ! registered_recipients="$(scope_read_recipients "$keyvault")"; then
  SYNC_FAIL_REASON="cannot enumerate $keyvault/recipients/ (unreadable or malformed pubkey file — see error above)"
  die "$SYNC_FAIL_REASON"
fi
if ! printf '%s\n' "$registered_recipients" | cut -f2 | grep -qxF "$my_pubkey"; then
  SYNC_FAIL_REASON="this machine's age key ($my_pubkey) is not a registered recipient of $keyvault — register it with: agentkeys add-recipient <machine-name>"
  die "$SYNC_FAIL_REASON"
fi

# ---------- helpers ----------

decrypt_to_json() {
  # Decrypt yaml file and emit JSON on stdout. Fails loudly on bad input.
  local f="$1"
  sops -d "$f" | yq -o json '.'
}

# Handle a vault file this machine's key cannot decrypt (the Type loops call
# this BEFORE any decrypt attempt — an out-of-scope file must never even be
# fed to sops). Encrypted for other machines → expected under per-path
# scope: log + count, caller continues. No sops recipients at all → that is
# not scope, it is plaintext sitting in the vault — keep dying loudly on it,
# exactly as sync always has.
skipped_count=0
skip_out_of_scope() {
  local f="$1"
  if ! yq -e '.sops.age[0].recipient' "$f" >/dev/null 2>&1; then
    SYNC_FAIL_REASON="$f has no sops age recipients (plaintext in the vault?) — refusing"
    die "$SYNC_FAIL_REASON"
  fi
  info "  Skipping ${f#"$keyvault"/} (out of this machine's scope)"
  skipped_count=$((skipped_count+1))
}

# Normalize a name to env-var-safe upper-snake (e.g. "foo-bar" -> "FOO_BAR").
# Uses printf (not echo) so there's no trailing newline for the second tr to
# transliterate into a stray underscore.
normalize_env_name() {
  printf '%s' "$1" | LC_ALL=C tr '[:lower:]' '[:upper:]' | LC_ALL=C tr -c 'A-Z0-9_' '_'
}

# Wrap a string in POSIX-safe single quotes for inclusion in a .env file as
# `KEY='value'`. Embedded ' is rewritten as the canonical '\'' close-escape-
# reopen sequence. Values with $, backtick, space, #, ! etc. are then safe
# to `source` from bash/zsh (no expansion, no word-splitting, no comment-
# truncation) and are read as literals by Python python-dotenv and most
# Node dotenv variants.
shell_quote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

# Validate that every value in a flat JSON object is a string and contains
# no newline/CR characters. Call this from the MAIN shell (never inside a
# `< <(...)` process substitution — `die` there exits the subshell only).
# After it returns, the JSON is safe to iterate via `iter_kv`.
validate_kv_values() {
  local json="$1"
  local ctx="$2"
  local bad
  bad="$(echo "$json" | jq -r '
    to_entries[]
    | select((.value | type) != "string" or (.value | test("[\\n\\r]")))
    | .key
  ' | head -1)"
  if [ -n "$bad" ] && [ "$bad" != "null" ]; then
    SYNC_FAIL_REASON="$ctx: key '$bad' has non-string or newline-containing value (refusing)"
    die "$SYNC_FAIL_REASON"
  fi
}

# Validate that every key in a Type A JSON object is a POSIX-safe env var
# name (starts with uppercase letter or underscore, followed by uppercase
# letters / digits / underscores). Without this, sync would happily emit
# `foo-bar='...'` or `1TOKEN='...'` which downstream `source` consumers
# reject — and only at load time on each consumer machine, far from the
# edit that introduced the bad key. Apply only to shared/*.yaml and
# agents/*.yaml; services/*.yaml keys are consumer names (path components)
# guarded separately.
validate_env_var_names() {
  local json="$1"
  local ctx="$2"
  local bad
  bad="$(echo "$json" | jq -r '
    to_entries[]
    | .key
    | select(test("^[A-Z_][A-Z0-9_]*$") | not)
  ' | head -1)"
  if [ -n "$bad" ]; then
    SYNC_FAIL_REASON="$ctx: key '$bad' is not a valid env var name (must match ^[A-Z_][A-Z0-9_]*\$). Rename it in the keyvault."
    die "$SYNC_FAIL_REASON"
  fi
}

# Iterate a flat JSON object as JSON-per-line. Each emitted line is a
# compact `{"key":..., "value":...}` object the caller parses with jq.
# Run inside process substitution; `validate_kv_values` should have been
# called first in the main shell to gate bad input.
iter_kv() {
  echo "$1" | jq -c 'to_entries[]'
}

# Refuse names that would be unsafe as filesystem path components: empty,
# null, anything containing '/', '..', or starting with '.'. Used for Type B
# consumer keys (which become both ~/.secrets/<svc>/<consumer>.token paths
# and SVC_AUTH_<CONSUMER> env-var suffixes).
validate_path_component() {
  local name="$1"
  local ctx="$2"
  case "$name" in
    ""|null)
      SYNC_FAIL_REASON="$ctx: empty/null name (refusing)"
      die "$SYNC_FAIL_REASON" ;;
    /*|*/*|*..*|.*)
      SYNC_FAIL_REASON="$ctx: unsafe name '$name' (contains '/', '..', or leading '.')"
      die "$SYNC_FAIL_REASON" ;;
  esac
}

# ---------- 2. Stage output ----------
#
# Safety guard: the atomic swap below moves $secrets_dir aside and rm -rf's
# the old copy. If $secrets_dir was set wrong (`AGENTKEYS_SECRETS=$HOME`,
# typo'd `--secrets-dir`), that's catastrophic. Refuse unless the target is:
#   (a) absent, or
#   (b) empty, or
#   (c) a directory we previously managed (marker file present).
# A marker file is written into staging below and survives the swap.
AGENTKEYS_MARKER=".agentkeys-managed"

if [ -e "$secrets_dir" ]; then
  if [ ! -d "$secrets_dir" ]; then
    SYNC_FAIL_REASON="$secrets_dir exists but is not a directory — refusing to overwrite"
    die "$SYNC_FAIL_REASON"
  fi
  if [ ! -f "$secrets_dir/$AGENTKEYS_MARKER" ]; then
    if [ -n "$(ls -A "$secrets_dir" 2>/dev/null)" ]; then
      SYNC_FAIL_REASON="$secrets_dir is not empty and is not marked as agentkeys-managed (missing $AGENTKEYS_MARKER file). Refusing to replace — if you really want to, delete the directory manually first."
      die "$SYNC_FAIL_REASON"
    fi
  fi
fi

umask 077
mkdir -p "$(dirname "$secrets_dir")"
staging="${secrets_dir}.staging.$$"
rm -rf "$staging"
mkdir -p "$staging"
chmod 700 "$staging"

# Marker survives the atomic swap and tags the dir as agentkeys-managed.
cat > "$staging/$AGENTKEYS_MARKER" <<EOF
This directory is managed by 'agentkeys sync'. Its contents are replaced on
every sync run. Do not edit by hand — your changes will be wiped.

Removing this marker file will cause future 'agentkeys sync' invocations to
refuse to overwrite this directory (a safety guard against AGENTKEYS_SECRETS
typos pointing at \$HOME etc.).
EOF
chmod 600 "$staging/$AGENTKEYS_MARKER"

# ---------- 2b. Enumerate vault secrets ----------
#
# ONE enumeration, shared with the scope generator (lib/scope.sh), so "what
# is a vault secret" is decided in exactly one place: the whole-vault scan
# minus CLI metadata minus gitignored plaintext, checked against find
# failures. The per-dir globs this replaces disagreed with the generator —
# they fed gitignored plaintext to sops -d, killing the sync on a file that
# is not a secret. Type routing below is by path prefix; nested files and
# non-standard top-level dirs are legitimate vault secrets (agentkeys edit
# allows them) that sync has never materialized — keep them visible, not
# fatal.
if ! vault_files="$(scope_list_encrypted_files "$keyvault")"; then
  SYNC_FAIL_REASON="could not enumerate vault files (unreadable subdirectory?)"
  die "$SYNC_FAIL_REASON"
fi

shared_yamls=(); service_yamls=(); agent_yamls=(); file_manifests=(); unrouted_files=()
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    shared/*/*|services/*/*|agents/*/*|files/*/*) unrouted_files+=("$rel") ;;
    shared/*.yaml)   shared_yamls+=("$keyvault/$rel") ;;
    services/*.yaml) service_yamls+=("$keyvault/$rel") ;;
    agents/*.yaml)   agent_yamls+=("$keyvault/$rel") ;;
    files/*.yaml)    file_manifests+=("$keyvault/$rel") ;;
    *)               unrouted_files+=("$rel") ;;
  esac
done <<< "$vault_files"

if [ ${#unrouted_files[@]} -gt 0 ]; then
  info "  (${#unrouted_files[@]} vault file(s) outside the four Type dirs, not materialized: ${unrouted_files[*]})"
fi

# ---------- 3. Process shared/ (Type A) ----------

declare -A SHARED_KV=()
declare -A SHARED_KV_SOURCE=()   # key -> which file it came from (for collision error)
shared_files_written=0

if [ ${#shared_yamls[@]} -gt 0 ]; then
  mkdir -p "$staging/shared"
  for f in "${shared_yamls[@]}"; do
    name="$(basename "$f" .yaml)"
    if ! machine_can_decrypt "$f"; then
      skip_out_of_scope "$f"; continue
    fi
    if ! json="$(decrypt_to_json "$f")"; then
      SYNC_FAIL_REASON="failed to decrypt $f"
      die "$SYNC_FAIL_REASON"
    fi

    # Validate values + key names up-front (must be main-shell so die aborts).
    validate_kv_values    "$json" "shared/$name.yaml"
    validate_env_var_names "$json" "shared/$name.yaml"

    # Collision detection (spec §4.3): fail loudly if a key appears in two
    # shared files. Done in a first pass so SHARED_KV stays consistent when
    # we abort.
    while IFS= read -r entry; do
      k="$(echo "$entry" | jq -r '.key')"
      if [ -n "${SHARED_KV_SOURCE[$k]+set}" ]; then
        SYNC_FAIL_REASON="duplicate key '$k' in shared/: first in ${SHARED_KV_SOURCE[$k]}, now in $name.yaml (spec §4.3)"
        die "$SYNC_FAIL_REASON"
      fi
      SHARED_KV_SOURCE[$k]="$name.yaml"
    done < <(iter_kv "$json")

    # Second pass: load values into SHARED_KV and emit shell-quoted .env
    # lines. Values are wrapped in '...' so $-expansion, backticks, spaces,
    # and '#' comments don't break downstream `source` consumers.
    {
      while IFS= read -r entry; do
        k="$(echo "$entry" | jq -r '.key')"
        v="$(echo "$entry" | jq -r '.value')"
        SHARED_KV[$k]="$v"
        echo "$k=$(shell_quote "$v")"
      done < <(iter_kv "$json")
    } > "$staging/shared/$name.env"
    chmod 600 "$staging/shared/$name.env"
    shared_files_written=$((shared_files_written + 1))
  done
fi

# ---------- 4. Process services/ (Type B) ----------

declare -A SERVICES_JSON=()
declare -A SEEN_SVC_NORM=()   # svc_upper -> original svc name (cross-service collision)
service_token_files_written=0

for f in "${service_yamls[@]}"; do
  svc="$(basename "$f" .yaml)"
  if ! machine_can_decrypt "$f"; then
    skip_out_of_scope "$f"; continue
  fi
  validate_path_component "$svc" "services/ filename"
  # Service name flows into Type B injection as `<SVC_UPPER>_AUTH_*`. After
  # normalize, the prefix must be a valid env-var start (letter/underscore),
  # otherwise `source` rejects it on the consumer side. Reject e.g.
  # `services/1password.yaml`.
  svc_norm="$(normalize_env_name "$svc")"
  case "$svc_norm" in
    [A-Z_]*) ;;
    *) SYNC_FAIL_REASON="services/$svc.yaml: name '$svc' normalizes to '$svc_norm' which is not a valid env var prefix (must start with letter or underscore). Rename the service file."
       die "$SYNC_FAIL_REASON" ;;
  esac
  # Cross-service normalize collision (e.g. `services/foo-bar.yaml` +
  # `services/foo_bar.yaml` both → `FOO_BAR`, second would silently overwrite
  # the first's `FOO_BAR_AUTH_*` injections).
  if [ -n "${SEEN_SVC_NORM[$svc_norm]+set}" ]; then
    SYNC_FAIL_REASON="services/$svc.yaml and services/${SEEN_SVC_NORM[$svc_norm]}.yaml both normalize to env prefix '$svc_norm' — Type B injection would silently overwrite. Rename one."
    die "$SYNC_FAIL_REASON"
  fi
  SEEN_SVC_NORM[$svc_norm]="$svc"

  if ! json="$(decrypt_to_json "$f")"; then
    SYNC_FAIL_REASON="failed to decrypt $f"; die "$SYNC_FAIL_REASON"
  fi
  # Validate values up-front (newline/CR rejected); validate_path_component
  # inside the loop guards against consumer keys containing '/', '..', or
  # leading '.' that would escape $staging/$svc/.
  validate_kv_values "$json" "services/$svc.yaml"
  SERVICES_JSON[$svc]="$json"

  # Per-service consumer-normalize collision detection.
  declare -A SEEN_CONSUMER_NORM=()
  mkdir -p "$staging/$svc"
  while IFS= read -r entry; do
    consumer="$(echo "$entry" | jq -r '.key')"
    token="$(echo "$entry" | jq -r '.value')"
    validate_path_component "$consumer" "services/$svc.yaml consumer key"
    # Consumer also flows into `<SVC>_AUTH_<CONSUMER>` — same constraint.
    c_norm="$(normalize_env_name "$consumer")"
    case "$c_norm" in
      [A-Z_]*) ;;
      *) SYNC_FAIL_REASON="services/$svc.yaml: consumer key '$consumer' normalizes to '$c_norm' which is not a valid env var component (must start with letter or underscore)."
         die "$SYNC_FAIL_REASON" ;;
    esac
    # Within-service consumer collision (e.g. `foo-bar` + `foo_bar` both
    # normalize to `FOO_BAR` — would silently overwrite the same env var).
    if [ -n "${SEEN_CONSUMER_NORM[$c_norm]+set}" ]; then
      SYNC_FAIL_REASON="services/$svc.yaml: consumers '$consumer' and '${SEEN_CONSUMER_NORM[$c_norm]}' both normalize to '$c_norm' — Type B injection would silently overwrite. Rename one."
      die "$SYNC_FAIL_REASON"
    fi
    SEEN_CONSUMER_NORM[$c_norm]="$consumer"
    printf '%s' "$token" > "$staging/$svc/$consumer.token"
    chmod 600 "$staging/$svc/$consumer.token"
    service_token_files_written=$((service_token_files_written + 1))
  done < <(iter_kv "$json")
  unset SEEN_CONSUMER_NORM
done

# ---------- 5. Process agents/ (Type A composed) ----------

agent_files_written=0

if [ ${#agent_yamls[@]} -gt 0 ]; then
  mkdir -p "$staging/agents"
  for f in "${agent_yamls[@]}"; do
    consumer="$(basename "$f" .yaml)"
    if ! machine_can_decrypt "$f"; then
      skip_out_of_scope "$f"; continue
    fi
    if ! agent_json="$(decrypt_to_json "$f")"; then
      SYNC_FAIL_REASON="failed to decrypt $f"; die "$SYNC_FAIL_REASON"
    fi

    declare -A COMPOSED=()

    # Layer 1: shared defaults
    for k in "${!SHARED_KV[@]}"; do
      COMPOSED[$k]="${SHARED_KV[$k]}"
    done

    # Layer 2: agent overrides (empty string skipped per spec §4.3).
    validate_kv_values    "$agent_json" "agents/$consumer.yaml"
    validate_env_var_names "$agent_json" "agents/$consumer.yaml"
    while IFS= read -r entry; do
      k="$(echo "$entry" | jq -r '.key')"
      v="$(echo "$entry" | jq -r '.value')"
      [ -z "$v" ] && continue
      COMPOSED[$k]="$v"
    done < <(iter_kv "$agent_json")

    # Layer 3: Type B injection. Service JSON was already validated when
    # services/ was processed (newline + path-component checks), so we can
    # iterate directly.
    for svc in "${!SERVICES_JSON[@]}"; do
      svc_upper="$(normalize_env_name "$svc")"
      while IFS= read -r entry; do
        c="$(echo "$entry" | jq -r '.key')"
        tok="$(echo "$entry" | jq -r '.value')"
        c_upper="$(normalize_env_name "$c")"
        COMPOSED["${svc_upper}_AUTH_${c_upper}"]="$tok"
        if [ "$c" = "$consumer" ]; then
          COMPOSED["${svc_upper}_AUTH"]="$tok"
        fi
      done < <(iter_kv "${SERVICES_JSON[$svc]}")
    done

    # Emit sorted KEY=value
    {
      for k in "${!COMPOSED[@]}"; do
        v="${COMPOSED[$k]}"
        case "$v" in
          *$'\n'*|*$'\r'*) SYNC_FAIL_REASON="agent $consumer key '$k' value contains newline"; die "$SYNC_FAIL_REASON" ;;
        esac
        echo "$k=$(shell_quote "$v")"
      done
    } | LC_ALL=C sort > "$staging/agents/$consumer.env"
    chmod 600 "$staging/agents/$consumer.env"
    agent_files_written=$((agent_files_written + 1))

    unset COMPOSED
  done
fi

# ---------- 6. Process files/ (Type C) ----------

type_c_files_written=0

for f in "${file_manifests[@]}"; do
  if ! machine_can_decrypt "$f"; then
    skip_out_of_scope "$f"; continue
  fi
  if ! json="$(decrypt_to_json "$f")"; then
    SYNC_FAIL_REASON="failed to decrypt $f"; die "$SYNC_FAIL_REASON"
  fi

  # Validate manifest shape
  if ! echo "$json" | jq -e 'has("files") and (.files | type == "array")' >/dev/null; then
    SYNC_FAIL_REASON="invalid Type C manifest $f: missing .files[] array"
    die "$SYNC_FAIL_REASON"
  fi

  # Iterate entries. Each line is one compact JSON object — safe because
  # base64 content has no embedded newlines.
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    dest="$(echo "$entry" | jq -r '.dest')"
    mode="$(echo "$entry" | jq -r '.mode')"
    b64content="$(echo "$entry" | jq -r '.content')"

    # Path traversal guards (per spec §6 pseudocode)
    case "$dest" in
      ""|null)             SYNC_FAIL_REASON="Type C entry in $f missing .dest"; die "$SYNC_FAIL_REASON" ;;
      /*)                  SYNC_FAIL_REASON="Type C absolute dest in $f: $dest"; die "$SYNC_FAIL_REASON" ;;
      *..*)                SYNC_FAIL_REASON="Type C '..' traversal in $f: $dest"; die "$SYNC_FAIL_REASON" ;;
      .*|*/.*)             SYNC_FAIL_REASON="Type C dotfile traversal in $f: $dest"; die "$SYNC_FAIL_REASON" ;;
    esac

    case "$mode" in
      ""|null) SYNC_FAIL_REASON="Type C entry $dest in $f missing .mode"; die "$SYNC_FAIL_REASON" ;;
    esac

    target="$staging/$dest"
    if [ -L "$target" ]; then
      SYNC_FAIL_REASON="Type C target is a symlink (refused): $target"; die "$SYNC_FAIL_REASON"
    fi
    mkdir -p "$(dirname "$target")"
    # Use the decode flag detected at startup (-d on GNU/macOS 13+, -D on
    # older macOS BSD). `--decode` is GNU-only and would break Type C sync.
    if ! echo "$b64content" | base64 "$BASE64_DECODE_FLAG" > "$target" 2>/dev/null; then
      SYNC_FAIL_REASON="Type C base64 decode failed for $dest in $f"; die "$SYNC_FAIL_REASON"
    fi
    chmod "$mode" "$target"
    type_c_files_written=$((type_c_files_written + 1))
  done < <(echo "$json" | jq -c ".files[]")
done

# ---------- 7. Atomic swap ----------

if [ -e "$secrets_dir" ] && [ ! -L "$secrets_dir" ]; then
  prev="${secrets_dir}.prev.$$"
  mv "$secrets_dir" "$prev"
  mv "$staging" "$secrets_dir"
  rm -rf "$prev"
else
  [ -L "$secrets_dir" ] && rm -f "$secrets_dir"
  mv "$staging" "$secrets_dir"
fi
staging=""  # so trap doesn't try to clean it

# ---------- 8. Write .sync-state ----------

commit_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
total_files=$((shared_files_written + service_token_files_written + agent_files_written + type_c_files_written))

cat > "$secrets_dir/.sync-state" <<EOF
{
  "commit_sha": "$commit_sha",
  "synced_at": "$(date '+%Y-%m-%dT%H:%M:%S%z')",
  "host": "$(hostname -s)",
  "files_written": $total_files,
  "breakdown": {
    "shared": $shared_files_written,
    "service_tokens": $service_token_files_written,
    "agents": $agent_files_written,
    "type_c_files": $type_c_files_written,
    "skipped": $skipped_count
  },
  "status": "ok"
}
EOF
chmod 600 "$secrets_dir/.sync-state"
rm -f "$secrets_dir/.sync-error"

info "✓ Synced commit ${commit_sha:0:8}"
info "  shared/<name>.env       : $shared_files_written"
info "  agents/<name>.env       : $agent_files_written"
info "  <svc>/<consumer>.token  : $service_token_files_written"
info "  Type C files            : $type_c_files_written"
info "  Skipped (out of scope)  : $skipped_count"
info "  Output                  : $secrets_dir"
