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
# Log the final outcome no matter how the script exits (early-return
# guards, set -e abort, or normal completion). Populated as we learn
# the values; trap fires once on EXIT.
_LOG_TOOL=""; _LOG_TUID=""; _LOG_EVENT=""; _LOG_STAGE=""; _LOG_REASON="enter"
trap '_alog "exit=$? event=${_LOG_EVENT:-?} tool=${_LOG_TOOL:-?} tuid=${_LOG_TUID:-?} stage=${_LOG_STAGE:-?} reason=${_LOG_REASON}"' EXIT

SID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
if [[ -z "$SID" ]]; then _LOG_REASON="no_sid"; exit 0; fi

if ! is_cloud_session "$SID"; then _LOG_REASON="not_cloud"; exit 0; fi

TOOL=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
_LOG_TOOL="$TOOL"
if [[ -z "$TOOL" ]]; then _LOG_REASON="no_tool"; exit 0; fi

# Skip internal / noisy tools
case "$TOOL" in
  TodoWrite|TodoRead|LS) _LOG_REASON="skip_noisy"; exit 0 ;;
esac

EVENT_NAME=$(echo "$HOOK_INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null || true)
_LOG_EVENT="$EVENT_NAME"

# Read current stage from shadow state.md
SHADOW_DIR="$(cloud_registry_get "$SID" scratch_dir)"
[[ -z "$SHADOW_DIR" ]] && SHADOW_DIR="${CLOUD_SCRATCH_BASE}/${SID}"
STATE_FILE="${SHADOW_DIR}/state.md"
if [[ ! -f "$STATE_FILE" ]]; then _LOG_REASON="no_state_file"; exit 0; fi

STAGE=$(_read_fm_field "$STATE_FILE" status)
_LOG_STAGE="$STAGE"
if [[ -z "$STAGE" ]]; then _LOG_REASON="no_stage"; exit 0; fi

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
  complete|cancelled|archived|interrupted) _LOG_REASON="terminal_stage"; exit 0 ;;
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
_LOG_TUID="$TOOL_USE_ID"

TOOL_INPUT_JSON=$(echo "$HOOK_INPUT" | jq -c '.tool_input // null' 2>/dev/null || echo "null")

# Sidechain identity: when this hook fires inside a subagent, Claude
# Code sets is_sidechain=true and adds agent_id / agent_type top-level
# fields. Same shape on Pre and Post.
IS_SIDECHAIN=$(echo "$HOOK_INPUT" | jq -r '.is_sidechain // false' 2>/dev/null || echo "false")
AGENT_ID=$(echo "$HOOK_INPUT" | jq -r '.agent_id // ""' 2>/dev/null || true)
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.agent_type // ""' 2>/dev/null || true)

if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
  # Started event — no tool_response, no is_error yet.
  _alog "post=started tool=$TOOL tuid=$TOOL_USE_ID stage=$STAGE cloud_sid=$CLOUD_SID summary_len=${#SUMMARY}"
  cloud_post_activity "$CLOUD_SID" "$STAGE" "${EPOCH:-0}" "$TOOL" "${SUMMARY:-}" \
    "$TOOL_INPUT_JSON" "null" "false" \
    "$IS_SIDECHAIN" "$AGENT_ID" "$AGENT_TYPE" \
    "started" "$TOOL_USE_ID"
  _LOG_REASON="posted_started"
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

_alog "post=finished tool=$TOOL tuid=$TOOL_USE_ID stage=$STAGE cloud_sid=$CLOUD_SID is_error=$IS_ERROR result_len=${#TOOL_RESULT_JSON}"
cloud_post_activity "$CLOUD_SID" "$STAGE" "${EPOCH:-0}" "$TOOL" "${SUMMARY:-}" \
  "$TOOL_INPUT_JSON" "$TOOL_RESULT_JSON" "$IS_ERROR" \
  "$IS_SIDECHAIN" "$AGENT_ID" "$AGENT_TYPE" \
  "finished" "$TOOL_USE_ID"
_LOG_REASON="posted_finished"

# Clear a permission/idle awaiting state once the agent resumes work.
# notification-hook.sh sets awaiting_user (reason=permission|idle)
# when CC blocks on a permission prompt or goes idle. Clicking
# Allow/Deny does NOT fire UserPromptSubmit and does NOT cause a
# stage transition — the only two existing clear points — so the
# "waiting for permission" banner would otherwise never disappear.
# A finished tool event is definitive proof the agent is working
# again, so clear here. question|picker reasons are intentionally
# left untouched: they have their own clear paths (UserPromptSubmit
# and ask-user-question-hook's PostToolUse:AskUserQuestion).
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
