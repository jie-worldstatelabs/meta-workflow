#!/bin/bash
# PostToolUse:Agent — write inflight marker after the main agent
# successfully launches a stagent workflow subagent.
#
# Inflight file: ${TOPIC_DIR}/.inflight/<stage>-<epoch>.json
# Lifecycle: created here, removed by SubagentStop / update-status /
# /stagent:interrupt|cancel / /stagent:continue / SessionStart.
#
# stop-hook.sh consults this file to distinguish "subagent in flight"
# from "stage never started", which prevents the spurious double-launch
# race that otherwise hits when the main agent goes idle after firing
# an async Agent tool call.
#
# Defensive: this hook MUST NOT exit non-zero on any unexpected input
# shape — it would otherwise surface as a hook failure on every Agent
# call, even unrelated ones. We swallow all internal errors and exit 0.

# Note: NO `set -e` / `set -u`. We tolerate missing fields and empty
# greps. `pipefail` is also off so grep-no-match doesn't abort.

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
source "$(dirname "$HOOK_DIR")/scripts/lib.sh" 2>/dev/null || exit 0

: "${CLAUDE_PLUGIN_ROOT:=$(dirname "$HOOK_DIR")}"

# Only track stagent workflow subagents, not unrelated ad-hoc Agent calls.
SUBAGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)
if [[ "$SUBAGENT_TYPE" != "stagent:workflow-subagent" ]]; then
  exit 0
fi

DESIRED_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
if ! resolve_state >/dev/null 2>&1; then
  exit 0
fi
resolve_workflow_dir_from_state >/dev/null 2>&1

if ! config_check >/dev/null 2>&1; then
  exit 0
fi

STATUS=$(_read_fm_field "$STATE_FILE" status 2>/dev/null)
EPOCH=$(_read_fm_field "$STATE_FILE" epoch 2>/dev/null)

if [[ -z "$STATUS" ]] || [[ -z "$EPOCH" ]]; then
  exit 0
fi
if is_terminal_status "$STATUS" 2>/dev/null; then
  exit 0
fi
if [[ "$STATUS" == "interrupted" ]]; then
  exit 0
fi
if ! config_is_stage "$STATUS" >/dev/null 2>&1; then
  exit 0
fi

# Extract agent_id and output_file. Try structured paths first
# (toolUseResult.agentId / .outputFile, plus tool_response variants),
# then fall back to grepping the plain text result.
AGENT_ID=$(echo "$HOOK_INPUT" | jq -r '
  .toolUseResult.agentId
  // .tool_response.agentId
  // .tool_response.agent_id
  // empty
' 2>/dev/null)
OUTPUT_FILE=$(echo "$HOOK_INPUT" | jq -r '
  .toolUseResult.outputFile
  // .tool_response.outputFile
  // .tool_response.output_file
  // empty
' 2>/dev/null)

if [[ -z "$AGENT_ID" ]]; then
  RESULT_TEXT=$(echo "$HOOK_INPUT" | jq -r '
    (.tool_response // .tool_result // empty)
    | if type == "string" then .
      elif type == "array" then map(.text? // "") | join("\n")
      elif type == "object" then ((.content // []) | if type == "array" then map(.text? // "") | join("\n") else (. | tostring) end)
      else (. | tostring)
      end
  ' 2>/dev/null)
  AGENT_ID=$(printf '%s' "$RESULT_TEXT" | grep -oE 'agentId:[[:space:]]*[A-Za-z0-9_-]+' 2>/dev/null | head -1 | sed -E 's/^agentId:[[:space:]]*//' 2>/dev/null)
  [[ -z "$OUTPUT_FILE" ]] && OUTPUT_FILE=$(printf '%s' "$RESULT_TEXT" | grep -oE 'output_file:[[:space:]]*[^[:space:]]+' 2>/dev/null | head -1 | sed -E 's/^output_file:[[:space:]]*//' 2>/dev/null)
fi

# Failed / synchronous Agent call may not contain agentId — skip cleanly.
if [[ -z "$AGENT_ID" ]]; then
  exit 0
fi

INFLIGHT_DIR="${TOPIC_DIR}/.inflight"
mkdir -p "$INFLIGHT_DIR" 2>/dev/null

INFLIGHT_FILE="${INFLIGHT_DIR}/${STATUS}-${EPOCH}.json"

jq -n \
  --arg agent_id   "$AGENT_ID" \
  --arg stage      "$STATUS" \
  --arg epoch      "$EPOCH" \
  --arg host       "$(hostname 2>/dev/null || echo unknown)" \
  --arg session_id "$DESIRED_SESSION" \
  --arg output     "${OUTPUT_FILE:-}" \
  --arg started    "$(date -u +%FT%TZ)" \
  '{
    agent_id:   $agent_id,
    stage:      $stage,
    epoch:      ($epoch | tonumber? // $epoch),
    host:       $host,
    session_id: $session_id,
    output:     $output,
    started:    $started
  }' > "${INFLIGHT_FILE}.tmp" 2>/dev/null \
  && mv "${INFLIGHT_FILE}.tmp" "$INFLIGHT_FILE" 2>/dev/null \
  || rm -f "${INFLIGHT_FILE}.tmp" 2>/dev/null

exit 0
