#!/bin/bash

# Dev Workflow Continue Script
# Resumes an interrupted workflow by restoring the saved resume_status.
# Only works when status is "interrupted" — use /stagent:start for a fresh start.
#
# Session-keyed model: each run lives under .stagent/<session_id>/.
# If the user resumes from a NEW Claude session (e.g. reopened terminal),
# the interrupted run's dir is renamed to this session's id so the stop hook
# and other session-scoped machinery resolve correctly.
#
# Usage: continue-workflow.sh [--session <id>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

SESSION_ARG=""
FORCE_MISMATCH=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --session=*)             SESSION_ARG="${1#--session=}"; shift ;;
    --session)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "❌ --session requires a value" >&2
        exit 1
      fi
      SESSION_ARG="$2"; shift 2 ;;
    --force-project-mismatch) FORCE_MISMATCH="yes";         shift ;;
    *)                       shift ;;
  esac
done

[[ -n "$SESSION_ARG" ]] && DESIRED_SESSION="$SESSION_ARG"

# Cross-machine takeover: if --session <id> refers to a cloud session
# that has never been seen on this machine, pull it down from the server
# and register both the server session_id and this machine's local
# session_id as aliases pointing at the same scratch dir. After this
# block, resolve_state will find the shadow via either key.
if [[ -n "${DESIRED_SESSION:-}" ]] && ! is_cloud_session "$DESIRED_SESSION"; then
  echo "▶️  Attempting cross-machine takeover of cloud session ${DESIRED_SESSION}..." >&2
  scratch_path="$(cloud_pull_shadow "$DESIRED_SESSION")"
  _pull_rc=$?
  if [[ $_pull_rc -eq 2 ]]; then
    # 404 — session was deleted from the server.
    echo "❌ Session ${DESIRED_SESSION} no longer exists on the server." >&2
    echo "   It was deleted via the web UI or the server API." >&2
    echo "   There is no state to resume. Start a new workflow with:" >&2
    echo "   /stagent:start <task>" >&2
    # Clean up any stale local state for this session.
    cloud_wipe_scratch "$DESIRED_SESSION" 2>/dev/null || true
    cloud_unregister_session "$DESIRED_SESSION" 2>/dev/null || true
    exit 1
  fi
  if [[ $_pull_rc -ne 0 ]]; then
    echo "❌ could not pull session ${DESIRED_SESSION} from server" >&2
    exit 1
  fi
  # Primary alias — matches the server-side session_id and the scratch
  # dir basename, so cloud_post_* helpers POST to the right row. Must
  # be registered here (before resolve_state) so is_cloud_session finds
  # the pulled shadow. Local-alias registration happens later, after
  # the ownership gate confirms this session is actually resumable.
  cloud_register_session "$DESIRED_SESSION" "${STAGENT_SERVER}" "" "$scratch_path"
  echo "   Shadow restored at: $scratch_path" >&2
fi

# Resolve the workflow to resume. Strategy:
#   1. If DESIRED_TOPIC or DESIRED_SESSION was set, use resolve_state (scoped).
#   2. Otherwise, scan all .stagent/*/ for a single interrupted run
#      (cross-session takeover — the common case when the user reopened
#      Claude Code in a fresh session).
if [[ -n "${DESIRED_SESSION:-}" ]]; then
  if ! resolve_state; then
    echo "No dev workflow matching the given --session." >&2
    exit 1
  fi
else
  # Cloud short-circuit: .stagent/ doesn't exist in cloud mode, so
  # resolve_interrupted_state (which walks the filesystem) would always
  # fail. Check if the current session is cloud-registered first and, if
  # so, resolve directly from the shadow dir via resolve_state.
  _cur_sid="$(read_cached_session_id)"
  if [[ -n "$_cur_sid" ]] && is_cloud_session "$_cur_sid"; then
    if ! resolve_state; then
      echo "No dev workflow found for the current cloud session (${_cur_sid})." >&2
      exit 1
    fi
  else
    rc=0
    resolve_interrupted_state || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      if [[ "$rc" -eq 2 ]]; then
        # Multiple matches already printed by resolve_interrupted_state
        exit 1
      fi
      echo "No interrupted dev workflow found." >&2
      if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
        echo "   Available workflows:" >&2
        echo "$workflows" >&2
      else
        echo "   Start a new workflow with: /stagent:start <task>" >&2
      fi
      exit 1
    fi
  fi
fi

STATUS=$(_read_fm_field "$STATE_FILE" status)
RESUME_STATUS=$(_read_fm_field "$STATE_FILE" resume_status)
IS_CLOUD="false"
if is_cloud_session "$RUN_DIR_NAME"; then
  IS_CLOUD="true"
fi

