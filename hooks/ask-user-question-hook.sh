#!/usr/bin/env bash
#
# AskUserQuestion hook — flip `awaiting_user` while the agent is
# blocked on the AskUserQuestion picker.
#
# Why this hook exists
# --------------------
# stop-hook.sh sets awaiting_user=true only when an interruptible
# stage's Stop event fires (the agent ended its turn without producing
# a done artifact). But when the agent invokes the `AskUserQuestion`
# tool — Claude Code's built-in multiple-choice picker — the agent is
# in the middle of a tool call from CC's perspective:
#
#   • The Stop event does NOT fire (the turn isn't done).
#   • UserPromptSubmit does NOT fire when the user picks an answer
#     (the answer comes back as a tool_result, not a prompt).
#
# Result without this hook: the workflow is genuinely waiting on the
# user (the picker is on screen, the agent is paused), but the webapp
# never sees `awaiting_user=true`, so the "waiting for you" banner /
# pill never lights up.
#
# This hook fills that gap with two events on the same script:
#   • PreToolUse:AskUserQuestion  → set awaiting_user=true,
#                                   also piggy-back cloud_reconcile_state
#                                   so any pending <stage>-report.md
#                                   that just landed locally is pushed
#                                   to cloud before the user clicks
#                                   the cloud link from the picker.
#   • PostToolUse:AskUserQuestion → set awaiting_user=false
# (UserPromptSubmit clears the flag too, so a stray "true" can't
# strand the UI even if PostToolUse is missed.)
#
# Silent + best-effort: any failure exits 0 so we never disturb the
# tool call itself.

set -uo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${CLAUDE_PLUGIN_ROOT:=$(dirname "$HOOK_DIR")}"

# shellcheck source=../scripts/lib.sh
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh" 2>/dev/null || exit 0

# Hook event tells us which direction to flip the flag. CC writes this
# as `hook_event_name` in the JSON payload for every hook invocation.
EVENT=$(echo "$HOOK_INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null)

case "$EVENT" in
  PreToolUse)  TARGET=true ;;
  PostToolUse) TARGET=false ;;
  *)           exit 0 ;;
esac

# Defensive: only fire on AskUserQuestion. The hooks.json matcher
# already filters by tool name, but this guard makes the script safe
# to invoke from anywhere (and survives matcher refactors).
TOOL=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
[[ "$TOOL" == "AskUserQuestion" ]] || exit 0

DESIRED_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)

if ! resolve_state 2>/dev/null; then
  exit 0
fi

[[ -f "${STATE_FILE:-}" ]] || exit 0

# Skip churny writes: only POST when the flag would actually change.
CURRENT="$(get_awaiting_user "$STATE_FILE")"
if [[ "$CURRENT" == "$TARGET" ]]; then
  exit 0
fi

set_awaiting_user "$STATE_FILE" "$TARGET"
if is_cloud_session "$RUN_DIR_NAME" 2>/dev/null; then
  cloud_post_awaiting_user "$RUN_DIR_NAME" "$TARGET" >/dev/null 2>&1 || true

  # On PreToolUse only: piggy-back the artifact-reconcile that
  # stop-hook.sh runs at every turn-end (lib.sh: cloud_reconcile_state).
  # AskUserQuestion is an in-flight tool, so Stop never fires while the
  # picker is up — without this, a `<stage>-report.md` written just
  # before the picker would stay local-only until the next genuine turn
  # end, and the user clicking the cloud link from the picker prompt
  # would see no plan. PostToolUse skips this on purpose: by then the
  # picker is gone, the agent's about to do more work, and the next
  # Stop / next AskUserQuestion will catch up.
  if [[ "$EVENT" == "PreToolUse" ]]; then
    cloud_reconcile_state "$RUN_DIR_NAME" >/dev/null 2>&1 || true
  fi
fi

exit 0
