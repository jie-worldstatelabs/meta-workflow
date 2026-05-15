#!/bin/bash
# PreToolUse + PostToolUse hook (all tools) — cloud-mode activity log.
#
# Emits two events per tool call so the webapp can render a pending row
# the moment a tool starts and upgrade it to "done" when it finishes:
#   * PreToolUse  → cloud_post_activity ... event_kind=started
#   * PostToolUse → cloud_post_activity ... event_kind=finished
# The pair is correlated by tool_use_id (Claude Code provides it on
# both events). For long-running tools (Bash sleeps, slow MCP calls)
# this is the difference between a feed that looks dead and one that
# looks alive.
#
# Always fire-and-forget (cloud_post_activity backgrounds the curl) —
# zero latency impact on the agent.
#
# Skipped: non-cloud sessions, no active stage, terminal stages,
#          and noisy internal tools (TodoWrite, TodoRead, LS).
#
# TELEMETRY LEVEL (STAGENT_TELEMETRY_LEVEL env var)
# -------------------------------------------------
#   summary (default) — strips tool_input / tool_result from the payload
#                        sent to the server. Only stage, tool name, one-line
#                        summary, is_error, agent_id, tool_use_id reach
#                        the server. Prevents raw file contents, Bash
#                        stdout, and API responses from leaving the local
#                        machine.
#   full              — opt-in to original behavior: sends full tool_input
#                        and tool_result. Use only when the server is
#                        trusted and the codebase is not sensitive.
#
# SENSITIVE TOOLS (Read, Write, Edit, MultiEdit, Bash)
# ----------------------------------------------------
# tool_input and tool_result are ALWAYS stripped unless
# STAGENT_TELEMETRY_LEVEL=full. These tools routinely emit file contents
# or command output that may contain secrets, PII, or proprietary code.

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

# ──────────────────────────────────────────────────────────────
# Diagnostic log. Every invocation appends exactly one line so we
# can reconstruct, after the fact, which Pre/PostToolUse pairs the
# webapp never received. Keyed by tool_use_id (the pairing key) so a
# missing `post=...` finished line for a given tuid pinpoints the
# lost event. Best-effort: a logging failure must NEVER abort the
# hook (that would make the diagnostics worse than the bug). The
# `|| true` + subshell isolation guarantees set -e can't trip here.
# ──────────────────────────────────────────────────────────────
ACTIVITY_LOG="${HOME}/.cache/stagent/activity-hook.log"
_alog() {
  { mkdir -p "$(dirname "$ACTIVITY_LOG")" 2>/dev/null &&
    printf '%s pid=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$$" "$*" \
      >> "$ACTIVITY_LOG"; } 2>/dev/null || true
}
_LOG_TOOL=""; _LOG_TUID=""; _LOG_EVENT=""; _LOG_STAGE=""; _LOG_REASON="enter"
trap '_alog "exit=$? event=${_LOG_EVENT:-?} tool=${_LOG_TOOL:-?} tuid=${_LOG_TUID:-?} stage=${_LOG_STAGE:-?} reason=${_LOG_REASON}"' EXIT

SID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
if [[ -z "$SID" ]]; then _LOG_REASON="no_sid"; exit 0; fi

if ! is_cloud_session "$SID"; then _LOG_REASON="not_cloud"; exit 0; fi

TOOL=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
_LOG_TOOL="$TOOL"
if [[ -z "$TOOL" ]]; then _LOG_REASON="no_tool"; exit 0; fi

case "$TOOL" in
  TodoWrite|TodoRead|LS) _LOG_REASON="skip_noisy"; exit 0 ;;
esac

EVENT_NAME=$(echo "$HOOK_INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null || true)
_LOG_EVENT="$EVENT_NAME"

SHADOW_DIR="$(cloud_registry_get "$SID" scratch_dir)"
[[ -z "$SHADOW_DIR" ]] && SHADOW_DIR="${CLOUD_SCRATCH_BASE}/${SID}"
STATE_FILE="${SHADOW_DIR}/state.md"
if [[ ! -f "$STATE_FILE" ]]; then _LOG_REASON="no_state_file"; exit 0; fi

STAGE=$(_read_fm_field "$STATE_FILE" status)
_LOG_STAGE="$STAGE"
if [[ -z "$STAGE" ]]; then _LOG_REASON="no_stage"; exit 0; fi

EPOCH=$(_read_fm_field "$STATE_FILE" epoch)

CLOUD_SID=$(_read_fm_field "$STATE_FILE" session_id)
[[ -z "$CLOUD_SID" ]] && CLOUD_SID="$SID"

case "$STAGE" in
  complete|cancelled|archived|interrupted) _LOG_REASON="terminal_stage"; exit 0 ;;
esac

INPUT=$(echo "$HOOK_INPUT" | jq -r '.tool_input // {}' 2>/dev/null || echo "{}")

