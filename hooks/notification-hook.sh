#!/usr/bin/env bash
#
# Notification hook — capture CC-framework-initiated pauses.
#
# Why this hook exists
# --------------------
# stop-hook.sh and ask-user-question-hook.sh together cover the cases
# where the AGENT itself decides to pause (typed a question and ended
# its turn, or invoked the AskUserQuestion picker). Neither covers the
# cases where Claude Code's framework pauses the agent without the
# agent asking:
#
#   • Permission prompt — agent tried to call a tool that needs
#     confirmation (e.g. an unwhitelisted Bash command). CC blocks the
#     tool call and waits for the user to click Allow/Deny. From the
#     agent's perspective it's mid-tool-call; Stop never fires.
#   • Idle notification — CC has been waiting on the user's input long
#     enough that it sends a native OS notification. Already covered
#     by stop-hook in most cases (since Stop fires before idle), but
#     it's a useful fallback for sessions where Stop didn't fire (e.g.
#     subagent in-flight when the user walked away).
#
# Both surface as the `Notification` hook event, distinguished by the
# `message` field in CC's payload. We map them to awaiting_reason so
# the webapp banner can show *why* we're paused, not just *that* we
# are. The boolean awaiting_user is set to true on either; clearing
# happens via UserPromptSubmit (existing hook) or update-status.sh.
#
# Silent + best-effort: any failure exits 0 so we never disturb CC.

set -uo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${CLAUDE_PLUGIN_ROOT:=$(dirname "$HOOK_DIR")}"

# shellcheck source=../scripts/lib.sh
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh" 2>/dev/null || exit 0

if ! resolve_state 2>/dev/null; then
  exit 0
fi
[[ -f "${STATE_FILE:-}" ]] || exit 0

# Extract the notification message. CC payload shape per
# https://code.claude.com/docs/en/hooks.md#notification-input :
#   { "session_id": "...", "transcript_path": "...",
#     "hook_event_name": "Notification",
#     "message": "Claude needs your permission to use Bash" }
MESSAGE=$(echo "$HOOK_INPUT" | jq -r '.message // ""' 2>/dev/null || true)

# Map the message to a stable reason tag the webapp can switch on.
# We deliberately don't try to be clever about parsing the tool name
# out of the message — the message text is CC's UX copy and may
# change between CC versions. The tag is the contract.
REASON=""
case "$MESSAGE" in
  *"permission"*|*"Permission"*|*"allow"*|*"Allow"*)
    REASON=permission
    ;;
  *"waiting"*|*"idle"*|*"Idle"*)
    REASON=idle
    ;;
  *)
    # Unknown message shape — still surface the pause, just leave the
    # reason blank rather than guessing. The webapp falls back to the
    # generic "waiting for you" copy in that case.
    REASON=""
    ;;
esac

# Skip churny writes — only post when state actually changes.
CURRENT="$(get_awaiting_user "$STATE_FILE")"
CURRENT_REASON="$(get_awaiting_reason "$STATE_FILE")"
if [[ "$CURRENT" == "true" && "$CURRENT_REASON" == "$REASON" ]]; then
  exit 0
fi

set_awaiting_user    "$STATE_FILE" true
set_awaiting_reason  "$STATE_FILE" "$REASON"
if is_cloud_session "$RUN_DIR_NAME" 2>/dev/null; then
  cloud_post_awaiting_user "$RUN_DIR_NAME" true "$REASON" >/dev/null 2>&1 || true
fi

exit 0
