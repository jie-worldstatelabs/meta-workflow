#!/bin/bash

# Dev Workflow Setup Script
#
# Two modes:
#   local (default)  workflow lives on disk under <project>/.stagent/
#                    — one run per session per worktree.
#   cloud            state and artifacts are mirrored to a remote server
#                    (the workflowUI webapp); the project worktree gets
#                    nothing under .stagent/. A transient shadow at
#                    ~/.cache/stagent/sessions/<session_id>/ holds
#                    the minimum files the skill needs to Read/Write
#                    against. Every write is POSTed to the server.
#
# Usage:
#   setup-workflow.sh --topic <topic>
#                     [--flow <name-or-path-or-url>]
#                     [--mode local|cloud]
#   setup-workflow.sh --validate-only [--flow <name-or-path>]
#
# --flow accepts:
#   (omitted)          default:  ${PLUGIN_ROOT}/skills/stagent/workflow/
#   cloud://author/name cloud:   named template on $STAGENT_SERVER
#   /abs/path          local:    absolute local path
#   ./rel/path         local:    relative local path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TOPIC=""
WORKFLOW_NAME=""
VALIDATE_ONLY=""
FORCE=""
# Default mode is cloud — authoritative state lives on the workflowUI
# server, with a local shadow for Claude's Read/Write tools. Users who
# want a fully-offline, local-only run can either:
#   • pass `--mode=local` on the command line, or
#   • export STAGENT_DEFAULT_MODE=local in their shell env
MODE="${STAGENT_DEFAULT_MODE:-cloud}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --topic=*)      TOPIC="${1#--topic=}";                 shift ;;
    --topic)        TOPIC="$2";                            shift 2 ;;
    --flow=*)   WORKFLOW_NAME="${1#--flow=}";      shift ;;
    --flow)     WORKFLOW_NAME="$2";                    shift 2 ;;
    --mode=*)       MODE="${1#--mode=}";                   shift ;;
    --mode)         MODE="$2";                             shift 2 ;;
    --validate-only) VALIDATE_ONLY="yes";                  shift ;;
    --force)        FORCE="yes";                           shift ;;
    *)              shift ;;
  esac
done

# --topic is required for real setup but not for --validate-only (no state.md
# gets written in that mode).
if [[ -z "$VALIDATE_ONLY" ]] && [[ -z "$TOPIC" ]]; then
  echo "❌ Error: --topic is required" >&2
  echo "Usage: setup-workflow.sh --topic <topic> [--flow <name-or-path-or-url>] [--mode local|cloud]" >&2
  echo "       setup-workflow.sh --validate-only [--flow <name-or-path>]" >&2
  exit 1
fi

if [[ "$MODE" != "local" ]] && [[ "$MODE" != "cloud" ]]; then
  echo "❌ Error: --mode must be 'local' or 'cloud'" >&2
  exit 1
fi

# --validate-only is a pure local filesystem operation — it reads
# workflow.json + stage .md files and exits. Nothing about the mode
# affects it, so force local regardless of default / env / explicit
# --mode (otherwise with the new cloud default, a bare
# --validate-only would hit the cloud branch that's inapplicable).
if [[ -n "$VALIDATE_ONLY" ]]; then
  MODE="local"
fi

# ──────────────────────────────────────────────────────────────
# Resolve workflow dir for LOCAL mode validation pathway.
# In cloud mode we defer resolution until after --topic / session_id
# checks, since the source may be a URL that we need to download first.
# ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "local" ]]; then
  if [[ -z "$WORKFLOW_NAME" ]]; then
    WORKFLOW_DIR="$DEFAULT_WORKFLOW_DIR"
  elif [[ "$WORKFLOW_NAME" == /* ]]; then
    WORKFLOW_DIR="$WORKFLOW_NAME"
  elif [[ "$WORKFLOW_NAME" == */* ]]; then
    WORKFLOW_DIR="$(cd "$WORKFLOW_NAME" 2>/dev/null && pwd || echo "$WORKFLOW_NAME")"
  else
    echo "❌ Invalid --flow value: '${WORKFLOW_NAME}'" >&2
    echo "   In local mode use an absolute or relative path (e.g. /path/to/workflow or ./my-workflow)." >&2
    exit 1
  fi
  CONFIG_FILE="${WORKFLOW_DIR}/workflow.json"

  if ! config_check; then
    exit 1
  fi

  if ! config_validate; then
    echo "⚠️  Workflow config has errors — fix them before starting a run." >&2
    echo "   Config: $CONFIG_FILE" >&2
    exit 1
  fi

  if [[ -n "$VALIDATE_ONLY" ]]; then
    _stages=$(config_all_stages | tr '\n' ' ' | sed 's/ $//')
    _stage_count=$(config_all_stages | wc -l | tr -d '[:space:]')
    _terminal_count=$(config_terminal_stages | wc -l | tr -d '[:space:]')
    _terminals=$(config_terminal_stages | tr '\n' ' ' | sed 's/ $//')
    _initial=$(config_initial_stage)
    echo "✓ Workflow validated: $_stage_count stages, $_terminal_count terminal"
    echo "   dir:      $WORKFLOW_DIR"
    echo "   initial:  $_initial"
    echo "   stages:   $_stages"
    echo "   terminal: $_terminals"
    exit 0
  fi

  if [[ -n "$WORKFLOW_NAME" ]]; then
    echo "✓ Custom workflow validated: $WORKFLOW_DIR"
  fi