# ──────────────────────────────────────────────────────────────
# Ownership gate — only 'interrupted' state is a safe pickup.
#
# Continuing an actively-running workflow creates two Claude
# sessions driving the same state machine concurrently: duplicate
# activity events, racing epoch updates, duplicate subagent
# dispatches. Refuse unless the owning session has explicitly let
# go via /stagent:interrupt (or via the SessionEnd hook that
# auto-interrupts on graceful exit).
# ──────────────────────────────────────────────────────────────
if [[ "$STATUS" != "interrupted" ]]; then
  if is_terminal_status "$STATUS"; then
    echo "❌ Cannot continue: workflow status is '$STATUS' (terminal — already ended)." >&2
    echo "   Start a fresh run with: /stagent:start <task>" >&2
    exit 1
  fi
  echo "❌ Cannot continue: workflow status is '$STATUS' — another Claude session owns it." >&2
  echo "" >&2
  echo "   Handing off without interrupting first would cause two Claude sessions to" >&2
  echo "   race on the same state machine (duplicate activity, racing epoch updates," >&2
  echo "   duplicate subagent dispatches)." >&2
  echo "" >&2
  echo "   To hand off cleanly:" >&2
  echo "     1. Go to the Claude session that owns this workflow." >&2
  echo "     2. Run /stagent:interrupt (or /exit — the SessionEnd hook will" >&2
  echo "        auto-interrupt on graceful exit)." >&2
  echo "     3. Come back here and retry /stagent:continue." >&2
  exit 1
fi

# ──────────────────────────────────────────────────────────────
# Local-alias registration (cloud mode only, post-ownership-gate)
# ──────────────────────────────────────────────────────────────
# Register this Claude session's own id as an alias for the target
# scratch dir. Without it, downstream callers (loop-tick, hooks,
# update-status) that read_cached_session_id would resolve to the
# current session's id — which has no registry entry — and fall
# through to "no active workflow".
#
# Placed AFTER the ownership gate so aliases are only written for
# sessions that actually passed resume checks. Terminal-status
# sessions exit before reaching this block, keeping the registry
# clean.
if [[ "$IS_CLOUD" == "true" ]]; then
  _LOCAL_SID="$(read_cached_session_id)"
  if [[ -n "$_LOCAL_SID" ]] && [[ "$_LOCAL_SID" != "$RUN_DIR_NAME" ]] && ! is_cloud_session "$_LOCAL_SID"; then
    _tgt_scratch="$(cloud_registry_get "$RUN_DIR_NAME" scratch_dir)"
    [[ -z "$_tgt_scratch" ]] && _tgt_scratch="$(cloud_scratch_dir)/${RUN_DIR_NAME}"
    _tgt_server="$(cloud_registry_get "$RUN_DIR_NAME" server)"
    [[ -z "$_tgt_server" ]] && _tgt_server="${STAGENT_SERVER:-https://stagent.worldstatelabs.com}"
    cloud_register_session "$_LOCAL_SID" "$_tgt_server" "" "$_tgt_scratch"
    echo "   Aliased local session ${_LOCAL_SID} → ${_tgt_scratch}" >&2
  fi
fi

# ──────────────────────────────────────────────────────────────
# Project identity check
# ──────────────────────────────────────────────────────────────
# Before touching state, verify the current CWD is in the same git
# project the workflow was started in (root commit fingerprint).
# Allows different HEADs but catches "wrong repo entirely".
verify_rc=0
verify_project_match "$STATE_FILE" "$(pwd)" || verify_rc=$?
case $verify_rc in
  0)
    CURRENT_DIR="$(pwd)"
    STORED_PR="$(_read_fm_field "$STATE_FILE" project_root)"
    if [[ -n "$CURRENT_DIR" ]] && [[ "$CURRENT_DIR" != "$STORED_PR" ]]; then
      # Same project, different local path (cross-machine clone or the
      # user cd'd from a subdir). Update project_root so cloud_post_diff
      # and any other downstream git ops use the right working copy.
      set_fm_field "$STATE_FILE" project_root "$CURRENT_DIR"
      PROJECT_ROOT="$CURRENT_DIR"
      if [[ "$IS_CLOUD" == "true" ]]; then
        CUR_EPOCH=$(_read_fm_field "$STATE_FILE" epoch)
        CUR_STATUS=$(_read_fm_field "$STATE_FILE" status)
        cloud_post_state "$RUN_DIR_NAME" "$CUR_STATUS" "${CUR_EPOCH:-1}" "" "true" "$CURRENT_DIR" || true
      fi
      echo "   project_root updated: ${STORED_PR:-<unset>} → $CURRENT_DIR" >&2
    fi
    ;;
  1)
    EXPECTED=$(_read_fm_field "$STATE_FILE" project_fingerprint)
    ACTUAL=$(git_project_fingerprint "$(pwd)")
    echo "❌ Project mismatch: current git repo doesn't match the workflow's project." >&2
    echo "   Current root commits:  $ACTUAL" >&2
    echo "   Workflow root commits: $EXPECTED" >&2
    echo "   cd to the right project and retry, or pass --force-project-mismatch to override." >&2
    [[ "$FORCE_MISMATCH" != "yes" ]] && exit 1
    echo "⚠️  --force-project-mismatch set; continuing anyway." >&2
    ;;
  2)
    EXPECTED=$(_read_fm_field "$STATE_FILE" project_fingerprint)
    echo "❌ Current directory has no git repo, but the workflow was started in one." >&2
    echo "   Workflow root commits: $EXPECTED" >&2
    echo "   cd into the workflow's project dir and retry, or pass --force-project-mismatch." >&2
    [[ "$FORCE_MISMATCH" != "yes" ]] && exit 1
    echo "⚠️  --force-project-mismatch set; continuing anyway." >&2
    ;;
