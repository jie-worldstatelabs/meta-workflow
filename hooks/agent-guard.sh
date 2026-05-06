#!/bin/bash

# Dev Workflow Agent Guard (PreToolUse hook for Agent tool)
# When a stagent is active and Claude launches an Agent, this hook
# injects guidance about what subagent_type / mode / prompt contents to use,
# driven by workflow.json.

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

# Fallback-derive CLAUDE_PLUGIN_ROOT if Claude Code didn't set it for this
# hook invocation. Real hook subprocesses always get it set; this is a
# safety net so manual invocations don't trip `set -u`.
: "${CLAUDE_PLUGIN_ROOT:=$(dirname "$HOOK_DIR")}"

# Session-keyed: resolve THIS session's workflow dir (from HOOK_INPUT).
# If there's no workflow for this session, nothing to advise.
DESIRED_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
if ! resolve_state; then
  exit 0
fi
resolve_workflow_dir_from_state

if ! config_check; then
  exit 0
fi

STATUS=$(_read_fm_field "$STATE_FILE" status)
EPOCH=$(_read_fm_field "$STATE_FILE" epoch)

# Terminal / paused: nothing to advise
if is_terminal_status "$STATUS" || [[ "$STATUS" == "interrupted" ]]; then
  exit 0
fi

# Must be a known active stage
if ! config_is_stage "$STATUS"; then
  exit 0
fi

# Deny duplicate launch: if a workflow subagent for this stage+epoch
# is already in flight (post-agent.sh wrote a marker, subagent hasn't
# stopped yet), refuse this Agent call. Without this, a stop-hook
# false-positive (which we also fix in stop-hook.sh) or any other path
# that prods the main agent into another launch would otherwise
# produce two concurrent subagents writing to the same project.
#
# Filter: only deny when the launch target IS the stagent workflow
# subagent. Other Agent calls (unrelated skills, user-driven Task
# delegations) must pass through even while our workflow has an
# in-flight subagent.
INCOMING_SUBAGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || true)
INFLIGHT_FILE="${TOPIC_DIR}/.inflight/${STATUS}-${EPOCH}.json"
if [[ "$INCOMING_SUBAGENT_TYPE" == "stagent:workflow-subagent" ]] && [[ -f "$INFLIGHT_FILE" ]]; then
  EXISTING_AGENT=$(jq -r '.agent_id // ""' "$INFLIGHT_FILE" 2>/dev/null || true)
  jq -n \
    --arg reason "[stagent] Refusing to launch a second subagent for stage '$STATUS' (epoch $EPOCH) — one is already in flight (agent_id: ${EXISTING_AGENT:-unknown}). Wait for it to complete; do not stop, the completion notification will arrive. To abort, run /stagent:interrupt or /stagent:cancel." \
    '{
      "decision": "block",
      "reason": $reason
    }'
  exit 0
fi

ARTIFACT="$(config_artifact_path "$STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
EXEC_TYPE="$(config_execution_type "$STATUS")"
TRANSITION_KEYS="$(config_transition_keys "$STATUS")"
INSTRUCTIONS_PATH="$(config_stage_instructions_path "$STATUS")"

if [[ "$EXEC_TYPE" == "inline" ]]; then
  cat <<EOF
[stagent] Active workflow (phase: $STATUS, epoch: $EPOCH).
This stage is INLINE — the main agent runs it directly.
Do NOT launch a subagent for this phase.
If you're about to launch workflow-subagent, you probably need to transition out of $STATUS first via ${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh.

Stage instructions: $INSTRUCTIONS_PATH
Expected output: $ARTIFACT
  ---
  epoch: $EPOCH
  result: <one of: $TRANSITION_KEYS>
  ---
EOF
  exit 0
fi

# Subagent stage. The subagent self-resolves its stage context via
# subagent-bootstrap.sh (see workflow-subagent.md system prompt), so
# the main agent only needs the canonical Agent-tool parameters.
SUBAGENT_TYPE="stagent:workflow-subagent"
MODEL="$(config_model "$STATUS")"

cat <<EOF
[stagent] Phase: $STATUS (epoch $EPOCH)

Agent tool parameters:
  - subagent_type: "$SUBAGENT_TYPE"$( [[ -n "$MODEL" ]] && printf '\n  - model: %s' "$MODEL" )
  - mode: bypassPermissions
  - prompt: "Execute the current workflow stage."
EOF
exit 0