case "$TOOL" in
  Read)
    SUMMARY=$(echo "$INPUT" | jq -r '.file_path // ""' 2>/dev/null || true)
    ;;
  Write|Edit|MultiEdit)
    SUMMARY=$(echo "$INPUT" | jq -r '.file_path // ""' 2>/dev/null || true)
    ;;
  Bash)
    SUMMARY=$(echo "$INPUT" | jq -r '.command // ""' 2>/dev/null | cut -c1-120 || true)
    ;;
  Grep)
    PAT=$(echo "$INPUT" | jq -r '.pattern // ""' 2>/dev/null || true)
    PPATH=$(echo "$INPUT" | jq -r '.path // ""' 2>/dev/null || true)
    SUMMARY="${PAT}${PPATH:+ in ${PPATH}}"
    ;;
  Glob)
    SUMMARY=$(echo "$INPUT" | jq -r '.pattern // ""' 2>/dev/null || true)
    ;;
  Agent)
    SUMMARY=$(echo "$INPUT" | jq -r '.subagent_type // .description // ""' 2>/dev/null \
              | cut -c1-80 || true)
    ;;
  WebSearch)
    SUMMARY=$(echo "$INPUT" | jq -r '.query // ""' 2>/dev/null || true)
    ;;
  WebFetch)
    SUMMARY=$(echo "$INPUT" | jq -r '.url // ""' 2>/dev/null || true)
    ;;
  *)
    SUMMARY=""
    ;;
esac

TOOL_USE_ID=$(echo "$HOOK_INPUT" | jq -r '.tool_use_id // ""' 2>/dev/null || true)
_LOG_TUID="$TOOL_USE_ID"

# ── Telemetry scoping ─────────────────────────────────────────────────────
# Default: strip tool_input and tool_result from the cloud payload.
# export STAGENT_TELEMETRY_LEVEL=full to restore original behavior.
# Sensitive tool class is ALWAYS stripped at summary level.
TELEMETRY_LEVEL="${STAGENT_TELEMETRY_LEVEL:-summary}"

IS_SENSITIVE=false
case "$TOOL" in
  Read|Write|Edit|MultiEdit|Bash) IS_SENSITIVE=true ;;
esac

if [[ "$TELEMETRY_LEVEL" == "full" ]]; then
  SCOPED_INPUT_JSON=$(echo "$HOOK_INPUT" | jq -c '.tool_input // null' 2>/dev/null || echo "null")
else
  if [[ "$IS_SENSITIVE" == "true" ]]; then
    SCOPED_INPUT_JSON="null"
  else
    SCOPED_INPUT_JSON=$(echo "$HOOK_INPUT" | jq -c '.tool_input // null' 2>/dev/null || echo "null")
  fi
fi

IS_SIDECHAIN=$(echo "$HOOK_INPUT" | jq -r '.is_sidechain // false' 2>/dev/null || echo "false")
AGENT_ID=$(echo "$HOOK_INPUT" | jq -r '.agent_id // ""' 2>/dev/null || true)
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.agent_type // ""' 2>/dev/null || true)

if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
  _alog "post=started tool=$TOOL tuid=$TOOL_USE_ID stage=$STAGE cloud_sid=$CLOUD_SID summary_len=${#SUMMARY} telemetry=$TELEMETRY_LEVEL sensitive=$IS_SENSITIVE"
  cloud_post_activity "$CLOUD_SID" "$STAGE" "${EPOCH:-0}" "$TOOL" "${SUMMARY:-}" \
    "$SCOPED_INPUT_JSON" "null" "false" \
    "$IS_SIDECHAIN" "$AGENT_ID" "$AGENT_TYPE" \
    "started" "$TOOL_USE_ID"
  _LOG_REASON="posted_started"
  exit 0
fi

# PostToolUse — finished event. Compute scoped result payload.
if [[ "$TELEMETRY_LEVEL" == "full" ]]; then
  TOOL_RESULT_JSON=$(echo "$HOOK_INPUT" | jq -c '.tool_response // null' 2>/dev/null || echo "null")
else
  # Strip result at summary level — carries tool output which for
  # Read/Bash/Write may contain file contents or shell stdout.
  TOOL_RESULT_JSON="null"
fi

IS_ERROR=$(echo "$HOOK_INPUT" | jq -r '
  if (.tool_response.is_error // false) == true then "true"
  elif (.tool_name == "Bash" and ((.tool_response.exit_code // 0) != 0)) then "true"
  else "false" end
' 2>/dev/null || echo "false")

_alog "post=finished tool=$TOOL tuid=$TOOL_USE_ID stage=$STAGE cloud_sid=$CLOUD_SID is_error=$IS_ERROR result_len=${#TOOL_RESULT_JSON} telemetry=$TELEMETRY_LEVEL sensitive=$IS_SENSITIVE"
cloud_post_activity "$CLOUD_SID" "$STAGE" "${EPOCH:-0}" "$TOOL" "${SUMMARY:-}" \
  "$SCOPED_INPUT_JSON" "$TOOL_RESULT_JSON" "$IS_ERROR" \
  "$IS_SIDECHAIN" "$AGENT_ID" "$AGENT_TYPE" \
  "finished" "$TOOL_USE_ID"
_LOG_REASON="posted_finished"

# Clear a permission/idle awaiting state once the agent resumes work.
if [[ "$(get_awaiting_user "$STATE_FILE" 2>/dev/null)" == "true" ]]; then
  _AR="$(get_awaiting_reason "$STATE_FILE" 2>/dev/null || true)"
  if [[ "$_AR" == "permission" || "$_AR" == "idle" ]]; then
    set_awaiting_user   "$STATE_FILE" false
    set_awaiting_reason "$STATE_FILE" ""
    _alog "cleared awaiting (reason=$_AR) on resumed activity tuid=$TOOL_USE_ID"
    cloud_post_awaiting_user "$CLOUD_SID" false >/dev/null 2>&1 || true
  fi
fi

exit 0
