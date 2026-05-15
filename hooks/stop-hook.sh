#!/bin/bash

# Dev Workflow Stop Hook
# Prevents session exit when a workflow is active.
#
# DESIGN: Generic state machine controller driven by workflow.json.
# Reads (status, epoch) from state.md, then for the current stage:
#   1. If the stage's artifact exists with matching epoch + non-empty result
#      → stage is DONE, use the stage's transitions to tell Claude which
#        status to move to next.
#   2. Else → stage is NOT DONE. For uninterruptible stages, block and prompt
#     Claude to execute the stage. For interruptible stages, emit a
#     systemMessage hint but do not block.

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

# Fallback-derive CLAUDE_PLUGIN_ROOT if Claude Code didn't set it for this
# hook invocation (e.g. manual test, sourced in a nested shell). Real hook
# subprocess invocation always has it set, so the `:=` no-op's in that path.
: "${CLAUDE_PLUGIN_ROOT:=$(dirname "$HOOK_DIR")}"

# Session-keyed: every session has its own .stagent/<session_id>/ dir.
# Resolve by THIS session's id (from HOOK_INPUT stdin). If there's no dir
# for this session, this hook fires for a bystander → nothing to do,
# allow exit cleanly.
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

# Cloud convergence: before we decide what to tell the agent, make sure
# the server is caught up with the local shadow. Runs on every stop-hook
# fire, which makes every turn-end an implicit sync checkpoint. Any
# prior silent failure (failed cloud_post_state, failed postwrite-hook)
# gets healed here without the user having to do anything.
#
# Safety:
#  - Uses short-timeout GET/POST so a network hiccup can't stall exits
#  - Idempotent; re-running is cheap
#  - Never blocks — returns 0 even on failure (failures logged to
#    .sync-warnings.log which we surface below)
if is_cloud_session "$RUN_DIR_NAME" && ! is_terminal_status "$STATUS" && [[ "$STATUS" != "interrupted" ]]; then
  cloud_reconcile_state "$RUN_DIR_NAME" || true
  ensure_baseline_and_fingerprint "$STATE_FILE" || true
fi

# Tail the shadow's sync-warnings log; we'll append these to whatever
# systemMessage we emit below so the user actually sees sync issues
# instead of them being silently eaten by stderr redirection.
SYNC_WARNINGS=""
if [[ -f "${TOPIC_DIR}/.sync-warnings.log" ]]; then
  SYNC_WARNINGS="$(tail -3 "${TOPIC_DIR}/.sync-warnings.log" 2>/dev/null)"
fi

# Terminal states (workflow's declared ones + the reserved "cancelled")
if is_terminal_status "$STATUS"; then
  case "$STATUS" in
    interrupted)
      # This shouldn't happen (interrupted isn't in terminal_stages by default)
      # but handle it gracefully — allow exit, keep state for /stagent:continue
      exit 0
      ;;
    *)
      # complete / escalated → done, clean up and allow exit.
      # In cloud mode the whole shadow gets wiped (update-status.sh already
      # did this on transition, but stop-hook runs as a safety net for the
      # case where update-status.sh crashed between POST and local cleanup).
      if is_cloud_session "$RUN_DIR_NAME"; then
        cloud_wipe_scratch "$RUN_DIR_NAME"
        cloud_unregister_session "$RUN_DIR_NAME"
      else
        rm -f "$STATE_FILE"
      fi
      exit 0
      ;;
  esac
fi

# Paused by user — allow exit but KEEP state file for /stagent:continue
# (interrupted is handled here since it's a state machine feature, not a "terminal" per config)
if [[ "$STATUS" == "interrupted" ]]; then
  exit 0
fi