esac

# ──────────────────────────────────────────────────────────────
# Workdir health check
# ──────────────────────────────────────────────────────────────
# Project fingerprint above only confirms "same repo". This block
# catches the subtler cross-clone case: the workflow's subagent
# committed work in the ORIGINAL workdir while this one is still
# stuck at an older HEAD. Continuing naively means the new stage
# runs against stale code and re-does (or contradicts) finished
# work.
#
# Three signals:
#   1. HEAD diverged / behind last_seen_head  → block (risk of redo)
#   2. HEAD advanced past last_seen_head      → warn only
#   3. Dirty workdir (uncommitted changes)    → warn only
#
# All blocks honor --force-project-mismatch as an override.
if git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  LSH="$(_read_fm_field "$STATE_FILE" last_seen_head)"
  CUR_HEAD="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo)"

  if [[ -n "$LSH" && -n "$CUR_HEAD" && "$LSH" != "$CUR_HEAD" ]]; then
    if git -C "$PROJECT_ROOT" merge-base --is-ancestor "$CUR_HEAD" "$LSH" 2>/dev/null; then
      # current HEAD is an ancestor of last_seen_head → this workdir is BEHIND.
      echo "❌ Workdir is behind the workflow's last-seen commit." >&2
      echo "   last_seen_head : $LSH" >&2
      echo "   current HEAD   : $CUR_HEAD" >&2
      echo "" >&2
      echo "   The workflow advanced HEAD on another workdir; this one is missing" >&2
      echo "   those commits. Fetch / checkout to sync, or pass" >&2
      echo "   --force-project-mismatch (the resumed stage will run against stale" >&2
      echo "   code and may duplicate or contradict finished work)." >&2
      [[ "$FORCE_MISMATCH" != "yes" ]] && exit 1
      echo "⚠️  --force-project-mismatch set; continuing against stale workdir." >&2
    elif git -C "$PROJECT_ROOT" merge-base --is-ancestor "$LSH" "$CUR_HEAD" 2>/dev/null; then
      # current HEAD is a descendant → workdir advanced. Soft warn only.
      echo "⚠️  Workdir HEAD has advanced since the workflow was last seen." >&2
      echo "     last_seen_head : $LSH" >&2
      echo "     current HEAD   : $CUR_HEAD" >&2
      echo "   Proceeding on the assumption the new commits belong to this workflow." >&2
    else
      # Diverged — neither is ancestor of the other.
      echo "❌ Workdir HEAD diverged from the workflow's last-seen commit." >&2
      echo "   last_seen_head : $LSH" >&2
      echo "   current HEAD   : $CUR_HEAD" >&2
      echo "   Reconcile branches before resuming (merge, rebase, or checkout)," >&2
      echo "   or pass --force-project-mismatch." >&2
      [[ "$FORCE_MISMATCH" != "yes" ]] && exit 1
      echo "⚠️  --force-project-mismatch set; continuing on diverged branch." >&2
    fi
  fi

  # Dirty-workdir warning (both equal-head and all diverged-head branches).
  DIRTY="$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | head -10)"
  if [[ -n "$DIRTY" ]]; then
    echo "⚠️  Workdir has uncommitted changes:" >&2
    echo "$DIRTY" | sed 's/^/     /' >&2
    echo "   These may conflict with the resumed workflow's next stage output." >&2
  fi
fi

# Terminal workflows (including user-cancelled ones) can't be resumed.
if is_terminal_status "$STATUS" 2>/dev/null; then
  case "$STATUS" in
    cancelled)
      echo "⚠️  Workflow '$TOPIC' was cancelled — resume unavailable." >&2
      echo "    Start a new workflow with /stagent:start if you want to retry." >&2
      ;;
    *)
      echo "⚠️  Workflow '$TOPIC' is already $STATUS — nothing to resume." >&2
      ;;
  esac
  exit 1
fi