fi

PROJECT_ROOT="$(pwd)"

SESSION_ID="$(read_cached_session_id)"
if [[ -z "$SESSION_ID" ]]; then
  echo "❌ Error: session_id is unknown." >&2
  echo "   The SessionStart hook (hooks/session-start.sh) did not populate" >&2
  echo "   the cache. Ensure the stagent plugin is properly installed" >&2
  echo "   and restart your Claude Code session." >&2
  exit 1
fi

# ══════════════════════════════════════════════════════════════
# Phase 0: Detect any active workflow for this session (local or cloud).
# One unified check before mode-specific branches so the user always
# gets the same clear message regardless of mode.
#
# Check order:
#   1. Cloud shadow  (~/.cache/stagent/sessions/<sid>/state.md)
#   2. Local run dir (<project>/.stagent/<sid>/state.md)
#   3. Cloud registry (~/.cache/stagent/cloud-registry/<sid>.json, shadow lost)
#   4. Cloud server GET (authoritative cross-machine check; skipped if offline)
#
# On active found → exit 2 so SKILL.md's Step 1 can ask the user.
# With --force   → skip the check entirely (SKILL.md re-runs with --force
#                  after the user confirms).
# ══════════════════════════════════════════════════════════════
if [[ -z "$FORCE" ]]; then
  _active_topic="" _active_status="" _active_mode="" _active_loc=""

  # 1. Cloud shadow
  _cs="${HOME}/.cache/stagent/sessions/${SESSION_ID}/state.md"
  if [[ -f "$_cs" ]]; then
    _s="$(_read_fm_field "$_cs" status)"
    case "$_s" in complete|escalated|cancelled|"") ;;
      *)
        _active_topic="$(_read_fm_field "$_cs" topic)"
        _active_status="$_s"
        _active_mode="cloud"
        _active_loc="$_cs"
        ;;
    esac
  fi

  # 2. Local run dir (only if cloud shadow didn't already fire)
  _ld="${PROJECT_ROOT}/.stagent/${SESSION_ID}/state.md"
  if [[ -z "$_active_status" ]] && [[ -f "$_ld" ]]; then
    _s="$(_read_fm_field "$_ld" status)"
    case "$_s" in complete|escalated|cancelled|"") ;;
      *)
        _active_topic="$(_read_fm_field "$_ld" topic)"
        _active_status="$_s"
        _active_mode="local"
        _active_loc="$_ld"
        ;;
    esac
  fi

  # 3. Cloud registry without shadow (orphaned registration)
  _cr="${HOME}/.cache/stagent/cloud-registry/${SESSION_ID}.json"
  if [[ -z "$_active_status" ]] && [[ -f "$_cr" ]]; then
    _active_mode="cloud"
    _active_status="unknown (registry exists, shadow missing)"
    _active_topic="$(jq -r '.topic // ""' "$_cr" 2>/dev/null)"
    _active_loc="$_cr"
  fi

  # 4. Cloud server GET — authoritative cross-machine check.
  #    Only attempted when STAGENT_SERVER is set and we haven't
  #    already found an active run locally. On network failure we fall
  #    through (offline-safe) and note the caveat in the output.
  _server_unreachable=""
  if [[ -z "$_active_status" ]] && [[ -n "${STAGENT_SERVER:-}" ]]; then
    _srv_snap="$(curl -sS -fL --max-time 4 \
        -H "$(_cloud_auth_header)" \
        "${STAGENT_SERVER}/api/sessions/${SESSION_ID}" 2>/dev/null)" || true
    if [[ -n "$_srv_snap" ]] && printf '%s' "$_srv_snap" | jq empty 2>/dev/null; then
      _srv_status="$(printf '%s' "$_srv_snap" | jq -r '.session.status // ""')"
      _srv_active="$(printf '%s' "$_srv_snap" | jq -r '.session.active // "false"')"
      case "$_srv_status" in complete|escalated|cancelled|"") ;;
        *)
          if [[ "$_srv_active" == "true" ]]; then
            _active_topic="$(printf '%s' "$_srv_snap" | jq -r '.session.topic // ""')"
            _active_status="$_srv_status"
            _active_mode="cloud (server)"
            _active_loc="${STAGENT_SERVER}/s/${SESSION_ID}"
          fi
          ;;
      esac
    elif [[ -n "${STAGENT_SERVER:-}" ]]; then
      _server_unreachable="   (server unreachable — relying on local state only)"
    fi
  fi

  if [[ -n "$_active_status" ]]; then
    echo "⚠️  This session already has an active workflow." >&2
    echo "" >&2
    echo "   Session : ${SESSION_ID}" >&2
    echo "   Topic   : ${_active_topic:-?}" >&2
    echo "   Status  : ${_active_status}" >&2
    echo "   Mode    : ${_active_mode}" >&2
    echo "   Location: ${_active_loc}" >&2
    [[ -n "$_server_unreachable" ]] && echo "$_server_unreachable" >&2
    echo "" >&2
    echo "   /stagent:interrupt to pause, /stagent:continue to resume," >&2
    echo "   /stagent:cancel to stop the existing workflow first." >&2
    exit 2
  fi

  unset _active_topic _active_status _active_mode _active_loc
  unset _cs _ld _cr _s _srv_snap _srv_status _srv_active _server_unreachable