# Corrupted state
if [[ -z "$STATUS" ]] || [[ -z "$EPOCH" ]] || ! [[ "$EPOCH" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Dev workflow: State file corrupted (status='$STATUS' epoch='$EPOCH')" >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# Active stage: must be declared in config
if ! config_is_stage "$STATUS"; then
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# Current stage's artifact
# ──────────────────────────────────────────────────────────────
ARTIFACT="$(config_artifact_path "$STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")"

ARTIFACT_EPOCH=""
ARTIFACT_RESULT=""
if [[ -f "$ARTIFACT" ]]; then
  ARTIFACT_EPOCH=$(_read_fm_field "$ARTIFACT" epoch)
  ARTIFACT_RESULT=$(_read_fm_field "$ARTIFACT" result)
fi

# ──────────────────────────────────────────────────────────────
# Bootstrap edge — setup-workflow.sh just wrote state.md, but
# stagent:stagent has NEVER been invoked yet. We detect this by
# the absence of the `bootstrap_completed_at` field in state.md
# (written exactly once by loop-tick.sh on its first successful run;
# never cleared thereafter, even across stage transitions).
#
# An empty field means the skill driver has not engaged this state.md
# at all. If the agent stops here it's between setup and the first
# Skill("stagent:stagent") invocation — the stage hasn't actually
# started, and the agent's about to wait for user input on a stage
# that's never run.
#
# Emit a different systemMessage that commands the agent to invoke
# stagent:stagent RIGHT NOW, instead of the normal interruptible
# "continue the conversation" hint (which reads as "turn is over,
# wait for user"). Skip the awaiting_user=true side effect because
# we're not genuinely waiting on the user — we're waiting on the
# agent to finish chaining.
#
# Replaces the older `.bootstrap_pending` sentinel-file design
# (negative marker deleted by side effect), which was vulnerable to
# path mismatches between SCRATCH_DIR / TOPIC_DIR / dirname($STATE_FILE)
# and to leaks across state.md corruption-recovery cycles. The new
# field travels with state.md so the lifecycle bit cannot become
# orphaned from the session it describes.
# ──────────────────────────────────────────────────────────────
BOOTSTRAP_COMPLETED_AT=$(get_bootstrap_completed_at "$STATE_FILE")
if [[ -z "$BOOTSTRAP_COMPLETED_AT" ]]; then
  # Block the stop instead of merely emitting `systemMessage`. A
  # systemMessage is informational — claude is free to acknowledge it
  # and end the turn, which is exactly what's been observed in the
  # wild: setup completes, the boot message renders, and claude stops
  # without ever invoking `Skill("stagent:stagent")`. The workflow
  # then sits frozen at its initial stage with the field still empty
  # until the user prompts something else.
  #
  # `decision: block` plus a `reason` body is the same control signal
  # the uninterruptible-stage path below uses. claude cannot end the
  # turn while this signal is in flight; the `reason` text becomes
  # the injected continuation prompt.
  BOOT_REASON="⚙️ Dev workflow: skill driver has not engaged stage \"$STATUS\" (epoch $EPOCH). state.md is missing \`bootstrap_completed_at\` — the field loop-tick.sh writes on its first successful run. Invoke \`Skill(\"stagent:stagent\")\` and run its Step 1 Bash through your Bash tool. Loading the skill or describing the stage in prose does not advance the lifecycle; only running the script does."
  [[ -n "$SYNC_WARNINGS" ]] && BOOT_REASON="${BOOT_REASON}  |  sync warnings: ${SYNC_WARNINGS}"
  BOOT_MSG="🚀 Dev workflow | Phase: $STATUS (epoch $EPOCH) | bootstrap → invoking stage loop"
  jq -n \
    --arg prompt "$BOOT_REASON" \
    --arg msg "$BOOT_MSG" \
    '{
      "decision": "block",
      "reason": $prompt,
      "systemMessage": $msg
    }'
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# Interruptible stages: output info, do NOT block exit
# For interruptible stages, a "transition key" result (e.g. planning:approved)
# triggers a ⚠️ hint. Other values (pending, empty, etc.) are neutral.
# ──────────────────────────────────────────────────────────────
if config_is_interruptible "$STATUS"; then
  INSTR="$(config_stage_instructions_path "$STATUS")"
  NEXT_STATUS=""
  if [[ -n "$ARTIFACT_RESULT" ]] && [[ -f "$ARTIFACT" ]] && [[ "$ARTIFACT_EPOCH" == "$EPOCH" ]]; then
    NEXT_STATUS=$(config_next_status "$STATUS" "$ARTIFACT_RESULT")
  fi
  if [[ -n "$NEXT_STATUS" ]]; then
    SYSTEM_MSG="📋 Dev workflow: $STATUS stage (epoch $EPOCH) — interruptible. ⚠️  $ARTIFACT has result: $ARTIFACT_RESULT; run \"${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status $NEXT_STATUS to proceed. Stage instructions: $INSTR"
[[ -n "$SYNC_WARNINGS" ]] && SYSTEM_MSG="${SYSTEM_MSG}  |  sync warnings: ${SYNC_WARNINGS}"
  else
    SYSTEM_MSG="📋 Dev workflow: $STATUS stage (epoch $EPOCH) — interruptible. Stage instructions: $INSTR. Continue the conversation to proceed, or use /stagent:cancel to abort."
  fi

  # Mark this session as awaiting user input. The flag is read by the
  # webapp to render a "waiting for you" banner + pill. Cleared when
  # the user types anything (UserPromptSubmit hook) or update-status.sh
  # advances the stage.
  if [[ "$(get_awaiting_user "$STATE_FILE")" != "true" ]]; then
    set_awaiting_user   "$STATE_FILE" true
    set_awaiting_reason "$STATE_FILE" question
    if is_cloud_session "$RUN_DIR_NAME"; then
      cloud_post_awaiting_user "$RUN_DIR_NAME" true question >/dev/null 2>&1 || true
    fi
  fi

  jq -n --arg msg "$SYSTEM_MSG" '{"systemMessage": $msg}'
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# Uninterruptible: either transition (stage done) or re-execute (stage not done)
# ──────────────────────────────────────────────────────────────

# Build input descriptors for prompt templating.
# Each input becomes a line: "  - {artifact_path}  (<description>)"
build_inputs_section() {
  local kind="$1"   # required | optional
  local stage="$2"
  local source_fn="config_${kind}_inputs"
  local section=""
  while IFS=$'\t' read -r from_stage description; do
    [[ -z "$from_stage" ]] && continue
    local path
    path="$(config_artifact_path "$from_stage" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    if [[ "$kind" == "optional" ]]; then
      section+="  - $path (if exists, else \"none\") — $description"$'\n'
    else
      section+="  - $path — $description"$'\n'
    fi
  done < <($source_fn "$stage")
  printf '%s' "$section"
}

REQUIRED_SECTION="$(build_inputs_section required "$STATUS")"
OPTIONAL_SECTION="$(build_inputs_section optional "$STATUS")"
TRANSITION_KEYS="$(config_transition_keys "$STATUS")"
EXEC_TYPE="$(config_execution_type "$STATUS")"
INSTRUCTIONS_PATH="$(config_stage_instructions_path "$STATUS")"

# Render the "execute this stage" instruction based on execution type.
# Always point to the stage instructions file — it owns the full per-stage protocol.
if [[ "$EXEC_TYPE" == "subagent" ]]; then
  # Single generic subagent for all stages; per-stage behavior lives in
  # the stage instructions file, which the subagent must read first.
  SUBAGENT_TYPE="stagent:workflow-subagent"
  MODEL="$(config_model "$STATUS")"
  MODEL_LINE=""
  if [[ -n "$MODEL" ]]; then
    MODEL_LINE="  - model: $MODEL"$'\n'
  fi
  STAGE_WORK="Read stage instructions: $INSTRUCTIONS_PATH

Call the Agent tool. When you do, the agent-guard PreToolUse hook will print
a prompt template you MUST copy verbatim into the Agent-tool \`prompt\` argument
(the subagent cannot see hook output — only the prompt string you pass it).

Agent-tool parameters:
  - subagent_type: $SUBAGENT_TYPE
$MODEL_LINE  - mode: bypassPermissions

The prompt you pass to the Agent tool must include (transcribe every path
literally — do NOT write \"see injected paths\"):
  - Stage name: $STATUS
  - Stage instructions file: $INSTRUCTIONS_PATH  ← subagent reads this FIRST
  - Project directory: $PROJECT_ROOT
  - Epoch: $EPOCH
  - Output: $ARTIFACT
  - Required inputs (MUST exist):
$REQUIRED_SECTION  - Optional inputs:
$OPTIONAL_SECTION
Agent MUST write $ARTIFACT with frontmatter:
  ---
  epoch: $EPOCH
  result: <one of: $TRANSITION_KEYS>
  ---"
else
  # inline — the main agent does the work directly, per the stage file
  STAGE_WORK="Read stage instructions: $INSTRUCTIONS_PATH

This is an inline stage (no subagent). Follow the stage file for the exact steps (e.g. verifying runs quick tests; planning runs Q&A with user).

Output: $ARTIFACT
Required inputs (MUST exist):
$REQUIRED_SECTION
Optional inputs:
$OPTIONAL_SECTION
Write $ARTIFACT with frontmatter:
  ---
  epoch: $EPOCH
  result: <one of: $TRANSITION_KEYS>
  ---"
fi

# ──────────────────────────────────────────────────────────────
# Decide: stage done → transition prompt | not done → execute prompt
# ──────────────────────────────────────────────────────────────
if [[ -f "$ARTIFACT" ]] && [[ "$ARTIFACT_EPOCH" == "$EPOCH" ]] && [[ -n "$ARTIFACT_RESULT" ]]; then
  NEXT=$(config_next_status "$STATUS" "$ARTIFACT_RESULT")
  if [[ -z "$NEXT" ]]; then
    CONTINUE_PROMPT="[stagent] BLOCKED EXIT — unknown result in artifact.

Status: $STATUS (epoch $EPOCH)
Artifact: $ARTIFACT
Result value: '$ARTIFACT_RESULT' — not in the transition table (valid keys: $TRANSITION_KEYS).

Inspect $ARTIFACT, then call:
  \"${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status <correct-next>

DO NOT STOP."
  else
    CONTINUE_PROMPT="[stagent] BLOCKED EXIT — stage '$STATUS' DONE (result: $ARTIFACT_RESULT), transition not yet called.

$ARTIFACT is valid for epoch $EPOCH.
You MUST now run:
  \"${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status $NEXT

Then continue the workflow (either do the next stage's work or, if the new status is terminal, announce completion).

DO NOT STOP. The loop is infinite — only /stagent:interrupt or /stagent:cancel stops it."
  fi
else
  # ──────────────────────────────────────────────────────────────
  # In-flight check: any async Agent dispatch (workflow-subagent for
  # subagent-type stages, general-purpose for inline fan-out stages,
  # or any other subagent_type) leaves a record under .async-ledger/.
  # While at least one record exists, the parent is yielding to async
  # work that will auto-wake it on tool_result injection. Block here
  # would force a re-inject that re-reads the stage protocol and
  # re-dispatches every Agent call → duplicate work. Exit cleanly
  # with an informational systemMessage instead.
  #
  # Maintained by agent-ledger-add.sh (PostToolUse Agent + isAsync
  # gate) and agent-ledger-remove.sh (SubagentStop, transcript_path
  # primary match with agent_id fallback). Wiped by update-status.sh
  # on stage transition, continue-workflow.sh on resume,
  # session-start.sh on recovery, interrupt-workflow.sh /
  # cancel-workflow.sh on user halt.
  # ──────────────────────────────────────────────────────────────
  LEDGER_DIR="${TOPIC_DIR}/.async-ledger"
  if [[ -d "$LEDGER_DIR" ]]; then
    # Build a per-subagent breakdown so the user can see what's
    # actually running and why the conversation looks paused. We
    # render: subagent_type · short agent_id · started timestamp.
    # Elapsed-time formatting is intentionally absent — date math
    # in bash is platform-specific (mac/GNU diverge) and the
    # absolute "started 14:22:13Z" tells the user enough.
    DETAIL_LINES=""
    ACTIVE=0
    for f in "$LEDGER_DIR"/*.json; do
      [[ -f "$f" ]] || continue
      ACTIVE=$((ACTIVE + 1))
      ROW=$(jq -r '
        "  • " +
        (.subagent_type // "?") +
        " · " +
        ((.agent_id // "?") | .[0:12]) +
        " · started " +
        (.started // "?")
      ' "$f" 2>/dev/null)
      [[ -n "$ROW" ]] && DETAIL_LINES="${DETAIL_LINES}${DETAIL_LINES:+
}${ROW}"
    done
    if [[ "$ACTIVE" -gt 0 ]]; then
      SYSTEM_MSG="⏳ Dev workflow | $STATUS stage (epoch $EPOCH) | $ACTIVE subagent(s) in flight:
${DETAIL_LINES}
Main agent will resume automatically when each completes (no action needed). Use /stagent:interrupt to pause or /stagent:cancel to abort."
      [[ -n "$SYNC_WARNINGS" ]] && SYSTEM_MSG="${SYSTEM_MSG}

sync warnings: ${SYNC_WARNINGS}"
      jq -n --arg msg "$SYSTEM_MSG" '{"systemMessage": $msg}'
      exit 0
    fi
  fi

  if [[ ! -f "$ARTIFACT" ]]; then
    REASON="$ARTIFACT does not exist"
  elif [[ "$ARTIFACT_EPOCH" != "$EPOCH" ]]; then
    REASON="$ARTIFACT has epoch='$ARTIFACT_EPOCH' (stale; expected $EPOCH)"
  else
    REASON="$ARTIFACT has no result field (incomplete)"
  fi

  CONTINUE_PROMPT="[stagent] BLOCKED EXIT — workflow in progress (phase: $STATUS, epoch: $EPOCH).

Reason: $REASON.

Execute the stage:
$STAGE_WORK

DO NOT STOP. The loop is infinite — only /stagent:interrupt or /stagent:cancel stops it."
fi

SYSTEM_MSG="🔄 Dev workflow | Phase: $STATUS (epoch $EPOCH) | EXIT BLOCKED — /stagent:interrupt to pause, /stagent:cancel to stop"
[[ -n "$SYNC_WARNINGS" ]] && SYSTEM_MSG="${SYSTEM_MSG}  |  sync warnings: ${SYNC_WARNINGS}"

jq -n \
  --arg prompt "$CONTINUE_PROMPT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
