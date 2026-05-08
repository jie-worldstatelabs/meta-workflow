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
# is already in flight (recorded in .async-ledger/, subagent hasn't
# stopped yet), refuse this Agent call. Without this, a stop-hook
# false-positive or any other path that prods the main agent into
# another launch would otherwise produce two concurrent subagents
# writing to the same project.
#
# Filter: only deny when the launch target IS the stagent workflow
# subagent. Inline fan-out stages legitimately emit N parallel
# general-purpose subagents — those must pass through. Other Agent
# calls (unrelated skills, user-driven Task delegations) likewise
# must pass through even while our workflow has an in-flight
# subagent.
INCOMING_SUBAGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || true)
if [[ "$INCOMING_SUBAGENT_TYPE" == "stagent:workflow-subagent" ]]; then
  LEDGER_DIR="${TOPIC_DIR}/.async-ledger"
  if [[ -d "$LEDGER_DIR" ]]; then
    EXISTING_AGENT=""
    for f in "$LEDGER_DIR"/*.json; do
      [[ -f "$f" ]] || continue
      MATCH=$(jq -r --arg s "$STATUS" --arg e "$EPOCH" '
        select(
          (.subagent_type == "stagent:workflow-subagent")
          and (.stage == $s)
          and ((.epoch | tostring) == $e)
        ) | .agent_id // ""
      ' "$f" 2>/dev/null)
      if [[ -n "$MATCH" ]]; then
        EXISTING_AGENT="$MATCH"
        break
      fi
    done
    if [[ -n "$EXISTING_AGENT" ]]; then
      jq -n \
        --arg reason "[stagent] Refusing to launch a second workflow subagent for stage '$STATUS' (epoch $EPOCH) — one is already in flight (agent_id: $EXISTING_AGENT). Wait for it to complete; do not stop, the completion notification will arrive. To abort, run /stagent:interrupt or /stagent:cancel." \
        '{
          "decision": "block",
          "reason": $reason
        }'
      exit 0
    fi
  fi
fi

ARTIFACT="$(config_artifact_path "$STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
EXEC_TYPE="$(config_execution_type "$STATUS")"
TRANSITION_KEYS="$(config_transition_keys "$STATUS")"
INSTRUCTIONS_PATH="$(config_stage_instructions_path "$STATUS")"

if [[ "$EXEC_TYPE" == "inline" ]]; then
  # Inline stages run in the main agent's own turn. Two sub-cases:
  #
  #   a) Main agent is launching `stagent:workflow-subagent` —
  #      that's wrong for an inline stage (workflow-subagent is for
  #      subagent-type stages). Warn explicitly so the agent
  #      doesn't end up doing nothing.
  #
  #   b) Main agent is launching some other subagent_type
  #      (e.g. general-purpose for parallel fan-out, per the stage
  #      protocol). That's intentional — pass through silently so
  #      the main agent can emit N parallel calls in a single
  #      response without per-call hook chatter cluttering its
  #      context and biasing it toward sequential dispatch.
  if [[ "$INCOMING_SUBAGENT_TYPE" == "stagent:workflow-subagent" ]]; then
    cat <<EOF
[stagent] Active workflow (phase: $STATUS, epoch: $EPOCH).
This stage is INLINE — the main agent runs it directly.
Do NOT launch \`stagent:workflow-subagent\` here. If you really meant to advance, transition out of $STATUS first via ${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh.

Stage instructions: $INSTRUCTIONS_PATH
Expected output: $ARTIFACT
  ---
  epoch: $EPOCH
  result: <one of: $TRANSITION_KEYS>
  ---
EOF
  fi
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