fi

# ══════════════════════════════════════════════════════════════
# CLOUD MODE
# ══════════════════════════════════════════════════════════════
if [[ "$MODE" == "cloud" ]]; then
  cloud_require_env || exit 1

  WORKTREE_ROOT="$(git -C "${PROJECT_ROOT}" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_ROOT")"

  SCRATCH_DIR="${HOME}/.cache/stagent/sessions/${SESSION_ID}"
  WORKFLOW_CACHE="${SCRATCH_DIR}/.workflow-cache"

  # --force: mirror what /stagent:cancel does for cloud sessions so
  # the server side is truly reset before we POST a new setup. Wiping
  # only the local shadow (as the old behaviour did) is not enough — the
  # server still holds an active session row, and the next setup POST
  # gets HTTP 409. All three helpers are idempotent and tolerate the
  # "nothing to cancel" case (e.g. registry already gone), so we can
  # call them unconditionally whenever --force is set.
  if [[ -n "$FORCE" ]]; then
    # 1. Tell the server to cancel the existing session (no-op if none).
    cloud_post_cancel "$SESSION_ID" || true
    # 2. Drop the local cloud-registry pointer so subsequent is_cloud_session
    #    checks don't see a stale registration.
    cloud_unregister_session "$SESSION_ID" || true
    # 3. Wipe the local shadow directory, if any.
    if [[ -d "$SCRATCH_DIR" ]]; then
      rm -rf "$SCRATCH_DIR"
    fi
  fi

  mkdir -p "$WORKFLOW_CACHE"

  # ── Resolve workflow source into $WORKFLOW_CACHE ──
  WORKFLOW_URL=""
  case "$WORKFLOW_NAME" in
    "")
      # Cloud mode + no --flow flag → use hub demo workflow
      _cloud_name="demo"
      WORKFLOW_URL="cloud://demo"
      cloud_fetch_workflow_from_name "$_cloud_name" "$WORKFLOW_CACHE" || {
        rm -rf "$SCRATCH_DIR"
        exit 1
      }
      ;;
    cloud://*)
      # cloud://author/name — cloud named template
      _cloud_name="${WORKFLOW_NAME#cloud://}"
      WORKFLOW_URL="${WORKFLOW_NAME}"
      cloud_fetch_workflow_from_name "$_cloud_name" "$WORKFLOW_CACHE" || {
        rm -rf "$SCRATCH_DIR"
        exit 1
      }
      ;;
    *)
      echo "❌ Invalid --flow value: '${WORKFLOW_NAME}'" >&2
      echo "   In cloud mode use cloud://author/name (e.g. cloud://demo)." >&2
      rm -rf "$SCRATCH_DIR"
      exit 1
      ;;
  esac

  WORKFLOW_DIR="$WORKFLOW_CACHE"
  CONFIG_FILE="${WORKFLOW_DIR}/workflow.json"
  if ! config_check; then
    rm -rf "$SCRATCH_DIR"
    exit 1
  fi
  if ! config_validate; then
    echo "❌ fetched workflow config failed validation" >&2
    rm -rf "$SCRATCH_DIR"
    exit 1
  fi

  INITIAL_STAGE="$(config_initial_stage)"

  # Compute the project fingerprint (set of git root commit SHAs) so
  # cross-machine continue can verify the resume target is the same repo.
  PROJECT_FINGERPRINT="$(git_project_fingerprint "$PROJECT_ROOT")"

  # Ensure a valid git HEAD before running run_file init commands.
  # Must happen before the setup POST so run_files values are captured
  # and included in the server payload for cross-machine reconstruction.
  ensure_git_baseline "$PROJECT_ROOT" "$TOPIC"

  # Capture worktree-snapshot tree at workflow start time so cloud_post_diff
  # can render "changes since workflow start" — excluding pre-existing dirty
  # state (e.g. untracked tool output in the user's repo from before /start).
  # Skip for workflows that opt out of worktree diffs (e.g. create-workflow,
  # which writes to ~/.config/stagent/ not the project).
  if [[ "$(config_modifies_worktree)" == "true" ]]; then
    _capture_baseline_tree "$SCRATCH_DIR" "$PROJECT_ROOT"
  fi

  # Generate run_files declared in workflow.json into the shadow dir.
  generate_run_files "$SCRATCH_DIR" "$PROJECT_ROOT" || { rm -rf "$SCRATCH_DIR"; exit 1; }

  # Build run_files payload: { name: content } for each generated file.
  run_files_json="{}"
  while IFS= read -r _rf_name; do
    [[ -z "$_rf_name" ]] && continue
    _rf_content="$(cat "${SCRATCH_DIR}/${_rf_name}" 2>/dev/null || true)"
    run_files_json="$(jq -n --argjson base "$run_files_json" --arg k "$_rf_name" --arg v "$_rf_content" \
                      '$base + {($k): $v}')"
  done < <(config_run_file_names)

  # ── Build setup payload + POST to server ──
  files_json="{}"
  for f in "$WORKFLOW_CACHE"/*.md; do
    [[ -f "$f" ]] || continue
    _name="$(basename "$f")"
    _content="$(cat "$f")"
    files_json="$(jq -n --argjson base "$files_json" --arg k "$_name" --arg v "$_content" \
                  '$base + {($k): $v}')"
  done
  wfval="$(cat "${WORKFLOW_CACHE}/workflow.json")"
  payload="$(jq -n \
      --arg topic "$TOPIC" \
      --argjson workflow "$wfval" \
      --argjson files "$files_json" \
      --argjson run_files "$run_files_json" \
      --arg url "$WORKFLOW_URL" \
      --arg proot "$PROJECT_ROOT" \
      --arg fpr "$PROJECT_FINGERPRINT" \
      --arg wtree "$WORKTREE_ROOT" \
      '{
        topic: $topic,
        workflow: $workflow,
        workflow_files: $files,
        run_files: (if ($run_files | length) == 0 then null else $run_files end),
        workflow_url: (if $url == "" then null else $url end),
        project_root: $proot,
        project_fingerprint: (if $fpr == "" then null else $fpr end),
        worktree: $wtree
      }')"

  tmp_body="$(mktemp -t dw-setup-XXXXXX)"
  trap 'rm -f "$tmp_body"' EXIT
  http_code=$(curl -sS -o "$tmp_body" -w "%{http_code}" \
      -X POST "${STAGENT_SERVER}/api/sessions/${SESSION_ID}/setup" \
      -H "$(_cloud_auth_header)" \
      -H "Content-Type: application/json" \
      --data "$payload" || echo "000")

  if [[ "$http_code" == "409" ]]; then
    remote_status=$(jq -r '.status // "?"' "$tmp_body" 2>/dev/null || echo "?")
    echo "⚠️  Server refused setup — an active workflow already exists for this session." >&2
    echo "    Remote status: ${remote_status}" >&2
    echo "    Use /stagent:cancel to stop the existing run first." >&2
    rm -rf "$SCRATCH_DIR"
    exit 2
  fi
  if [[ "$http_code" != "200" ]]; then
    echo "❌ setup POST failed with HTTP ${http_code}:" >&2
    cat "$tmp_body" >&2
    echo "" >&2
    rm -rf "$SCRATCH_DIR"
    exit 1
  fi

  # ── Write local shadow state.md ──
  cat > "${SCRATCH_DIR}/state.md" <<EOF
---
active: true
status: $INITIAL_STAGE
epoch: 1
resume_status:
topic: "$TOPIC"
session_id: $SESSION_ID
worktree: "$WORKTREE_ROOT"
workflow_dir: "$WORKFLOW_CACHE"
project_root: "$PROJECT_ROOT"
project_fingerprint: ${PROJECT_FINGERPRINT:-}
mode: cloud
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

  # Bootstrap-edge lifecycle is now derived from state.md's
  # `bootstrap_completed_at` field (set by loop-tick.sh on first
  # successful run). Setup writes state.md without the field; that
  # absence IS the "skill not yet engaged" signal stop-hook reads.
  # No sentinel file to write here — see mark_bootstrap_completed().

  cloud_register_session "$SESSION_ID" "$STAGENT_SERVER" "$WORKFLOW_URL"

  # Seed the server with an initial (empty) diff so the session page's
  # "Working-tree diff" panel has content to anchor on.
  cloud_post_diff "$SESSION_ID" || true

  # Force config_show_stage_context to print shadow paths, not ${project}/.stagent/.
  DW_RUN_BASE="${HOME}/.cache/stagent/sessions"
  export DW_RUN_BASE

  INTERRUPTIBLE_HINT=""
  if config_is_interruptible "$INITIAL_STAGE"; then
    INTERRUPTIBLE_HINT=" — interruptible"
  fi

  echo "☁️  Dev workflow activated (cloud)."
  echo ""
  echo "   Topic: $TOPIC"
  echo "   Session: $SESSION_ID"
  echo "   Worktree: $WORKTREE_ROOT"
  echo "   Status: $INITIAL_STAGE (epoch 1)$INTERRUPTIBLE_HINT"
  if [[ -n "$WORKFLOW_URL" ]]; then
    echo "   Workflow source: $WORKFLOW_URL"
  else
    echo "   Workflow source: ${WORKFLOW_NAME:-default}"
  fi

  if config_is_stage "$INITIAL_STAGE"; then
    config_show_stage_context "$INITIAL_STAGE" "$SESSION_ID" "$PROJECT_ROOT"
  fi

  echo ""
  echo "   Shadow dir: $SCRATCH_DIR"
  echo "   Server:     $STAGENT_SERVER"
  echo "   UI:         ${STAGENT_SERVER}/s/${SESSION_ID}"
  echo "   To pause:  /stagent:interrupt"
  echo "   To cancel: /stagent:cancel"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📍 RELAY THIS TO THE USER VERBATIM BEFORE CONTINUING:"
  echo ""
  echo "   Live session URL:"
  echo "   ${STAGENT_SERVER}/s/${SESSION_ID}"
  echo ""
  echo "   (The user needs this link to watch the workflow in a browser."
  echo "    Do not summarise it away — paste it as-is in your next message.)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Anonymous-cloud nudge: if the user has no bearer token stored at
  # ~/.config/stagent/auth.json, they're running as an anonymous capability
  # URL (whoever knows the session_id can read/write it). Surface the
  # benefits of logging in once, right after activation, so they don't
  # miss the browser dashboard / cross-device resume / private sessions
  # features. Non-blocking, informational only.
  if ! cloud_is_logged_in; then
    echo ""
    echo "💡 Tip — this session is running anonymously (no account attached)."
    echo "   Sign in to unlock:"
    echo "     • Your home dashboard — browse, search, and resume all your past sessions"
    echo "     • Cross-machine continue without copy-pasting session IDs"
    echo "     • Private sessions (strangers who guess the URL can't read your run)"
    echo "     • Your own rate-limit quota instead of shared anonymous"
    echo ""
    echo "   One command:"
    echo "     /stagent:login"
  fi

  exit 0
fi

# ══════════════════════════════════════════════════════════════
# LOCAL MODE (original behavior)
# ══════════════════════════════════════════════════════════════

SESSION_RUN_DIR="${PROJECT_ROOT}/.stagent/${SESSION_ID}"

# ──────────────────────────────────────────────────────────────
# Phase 1: Ensure git repo with a HEAD commit (baseline)
# ──────────────────────────────────────────────────────────────
ensure_git_baseline "${PROJECT_ROOT}" "$TOPIC"
AUTO_GIT_MSG="$_ENSURE_GIT_MSG"

WORKTREE_ROOT="$(git -C "${PROJECT_ROOT}" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_ROOT")"

# ──────────────────────────────────────────────────────────────
# Phase 2: Archive this session's prior run (if any) before starting fresh.
# ──────────────────────────────────────────────────────────────
ARCHIVE_MSG=""
rc=0
archive_run_dir "$SESSION_RUN_DIR" "" "" || rc=$?
case $rc in
  0) ARCHIVE_MSG="   📦 Archived previous run: $ARCHIVE_RESULT_PATH" ;;
  2) ARCHIVE_MSG="   ⚠️  Archive failed; previous run removed." ;;
  # rc=1 → nothing to archive, stay silent
esac
rm -f "${PROJECT_ROOT}/.stagent/state.md"

# ──────────────────────────────────────────────────────────────
# Phase 3: Create this session's run dir and state.md
# ──────────────────────────────────────────────────────────────
TOPIC_DIR="$SESSION_RUN_DIR"
mkdir -p "$TOPIC_DIR"

# Capture worktree-snapshot tree at workflow start time. Local mode
# doesn't render diffs today, but keeping symmetry with cloud mode so
# the same files exist on disk whichever mode the user picks.
if [[ "$(config_modifies_worktree)" == "true" ]]; then
  _capture_baseline_tree "$TOPIC_DIR" "$PROJECT_ROOT"
fi

INITIAL_STAGE="$(config_initial_stage)"
LOCAL_FINGERPRINT="$(git_project_fingerprint "$PROJECT_ROOT")"

cat > "${TOPIC_DIR}/state.md" <<EOF
---
active: true
status: $INITIAL_STAGE
epoch: 1
resume_status:
topic: "$TOPIC"
session_id: $SESSION_ID
worktree: "$WORKTREE_ROOT"
workflow_dir: "$WORKFLOW_DIR"
project_root: "$PROJECT_ROOT"
project_fingerprint: ${LOCAL_FINGERPRINT:-}
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

# Bootstrap-edge lifecycle now lives inside state.md as the
# `bootstrap_completed_at` field — see the cloud-path note above and
# mark_bootstrap_completed() in lib.sh.

# ──────────────────────────────────────────────────────────────
# Phase 4: Generate run_files declared in workflow.json
# ──────────────────────────────────────────────────────────────
# Phase 1 above has already ensured a valid git HEAD exists, so
# "git rev-parse HEAD 2>/dev/null || echo EMPTY" is safe here.
generate_run_files "$TOPIC_DIR" "$PROJECT_ROOT" || exit 1

# ──────────────────────────────────────────────────────────────
# Phase 5: Surface context to the main agent
# ──────────────────────────────────────────────────────────────
INTERRUPTIBLE_HINT=""
if config_is_interruptible "$INITIAL_STAGE"; then
  INTERRUPTIBLE_HINT=" — interruptible"
fi

echo "🔄 Dev workflow activated."
echo ""
echo "   Topic: $TOPIC"
echo "   Session: $SESSION_ID"
echo "   Worktree: $WORKTREE_ROOT"
echo "   Status: $INITIAL_STAGE (epoch 1)$INTERRUPTIBLE_HINT"
if [[ -n "${ARCHIVE_MSG:-}" ]]; then
  echo "$ARCHIVE_MSG"
fi
if [[ -n "$AUTO_GIT_MSG" ]]; then
  printf '%b\n' "$AUTO_GIT_MSG"
fi

if config_is_stage "$INITIAL_STAGE"; then
  config_show_stage_context "$INITIAL_STAGE" "$SESSION_ID" "$PROJECT_ROOT"
fi

echo ""
echo "   Run dir: $TOPIC_DIR"
echo "   Workflow dir: $WORKFLOW_DIR"
echo "   To pause: /stagent:interrupt"
echo "   To cancel: /stagent:cancel"
