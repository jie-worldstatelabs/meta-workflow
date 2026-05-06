#!/bin/bash

# Dev Workflow Status Update Script
# Atomic phase transition: validates required inputs, increments epoch,
# updates status, and deletes the new stage's output artifact.
#
# Resolves which workflow to operate on (multiple topics may coexist):
#   --topic <name>           explicit
#   else                     if exactly one active workflow exists, use it
#
# Usage: update-status.sh --status <status> [--topic <topic>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

NEW_STATUS=""
TOPIC_ARG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --status=*) NEW_STATUS="${1#--status=}"; shift ;;
    --status)   NEW_STATUS="$2";             shift 2 ;;
    --topic=*)  TOPIC_ARG="${1#--topic=}";   shift ;;
    --topic)    TOPIC_ARG="$2";              shift 2 ;;
    *)
      echo "Warning: unknown argument: $1" >&2
      shift
      ;;
  esac
done

if [[ -z "$NEW_STATUS" ]]; then
  echo "⚠️  --status is required" >&2
  exit 1
fi

# Route to the right state.md
if [[ -n "$TOPIC_ARG" ]]; then
  DESIRED_TOPIC="$TOPIC_ARG"
fi

if ! resolve_state; then
  echo "⚠️  Could not resolve an active dev workflow" >&2
  if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
    echo "   Available workflows:" >&2
    echo "$workflows" >&2
    echo "   Pass --topic <name> to select one." >&2
  else
    echo "   No workflows found. Run /stagent:start to start one." >&2
  fi
  exit 1
fi

resolve_workflow_dir_from_state

if ! config_check; then
  exit 1
fi

# If the project was pre-git at setup time but has a git repo now (very
# common: greenfield scaffold that the executor initialises a few minutes
# later), backfill baseline + project_fingerprint before proceeding.
# ensure_baseline_and_fingerprint is idempotent and cheap.
ensure_baseline_and_fingerprint "$STATE_FILE" || true

# Validate: the new status must be either an active stage or a terminal stage.
if ! config_is_stage "$NEW_STATUS" && ! is_terminal_status "$NEW_STATUS"; then
  echo "❌ Unknown status: '$NEW_STATUS'" >&2
  echo "   Valid stages: $(config_all_stages | tr '\n' ' ')" >&2
  echo "   Terminal stages: $(config_terminal_stages | tr '\n' ' ')" >&2
  exit 1
fi

# Read current state
CURRENT_EPOCH=$(_read_fm_field "$STATE_FILE" epoch)
if [[ -z "$CURRENT_EPOCH" ]] || ! [[ "$CURRENT_EPOCH" =~ ^[0-9]+$ ]]; then
  CURRENT_EPOCH=0
fi
NEW_EPOCH=$((CURRENT_EPOCH + 1))

# ──────────────────────────────────────────────────────────────
# Max-epoch cap. workflow.json may declare `.max_epoch`; when absent we
# default to 20 (config_max_epoch). Once a transition would take the
# workflow to that epoch or beyond, short-circuit to the `escalated`
# terminal — prevents runaway loops (e.g. executing↔verifying) from
# burning unbounded turns. User-initiated terminal transitions
# (complete / cancelled / escalated themselves) bypass the cap. If the
# workflow does not declare `escalated` as a terminal, we log and fall
# through so the configuration still makes forward progress.
# ──────────────────────────────────────────────────────────────
MAX_EPOCH="$(config_max_epoch)"
if ! is_terminal_status "$NEW_STATUS" && [[ "$NEW_EPOCH" -ge "$MAX_EPOCH" ]]; then
  if config_is_terminal "escalated"; then
    echo "⚠️  [stagent] epoch $NEW_EPOCH reached max-epoch $MAX_EPOCH — escalating (was heading to '$NEW_STATUS')" >&2
    NEW_STATUS="escalated"
  else
    echo "⚠️  [stagent] epoch $NEW_EPOCH reached max-epoch $MAX_EPOCH but 'escalated' is not declared under .terminal_stages — proceeding to '$NEW_STATUS' without auto-escalation" >&2
  fi
