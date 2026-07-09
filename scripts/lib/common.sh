#!/usr/bin/env bash
# Shared helpers for agentkeys subcommands.
# Source this from cmd-*.sh:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

set -euo pipefail

# ---------- Logging ----------

_log() {
  local level="$1"; shift
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] [$level] $*" >&2
}
info()  { _log "INFO"  "$@"; }
warn()  { _log "WARN"  "$@"; }
err()   { _log "ERROR" "$@"; }
die()   { err "$@"; exit 1; }

# ---------- Path resolution ----------

expand_path() {
  # Expand leading ~ and resolve to absolute path
  local p="$1"
  p="${p/#\~/$HOME}"
  if [ -e "$p" ]; then
    cd "$(dirname "$p")" && echo "$PWD/$(basename "$p")"
  else
    # Doesn't exist yet — resolve parent only
    local parent
    parent="$(dirname "$p")"
    if [ -d "$parent" ]; then
      cd "$parent" && echo "$PWD/$(basename "$p")"
    else
      echo "$p"
    fi
  fi
}

find_keyvault_root() {
  # Resolution order:
  #   1. $AGENTKEYS_KEYVAULT (explicit env override — set ad-hoc in your
  #      shell or by a wrapper; wins over everything)
  #   2. cwd walk-up — you cd'd into a vault, work on that one
  #   3. ~/.agentkeys/config (or $AGENTKEYS_CONFIG_FILE) — the default vault
  #      path picked at install time; covers cron/launchd and "just work
  #      from anywhere" usage.
  # Canonical-layout (.sops.yaml + recipients/ + shared/) is required for
  # all three — otherwise sync could decrypt 0 files from an empty unrelated
  # dir and atomically wipe a marker-managed ~/.secrets cache.
  _looks_like_vault() {
    [ -d "$1" ] && [ -f "$1/.sops.yaml" ] && [ -d "$1/recipients" ] && [ -d "$1/shared" ]
  }
  # The returned path is used in TEXT comparisons downstream — e.g.
  # scope_list_encrypted_files strips "$keyvault/" off find output as a
  # string. A trailing slash (AGENTKEYS_KEYVAULT=/vault/) broke that strip:
  # paths stayed absolute, metadata exclusions missed, .sops.yaml gained
  # absolute-path rules and updatekeys skipped the real files — a scope
  # change (revocation!) could "succeed" without re-encrypting anything.
  # So every return goes through the shell's canonical form. PHYSICAL
  # (pwd -P): find does not recurse into a bare symlink operand (-P is its
  # default), so a logical symlink path would make the vault file scan come
  # back empty — same silent-revocation failure through another door.
  _canon_dir() { ( CDPATH='' cd -- "$1" 2>/dev/null && pwd -P ); }

  # 1. Explicit env override
  if [ -n "${AGENTKEYS_KEYVAULT:-}" ]; then
    if _looks_like_vault "$AGENTKEYS_KEYVAULT" && _canon_dir "$AGENTKEYS_KEYVAULT"; then
      return 0
    fi
    err "AGENTKEYS_KEYVAULT='$AGENTKEYS_KEYVAULT' is not a keyvault (missing .sops.yaml, recipients/, or shared/)"
    return 1
  fi

  # 2. cwd walk-up
  local dir="${1:-$PWD}"
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if _looks_like_vault "$dir"; then
      _canon_dir "$dir" && return 0
      return 1
    fi
    dir="$(dirname "$dir")"
  done

  # 3. Config-file fallback. Source the config in a subshell so any extra
  # variables it sets (we only care about AGENTKEYS_KEYVAULT) don't leak.
  local cfg="${AGENTKEYS_CONFIG_FILE:-$HOME/.agentkeys/config}"
  if [ -f "$cfg" ]; then
    local cfg_vault
    cfg_vault="$(
      AGENTKEYS_KEYVAULT=""
      # shellcheck disable=SC1090
      source "$cfg" 2>/dev/null || true
      printf '%s' "${AGENTKEYS_KEYVAULT:-}"
    )"
    if [ -n "$cfg_vault" ] && _looks_like_vault "$cfg_vault"; then
      _canon_dir "$cfg_vault" && return 0
      return 1
    fi
  fi

  return 1
}

# ---------- Dependency check ----------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1 (install with: brew install $1)"
}

check_deps() {
  local deps=(sops age git jq yq)
  local missing=()
  for c in "${deps[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "Missing dependencies: ${missing[*]} (install with: brew install ${missing[*]})"
  fi
}

# ---------- Age key ----------

AGE_KEY_FILE_DEFAULT="$HOME/.age/key.txt"

age_key_file() {
  echo "${AGE_KEY_FILE:-$AGE_KEY_FILE_DEFAULT}"
}

age_pubkey() {
  local key_file
  key_file="$(age_key_file)"
  [ -f "$key_file" ] || die "Age private key not found at $key_file. Run: age-keygen -o $key_file"
  grep "^# public key:" "$key_file" | sed 's/^# public key: //'
}

# Return 0 if this machine's age pubkey is listed among a sops-encrypted
# file's recipients (i.e. we're expected to decrypt it). Used by sync to skip
# out-of-scope files instead of dying on them. Reads the file's own sops.age
# metadata (its CURRENT encrypted state), not .sops.yaml (future rules).
#
# NOT `yq | grep -q`: grep -q exits at its first match, and under pipefail
# the producer's SIGPIPE (141) then fails the whole pipeline — turning a
# POSITIVE membership hit into an intermittent false "out of scope" (seen
# live: a 3-recipient file whose matching key sat on the first line).
# Materialize, then match — no pipe, no SIGPIPE.
machine_can_decrypt() {
  local f="$1" mypub recips
  [ -f "$(age_key_file)" ] || return 1
  mypub="$(age_pubkey)" || return 1
  recips="$(yq '.sops.age[].recipient' "$f" 2>/dev/null)" || return 1
  grep -qxF "$mypub" <<< "$recips"
}

# ---------- Confirmation prompt ----------

confirm() {
  local prompt="${1:-Continue?}"
  local default="${2:-n}"
  local yn_hint
  case "$default" in
    y|Y) yn_hint="[Y/n]" ;;
    *)   yn_hint="[y/N]" ;;
  esac

  read -r -p "$prompt $yn_hint " ans
  ans="${ans:-$default}"
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}
