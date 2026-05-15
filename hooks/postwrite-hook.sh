#!/bin/bash
# PostToolUse hook (Write/Edit/MultiEdit) — cloud mode state.md mirror.
#
# When cloud mode is active for the current session, this hook mirrors
# writes to state.md under the shadow dir to the server:
#   * state.md  → POST /api/sessions/<sid>/state
#
# Artifact sync (<stage>-report.md) is intentionally NOT handled here.
# update-status.sh is the authoritative sync point for stage artifacts.
#
# Any other file path is ignored. For local-mode sessions (no cloud
# registry entry) the hook exits immediately so it's free on the hot path.
#
# Session ID is derived from the file path (the first directory component
# under SCRATCH_ROOT), NOT from the hook input's session_id.
#
# DIFF UPLOAD OPT-OUT (STAGENT_DISABLE_DIFF_UPLOAD env var)
# ----------------------------------------------------------
# Set STAGENT_DISABLE_DIFF_UPLOAD=1 to prevent this hook from calling
# cloud_post_diff on project-worktree writes. This stops continuous
# working-tree diff data (which includes ALL modified file contents) from
# being sent to the stagent server on every agent write. Recommended for
# proprietary codebases, codebases containing secrets, or when the UI
# diff panel is not needed.

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

TOOL=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
[[ -z "$FILE_PATH" ]] && exit 0

SCRATCH_ROOT="$(cloud_scratch_dir)"

case "$FILE_PATH" in
  "$SCRATCH_ROOT"/*)
    REL="${FILE_PATH#$SCRATCH_ROOT/}"
    PATH_SID="${REL%%/*}"

    is_cloud_session "$PATH_SID" || exit 0

    REL_FILE="${REL#*/}"

    case "$REL_FILE" in
      state.md)
        ST=$(_read_fm_field "$FILE_PATH" status)
        EP=$(_read_fm_field "$FILE_PATH" epoch)
        RE=$(_read_fm_field "$FILE_PATH" resume_status)
        cloud_post_state "$PATH_SID" "${ST:-}" "${EP:-1}" "${RE:-}" "true" 2>/dev/null || true
        ;;
    esac
    ;;
  *)
    # Project-worktree write. Trigger a diff refresh so the UI reflects
    # mid-stage subagent writes. cloud_post_diff dedups internally.
    #
    # SECURITY: diff upload sends working-tree content to the stagent
    # server. Set STAGENT_DISABLE_DIFF_UPLOAD=1 to opt out.
    if [[ "${STAGENT_DISABLE_DIFF_UPLOAD:-0}" == "1" ]]; then
      exit 0
    fi
    PLUGIN_SID=$(read_cached_session_id 2>/dev/null || true)
    if [[ -n "$PLUGIN_SID" ]] && is_cloud_session "$PLUGIN_SID"; then
      cloud_post_diff "$PLUGIN_SID" >/dev/null 2>&1 || true
    fi
    ;;
esac

exit 0