fi

# ──────────────────────────────────────────────────────────────
# Validate required inputs for the new stage
# ──────────────────────────────────────────────────────────────
if config_is_stage "$NEW_STATUS"; then
  MISSING_INPUTS=()
  while IFS=$'\t' read -r type key description; do
    [[ -z "$key" ]] && continue
    input_path=
    if [[ "$type" == "run_file" ]]; then
      input_path="$(config_run_file_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    else
      input_path="$(config_artifact_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    fi
    if [[ ! -f "$input_path" ]]; then
      MISSING_INPUTS+=("$input_path ($description)")
    fi
  done < <(config_required_inputs "$NEW_STATUS")

  if [[ ${#MISSING_INPUTS[@]} -gt 0 ]]; then
    echo "❌ Cannot transition to '$NEW_STATUS' for topic '$TOPIC': required inputs missing:" >&2
    for m in "${MISSING_INPUTS[@]}"; do
      echo "   - $m" >&2
    done
    echo "" >&2
    echo "   (required inputs are declared in workflow.json → stages.$NEW_STATUS.inputs.required)" >&2
    exit 1
  fi
fi

# ──────────────────────────────────────────────────────────────
# Validate the outgoing stage's artifact before any state mutation
# or cloud upload. Two guards, applied to both local and cloud
# sessions:
#
#   1. File exists at the canonical path. Subagents that wrote to a
#      non-canonical filename (e.g. missing the '-report' suffix)
#      used to slip past and leave the UI with "no artifact" while
#      the state machine happily advanced.
#   2. Artifact's frontmatter `epoch:` matches state.md's `epoch:`.
#      stop-hook already applies this check before claiming the stage
#      is done, but stop-hook runs only on the main agent's exit
#      attempt — any direct call to update-status.sh (scripts, tests,
#      future callers) would otherwise bypass it. This is the
#      belt-and-suspenders guard that makes "wrong epoch sneaks
#      through to advance the state machine" impossible.
#
# Skipped for terminal transitions: users cancelling or escalating
# should not be blocked on artifact integrity — they want out.
# ──────────────────────────────────────────────────────────────
CURRENT_STATUS=$(_read_fm_field "$STATE_FILE" status)
if config_is_stage "$CURRENT_STATUS" && ! is_terminal_status "$NEW_STATUS"; then
  CURRENT_ARTIFACT="$(config_artifact_path "$CURRENT_STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
  if [[ ! -f "$CURRENT_ARTIFACT" ]]; then
    echo "❌ Cannot transition from '$CURRENT_STATUS' to '$NEW_STATUS': expected artifact missing at canonical path:" >&2
    echo "   $CURRENT_ARTIFACT" >&2
    echo "   The current stage's subagent/main agent should have written this file. Check its output — it may have written to a different filename (e.g. missing the '-report' suffix)." >&2
    exit 1
  fi
  _ART_EPOCH=$(_read_fm_field "$CURRENT_ARTIFACT" epoch)
  if [[ -n "$_ART_EPOCH" && "$_ART_EPOCH" != "$CURRENT_EPOCH" ]]; then
    echo "❌ Cannot transition: artifact epoch mismatch." >&2
    echo "   Artifact:        $CURRENT_ARTIFACT" >&2
    echo "   Artifact epoch:  $_ART_EPOCH" >&2
    echo "   State epoch:     $CURRENT_EPOCH" >&2
    echo "   The artifact was written for a different round (stale or future)." >&2
    echo "   Re-run the stage so its 'epoch:' matches state.md, then retry." >&2
    exit 1
  fi
fi

# ──────────────────────────────────────────────────────────────
# Sync the *outgoing* stage's artifact to the cloud BEFORE touching
# local state. This is the authoritative artifact sync point: the
# postwrite-hook fires opportunistically during writes and may silently
# skip (wrong filename, subagent oddities, network hiccup), but every
# transition must carry an uploaded artifact or the UI drifts from the
# state machine. By enforcing the upload here — and failing the
# transition if either the local file or the upload is missing — we
# turn a previously-silent data loss into a loud, observable failure
# the user can act on.
#
# Non-cloud sessions are exempt. Terminal transitions (cancel/escalate/
# complete) are best-effort: the user wants out, don't block on sync.
# ──────────────────────────────────────────────────────────────
if is_cloud_session "$RUN_DIR_NAME" && config_is_stage "$CURRENT_STATUS"; then
  CURRENT_ARTIFACT="$(config_artifact_path "$CURRENT_STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
  if is_terminal_status "$NEW_STATUS"; then
    # Terminal transition: best-effort upload, never block shutdown.
    [[ -f "$CURRENT_ARTIFACT" ]] && cloud_post_artifact "$RUN_DIR_NAME" "$CURRENT_STATUS" "$CURRENT_ARTIFACT" || true
  else
    if ! cloud_post_artifact "$RUN_DIR_NAME" "$CURRENT_STATUS" "$CURRENT_ARTIFACT"; then
      echo "❌ Cannot transition: failed to sync '$CURRENT_STATUS' artifact to cloud." >&2
      echo "   Local path: $CURRENT_ARTIFACT" >&2
      echo "   Check network / server / auth, then retry the transition." >&2
      exit 1
    fi
  fi
fi

# Update status + epoch (two calls; set_fm_field already does atomic temp+mv)
set_fm_field "$STATE_FILE" status "$NEW_STATUS"
set_fm_field "$STATE_FILE" epoch "$NEW_EPOCH"

# Any stage transition clears the awaiting-user flag — we're no longer
# paused on the previous stage by definition. Covers the case where an
# interruptible stage pauses (awaiting=true), the user then runs
# update-status.sh directly without first typing a reply, and the
# UserPromptSubmit hook therefore never fires.
set_awaiting_user "$STATE_FILE" false

# Any stage transition also clears the bootstrap-edge marker — at
# this point the workflow has demonstrably advanced past the
# bootstrap window, even if the user called update-status.sh
# directly without going through loop-tick.sh first (rare, but
# possible in debug/recovery workflows).
rm -f "$(dirname "$STATE_FILE")/.bootstrap_pending"

# Clear inflight markers for the stage we just left. SubagentStop
# normally already removed them; this is the belt-and-suspenders
# cleanup for any path where a transition happens without a clean
# subagent stop event (manual update-status, inline stages, etc.).
rm -rf "${TOPIC_DIR}/.inflight" 2>/dev/null || true

# Record the git HEAD seen by this workdir at transition time. continue-
# workflow.sh compares current workdir HEAD against this to detect
# cross-clone takeovers where the new workdir is missing commits the
# workflow's subagent already produced.
if _LSH="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)"; then
  [[ -n "$_LSH" ]] && set_fm_field "$STATE_FILE" last_seen_head "$_LSH"
fi

# Invalidate the artifact the new stage will produce
NEW_ARTIFACT=""
if config_is_stage "$NEW_STATUS"; then
  NEW_ARTIFACT="$(config_artifact_path "$NEW_STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
  rm -f "$NEW_ARTIFACT"
fi

# ──────────────────────────────────────────────────────────────
# Cloud mirror — mirror state + artifact wipe to the server.
# ──────────────────────────────────────────────────────────────
if is_cloud_session "$RUN_DIR_NAME"; then
  _active="true"
  if is_terminal_status "$NEW_STATUS"; then
    _active="false"
  fi
  cloud_post_state "$RUN_DIR_NAME" "$NEW_STATUS" "$NEW_EPOCH" "" "$_active" || {
    echo "⚠️  cloud state sync failed; local shadow is ahead of server" >&2
  }
  # Mirror the awaiting-user clear to the server so the webapp banner
  # disappears as soon as the transition lands, not on the next
  # unrelated state push.
  cloud_post_awaiting_user "$RUN_DIR_NAME" false >/dev/null 2>&1 || true
  if config_is_stage "$NEW_STATUS"; then
    cloud_delete_artifact "$RUN_DIR_NAME" "$NEW_STATUS" || true
  fi
  # Refresh the working-tree diff on every transition so the UI stays in
  # step with whatever the executor committed. Cheap (git diff + curl) and
  # best-effort — failures never block the transition.
  cloud_post_diff "$RUN_DIR_NAME" || true
  if is_terminal_status "$NEW_STATUS"; then
    # Terminal artifact: per `skills/stagent/SKILL.md` (200ff) the
    # main agent is supposed to write a human-friendly summary at
    # `next_artifact_path` BEFORE calling update-status.sh. We honour
    # that as the default path and only synthesize a mechanical
    # fallback when the agent skipped the contract.
    #
    # The agent writes `epoch: <TICK.epoch>` per the contract — the
    # epoch it sees in the loop-tick output, which is the OLD epoch.
    # By the time we get here `cloud_post_state` above has already
    # advanced server.epoch to NEW_EPOCH. The webapp's artifact route
    # enforces `artifact_epoch === session.epoch`, so the stale
    # frontmatter would 409 and `2>/dev/null || true` would swallow
    # the failure. Plumbing fix: we own that off-by-one; rewrite the
    # frontmatter epoch+result to canonical values right before
    # upload. set_fm_field is idempotent — synthesized files (which
    # already carry NEW_EPOCH and NEW_STATUS) pay nothing.
    #
    # Best-effort — failures must not block the terminal cleanup
    # below (the state transition itself already succeeded
    # server-side).
    TERMINAL_REPORT="${TOPIC_DIR}/${NEW_STATUS}-report.md"
    if [[ ! -f "$TERMINAL_REPORT" ]]; then
      _started_at=$(_read_fm_field "$STATE_FILE" started_at 2>/dev/null || true)
      _workflow_url="$(cloud_registry_get "$RUN_DIR_NAME" workflow_url 2>/dev/null || echo "")"
      synthesize_terminal_report \
        "$TERMINAL_REPORT" \
        "$RUN_DIR_NAME" \
        "${TOPIC:-}" \
        "$NEW_STATUS" \
        "$CURRENT_STATUS" \
        "$NEW_EPOCH" \
        "${_started_at:-}" \
        "${_workflow_url:-}" \
        || true
    fi
    if [[ -f "$TERMINAL_REPORT" ]]; then
      set_fm_field "$TERMINAL_REPORT" epoch  "$NEW_EPOCH"  2>/dev/null || true
      set_fm_field "$TERMINAL_REPORT" result "$NEW_STATUS" 2>/dev/null || true
    fi
    cloud_post_artifact "$RUN_DIR_NAME" "$NEW_STATUS" "$TERMINAL_REPORT" 2>/dev/null || true

    cloud_post_archive "$RUN_DIR_NAME" || true
    # Terminal status = we're done. Wipe the shadow so nothing stays on
    # this machine; server keeps the audit trail. Same cleanup as cancel.
    # `|| true` both: the terminal transition has already succeeded on
    # the server; a cleanup glitch must not surface as a script exit 1
    # and make the main agent think the transition failed.
    cloud_wipe_scratch "$RUN_DIR_NAME" || true
    cloud_unregister_session "$RUN_DIR_NAME" || true
  fi
fi

echo "[stagent] Topic: $TOPIC | Status: $NEW_STATUS | epoch: $NEW_EPOCH"

if config_is_stage "$NEW_STATUS"; then
  config_show_stage_context "$NEW_STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT"
fi
