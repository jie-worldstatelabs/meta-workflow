#!/bin/bash
#
# agent-ledger-add.sh — PostToolUse:Agent hook (canonical async dispatch tracker).
#
# When the main agent's `Agent(...)` tool call returns asynchronously
# (`tool_response.isAsync: true`), CC has launched the subagent in
# the background and returned an agentId handle to the parent. This
# hook records the dispatch under <run-dir>/.async-ledger/<agent_id>.json
# with enough metadata that:
#
#   • stop-hook.sh can detect "subagents in flight" and refuse to
#     block the turn-end (the parent must be allowed to truly sleep
#     so CC's native auto-wake — subagent completion → tool_result
#     injection — can revive it).
#   • agent-guard.sh can dedup re-dispatch for the workflow-subagent
#     path (one in-flight workflow-subagent per stage+epoch).
#   • interrupt-workflow.sh / cancel-workflow.sh can collect
#     agent_ids to send STAGENT_STOP_AGENT_IDS for graceful kill.
#   • agent-ledger-remove.sh (SubagentStop) can match completion
#     via transcript_path identity (robust to CC version changes
#     in agent_id field naming) with agent_id fallback.
#
# Records ALL async Agent dispatches, regardless of subagent_type —
# both stagent:workflow-subagent (subagent-type stages) and
# general-purpose / others (inline fan-out stages) are tracked the
# same way. Only the agent-guard dedup path discriminates by type.
#
# Best-effort: any failure path silently exits 0 to avoid
# disrupting unrelated Claude Code activity.

set -uo pipefail

HOOK_INPUT=$(cat)

# Only async dispatches need ledger tracking. Synchronous Agent
# calls finish before PostToolUse returns — no waiting period to
# track.
IS_ASYNC=$(echo "$HOOK_INPUT" | jq -r '.tool_response.isAsync // false' 2>/dev/null)
[[ "$IS_ASYNC" != "true" ]] && exit 0

AGENT_ID=$(echo "$HOOK_INPUT" | jq -r '
  .tool_response.agentId
  // .tool_response.agent_id
  // .toolUseResult.agentId
  // empty
' 2>/dev/null)
[[ -z "$AGENT_ID" ]] && exit 0

OUTPUT_FILE=$(echo "$HOOK_INPUT" | jq -r '
  .tool_response.outputFile
  // .tool_response.output_file
  // .toolUseResult.outputFile
  // empty
' 2>/dev/null)

SUBAGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)
TOOL_USE_ID=$(echo "$HOOK_INPUT" | jq -r '.tool_use_id // ""' 2>/dev/null)
DESIRED_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$HOOK_DIR")"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib.sh" 2>/dev/null || exit 0

if ! resolve_state 2>/dev/null; then
  exit 0
fi
resolve_workflow_dir_from_state >/dev/null 2>&1 || true

STATUS=$(_read_fm_field "$STATE_FILE" status 2>/dev/null)
EPOCH=$(_read_fm_field "$STATE_FILE" epoch 2>/dev/null)

LEDGER_DIR="$(dirname "$STATE_FILE")/.async-ledger"
mkdir -p "$LEDGER_DIR" 2>/dev/null || exit 0

LEDGER_FILE="${LEDGER_DIR}/${AGENT_ID}.json"

jq -n \
  --arg agent_id          "$AGENT_ID" \
  --arg subagent_type     "$SUBAGENT_TYPE" \
  --arg stage             "$STATUS" \
  --arg epoch             "$EPOCH" \
  --arg session_id        "$DESIRED_SESSION" \
  --arg host              "$(hostname 2>/dev/null || echo unknown)" \
  --arg transcript_output "${OUTPUT_FILE:-}" \
  --arg started           "$(date -u +%FT%TZ)" \
  --arg tool_use_id       "$TOOL_USE_ID" \
  '{
    agent_id:          $agent_id,
    subagent_type:     $subagent_type,
    stage:             $stage,
    epoch:             ($epoch | tonumber? // $epoch),
    session_id:        $session_id,
    host:              $host,
    transcript_output: $transcript_output,
    started:           $started,
    tool_use_id:       $tool_use_id
  }' > "${LEDGER_FILE}.tmp" 2>/dev/null \
  && mv "${LEDGER_FILE}.tmp" "$LEDGER_FILE" 2>/dev/null \
  || rm -f "${LEDGER_FILE}.tmp" 2>/dev/null

exit 0
