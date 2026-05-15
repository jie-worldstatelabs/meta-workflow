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

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

SID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
[[ -z "$SID" ]] && exit 0

is_cloud_session "$SID" || exit 0

TOOL=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
[[ -z "$TOOL" ]] && exit 0

# Skip internal / noisy tools
case "$TOOL" in
  TodoWrite|TodoRead|LS) exit 0 ;;
esac

EVENT_NAME=$(echo "$HOOK_INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null || true)

# Read current stage from shadow state.md
SHADOW_DIR="$(cloud_registry_get "$SID" scratch_dir)"
[[ -z "$SHADOW_DIR" ]] && SHADOW_DIR="${CLOUD_SCRATCH_BASE}/${SID}"
STATE_FILE="${SHADOW_DIR}/state.md"
[[ -f "$STATE_FILE" ]] || exit 0

STAGE=$(_read_fm_field "$STATE_FILE" status)
[[ -z "$STAGE" ]] && exit 0

EPOCH=$(_read_fm_field "$STATE_FILE" epoch)

# Takeover aliasing: Claude Code's session_id ($SID) is the local CC
# session, which in a takeover may differ from the cloud server-side
# session_id. The cloud server keys rows by the server-side id, so
# posting to /api/sessions/<local-SID>/activity 404s. state.md's
# frontmatter always carries the canonical cloud session_id — use it.
CLOUD_SID=$(_read_fm_field "$STATE_FILE" session_id)
[[ -z "$CLOUD_SID" ]] && CLOUD_SID="$SID"

# Skip known terminal statuses
case "$STAGE" in
  complete|cancelled|archived|interrupted) exit 0 ;;
esac

# Extract a one-line summary from tool_input — same shape regardless
# of which hook fired (tool_input is present in both Pre/PostToolUse).
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
    # Prompt capture happens in agent-guard.sh (PreToolUse) — posting
    # it here would be delayed until the subagent returns, which for
    # long stages can mean the webapp shows "No prompt captured" for
    # the entire run. Keep this branch to just emit the activity-feed
    # summary above.
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

# tool_use_id is present on BOTH PreToolUse and PostToolUse payloads
# in Claude Code; the webapp uses it to pair the started/finished
# rows so the pending row gets upgraded in place rather than rendered
# twice. Empty when CC didn't supply it (older versions) — webapp
# degrades to inserting a fresh row.
TOOL_USE_ID=$(echo "$HOOK_INPUT" | jq -r '.tool_use_id // ""' 2>/dev/null || true)

TOOL_INPUT_JSON=$(echo "$HOOK_INPUT" | jq -c '.tool_input // null' 2>/dev/null || echo "null")

# Sidechain identity: when this hook fires inside a subagent, Claude
# Code sets is_sidechain=true and adds agent_id / agent_type top-level
# fields. Same shape on Pre and Post.
IS_SIDECHAIN=$(echo "$HOOK_INPUT" | jq -r '.is_sidechain // false' 2>/dev/null || echo "false")
AGENT_ID=$(echo "$HOOK_INPUT" | jq -r '.agent_id // ""' 2>/dev/null || true)
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.agent_type // ""' 2>/dev/null || true)

if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
  # Started event — no tool_response, no is_error yet.
  cloud_post_activity "$CLOUD_SID" "$STAGE" "${EPOCH:-0}" "$TOOL" "${SUMMARY:-}" \
    "$TOOL_INPUT_JSON" "null" "false" \
    "$IS_SIDECHAIN" "$AGENT_ID" "$AGENT_TYPE" \
    "started" "$TOOL_USE_ID"
  exit 0
fi

# PostToolUse — finished event. Includes tool_response + is_error.
TOOL_RESULT_JSON=$(echo "$HOOK_INPUT" | jq -c '.tool_response // null' 2>/dev/null || echo "null")

# Error heuristic: prefer the explicit is_error field Claude Code
# sets on most tool responses; for Bash, also treat a non-zero
# exit_code as an error since Claude Code doesn't always set is_error
# for shell commands. Missing fields → not an error.
IS_ERROR=$(echo "$HOOK_INPUT" | jq -r '
  if (.tool_response.is_error // false) == true then "true"
  elif (.tool_name == "Bash" and ((.tool_response.exit_code // 0) != 0)) then "true"
  else "false" end
' 2>/dev/null || echo "false")

cloud_post_activity "$CLOUD_SID" "$STAGE" "${EPOCH:-0}" "$TOOL" "${SUMMARY:-}" \
  "$TOOL_INPUT_JSON" "$TOOL_RESULT_JSON" "$IS_ERROR" \
  "$IS_SIDECHAIN" "$AGENT_ID" "$AGENT_TYPE" \
  "finished" "$TOOL_USE_ID"

exit 0
