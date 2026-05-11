#!/bin/bash
# SessionStart hook — caches two things that Claude Code does NOT hand
# to the main agent's Bash-tool subprocesses, so setup/update-status
# scripts and skill instructions can find them later:
#
#   1. session_id  → the Claude Code session UUID, keyed by cwd hash
#      and by harness PPID. Used as the .stagent/<session_id>/
#      directory name and as the session_id field inside state.md.
#
#   2. plugin_root → the absolute path to this plugin's install
#      directory. $CLAUDE_PLUGIN_ROOT is set here (the hook runs in a
#      hook subprocess) but is NOT present in the main agent's Bash-tool
#      env. Writing it to ~/.config/stagent/plugin-root lets SKILL.md and
#      ad-hoc scripts read it back with a single `cat` without a
#      filesystem discovery pattern.
#
# Layout (XDG-split):
#   ~/.config/stagent/plugin-root            ← one-line absolute path
#   ~/.cache/stagent/session-cache/cwd-<sha1-of-pwd>  ← session_id, primary key
#   ~/.cache/stagent/session-cache/ppid-<PPID>        ← session_id, secondary key

set -euo pipefail

HOOK_INPUT=$(cat)
SID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
[[ -z "$SID" ]] && exit 0

CACHE_DIR="${HOME}/.cache/stagent/session-cache"
mkdir -p "$CACHE_DIR"

CWD_HASH=$(printf '%s' "$(pwd)" | shasum -a 1 | cut -c1-16)
echo "$SID" > "${CACHE_DIR}/cwd-${CWD_HASH}"
echo "$SID" > "${CACHE_DIR}/ppid-${PPID}"

# Plugin root pointer — refreshed on every SessionStart so the file
# always matches the current install path (useful if the plugin moves
# between marketplace version bumps).
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]] && [[ -d "$CLAUDE_PLUGIN_ROOT/scripts" ]]; then
  mkdir -p "${HOME}/.config/stagent"
  echo "$CLAUDE_PLUGIN_ROOT" > "${HOME}/.config/stagent/plugin-root"
fi

# Opportunistic GC: prune session-cache entries older than 7 days
find "$CACHE_DIR" -type f -mtime +7 -delete 2>/dev/null || true

# Clear stale inflight markers for this session. By definition, this
# CC process is *just starting*; any inflight in this session's
# TOPIC_DIR was written by a previous CC process whose subagents have
# died with it. Safe to nuke unconditionally — sibling CC sessions
# have their own TOPIC_DIRs, never this one's.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$(dirname "$HOOK_DIR")/scripts/lib.sh"
if [[ -f "$LIB" ]]; then
  (
    set +e
    # shellcheck disable=SC1090
    source "$LIB"
    DESIRED_SESSION="$SID"
    if resolve_state >/dev/null 2>&1; then
      resolve_workflow_dir_from_state >/dev/null 2>&1
      if [[ -n "${TOPIC_DIR:-}" ]]; then
        # Flush stopped events to cloud first so any pre-existing
        # ledger entries that survived a hard exit get their badges
        # flipped to done before the dir vanishes.
        cloud_flush_pending_subagents "$RUN_DIR_NAME" "${TOPIC_DIR}/.async-ledger" || true
        rm -rf "${TOPIC_DIR}/.async-ledger"
      fi
    fi
  ) || true
fi

exit 0
