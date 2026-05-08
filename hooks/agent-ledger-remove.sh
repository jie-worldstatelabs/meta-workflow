#!/bin/bash
#
# agent-ledger-remove.sh — SubagentStop hook (canonical completion tracker).
#
# Pairs with agent-ledger-add.sh. SubagentStop fires when an async
# subagent terminates (success, failure, or cancellation). This hook
# removes the matching ledger entry so stop-hook.sh's "subagents in
# flight" count drops accordingly.
#
# CC fires SubagentStop for ALL subagents in this CC instance,
# including ones unrelated to stagent — so a no-match here is normal
# and silent. Removing nothing on a bystander event is the correct
# behaviour.
#
# Match strategy (any ONE wins):
#   1. transcript_path identity (PRIMARY) — readlink -f the ledger
#      record's transcript_output AND the hook's transcript_path,
#      compare canonical paths. transcript_path is a documented
#      top-level hook input field, so this match survives CC version
#      changes that have historically renamed agent_id sub-fields.
#   2. agent_id identity (FALLBACK) — match against any of the
#      .agent_id / .agentId / .subagent_id / .id field names.
#
# Best-effort: any failure path silently exits 0.

set -uo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$HOOK_DIR")"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib.sh" 2>/dev/null || exit 0

DESIRED_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
if ! resolve_state 2>/dev/null; then
  exit 0
fi
resolve_workflow_dir_from_state >/dev/null 2>&1 || true

LEDGER_DIR="$(dirname "$STATE_FILE")/.async-ledger"
[[ -d "$LEDGER_DIR" ]] || exit 0

HOOK_TRANSCRIPT=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
HOOK_AGENT_ID=$(echo "$HOOK_INPUT" | jq -r '
  .agent_id // .agentId // .subagent_id // .id // ""
' 2>/dev/null)

HOOK_TRANSCRIPT_REAL=""
if [[ -n "$HOOK_TRANSCRIPT" ]] && [[ "$HOOK_TRANSCRIPT" != "null" ]]; then
  HOOK_TRANSCRIPT_REAL=$(readlink -f "$HOOK_TRANSCRIPT" 2>/dev/null || true)
fi

if [[ -z "$HOOK_TRANSCRIPT_REAL" ]] && { [[ -z "$HOOK_AGENT_ID" ]] || [[ "$HOOK_AGENT_ID" == "null" ]]; }; then
  exit 0
fi

# Resolve cloud session id from state.md frontmatter (takeover-safe;
# differs from the local CC session id during cross-machine resume).
CLOUD_SID=$(_read_fm_field "$STATE_FILE" session_id 2>/dev/null)
[[ -z "$CLOUD_SID" ]] && CLOUD_SID="$DESIRED_SESSION"

# Helper: given a confirmed-match ledger file, read its metadata,
# fire the cloud "subagent_stopped" event, then delete the file.
# We capture metadata BEFORE rm so the cloud notification has the
# stage / epoch / agent_type / started fields the webapp needs.
_finalize_match() {
  local f="$1"
  local rec_agent_id rec_agent_type rec_stage rec_epoch rec_started
  rec_agent_id=$(jq -r '.agent_id // ""' "$f" 2>/dev/null)
  rec_agent_type=$(jq -r '.subagent_type // ""' "$f" 2>/dev/null)
  rec_stage=$(jq -r '.stage // ""' "$f" 2>/dev/null)
  rec_epoch=$(jq -r '.epoch // 0' "$f" 2>/dev/null)
  rec_started=$(jq -r '.started // ""' "$f" 2>/dev/null)
  rm -f "$f"
  if is_cloud_session "$RUN_DIR_NAME" 2>/dev/null; then
    cloud_post_subagent_stopped \
      "$CLOUD_SID" "$rec_stage" "$rec_epoch" \
      "$rec_agent_id" "$rec_agent_type" "$rec_started" \
      >/dev/null 2>&1 || true
  fi
  rmdir "$LEDGER_DIR" 2>/dev/null || true
}

# Fast path: ledger files are keyed by agent_id, so if we got an
# agent_id from the hook we can attempt a direct file lookup. Only
# finalize after also confirming transcript_path identity when both
# signals are present (defense against stale entries with reused
# ids). When only one signal is present, that one decides.
if [[ -n "$HOOK_AGENT_ID" ]] && [[ "$HOOK_AGENT_ID" != "null" ]]; then
  CANDIDATE="${LEDGER_DIR}/${HOOK_AGENT_ID}.json"
  if [[ -f "$CANDIDATE" ]]; then
    if [[ -n "$HOOK_TRANSCRIPT_REAL" ]]; then
      REC_OUTPUT=$(jq -r '.transcript_output // ""' "$CANDIDATE" 2>/dev/null)
      REC_REAL=""
      if [[ -n "$REC_OUTPUT" ]] && [[ "$REC_OUTPUT" != "null" ]]; then
        REC_REAL=$(readlink -f "$REC_OUTPUT" 2>/dev/null || true)
      fi
      if [[ -n "$REC_REAL" ]] && [[ "$REC_REAL" != "$HOOK_TRANSCRIPT_REAL" ]]; then
        # ID matches but transcript differs — bystander collision,
        # do nothing. Fall through to slow-path scan in case the real
        # match lives elsewhere.
        :
      else
        _finalize_match "$CANDIDATE"
        exit 0
      fi
    else
      _finalize_match "$CANDIDATE"
      exit 0
    fi
  fi
fi

# Slow path: scan all entries and match by transcript_path identity
# (the agent_id-keyed file may not exist if CC's id field name
# changed and the hook recorded a different shape).
for f in "$LEDGER_DIR"/*.json; do
  [[ -f "$f" ]] || continue

  match=0

  if [[ -n "$HOOK_TRANSCRIPT_REAL" ]]; then
    REC_OUTPUT=$(jq -r '.transcript_output // ""' "$f" 2>/dev/null)
    if [[ -n "$REC_OUTPUT" ]] && [[ "$REC_OUTPUT" != "null" ]]; then
      REC_REAL=$(readlink -f "$REC_OUTPUT" 2>/dev/null || true)
      if [[ -n "$REC_REAL" ]] && [[ "$REC_REAL" == "$HOOK_TRANSCRIPT_REAL" ]]; then
        match=1
      fi
    fi
  fi

  if [[ "$match" -eq 0 ]] && [[ -n "$HOOK_AGENT_ID" ]] && [[ "$HOOK_AGENT_ID" != "null" ]]; then
    REC_ID=$(jq -r '.agent_id // ""' "$f" 2>/dev/null)
    if [[ -n "$REC_ID" ]] && [[ "$REC_ID" == "$HOOK_AGENT_ID" ]]; then
      match=1
    fi
  fi

  if [[ "$match" -eq 1 ]]; then
    _finalize_match "$f"
    exit 0
  fi
done

rmdir "$LEDGER_DIR" 2>/dev/null || true
exit 0