# Decide the phase we're resuming into:
#   - interrupted → restore resume_status (normal /interrupt + /continue flow)
#   - active stage + local mode → must have been interrupted first
#   - active stage + cloud mode → cross-machine takeover; keep the current
#     status as the display phase, stop-hook will drive the stage from there
DISPLAY_PHASE=""
if [[ "$STATUS" == "interrupted" ]]; then
  # If resume_status is empty (corrupt state.md or a legacy run), fall
  # back to the workflow's own initial_stage. No hardcoded stage names.
  if [[ -z "$RESUME_STATUS" ]]; then
    RESUME_STATUS="$(config_initial_stage 2>/dev/null || true)"
  fi
  if [[ -z "$RESUME_STATUS" ]]; then
    echo "⚠️  Workflow '$TOPIC' has no resume_status and no initial_stage — cannot resume safely." >&2
    echo "   Inspect $STATE_FILE and set resume_status manually, or start over with /stagent:start." >&2
    exit 1
  fi
  DISPLAY_PHASE="$RESUME_STATUS"
elif [[ "$IS_CLOUD" == "true" ]]; then
  DISPLAY_PHASE="$STATUS"
else
  echo "⚠️  Workflow '$TOPIC' is not interrupted (status: $STATUS)." >&2
  echo "   Only interrupted workflows can be continued in local mode." >&2
  exit 1
fi

# ──────────────────────────────────────────────────────────────
# Cross-session takeover (LOCAL MODE ONLY): rename the run dir to this
# session's id so hooks resolve to it from this session onward. In
# cloud mode the shadow dir is keyed by the server session_id and
# resolve_state uses registry aliases, so no rename is needed.
# ──────────────────────────────────────────────────────────────
if [[ "$IS_CLOUD" != "true" ]]; then
  NEW_SESSION="$(read_cached_session_id)"
  OLD_SESSION="$RUN_DIR_NAME"
  if [[ -n "$NEW_SESSION" ]] && [[ "$NEW_SESSION" != "$OLD_SESSION" ]]; then
    NEW_DIR="${PROJECT_ROOT}/.stagent/${NEW_SESSION}"
    if [[ -e "$NEW_DIR" ]]; then
      echo "⚠️  This session already has a workflow dir at $NEW_DIR — refusing to overwrite." >&2
      echo "   Cancel or resolve that run first, then retry continue." >&2
      exit 1
    fi
    mv "$TOPIC_DIR" "$NEW_DIR"
    TOPIC_DIR="$NEW_DIR"
    STATE_FILE="$NEW_DIR/state.md"
    RUN_DIR_NAME="$NEW_SESSION"
    set_fm_field "$STATE_FILE" session_id "$NEW_SESSION"
  fi
fi

# Clear any residual inflight markers before resuming. By the time
# /stagent:continue runs, the CC process that wrote those markers is
# either gone (interrupted-style resume) or on another machine
# (cross-machine takeover). Either way, those subagents are
# unreachable from here — keeping the markers around would only
# trick stop-hook into believing something is still running.
[[ -n "${TOPIC_DIR:-}" ]] && rm -rf "${TOPIC_DIR}/.inflight" 2>/dev/null || true

# Restore active status. On an interrupted-style resume this flips
# back to the saved resume_status; on a cloud cross-machine takeover
# of an already-active stage we leave the status alone (DISPLAY_PHASE
# equals $STATUS).
if [[ "$STATUS" == "interrupted" ]]; then
  set_fm_field "$STATE_FILE" status "$RESUME_STATUS"
  set_fm_field "$STATE_FILE" resume_status ""
fi

# Resuming = starting fresh driving. If the last live session crashed
# while awaiting user input, the flag on disk / server would still be
# true; clear it now so the webapp banner doesn't linger past resume.
# Correct even if the resumed stage happens to be interruptible: the
# first turn post-resume is the agent's, not the user's, so by
# definition we're not awaiting a reply yet.
set_awaiting_user "$STATE_FILE" false

if [[ "$IS_CLOUD" == "true" ]]; then
  CUR_EPOCH=$(_read_fm_field "$STATE_FILE" epoch)
  cloud_post_state "$RUN_DIR_NAME" "$DISPLAY_PHASE" "${CUR_EPOCH:-1}" "" "true" || {
    echo "⚠️  cloud resume sync failed" >&2
  }
  cloud_post_awaiting_user "$RUN_DIR_NAME" false >/dev/null 2>&1 || true
fi

echo "▶️  Dev workflow resumed."
echo ""
echo "   Topic:  $TOPIC"
echo "   Phase:  $DISPLAY_PHASE"
echo "   Session: $RUN_DIR_NAME"
echo "   State dir: $TOPIC_DIR"
echo ""
echo "   The stop hook is now active again."
echo "   To interrupt again: /stagent:interrupt"
echo "   To cancel: /stagent:cancel"
