#!/bin/sh
# OpenClaw exec SecretRef provider — POSIX sh (compatible with /bin/bash 3.2).
# stdin : {"protocolVersion":1,"provider":"<p>","ids":["KEY",...]}
# stdout: {"protocolVersion":1,"values":{"KEY":"<val>"},"errors":{...}}
#
# Reads from the composed agent env file at:
#   $HOME/.secrets/agents/$AGENTKEYS_AGENT.env   (if AGENTKEYS_AGENT is set)
# Falls back to globbing $HOME/.secrets/agents/*.env, then shared/*.env.
#
# No secret is written to stderr/log. PATH pinned to coreutils + jq.
set -eu
set -f                       # no glob expansion on id=".*"
PATH=/usr/bin:/bin
export PATH
umask 077
REQ=$(cat)
emit_err() { jq -nc --arg m "$1" '{protocolVersion:1,values:{},errors:{_:{message:$m}}}'; exit 0; }
printf '%s' "$REQ" | jq -e '.protocolVersion==1' >/dev/null 2>&1 || emit_err "bad protocolVersion"
printf '%s' "$REQ" | jq -e '(.ids|type=="array") and (.ids|all(type=="string" and test("^[A-Z][A-Z0-9_]{0,127}$")))' >/dev/null 2>&1 || emit_err "bad ids"
if [ -n "${AGENTKEYS_AGENT:-}" ] && [ -f "$HOME/.secrets/agents/${AGENTKEYS_AGENT}.env" ]; then
  SRCS="$HOME/.secrets/agents/${AGENTKEYS_AGENT}.env"
else
  SRCS=$(find "$HOME/.secrets/agents" -maxdepth 1 -type f -name '*.env' 2>/dev/null || true)
  [ -z "$SRCS" ] && SRCS=$(find "$HOME/.secrets/shared" -maxdepth 1 -type f -name '*.env' 2>/dev/null || true)
fi
lookup() {
  _k=$1
  for _f in $SRCS; do
    [ -f "$_f" ] || continue
    _line=$(grep -E "^${_k}=" "$_f" | tail -n1 || true)
    [ -n "$_line" ] || continue
    _v=${_line#*=}
    case "$_v" in
      \'*\') _v=${_v#\'}; _v=${_v%\'}; _v=$(printf '%s' "$_v" | sed "s/'\\\\''/'/g") ;;
    esac
    printf '%s' "$_v"
    return 0
  done
  return 1
}
values='{}'
errors='{}'
for id in $(printf '%s' "$REQ" | jq -r '.ids[]'); do
  [ -n "$id" ] || continue
  if val=$(lookup "$id"); then
    values=$(printf '%s' "$val" | jq -Rs --arg k "$id" --argjson o "$values" '$o + {($k): rtrimstr("\n")}')
  else
    errors=$(jq -nc --arg k "$id" --argjson o "$errors" '$o + {($k):{message:"not found"}}')
  fi
done
jq -nc --argjson v "$values" --argjson e "$errors" \
  '{protocolVersion:1,values:$v} + (if ($e|length)>0 then {errors:$e} else {} end)'
