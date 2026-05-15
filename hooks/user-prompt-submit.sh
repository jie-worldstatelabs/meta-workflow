#!/usr/bin/env bash
#
# UserPromptSubmit hook — clear the `awaiting_user` flag whenever the
# user types something.
#
# stop-hook.sh sets awaiting_user=true when it pauses an interruptible
# stage; the webapp renders a "waiting for you" banner based on that
# flag. The moment the user sends a message, we're no longer waiting —
# the agent's next turn is about to run. Clearing here keeps the banner
# in sync with reality.
#
# This hook is silent: it does no validation, never blocks the prompt,
# and doesn't write anything to stdout. On errors it exits 0 so the
# user's prompt always goes through.

set -eu

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${CLAUDE_PLUGIN_ROOT:=$(dirname "$HOOK_DIR")}"

# shellcheck source=../scripts/lib.sh
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh" 2>/dev/null || exit 0

# Resolve the active session's state file. resolve_state from lib.sh
# does the same topic/session discovery used by update-status.sh.
if ! resolve_state 2>/dev/null; then
  exit 0
fi

# resolve_state sets STATE_FILE + RUN_DIR_NAME on success.
[[ -f "${STATE_FILE:-}" ]] || exit 0

# Only touch if currently awaiting — avoids churny writes + cloud POSTs
# on every single prompt the user sends.
if [[ "$(get_awaiting_user "$STATE_FILE")" != "true" ]]; then
  exit 0
fi

set_awaiting_user   "$STATE_FILE" false
set_awaiting_reason "$STATE_FILE" ""
if is_cloud_session "$RUN_DIR_NAME" 2>/dev/null; then
  cloud_post_awaiting_user "$RUN_DIR_NAME" false >/dev/null 2>&1 || true
fi

exit 0
