#!/bin/bash

# Dev Workflow Interrupt Script
# Pauses the loop at the current phase WITHOUT clearing state.
# Resume with: /stagent:continue
# Cancel entirely with: /stagent:cancel
#
# Usage: interrupt-workflow.sh
# Targets the active workflow for the current session (or the single
# active run if called outside a session context).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

while [[ $# -gt 0 ]]; do
  case $1 in
    --session=*)  DESIRED_SESSION="${1#--session=}"; shift ;;
    --session)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "❌ --session requires a value" >&2
        exit 1
      fi
      DESIRED_SESSION="$2"; shift 2 ;;
    *)            shift ;;
  esac
done

if ! resolve_state; then
  echo "No active dev workflow found." >&2
  if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
    echo "   Available workflows:" >&2
    echo "$workflows" >&2
  fi
  exit 1
fi

STATUS=$(_read_fm_field "$STATE_FILE" status)

if [[ "$STATUS" == "interrupted" ]]; then
  echo "⚠️  Workflow is already interrupted (topic: $TOPIC)." >&2
  echo "   Resume with: /stagent:continue" >&2
  echo "   Cancel with: /stagent:cancel" >&2
  exit 0
fi

if is_terminal_status "$STATUS"; then
  echo "⚠️  Workflow already finished (status: $STATUS)." >&2
  exit 1
fi

# Surface in-flight subagent ids so the slash command can TaskStop them
# before completing the interrupt. Without this, orphan subagents keep
# running, may write post-interrupt reports, and confuse the next
# /stagent:continue (which sees a "fresh" report and auto-advances).
# Covers BOTH workflow-subagent dispatches and inline-fanout
# general-purpose dispatches — every async Agent call is in the ledger.
LEDGER_DIR="${TOPIC_DIR}/.async-ledger"
LEDGER_AGENT_IDS=""
if [[ -d "$LEDGER_DIR" ]]; then
  for f in "$LEDGER_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    aid=$(jq -r '.agent_id // ""' "$f" 2>/dev/null || true)
    [[ -n "$aid" ]] && [[ "$aid" != "null" ]] && LEDGER_AGENT_IDS+="${LEDGER_AGENT_IDS:+ }$aid"
  done
fi
if [[ -n "$LEDGER_AGENT_IDS" ]]; then
  echo "STAGENT_STOP_AGENT_IDS: $LEDGER_AGENT_IDS"
fi
# Hard cleanup — even if the slash command's TaskStop step is skipped,
# the ledger entries must not survive interrupt; otherwise stop-hook
# on the next /stagent:continue would see them and assume something
# is still running. Flush stopped events to cloud first so the webapp
# flips each subagent's badge to done before the entries vanish.
cloud_flush_pending_subagents "$RUN_DIR_NAME" "$LEDGER_DIR" || true
rm -rf "$LEDGER_DIR" 2>/dev/null || true

# Save current status as resume_status, then set interrupted.
set_fm_field "$STATE_FILE" resume_status "$STATUS"
set_fm_field "$STATE_FILE" status interrupted

# Record git HEAD at interrupt time so a cross-clone /continue can detect
# "this workdir is missing the commits the interrupted session produced".
if _LSH="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)"; then
  [[ -n "$_LSH" ]] && set_fm_field "$STATE_FILE" last_seen_head "$_LSH"
fi

if is_cloud_session "$RUN_DIR_NAME"; then
  CUR_EPOCH=$(_read_fm_field "$STATE_FILE" epoch)
  cloud_post_state "$RUN_DIR_NAME" "interrupted" "${CUR_EPOCH:-1}" "$STATUS" "true" || {
    echo "⚠️  cloud interrupt sync failed" >&2
  }
fi

echo "⏸️  Dev workflow interrupted."
echo ""
echo "   Topic: $TOPIC"
echo "   Phase: $STATUS (saved as resume_status)"
echo "   State preserved at: $STATE_FILE"
echo ""
echo "   Resume with: /stagent:continue"
echo "   Cancel entirely with: /stagent:cancel"
