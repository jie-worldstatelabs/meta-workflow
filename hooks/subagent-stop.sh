#!/bin/bash
# SubagentStop — clear inflight marker for the workflow subagent that
# just stopped. Pairs with post-agent.sh which writes them.
#
# CC fires SubagentStop for ANY subagent (including sub-sub-agents the
# workflow-subagent itself launches), so we MUST match precisely and
# refuse to clean up otherwise — wiping inflight on a sub-sub-agent's
# stop would falsely tell stop-hook "no subagent in flight" while the
# real workflow-subagent is still running.
#
# Match strategy (any ONE wins):
#   1. transcript_path identity — primary, robust
#      Resolve the inflight's recorded `output` (a symlink under
#      tasks/<id>.output) AND the hook input's `transcript_path` to
#      canonical paths via readlink -f and compare. transcript_path is
#      a documented top-level hook input field; this matches purely on
#      filesystem identity, no field-name or path-format guessing.
#   2. agent_id identity — fallback
#      Cross-check `.agent_id` / `.agentId` / `.subagent_id` / `.id`
#      against the inflight file's recorded agent_id.
#
# If neither matches we leave inflight alone. Worst case: inflight
# leaks until /stagent:interrupt|cancel|continue or the next stage
# transition. Better than a false wipe that re-opens the race.

# No `set -e` / `set -u`. Defensive — must never exit non-zero on
# unexpected input.

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
source "$(dirname "$HOOK_DIR")/scripts/lib.sh" 2>/dev/null || exit 0

: "${CLAUDE_PLUGIN_ROOT:=$(dirname "$HOOK_DIR")}"

DESIRED_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
if ! resolve_state >/dev/null 2>&1; then
  exit 0
fi
resolve_workflow_dir_from_state >/dev/null 2>&1

INFLIGHT_DIR="${TOPIC_DIR}/.inflight"
[[ -d "$INFLIGHT_DIR" ]] || exit 0

# Hook input fields (any may be absent on a given CC version).
HOOK_TRANSCRIPT=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
HOOK_AGENT_ID=$(echo "$HOOK_INPUT" | jq -r '
  .agent_id // .agentId // .subagent_id // .id // ""
' 2>/dev/null)

# Pre-resolve the hook's transcript path to canonical form.
HOOK_TRANSCRIPT_REAL=""
if [[ -n "$HOOK_TRANSCRIPT" ]] && [[ "$HOOK_TRANSCRIPT" != "null" ]]; then
  HOOK_TRANSCRIPT_REAL=$(readlink -f "$HOOK_TRANSCRIPT" 2>/dev/null || true)
fi

# If we have neither signal we can't safely identify which subagent
# stopped — leave inflight alone.
if [[ -z "$HOOK_TRANSCRIPT_REAL" ]] && { [[ -z "$HOOK_AGENT_ID" ]] || [[ "$HOOK_AGENT_ID" == "null" ]]; }; then
  exit 0
fi

# Walk inflight files looking for an unambiguous match.
for f in "$INFLIGHT_DIR"/*.json; do
  [[ -f "$f" ]] || continue

  match=0

  # Primary: transcript_path identity via realpath of inflight's output.
  if [[ -n "$HOOK_TRANSCRIPT_REAL" ]]; then
    INFLIGHT_OUTPUT=$(jq -r '.output // ""' "$f" 2>/dev/null)
    if [[ -n "$INFLIGHT_OUTPUT" ]] && [[ "$INFLIGHT_OUTPUT" != "null" ]]; then
      INFLIGHT_REAL=$(readlink -f "$INFLIGHT_OUTPUT" 2>/dev/null || true)
      if [[ -n "$INFLIGHT_REAL" ]] && [[ "$INFLIGHT_REAL" == "$HOOK_TRANSCRIPT_REAL" ]]; then
        match=1
      fi
    fi
  fi

  # Fallback: agent_id identity.
  if [[ "$match" -eq 0 ]] && [[ -n "$HOOK_AGENT_ID" ]] && [[ "$HOOK_AGENT_ID" != "null" ]]; then
    AID=$(jq -r '.agent_id // ""' "$f" 2>/dev/null)
    if [[ -n "$AID" ]] && [[ "$AID" == "$HOOK_AGENT_ID" ]]; then
      match=1
    fi
  fi

  if [[ "$match" -eq 1 ]]; then
    rm -f "$f"
    break
  fi
done

# If the dir is now empty, prune it for cleanliness.
rmdir "$INFLIGHT_DIR" 2>/dev/null || true

exit 0
