#!/bin/bash
# Cancel a dev workflow.
#
# Default:  move the run dir to .stagent/.archive/<ts>-<topic>-cancelled/
#           so the audit trail (reports + baseline) is preserved.
# --hard:   rm -rf the run dir (no archive). Use when you really don't want
#           the artifacts.
#
# Usage: cancel-workflow.sh [--hard]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# ── Audit log ────────────────────────────────────────────────────
# Append one TSV row per cancel attempt to ~/.cache/stagent/cancel.log.
# Captures sid, which branch the script took, server status class
# observed, and final exit code. Trap-based so a single line is written
# regardless of which exit path the script takes — including failures.
# Failures inside the trap are swallowed so logging never affects the
# user-visible exit code.
_AUDIT_SID="?"
_AUDIT_BRANCH="parse-args"
_AUDIT_SRV="?"
_AUDIT_LOG="${HOME}/.cache/stagent/cancel.log"
_emit_audit() {
  local rc=$?
  {
    mkdir -p "$(dirname "$_AUDIT_LOG")" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%FT%TZ)" \
      "${_AUDIT_SID:-?}" \
      "${_AUDIT_BRANCH:-?}" \
      "${_AUDIT_SRV:-?}" \
      "$rc" \
      >> "$_AUDIT_LOG" 2>/dev/null
  } || true
  return $rc
}
trap _emit_audit EXIT

HARD=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --hard)       HARD="yes"; shift ;;
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
  # Local resolution failed — but for cloud sessions, the server can be
  # active even when the local shadow has been wiped (claude killed
  # mid-run, cache cleared, plugin re-installed, etc.). Without this
  # fallback the user is stuck: /stagent:start refuses ("server has
  # active workflow"), /stagent:cancel refuses ("no local state"). We
  # check the cwd-cache for a session_id this directory was last tied
  # to and reconcile against the server.
  #
  # Two distinct sub-cases:
  #   (a) server reports `active` → local cancelled mid-flight, server
  #       still owes us a cancel POST. Fire it, then sweep local.
  #   (b) server is non-active (cancelled / archived / unknown) but the
  #       local registry file still exists → leaked from a previous
  #       cancel that completed on the server but didn't fully clean
  #       locally (e.g. webapp-side cancel, cancel script killed
  #       between wipe_scratch and unregister_session). Sweep the
  #       leaked registry so /stagent:start unblocks. Idempotent — if
  #       there's nothing to clean we fall through.
  #
  # Safety:
  #   - Only the cwd-cache is consulted (PPID walk forced off via
  #     _DW_FORCE_CWD_CACHE=1) so the sid is guaranteed to belong to
  #     a claude session that ran in THIS directory. No parent-process
  #     bleedthrough into unrelated workflows.
  #   - Owned cloud sessions are protected by server-side ownership
  #     checks — POSTing cancel from a different identity returns 403.
  #   - Anonymous sessions are URL-as-credential by design; if the cwd
  #     cache still points at one, the user is the URL holder.
  _AUDIT_BRANCH="resolve-failed"
  CLOUD_SID="${DESIRED_SESSION:-$(_DW_FORCE_CWD_CACHE=1 read_cached_session_id 2>/dev/null || true)}"
  _AUDIT_SID="${CLOUD_SID:-?}"
  if [[ -n "$CLOUD_SID" ]]; then
    SRV_CLASS="$(cloud_session_status_class "$CLOUD_SID" 2>/dev/null || echo unknown)"
    _AUDIT_SRV="$SRV_CLASS"

    # (a) server still active — break the deadlock by cancelling there.
    if [[ "$SRV_CLASS" == "active" ]]; then
      _AUDIT_BRANCH="fallback-server-active"
      echo "▶️  No local state for session ${CLOUD_SID}, but the server still has it active." >&2
      echo "   Cancelling on the server to clear the deadlock..." >&2
      if [[ -n "$HARD" ]]; then
        cloud_delete_session "$CLOUD_SID" || true
      else
        cloud_post_cancel "$CLOUD_SID" || {
          echo "⚠️  cloud cancel POST failed — the server may still show this run as active" >&2
          exit 1
        }
      fi
      cloud_wipe_scratch    "$CLOUD_SID" 2>/dev/null || true
      cloud_unregister_session "$CLOUD_SID" 2>/dev/null || true
      if [[ -n "$HARD" ]]; then
        echo "Dev workflow cancelled (hard-deleted from cloud — no local state was found)."
      else
        echo "Dev workflow cancelled (archived on server — no local state was found)."
      fi
      exit 0
    fi

    # (b) server non-active — sweep any leaked local registry file.
    # cloud_registry_file gives the canonical path; existence test
    # avoids running unregister for sessions that have nothing left
    # to clean (which would still succeed but is noisy in the log).
    _CR_FILE="$(cloud_registry_file "$CLOUD_SID" 2>/dev/null || echo "")"
    if [[ -n "$_CR_FILE" ]] && [[ -f "$_CR_FILE" ]]; then
      _AUDIT_BRANCH="fallback-stale-registry"
      echo "▶️  Stale local registry for session ${CLOUD_SID} (server status: ${SRV_CLASS})." >&2
      echo "   Cleaning up local-only state — server already finalised this session." >&2
      cloud_wipe_scratch    "$CLOUD_SID" 2>/dev/null || true
      cloud_unregister_session "$CLOUD_SID" 2>/dev/null || true
      echo "Dev workflow registry cleaned (server status was '${SRV_CLASS}')."
      exit 0
    fi
  fi

  _AUDIT_BRANCH="no-match"
  echo "No matching dev workflow to cancel." >&2
  if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
    echo "   Available workflows:" >&2
    echo "$workflows" >&2
  fi
  exit 1
fi
_AUDIT_SID="${RUN_DIR_NAME:-$_AUDIT_SID}"

# Surface in-flight subagent ids so the slash command can TaskStop them
# before completing the cancel. Without this, orphan subagents keep
# running and may corrupt the project after the workflow has been wiped.
# Covers BOTH workflow-subagent dispatches and inline-fanout
# general-purpose dispatches — every async Agent call is in the ledger.
LEDGER_DIR="${TOPIC_DIR:-}/.async-ledger"
LEDGER_AGENT_IDS=""
if [[ -n "${TOPIC_DIR:-}" ]] && [[ -d "$LEDGER_DIR" ]]; then
  for f in "$LEDGER_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    aid=$(jq -r '.agent_id // ""' "$f" 2>/dev/null || true)
    [[ -n "$aid" ]] && [[ "$aid" != "null" ]] && LEDGER_AGENT_IDS+="${LEDGER_AGENT_IDS:+ }$aid"
  done
fi
if [[ -n "$LEDGER_AGENT_IDS" ]]; then
  echo "STAGENT_STOP_AGENT_IDS: $LEDGER_AGENT_IDS"
fi
# Hard cleanup — local cancel branches below either rm -rf TOPIC_DIR
# or archive it, but the cloud branch only wipes the shadow afterwards
# and we want the ledger gone before any "are we still in flight?"
# check elsewhere races.
[[ -n "${TOPIC_DIR:-}" ]] && rm -rf "$LEDGER_DIR" 2>/dev/null || true

# Cloud mode: server is authoritative. Hit the cancel endpoint, wipe the
# shadow dir, drop the registry entry. No local archive — server holds the
# audit trail.
if is_cloud_session "$RUN_DIR_NAME"; then
  _AUDIT_BRANCH="cloud-main${HARD:+-hard}"
  if [[ -n "$HARD" ]]; then
    cloud_delete_session "$RUN_DIR_NAME" || true
  else
    cloud_post_cancel "$RUN_DIR_NAME" || {
      echo "⚠️  cloud cancel POST failed — the server may still show this run as active" >&2
      _AUDIT_SRV="post-failed"
    }
  fi
  cloud_wipe_scratch "$RUN_DIR_NAME"
  cloud_unregister_session "$RUN_DIR_NAME"
  if [[ -n "$HARD" ]]; then
    echo "Dev workflow '$TOPIC' cancelled (hard-deleted from cloud)."
  else
    echo "Dev workflow '$TOPIC' cancelled (archived on server)."
  fi
  exit 0
fi

if [[ -n "$HARD" ]]; then
  _AUDIT_BRANCH="local-hard"
  # Hard delete — no archive, no audit trail.
  if [[ -d "$TOPIC_DIR" ]]; then
    rm -rf "$TOPIC_DIR"
    echo "Dev workflow '$TOPIC' cancelled (hard-deleted $TOPIC_DIR)."
  else
    rm -f "$STATE_FILE"
    echo "Dev workflow '$TOPIC' cancelled."
  fi
  exit 0
fi

# Default: archive to .stagent/.archive/<ts>-<topic>-cancelled/
_AUDIT_BRANCH="local-archive"
rc=0
archive_run_dir "$TOPIC_DIR" "$TOPIC" "cancelled" || rc=$?
case $rc in
  0) echo "Dev workflow '$TOPIC' cancelled (archived to $ARCHIVE_RESULT_PATH)." ;;
  1)
    # Nothing to archive — dir already missing or empty.
    rm -f "$STATE_FILE"
    echo "Dev workflow '$TOPIC' cancelled."
    ;;
  2)
    echo "⚠️  Archive failed; run '$TOPIC' removed." >&2
    ;;
esac
