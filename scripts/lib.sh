#!/bin/bash
# Shared utilities for stagent scripts.
#
# Groups:
#   1. .stagent/ discovery (find_dw_root)
#   2. State resolution (resolve_state) — locates the right state.md among
#      possibly many per-topic subdirs
#   3. Workflow config access (reads workflow.json)

# ──────────────────────────────────────────────────────────────
# Plugin & default workflow paths
# ──────────────────────────────────────────────────────────────

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$_LIB_DIR")"

# A workflow is a directory containing workflow.json + one {stage}.md per stage.
# Default ships at skills/stagent/workflow/.
DEFAULT_WORKFLOW_DIR="${PLUGIN_ROOT}/skills/stagent/workflow"

# Resolved workflow dir + config file (may be overridden by resolve_workflow_dir_from_state)
WORKFLOW_DIR="$DEFAULT_WORKFLOW_DIR"
CONFIG_FILE="${WORKFLOW_DIR}/workflow.json"

# ──────────────────────────────────────────────────────────────
# .stagent/ discovery
# ──────────────────────────────────────────────────────────────

# Echo the absolute path to the nearest .stagent/ dir (upward walk from CWD).
# Returns 1 if none found.
find_dw_root() {
  if [[ -d ".stagent" ]]; then
    echo "$(pwd)/.stagent"
    return 0
  fi
  local dir
  dir="$(pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.stagent" ]]; then
      echo "$dir/.stagent"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# Read a YAML frontmatter scalar from a file; echoes the value (or empty
# if the field is absent). Always exits 0 — callers branch on the string
# value, not on the rc.
#
# The `|| true` is load-bearing: when the field is missing, `grep` exits
# 1 (no match). Under `set -o pipefail` (which most plugin scripts set
# at their head), that grep failure propagates as the pipeline rc → the
# function returns 1. Combined with `set -e`, the caller's command
# substitution `VAR=$(_read_fm_field ...)` then aborts the entire
# script silently — exactly what bit cross-machine `/stagent:continue`
# when `cloud_pull_shadow` rebuilt state.md without `last_seen_head`,
# leaving the script to die at the workdir-health check before the
# status flip ran.
_read_fm_field() {
  local file="$1" field="$2"
  { grep "^${field}:" "$file" 2>/dev/null || true; } \
    | head -1 \
    | sed "s/^${field}: *//" \
    | sed 's/^"\(.*\)"$/\1/' \
    | tr -d '[:space:]'
}

# Set (or insert if missing) a frontmatter scalar in state.md. Operates only
# on the first YAML frontmatter block (between the first two --- lines).
set_fm_field() {
  local file="$1" field="$2" value="$3"
  awk -v field="$field" -v value="$value" '
    BEGIN { fm=0; done=0 }
    /^---$/ {
      fm++
      if (fm == 2 && !done) { print field ": " value; done=1 }
      print; next
    }
    fm == 1 && $0 ~ "^" field ":" { if (!done) { print field ": " value; done=1 } ; next }
    { print }
  ' "$file" > "${file}.tmp.$$" && mv "${file}.tmp.$$" "$file"
}

# ──────────────────────────────────────────────────────────────
# awaiting_user — "this stage is interruptible AND we've paused
# because the agent expects a reply from the user."
# ──────────────────────────────────────────────────────────────
#
# Written by stop-hook.sh when an interruptible stage leaves the agent
# without a done artifact; cleared by UserPromptSubmit (user sent a
# message) and by update-status.sh (stage transitioned).
#
# Missing field is treated as false — guarantees backwards-compat with
# state.md files produced by older plugin versions that don't know
# about this field.

get_awaiting_user() {
  local file="$1"
  local v
  v="$(_read_fm_field "$file" awaiting_user)"
  [[ "$v" == "true" ]] && echo "true" || echo "false"
}

set_awaiting_user() {
  local file="$1" value="$2"
  # Normalise to lowercase true/false.
  case "$value" in
    true|TRUE|1|yes)   value=true ;;
    *)                 value=false ;;
  esac
  set_fm_field "$file" awaiting_user "$value"
}

# ──────────────────────────────────────────────────────────────
# bootstrap_completed_at — "the stagent skill driver has engaged
# this state.md at least once."
# ──────────────────────────────────────────────────────────────
#
# A positive lifecycle marker recorded inside state.md frontmatter,
# replacing the older negative `.bootstrap_pending` sentinel file. Set
# exactly once, by loop-tick.sh on its first successful run; never
# cleared, even across stage transitions.
#
# Stop-hook.sh reads this to decide whether the bootstrap-edge
# `decision: block` branch should fire. Empty / missing field means
# "no driver has engaged yet → block to force `Skill("stagent:stagent")`
# invocation". Any non-empty value means "loop is or was driving →
# fall through to the normal interruptible / uninterruptible logic."
#
# Lives inside state.md so the lifecycle bit can never become orphaned
# (e.g. file-system path mismatches between SCRATCH_DIR / TOPIC_DIR /
# `dirname $STATE_FILE` that plagued the old sentinel-file design).

get_bootstrap_completed_at() {
  local file="$1"
  _read_fm_field "$file" bootstrap_completed_at
}

# Idempotent: only writes when the field is empty/missing. Safe to
# call on every loop tick — repeated invocations don't churn state.md.
mark_bootstrap_completed() {
  local file="$1"
  local cur; cur="$(_read_fm_field "$file" bootstrap_completed_at)"
  if [[ -z "$cur" ]]; then
    set_fm_field "$file" bootstrap_completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
}

# ──────────────────────────────────────────────────────────────
# Archive helper — move a run dir to .stagent/.archive/
# ──────────────────────────────────────────────────────────────
#
# Shared by setup-workflow.sh (archive-on-replace) and cancel-workflow.sh
# (archive-on-cancel) so the "keep audit trail instead of rm -rf" policy
# lives in one place.
#
# Archive path: <.stagent>/.archive/<YYYYMMDD-HHMMSS>-<topic>[-<suffix>]/
# Hidden dot-dir so resolve_state's "$dw"/*/state.md glob skips it.
#
# Args:
#   $1 = run dir (absolute), typically .stagent/<session_id>
#   $2 = topic fallback (optional, used when state.md is missing/empty)
#   $3 = suffix (optional, e.g. "cancelled" to distinguish intent)
#
# Side effects:
#   On success: sets ARCHIVE_RESULT_PATH to the archive dir, returns 0.
#   On skip   : run dir missing or empty, ARCHIVE_RESULT_PATH="", returns 1.
#   On error  : mv failed, falls back to rm -rf the run dir so callers can
#               proceed, ARCHIVE_RESULT_PATH="", returns 2.
archive_run_dir() {
  local run_dir="$1"
  local topic_fallback="${2:-}"
  local suffix="${3:-}"
  ARCHIVE_RESULT_PATH=""

  if [[ ! -d "$run_dir" ]] || [[ -z "$(ls -A "$run_dir" 2>/dev/null)" ]]; then
    return 1
  fi

  local dw_root; dw_root="$(dirname "$run_dir")"
  local archive_root="${dw_root}/.archive"

  # Derive a human-readable topic label for the archive dir name.
  # Primary source is state.md; if that's missing/corrupt we fall back
  # to whatever the caller supplied, or the run dir basename, or the
  # literal "orphan". No stage-name-specific parsing.
  local topic=""
  if [[ -f "$run_dir/state.md" ]]; then
    topic=$(_read_fm_field "$run_dir/state.md" topic)
  fi
  [[ -z "$topic" ]] && topic="${topic_fallback:-}"
  [[ -z "$topic" ]] && topic="$(basename "$run_dir")"
  [[ -z "$topic" ]] && topic="orphan"

  local topic_safe
  topic_safe=$(printf '%s' "$topic" | tr -c '[:alnum:]_-' '-' \
               | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' | cut -c1-40)
  [[ -z "$topic_safe" ]] && topic_safe="orphan"

  local name="$(date -u +%Y%m%d-%H%M%S)-${topic_safe}"
  [[ -n "$suffix" ]] && name="${name}-${suffix}"

  mkdir -p "$archive_root"
  local base="${archive_root}/${name}"
  local target="$base"
  local n=1
  while [[ -e "$target" ]]; do
    target="${base}-${n}"
    n=$((n + 1))
  done

  if mv "$run_dir" "$target" 2>/dev/null; then
    ARCHIVE_RESULT_PATH="$target"
    return 0
  fi

  # mv failed — fall back to rm so caller can proceed with setup
  rm -rf "$run_dir"
  return 2
}

# ──────────────────────────────────────────────────────────────
# Session-id cache (written by hooks/session-start.sh, read by
# setup-workflow.sh and continue-workflow.sh)
# ──────────────────────────────────────────────────────────────
#
# Claude Code exposes session_id to hooks via stdin JSON, but NOT to the
# Bash tool's subprocess env. The cache bridges that gap.
#
# SessionStart hook writes two keys:
#   cwd-<sha1(cwd)>   matches when reader's cwd == hook's cwd
#   ppid-<PPID>       matches when reader's $PPID (walked up if needed) is
#                     the Claude Code harness PID (same as hook's $PPID)
#
# Readers try both, walking the process tree on the ppid path. If neither
# matches, the session_id is unknown and setup-workflow.sh fails fast
# (it can't create a session-keyed run dir without one).

_DW_SESSION_CACHE_DIR="${HOME}/.cache/stagent/session-cache"

_session_cache_cwd_key() {
  printf '%s' "$(pwd)" | shasum -a 1 | cut -c1-16
}

# Echo the cached session_id for the current session, or empty if unknown.
#
# Resolution order is PPID-first, cwd-fallback:
#   1. Walk the PPID chain up to 20 hops. Trust a ppid-<pid> cache entry
#      only when that PID is still alive AND its comm name looks like a
#      Claude Code process. This is the only signal that stays unique
#      across concurrent sessions sharing a working directory.
#   2. Fall back to the cwd-<sha1(pwd)> cache ONLY when the PPID chain
#      yielded nothing. This branch misattributes when two Claude Code
#      sessions share the same cwd (they overwrite each other's cwd
#      cache), so it's strictly a last-resort guess.
#
# The comm-name check on PPID hits defends against PID recycling: after
# a Claude Code session exits the kernel may hand its PID to an unrelated
# process, leaving a stale ppid-<old-pid> file behind. Skip those.
read_cached_session_id() {
  local cache="$_DW_SESSION_CACHE_DIR"

  # Test-only override: when _DW_FORCE_CWD_CACHE=1, skip the PPID chain
  # and go straight to cwd-cache. The e2e suite uses this because it
  # runs under an outer Claude Code session whose ppid-cache entry
  # would otherwise shadow the per-test cwd-cache the test just wrote.
  # Never set this in real plugin runs.
  if [[ "${_DW_FORCE_CWD_CACHE:-}" != "1" ]]; then
    local pid=$PPID
    local hops=0
    while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && $hops -lt 20 ]]; do
      if [[ -f "${cache}/ppid-${pid}" ]]; then
        local comm
        comm="$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "$comm" && "$comm" == *claude* ]]; then
          cat "${cache}/ppid-${pid}"
          return 0
        fi
      fi
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
      hops=$((hops + 1))
    done
  fi

  local key
  key="$(_session_cache_cwd_key)"
  if [[ -f "${cache}/cwd-${key}" ]]; then
    cat "${cache}/cwd-${key}"
    return 0
  fi

  echo ""
}

# ──────────────────────────────────────────────────────────────
# State resolution
# ──────────────────────────────────────────────────────────────
#
# Layout: <project>/.stagent/<session_id>/state.md plus per-stage
# reports in the same <session_id>/ subdir. Each Claude session gets its
# own isolated run, so multiple sessions in the same worktree coexist
# without stepping on each other.
#
# resolve_state() is the main entry point. It keys by session_id: either
# DESIRED_SESSION (set by callers, e.g. hooks parsing HOOK_INPUT.session_id)
# or the cached session_id for the current Claude session
# (read_cached_session_id, populated by hooks/session-start.sh).
#
# Optional inputs (callers may set as shell vars before calling):
#   DESIRED_SESSION=<id>   — use this session's subdir (primary resolution)
#   DESIRED_TOPIC=<name>   — fallback: scan all session subdirs for one
#                            whose `topic:` frontmatter matches. Useful
#                            for CLI commands that want to target a
#                            specific run without knowing its session_id.
#
# On success, sets: STATE_FILE, TOPIC, RUN_DIR_NAME, TOPIC_DIR, PROJECT_ROOT
# Returns 0 on success, 1 if nothing resolvable.

_populate_state_vars() {
  local sd="$1"
  local project_root="$2"
  STATE_FILE="$sd"
  TOPIC_DIR="$(dirname "$sd")"
  RUN_DIR_NAME="$(basename "$TOPIC_DIR")"
  TOPIC="$(_read_fm_field "$sd" topic)"
  [[ -z "$TOPIC" ]] && TOPIC="$RUN_DIR_NAME"
  PROJECT_ROOT="$project_root"
}

resolve_state() {
  # Cloud mode short-circuit: if the current session is registered as
  # cloud, read its shadow state.md from the scratch dir directly. The
  # project's worktree has no .stagent/ in cloud mode, so walking up
  # from CWD would fail — the scratch dir is the only truth locally.
  local _sess="${DESIRED_SESSION:-}"
  if [[ -z "$_sess" ]]; then _sess="$(read_cached_session_id)"; fi
  if [[ -n "$_sess" ]] && is_cloud_session "$_sess"; then
    # Read scratch dir from the registry — allows cross-machine takeover
    # to alias one physical shadow under the local session_id without
    # renaming the on-disk directory.
    local _scratch_dir; _scratch_dir="$(cloud_registry_get "$_sess" scratch_dir)"
    [[ -z "$_scratch_dir" ]] && _scratch_dir="$(cloud_scratch_dir)/${_sess}"
    local _state="${_scratch_dir}/state.md"
    if [[ -f "$_state" ]]; then
      _populate_state_vars "$_state" ""
      local _pr; _pr="$(_read_fm_field "$_state" project_root)"
      [[ -z "$_pr" ]] && _pr="$(pwd)"
      PROJECT_ROOT="$_pr"
      return 0
    fi
  fi

  local dw
  dw="$(find_dw_root)" || return 1
  local project_root
  project_root="$(dirname "$dw")"

  # Session-keyed layout: .stagent/<session_id>/state.md
  # Primary resolution: DESIRED_SESSION (caller-supplied, typically from
  # HOOK_INPUT in hooks) or the cached session_id for this Claude session.
  local session="${DESIRED_SESSION:-}"
  if [[ -z "$session" ]]; then
    session="$(read_cached_session_id)"
  fi

  if [[ -n "$session" ]] && [[ -f "$dw/$session/state.md" ]]; then
    _populate_state_vars "$dw/$session/state.md" "$project_root"
    return 0
  fi

  # Fallback for cross-session CLI queries: DESIRED_TOPIC filters by the
  # `topic:` field in state.md across all session dirs.
  if [[ -n "${DESIRED_TOPIC:-}" ]]; then
    local sd
    for sd in "$dw"/*/state.md; do
      [[ -f "$sd" ]] || continue
      local tp
      tp="$(_read_fm_field "$sd" topic)"
      if [[ "$tp" == "$DESIRED_TOPIC" ]]; then
        _populate_state_vars "$sd" "$project_root"
        return 0
      fi
    done
  fi

  # Unambiguous single-workflow fallback. When neither DESIRED_SESSION
  # nor DESIRED_TOPIC was provided and the project has exactly one
  # session subdir under .stagent/, just use it. This removes the
  # friction of having to pass --topic when calling plugin scripts from
  # an agent Bash invocation that didn't inherit the session-start hook
  # context (so read_cached_session_id returned empty). With two or
  # more candidates we still error out — the error message below will
  # list them so the caller knows what to pass.
  #
  # GATE: only trigger when we have NO session signal at all. If the
  # caller named a specific session (DESIRED_SESSION) or we resolved
  # one from the cache, a missing state.md means "this session has no
  # workflow" — not "take the neighbor's". Without this gate, a stop-
  # hook firing in Claude Code session A (cwd=/proj/sub) would adopt
  # the workflow started by session B (cwd=/proj) because the project's
  # .stagent/ happens to have exactly one entry.
  if [[ -z "$session" ]]; then
    local _candidates=()
    local _c
    for _c in "$dw"/*/state.md; do
      [[ -f "$_c" ]] && _candidates+=("$_c")
    done
    if [[ ${#_candidates[@]} -eq 1 ]]; then
      _populate_state_vars "${_candidates[0]}" "$project_root"
      return 0
    fi
  fi

  # Legacy: flat .stagent/state.md (pre-v1.11) — single-workflow fallback
  if [[ -f "$dw/state.md" ]]; then
    _populate_state_vars "$dw/state.md" "$project_root"
    TOPIC_DIR="$dw"
    RUN_DIR_NAME=""
    return 0
  fi

  return 1
}

# Find a state.md with status=interrupted across all session dirs under
# .stagent/. Used by continue-workflow.sh for cross-session takeover.
# On success: sets STATE_FILE/TOPIC_DIR/RUN_DIR_NAME/TOPIC/PROJECT_ROOT to
# the found dir (still keyed by the ORIGINAL session id — caller must
# rename to new session id).
resolve_interrupted_state() {
  local dw
  dw="$(find_dw_root)" || return 1
  local project_root
  project_root="$(dirname "$dw")"

  local match_count=0
  local match=""
  local sd
  for sd in "$dw"/*/state.md; do
    [[ -f "$sd" ]] || continue
    local st
    st="$(_read_fm_field "$sd" status)"
    if [[ "$st" == "interrupted" ]]; then
      match_count=$((match_count + 1))
      match="$sd"
    fi
  done

  if [[ $match_count -eq 0 ]]; then
    return 1
  fi
  if [[ $match_count -gt 1 ]]; then
    echo "⚠️  Multiple interrupted workflows found; disambiguate with --session <id>:" >&2
    for sd in "$dw"/*/state.md; do
      [[ -f "$sd" ]] || continue
      local st
      st="$(_read_fm_field "$sd" status)"
      [[ "$st" == "interrupted" ]] || continue
      local tp
      tp="$(_read_fm_field "$sd" topic)"
      echo "   - session: $(basename "$(dirname "$sd")")   topic: ${tp:-?}" >&2
    done
    return 2
  fi

  _populate_state_vars "$match" "$project_root"
  return 0
}

# List all workflows (state.md files) under .stagent/, with their status.
# Useful for error messages when resolve_state is ambiguous.
list_all_workflows() {
  local dw
  dw="$(find_dw_root)" || return 1
  for sd in "$dw"/*/state.md; do
    [[ -f "$sd" ]] || continue
    local topic status
    topic="$(_read_fm_field "$sd" topic)"
    status="$(_read_fm_field "$sd" status)"
    echo "  - topic=${topic:-?} status=$status"
  done
}

# ──────────────────────────────────────────────────────────────
# Workflow config access
# ──────────────────────────────────────────────────────────────

# Called AFTER resolve_state so state.md can override the default workflow dir.
resolve_workflow_dir_from_state() {
  if [[ -z "${STATE_FILE:-}" ]] || [[ ! -f "${STATE_FILE}" ]]; then
    return 0
  fi
  local dir
  dir="$(_read_fm_field "$STATE_FILE" workflow_dir)"
  if [[ -n "$dir" ]]; then
    WORKFLOW_DIR="$dir"
    CONFIG_FILE="${dir}/workflow.json"
  fi
}

config_check() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ workflow.json not found at $CONFIG_FILE" >&2
    return 1
  fi
  if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo "❌ workflow.json is not valid JSON" >&2
    return 1
  fi
  return 0
}

# Structural validation of the resolved workflow config + directory. Checks:
#   - initial_stage is set and references a declared stage
#   - terminal_stages is a non-empty array
#   - each stage has a matching <stage>.md next to workflow.json
#   - each stage's execution.type is inline | subagent
#   - subagent stages must declare subagent_type
#   - each transition target is either another stage or a terminal stage
#   - each required/optional input's from_stage references a declared stage
# Emits one "❌ ..." line per issue on stderr; returns 0 only on clean.
# Assumes config_check has already passed (file exists, valid JSON).
config_validate() {
  local errors=0

  # initial_stage
  local init; init="$(jq -r '.initial_stage // ""' "$CONFIG_FILE")"
  if [[ -z "$init" ]]; then
    echo "❌ .initial_stage is missing" >&2; errors=$((errors + 1))
  elif ! config_is_stage "$init"; then
    echo "❌ .initial_stage='$init' is not declared under .stages" >&2; errors=$((errors + 1))
  fi

  # max_epoch — optional; when present must be a positive integer
  local me_type
  me_type=$(jq -r '.max_epoch | type' "$CONFIG_FILE")
  if [[ "$me_type" != "null" ]]; then
    if [[ "$me_type" != "number" ]]; then
      echo "❌ .max_epoch must be a positive integer (got $me_type)" >&2
      errors=$((errors + 1))
    else
      local me_val; me_val=$(jq -r '.max_epoch' "$CONFIG_FILE")
      if ! [[ "$me_val" =~ ^[1-9][0-9]*$ ]]; then
        echo "❌ .max_epoch must be a positive integer ≥ 1 (got $me_val)" >&2
        errors=$((errors + 1))
      fi
    fi
  fi

  # terminal_stages
  local term_count
  term_count=$(jq '.terminal_stages | if type=="array" then length else -1 end' "$CONFIG_FILE")
  if [[ "$term_count" -lt 0 ]]; then
    echo "❌ .terminal_stages must be an array" >&2; errors=$((errors + 1))
  elif [[ "$term_count" -eq 0 ]]; then
    echo "❌ .terminal_stages is empty (need at least one, e.g. \"complete\")" >&2
    errors=$((errors + 1))
  fi

  # stages must be an object
  local stage_type
  stage_type=$(jq -r '.stages | type' "$CONFIG_FILE")
  if [[ "$stage_type" != "object" ]]; then
    echo "❌ .stages must be an object (got $stage_type)" >&2
    return $((errors + 1))
  fi

  # Per-stage checks
  local stage
  while read -r stage; do
    [[ -z "$stage" ]] && continue
    local prefix="stage '$stage':"

    # .md file exists next to workflow.json
    local md; md="$(config_stage_instructions_path "$stage")"
    if [[ ! -f "$md" ]]; then
      echo "❌ $prefix instructions file missing: $md" >&2; errors=$((errors + 1))
    fi

    # execution.type sanity
    local etype; etype="$(jq -r --arg s "$stage" '.stages[$s].execution.type // ""' "$CONFIG_FILE")"
    case "$etype" in
      inline|subagent) ;;
      "") echo "❌ $prefix execution.type is missing" >&2; errors=$((errors + 1)) ;;
      *)  echo "❌ $prefix execution.type='$etype' must be 'inline' or 'subagent'" >&2
          errors=$((errors + 1)) ;;
    esac

    # subagent stages must NOT declare subagent_type. There is one generic
    # stagent:workflow-subagent hardcoded in agent-guard.sh and
    # stop-hook.sh — per-stage behavior comes entirely from the stage
    # instructions file. Accepting a per-stage subagent_type here would
    # create a silent mismatch between workflow.json and what actually
    # gets launched.
    if [[ "$etype" == "subagent" ]]; then
      local sub; sub="$(jq -r --arg s "$stage" '.stages[$s].execution.subagent_type // ""' "$CONFIG_FILE")"
      if [[ -n "$sub" ]]; then
        echo "❌ $prefix execution.subagent_type is not supported — the plugin uses a single generic workflow-subagent for all subagent stages. Remove this field; per-stage behavior comes from the stage instructions file." >&2
        errors=$((errors + 1))
      fi

      # subagent stages cannot be interruptible — the main agent blocks on
      # the Agent tool call for the duration, so the stop hook has no turn
      # boundary to fire at. Accepting the flag would silently lie.
      local intr
      intr="$(jq -r --arg s "$stage" '.stages[$s].interruptible // false' "$CONFIG_FILE")"
      if [[ "$intr" == "true" ]]; then
        echo "❌ $prefix execution.type=subagent cannot be interruptible — main agent blocks on the Agent tool call, stop hook has no chance to fire" >&2
        errors=$((errors + 1))
      fi
    fi

    # transitions point to a declared stage OR a terminal
    local result next
    while IFS=$'\t' read -r result next; do
      [[ -z "$result" ]] && continue
      if [[ -z "$next" ]]; then
        echo "❌ $prefix transitions['$result'] has no target" >&2
        errors=$((errors + 1)); continue
      fi
      if ! config_is_stage "$next" && ! config_is_terminal "$next"; then
        echo "❌ $prefix transitions['$result'] → '$next' is neither a declared stage nor a terminal" >&2
        errors=$((errors + 1))
      fi
    done < <(jq -r --arg s "$stage" '.stages[$s].transitions // {} | to_entries[]? | "\(.key)\t\(.value)"' "$CONFIG_FILE")

    # inputs.required[*] / inputs.optional[*] — validate from_stage and from_run_file refs
    local kind from
    for kind in required optional; do
      while read -r from; do
        [[ -z "$from" ]] && continue
        if ! config_is_stage "$from"; then
          echo "❌ $prefix inputs.$kind references unknown from_stage '$from'" >&2
          errors=$((errors + 1))
        fi
      done < <(jq -r --arg s "$stage" --arg k "$kind" '.stages[$s].inputs[$k][]? | .from_stage // empty' "$CONFIG_FILE")

      while read -r from; do
        [[ -z "$from" ]] && continue
        if ! jq -e --arg n "$from" '.run_files[$n]' "$CONFIG_FILE" > /dev/null 2>&1; then
          echo "❌ $prefix inputs.$kind references unknown from_run_file '$from' (not declared in .run_files)" >&2
          errors=$((errors + 1))
        fi
      done < <(jq -r --arg s "$stage" --arg k "$kind" '.stages[$s].inputs[$k][]? | .from_run_file // empty' "$CONFIG_FILE")
    done
  done < <(config_all_stages)

  return $errors
}

config_initial_stage() {
  jq -r '.initial_stage' "$CONFIG_FILE"
}

config_terminal_stages() {
  jq -r '.terminal_stages[]' "$CONFIG_FILE"
}

# Cap on total transitions before update-status.sh auto-escalates.
# Read from workflow.json `.max_epoch`; falls back to 20 when absent,
# null, or malformed. Always a positive integer.
config_max_epoch() {
  local v
  v="$(jq -r '.max_epoch // empty' "$CONFIG_FILE" 2>/dev/null)"
  if [[ -z "$v" ]] || ! [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
    echo 20
  else
    echo "$v"
  fi
}

# Whether this workflow modifies the project worktree. When true (default)
# the plugin captures a baseline-tree at setup and POSTs a working-tree
# diff to the server; when false it skips both and the UI hides the diff
# panel. Set to false for workflows whose output lives outside the
# project (e.g. create-workflow writes to ~/.config/stagent/).
#
# Reads workflow.json `.modifies_worktree`. Accepts true/false; anything
# else (missing, null, malformed) defaults to true for backward compat
# with workflows authored before this field existed.
config_modifies_worktree() {
  # Note: don't use `// empty` here — jq's `//` treats `false` as an
  # alternative trigger, so `false // empty` returns empty and we'd
  # default `false` workflows back to `true`. Raw read + string match
  # is the safe pattern.
  local v
  v="$(jq -r '.modifies_worktree' "$CONFIG_FILE" 2>/dev/null)"
  case "$v" in
    false) echo "false" ;;
    *) echo "true" ;;  # true, null, missing, malformed → default true
  esac
}

config_all_stages() {
  jq -r '.stages | keys[]' "$CONFIG_FILE"
}

config_is_stage() {
  jq -e --arg s "$1" '.stages[$s]' "$CONFIG_FILE" > /dev/null 2>&1
}

config_is_terminal() {
  jq -e --arg s "$1" '.terminal_stages | index($s)' "$CONFIG_FILE" > /dev/null 2>&1
}

# Treats both the workflow's declared terminal_stages and the plugin-
# reserved status "cancelled" as terminal. Server-side /cancel sets
# status=cancelled, which may not be in an older session's stored
# workflow_json.terminal_stages — this wrapper closes that gap so any
# script reasoning about "is this done?" gets the right answer even
# for older sessions that were created before we added cancelled.
is_terminal_status() {
  local s="$1"
  [[ -z "$s" ]] && return 1
  [[ "$s" == "cancelled" ]] && return 0
  config_is_terminal "$s"
}

config_is_interruptible() {
  local s="$1"
  local v
  v=$(jq -r --arg s "$s" '.stages[$s].interruptible // false' "$CONFIG_FILE")
  [[ "$v" == "true" ]]
}

config_execution_type() {
  jq -r --arg s "$1" '.stages[$s].execution.type // ""' "$CONFIG_FILE"
}

config_model() {
  jq -r --arg s "$1" '.stages[$s].execution.model // ""' "$CONFIG_FILE"
}

config_next_status() {
  jq -r --arg s "$1" --arg r "$2" '.stages[$s].transitions[$r] // ""' "$CONFIG_FILE"
}

config_transition_keys() {
  jq -r --arg s "$1" '.stages[$s].transitions // {} | keys | join(" ")' "$CONFIG_FILE"
}

# Emit tab-separated: type\tkey\tdescription
# type is "stage" (from_stage) or "run_file" (from_run_file)
config_required_inputs() {
  jq -r --arg s "$1" '
    .stages[$s].inputs.required[]? |
    if .from_stage   then "stage\t\(.from_stage)\t\(.description)"
    elif .from_run_file then "run_file\t\(.from_run_file)\t\(.description)"
    else empty end
  ' "$CONFIG_FILE"
}

config_optional_inputs() {
  jq -r --arg s "$1" '
    .stages[$s].inputs.optional[]? |
    if .from_stage   then "stage\t\(.from_stage)\t\(.description)"
    elif .from_run_file then "run_file\t\(.from_run_file)\t\(.description)"
    else empty end
  ' "$CONFIG_FILE"
}

# Artifact path for a stage's output.
# Resolution precedence:
#   1. DW_RUN_BASE env var — setup-workflow.sh exports this in cloud mode
#      before state.md exists, so config_show_stage_context prints the
#      right shadow path.
#   2. $TOPIC_DIR — set by resolve_state after state.md is located; points
#      to the correct run dir in both local and cloud modes.
#   3. Fallback: <project>/.stagent/<run_dir_name>/<stage>-report.md —
#      the legacy local-mode path when neither of the above is populated.
config_artifact_path() {
  local stage="$1"
  local run_dir_name="$2"
  local project_root="$3"
  if [[ -n "${DW_RUN_BASE:-}" ]]; then
    echo "${DW_RUN_BASE}/${run_dir_name}/${stage}-report.md"
    return
  fi
  if [[ -n "${TOPIC_DIR:-}" ]]; then
    echo "${TOPIC_DIR}/${stage}-report.md"
    return
  fi
  echo "${project_root}/.stagent/${run_dir_name}/${stage}-report.md"
}

# Path for a run_file (created once at setup time, stored in the run dir).
# Resolution precedence mirrors config_artifact_path. Takes the same
# explicit (run_dir_name, project_root) positional args because cloud
# setup-workflow.sh calls this BEFORE resolve_state has populated the
# global RUN_DIR_NAME / PROJECT_ROOT — so the function must accept its
# context from the caller, not read shell globals.
config_run_file_path() {
  local name="$1"
  local run_dir_name="$2"
  local project_root="${3:-}"
  if [[ -n "${DW_RUN_BASE:-}" ]]; then
    echo "${DW_RUN_BASE}/${run_dir_name}/${name}"
    return
  fi
  if [[ -n "${TOPIC_DIR:-}" ]]; then
    echo "${TOPIC_DIR}/${name}"
    return
  fi
  echo "${project_root}/.stagent/${run_dir_name}/${name}"
}

# Init shell command for a run_file.
config_run_file_init() {
  jq -r --arg n "$1" '.run_files[$n].init // empty' "$CONFIG_FILE"
}

# All declared run_file names.
config_run_file_names() {
  jq -r '.run_files // {} | keys[]' "$CONFIG_FILE"
}

# Stage-instructions markdown path.
config_stage_instructions_path() {
  local stage="$1"
  echo "${WORKFLOW_DIR}/${stage}.md"
}

# Print summary of a stage's I/O context (for Claude's context after transitions).
config_show_stage_context() {
  local stage="$1"
  local topic="$2"
  local project_root="$3"

  local required=""
  while IFS=$'\t' read -r type key description; do
    [[ -z "$key" ]] && continue
    local path
    if [[ "$type" == "run_file" ]]; then
      path="$(config_run_file_path "$key" "$topic" "$project_root")"
    else
      path="$(config_artifact_path "$key" "$topic" "$project_root")"
    fi
    required+="     - ${path} — ${description}"$'\n'
  done < <(config_required_inputs "$stage")

  local optional=""
  while IFS=$'\t' read -r type key description; do
    [[ -z "$key" ]] && continue
    local path
    if [[ "$type" == "run_file" ]]; then
      path="$(config_run_file_path "$key" "$topic" "$project_root")"
    else
      path="$(config_artifact_path "$key" "$topic" "$project_root")"
    fi
    optional+="     - ${path} — ${description} (if exists)"$'\n'
  done < <(config_optional_inputs "$stage")

  if [[ -n "$required" ]]; then
    echo "   Required inputs:"
    printf '%s' "$required"
  fi
  if [[ -n "$optional" ]]; then
    echo "   Optional inputs:"
    printf '%s' "$optional"
  fi
  echo "   Output: $(config_artifact_path "$stage" "$topic" "$project_root")"
}

# ──────────────────────────────────────────────────────────────
# Cloud mode
# ──────────────────────────────────────────────────────────────
#
# Cloud mode puts the authoritative copy of state + artifacts on a
# remote server (the workflowUI webapp). A transient shadow lives under
# ~/.cache/stagent/sessions/<session_id>/ so Claude's Read/Write
# tools still have real file paths to operate on. Every write is mirrored
# to the server via curl. The project worktree gets no .stagent/ dir.
#
# Registry: ~/.cache/stagent/cloud-registry/<session_id>.json records
# {mode, session_id, scratch_dir, server, workflow_url}. Its presence is
# how every script/hook decides "cloud or local" — no env var needed.

CLOUD_REGISTRY_DIR="${HOME}/.cache/stagent/cloud-registry"
CLOUD_SCRATCH_BASE="${HOME}/.cache/stagent/sessions"

# Default cloud server for this plugin build. Hard-coded so users only need
# to export STAGENT_API_TOKEN; the server URL is baked in. Override by
# exporting STAGENT_SERVER=... (useful for pointing at a local dev
# webapp, a staging deployment, or a fork).
: "${STAGENT_SERVER:=https://stagent.worldstatelabs.com}"
export STAGENT_SERVER

cloud_scratch_dir() {
  echo "$CLOUD_SCRATCH_BASE"
}

cloud_registry_file() {
  echo "${CLOUD_REGISTRY_DIR}/${1}.json"
}

is_cloud_session() {
  local sid="$1"
  [[ -n "$sid" ]] && [[ -f "${CLOUD_REGISTRY_DIR}/${sid}.json" ]]
}

# Echo a field from the registry JSON. Returns empty if missing.
cloud_registry_get() {
  local sid="$1" field="$2"
  local f; f="$(cloud_registry_file "$sid")"
  [[ -f "$f" ]] || { echo ""; return; }
  jq -r --arg k "$field" '.[$k] // ""' "$f" 2>/dev/null
}

# Register a session as cloud-managed.
# Args:
#   $1 = session_id used as the registry file key (may be the local
#        Claude session_id in a takeover scenario)
#   $2 = server URL
#   $3 = workflow URL (may be empty)
#   $4 = scratch dir override (optional). Defaults to
#        ${CLOUD_SCRATCH_BASE}/${sid}. Used by cross-machine takeover
#        where one physical scratch dir is aliased under two keys.
cloud_register_session() {
  local sid="$1" server="$2" url="$3" scratch="${4:-}"
  [[ -z "$scratch" ]] && scratch="${CLOUD_SCRATCH_BASE}/${sid}"
  mkdir -p "$CLOUD_REGISTRY_DIR"
  jq -n \
    --arg sid "$sid" \
    --arg scratch "$scratch" \
    --arg server "$server" \
    --arg url "$url" \
    '{mode:"cloud", session_id:$sid, scratch_dir:$scratch, server:$server, workflow_url:$url}' \
    > "$(cloud_registry_file "$sid")"
}

# Drop the registry entry for a session — and any alias entries that
# point at the same scratch_dir (cross-machine takeover creates two
# registry files for one physical shadow; we must clean both).
cloud_unregister_session() {
  local sid="$1"
  local primary; primary="$(cloud_registry_file "$sid")"
  local scratch=""
  if [[ -f "$primary" ]]; then
    scratch="$(jq -r '.scratch_dir // ""' "$primary" 2>/dev/null)"
  fi
  rm -f "$primary"
  if [[ -n "$scratch" ]] && [[ -d "$CLOUD_REGISTRY_DIR" ]]; then
    local other other_scratch
    for other in "$CLOUD_REGISTRY_DIR"/*.json; do
      [[ -f "$other" ]] || continue
      other_scratch="$(jq -r '.scratch_dir // ""' "$other" 2>/dev/null)"
      # Must use `if`, not `[[ ]] && rm` — the && short-circuit returns
      # non-zero when the test is false, and under `set -e` in callers
      # that becomes the function's exit code and kills the script.
      if [[ "$other_scratch" == "$scratch" ]]; then
        rm -f "$other"
      fi
    done
  fi
  return 0
}

# Wipe the local shadow for a session. Returns 0 unconditionally —
# cleanup operations must not trip `set -e` in callers.
cloud_wipe_scratch() {
  local sid="$1"
  [[ -z "$sid" ]] && return 0
  rm -rf "${CLOUD_SCRATCH_BASE}/${sid}"
  return 0
}

# ──────────────────────────────────────────────────────────────
# Cloud env + HTTP helpers
# ──────────────────────────────────────────────────────────────

cloud_require_env() {
  # Auth is currently disabled — session_id in the URL is the capability.
  # Only the server URL must be set, and it always is (baked-in default
  # at the top of this file; users can override by exporting
  # STAGENT_SERVER). This function stays in place so a future
  # multi-user auth layer can plug back in without touching callers.
  if [[ -z "${STAGENT_SERVER:-}" ]]; then
    echo "❌ STAGENT_SERVER unexpectedly empty" >&2
    return 1
  fi
  return 0
}

_cloud_server() {
  local sid="${1:-}"
  if [[ -n "$sid" ]]; then
    local s; s="$(cloud_registry_get "$sid" server)"
    [[ -n "$s" ]] && { echo "$s"; return; }
  fi
  echo "${STAGENT_SERVER:-}"
}

# Auth header for cloud requests. Two modes:
#
#   - Authenticated: ~/.config/stagent/auth.json exists with a `token`
#     field. We emit "Authorization: Bearer <token>" so the server can
#     attribute the request to the logged-in user and stamp user_id on
#     any rows it creates.
#
#   - Anonymous: no auth file. We emit a benign X-Stagent marker
#     so the curl -H argument is always well-formed (curl rejects empty
#     -H values). Server routes that don't require auth continue to
#     accept the request; routes that check user_id see NULL.
#
# To log in:  /stagent:login
# To log out: /stagent:logout
# Returns 0 if the user has a non-empty bearer token at
# ~/.config/stagent/auth.json (written by login-workflow.sh), else 1.
# Used by setup-workflow.sh to surface a "consider logging in" tip on
# anonymous cloud runs. Never errors; non-zero just means "not logged in".
cloud_is_logged_in() {
  local auth_file="${HOME}/.config/stagent/auth.json"
  [[ -f "$auth_file" ]] || return 1
  local token
  token="$(jq -r '.token // empty' "$auth_file" 2>/dev/null || true)"
  [[ -n "$token" ]]
}

# Translate a curl(1) exit code into a friendly, actionable message on
# stderr. Called by cloud-facing scripts (login, publish, fetch) when a
# curl invocation fails so users see guidance instead of raw
# "curl: (6) Could not resolve host" dumps.
#
# Usage: cloud_explain_curl_exit <exit_code> [server_url]
# Exit code 0 is a no-op; unknown codes fall back to a generic message.
cloud_explain_curl_exit() {
  local code="$1" server="${2:-the stagent server}"
  case "$code" in
    0)   return 0 ;;
    6)   echo "❌ Can't resolve ${server} — DNS lookup failed." >&2
         echo "   Check your internet connection, VPN, or DNS settings." >&2
         echo "   Try: ping ${server#https://} or switch DNS to 8.8.8.8" >&2 ;;
    7)   echo "❌ Can't connect to ${server} — connection refused." >&2
         echo "   The server may be down, or your firewall/VPN is blocking it." >&2 ;;
    28)  echo "❌ Connection to ${server} timed out." >&2
         echo "   Network is slow or unreachable. Retry in a moment." >&2 ;;
    35|56) echo "❌ TLS/connection reset by ${server}." >&2
         echo "   Often caused by unstable VPN or MTU issues. Retry, or toggle VPN off." >&2 ;;
    52)  echo "❌ Empty reply from ${server}." >&2
         echo "   The server accepted the connection but returned nothing. It may be restarting." >&2 ;;
    60)  echo "❌ TLS certificate verification failed for ${server}." >&2
         echo "   Check system clock and CA bundle. Corporate proxy may be MITMing." >&2 ;;
    *)   echo "❌ Network error contacting ${server} (curl exit ${code})." >&2
         echo "   Check your connection and try again." >&2 ;;
  esac
}

_cloud_auth_header() {
  local auth_file="${HOME}/.config/stagent/auth.json"
  if [[ -f "$auth_file" ]]; then
    local token
    token="$(jq -r '.token // empty' "$auth_file" 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      echo "Authorization: Bearer ${token}"
      return 0
    fi
  fi
  echo "X-Stagent: plugin"
}

# ──────────────────────────────────────────────────────────────
# Reliability primitives
# ──────────────────────────────────────────────────────────────
#
# Every mutating cloud call goes through one of these helpers so we get
# bounded retries + visible failure logging for free. Silent failures
# used to cause state drift (observed in prod: a cloud_post_state call
# at transition time failed once, got swallowed by `|| echo warning`,
# and the server sat on the old status for minutes until a separate
# call happened to converge it). These helpers fix that class of bug:
#
#   _cloud_curl_retry  — 2 attempts, 1s gap, 5s timeout each → ~11s worst
#                        case. Use for transitions where correctness is
#                        paramount (update-status.sh).
#   _cloud_curl_once   — 1 attempt, 3s timeout → ~3s worst case. Use for
#                        convergence loops that run frequently and can
#                        afford to miss a cycle (stop-hook reconcile).
#   _cloud_warn        — append timestamped message to the shadow's
#                        .sync-warnings.log + stderr. stop-hook tails
#                        the file and surfaces it via systemMessage so
#                        the user actually sees sync issues.

# Returns 0 on any 2xx, 1 otherwise. Discards response body.
# Usage: _cloud_curl_retry <method> <url> [additional curl args...]
_cloud_curl_retry() {
  local method="$1" url="$2"
  shift 2
  local attempt=1 max=2 delay=1
  local http_code
  while [[ $attempt -le $max ]]; do
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
                --max-time 5 \
                -X "$method" "$url" \
                -H "$(_cloud_auth_header)" \
                "$@" 2>/dev/null || echo "000")
    case "$http_code" in
      2*) return 0 ;;
    esac
    if [[ $attempt -lt $max ]]; then
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# Single attempt, short timeout. Same interface as _cloud_curl_retry.
_cloud_curl_once() {
  local method="$1" url="$2"
  shift 2
  local http_code
  http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
              --max-time 3 \
              -X "$method" "$url" \
              -H "$(_cloud_auth_header)" \
              "$@" 2>/dev/null || echo "000")
  case "$http_code" in
    2*) return 0 ;;
    *)  return 1 ;;
  esac
}

# Append a timestamped warning to the shadow's .sync-warnings.log and
# echo to stderr. Bounded to 100 lines so it can't grow unbounded.
# Callers: every cloud_post_* helper on final failure, and
# ensure_baseline_and_fingerprint / cloud_reconcile_state on notable events.
_cloud_warn() {
  local sid="$1" msg="$2"
  [[ -n "$msg" ]] || return 0
  echo "⚠️  [stagent cloud] $msg" >&2
  [[ -n "$sid" ]] || return 0
  local shadow; shadow="$(cloud_registry_get "$sid" scratch_dir)"
  [[ -z "$shadow" ]] && shadow="${CLOUD_SCRATCH_BASE}/${sid}"
  [[ -d "$shadow" ]] || return 0
  local log="${shadow}/.sync-warnings.log"
  printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$log"
  if [[ $(wc -l < "$log" 2>/dev/null || echo 0) -gt 100 ]]; then
    tail -100 "$log" > "${log}.tmp.$$" && mv "${log}.tmp.$$" "$log"
  fi
}

# POST JSON to an endpoint via the retry wrapper. Returns 0 on 2xx, 1 otherwise.
# No response body — routes are fire-and-forget by convention.
_cloud_post_json() {
  local url="$1" body="$2"
  _cloud_curl_retry POST "$url" \
    -H "Content-Type: application/json" \
    --data "$body"
}

# ──────────────────────────────────────────────────────────────
# Remote workflow config fetch
# ──────────────────────────────────────────────────────────────
#
# Supported forms (matches setup-workflow.sh --flow argument):
#   cloud://author/name  named template on $STAGENT_SERVER
#   /abs/path         local absolute path (copied verbatim)
#   bare name         resolved against PLUGIN_ROOT/skills/stagent/
#
# Destination is a local directory that setup-workflow.sh prepares — the
# scratch dir's .workflow-cache/ in cloud mode, or a fresh temp dir for
# local mode.

cloud_fetch_workflow_from_url() {
  local url="$1" dest="$2"
  mkdir -p "$dest"
  if ! curl -sS -fL -H "$(_cloud_auth_header)" -o "${dest}/workflow.json" "${url%/}/workflow.json"; then
    echo "❌ failed to fetch ${url%/}/workflow.json" >&2
    return 1
  fi
  if ! jq empty "${dest}/workflow.json" 2>/dev/null; then
    echo "❌ remote workflow.json is not valid JSON" >&2
    return 1
  fi
  local stages
  stages="$(jq -r '.stages | keys[]' "${dest}/workflow.json")"
  local stage
  while read -r stage; do
    [[ -z "$stage" ]] && continue
    if ! curl -sS -fL -H "$(_cloud_auth_header)" \
         -o "${dest}/${stage}.md" "${url%/}/${stage}.md"; then
      echo "⚠️  could not fetch ${stage}.md from ${url}" >&2
    fi
  done <<< "$stages"
  return 0
}

cloud_fetch_workflow_from_name() {
  local name="$1" dest="$2"
  cloud_require_env || return 1
  mkdir -p "$dest"
  local base="${STAGENT_SERVER}/api/workflows/${name}"
  local bundle
  local fetch_rc=0
  bundle="$(curl -sS -fL -H "$(_cloud_auth_header)" "$base" 2>/dev/null)" || fetch_rc=$?
  if [[ $fetch_rc -ne 0 ]]; then
    # curl exit 22 = server returned a 4xx/5xx under -f. Treat as "not found /
    # not authorized" with a specific hint; other codes are network problems.
    if [[ $fetch_rc -eq 22 ]]; then
      echo "❌ Workflow '${name}' not found on the hub (or you don't have access)." >&2
      echo "   Check the name, or run /stagent:login if it's private." >&2
    else
      cloud_explain_curl_exit "$fetch_rc" "$STAGENT_SERVER"
    fi
    return 1
  fi
  printf '%s' "$bundle" | jq '.workflow' > "${dest}/workflow.json"
  # Write each file directly from the bundle — no secondary HTTP requests needed.
  local fnames
  fnames="$(printf '%s' "$bundle" | jq -r '.files | keys[]?')"
  local fname
  while read -r fname; do
    [[ -z "$fname" ]] && continue
    printf '%s' "$bundle" | jq -r --arg f "$fname" '.files[$f]' > "${dest}/${fname}"
  done <<< "$fnames"
  return 0
}

# ──────────────────────────────────────────────────────────────
# Cloud state / artifact sync
# ──────────────────────────────────────────────────────────────

# POST /api/sessions/<sid>/setup — initial workflow registration.
# Arguments:
#   $1 = session_id
#   $2 = topic
#   $3 = resolved workflow dir (must contain workflow.json + *.md)
#   $4 = workflow_url (may be empty)
#   $5 = project_root
#   $6 = worktree
#   $7 = force (true|false)
cloud_post_setup() {
  local sid="$1" topic="$2" wfdir="$3" wfurl="$4" proot="$5" wtree="$6" force="$7"
  cloud_require_env || return 1

  local wfjson="${wfdir}/workflow.json"
  [[ -f "$wfjson" ]] || { echo "❌ missing ${wfjson}" >&2; return 1; }

  # Build { "<stage>.md": "<contents>" } map for all .md files next to workflow.json.
  local files_json="{}"
  local f
  for f in "$wfdir"/*.md; do
    [[ -f "$f" ]] || continue
    local name content
    name="$(basename "$f")"
    content="$(cat "$f")"
    files_json="$(jq -n --argjson base "$files_json" --arg k "$name" --arg v "$content" \
                  '$base + {($k): $v}')"
  done

  local wfval; wfval="$(cat "$wfjson")"
  local payload
  payload="$(jq -n \
      --arg topic "$topic" \
      --argjson workflow "$wfval" \
      --argjson files "$files_json" \
      --arg url "$wfurl" \
      --arg proot "$proot" \
      --arg wtree "$wtree" \
      --argjson force "$force" \
      '{
        topic: $topic,
        workflow: $workflow,
        workflow_files: $files,
        workflow_url: (if $url == "" then null else $url end),
        project_root: (if $proot == "" then null else $proot end),
        worktree: (if $wtree == "" then null else $wtree end),
        force: $force
      }')"

  _cloud_post_json "${STAGENT_SERVER}/api/sessions/${sid}/setup" "$payload"
}

cloud_post_state() {
  local sid="$1" status="$2" epoch="$3" resume="${4:-}" active="${5:-true}" project_root="${6:-}" fingerprint="${7:-}"
  cloud_require_env || return 1
  local payload
  payload="$(jq -n \
      --arg status "$status" \
      --argjson epoch "${epoch:-1}" \
      --arg resume "$resume" \
      --argjson active "$active" \
      --arg pr "$project_root" \
      --arg fpr "$fingerprint" \
      '{
        status: $status,
        epoch: $epoch,
        resume_status: (if $resume == "" then null else $resume end),
        active: $active
      }
      + (if $pr  == "" then {} else {project_root: $pr} end)
      + (if $fpr == "" then {} else {project_fingerprint: $fpr} end)')"
  if ! _cloud_post_json "${STAGENT_SERVER}/api/sessions/${sid}/state" "$payload"; then
    _cloud_warn "$sid" "cloud_post_state failed after retries: status=${status} epoch=${epoch}"
    return 1
  fi
  return 0
}

# Partial state update — PATCH-style POST carrying only awaiting_user.
# The webapp's /api/sessions/<id>/state handler uses `body.field ??
# current` semantics so omitted fields are preserved. We exploit that
# to flip just the awaiting flag without re-sending the whole snapshot
# (which would mean recomputing active/project_root/fingerprint every
# time the stop hook fires).
cloud_post_awaiting_user() {
  local sid="$1" awaiting="$2"
  cloud_require_env || return 1
  # Coerce to JSON boolean literal.
  case "$awaiting" in
    true|TRUE|1|yes) awaiting=true ;;
    *)               awaiting=false ;;
  esac
  local payload
  payload="$(jq -n --argjson a "$awaiting" '{awaiting_user: $a}')"
  if ! _cloud_post_json "${STAGENT_SERVER}/api/sessions/${sid}/state" "$payload"; then
    _cloud_warn "$sid" "cloud_post_awaiting_user failed: awaiting=${awaiting}"
    return 1
  fi
  return 0
}

# ──────────────────────────────────────────────────────────────
# Project identity (git root-commit fingerprint)
# ──────────────────────────────────────────────────────────────
#
# We use the set of root commits (`git rev-list --max-parents=0 HEAD`)
# as a stable, language-agnostic identifier for "this is the same
# project". Two clones of the same repo share a root commit; two
# unrelated repos cannot. The check is meant to catch the case where
# a user resumes a workflow from the wrong directory — not to verify
# that HEAD matches, so different revisions are allowed.

git_project_fingerprint() {
  local dir="${1:-.}"
  # Not a git repo at all → empty fingerprint, success exit.
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { echo ""; return 0; }
  # Git repo with no commits yet (fresh `git init` before first commit):
  # rev-list on HEAD would fail with exit 128, which combined with
  # `set -o pipefail` propagates a non-zero status to the caller and
  # — under `set -e` in setup-workflow.sh — would silently kill the
  # whole script. Detect the no-HEAD case explicitly and return an
  # empty fingerprint (success exit) so callers skip the verification.
  git -C "$dir" rev-parse HEAD >/dev/null 2>&1 || { echo ""; return 0; }
  git -C "$dir" rev-list --max-parents=0 HEAD 2>/dev/null \
    | sort | tr '\n' ',' | sed 's/,$//'
}

# Compare the current CWD's fingerprint with the one recorded in the
# given state.md. Return codes:
#   0 → match, or either side has no fingerprint (skip — nothing to verify)
#   1 → mismatch: both sides have git but root commits differ
#   2 → mismatch: state.md has a fingerprint but the current dir is not git
verify_project_match() {
  local state_file="$1"
  local cwd="${2:-$(pwd)}"
  local expected; expected="$(_read_fm_field "$state_file" project_fingerprint)"
  [[ -z "$expected" ]] && return 0
  [[ "$expected" == "EMPTY" ]] && return 0
  local actual; actual="$(git_project_fingerprint "$cwd")"
  if [[ -z "$actual" ]]; then
    return 2
  fi
  if [[ "$actual" != "$expected" ]]; then
    return 1
  fi
  return 0
}

cloud_post_artifact() {
  local sid="$1" stage="$2" file="$3"
  cloud_require_env || return 1
  if [[ ! -f "$file" ]]; then
    _cloud_warn "$sid" "cloud_post_artifact: file not found: $file"
    return 1
  fi
  if ! _cloud_curl_retry POST \
        "${STAGENT_SERVER}/api/sessions/${sid}/artifacts/${stage}" \
        -H "Content-Type: text/plain" \
        --data-binary "@${file}"; then
    local bytes; bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
    _cloud_warn "$sid" "cloud_post_artifact failed after retries: stage=${stage} bytes=${bytes}"
    return 1
  fi
  return 0
}

# Write a machine-generated terminal summary to `dest` when the main
# agent didn't produce one. Data-driven (no LLM): topic, timing, live
# URL, and the latest artifact per stage as seen on the server. Carries
# a visible disclaimer so users can tell it apart from a human summary.
#
# Usage:
#   synthesize_terminal_report \
#     <dest_path> <sid> <topic> <terminal> <outgoing_stage> \
#     <final_epoch> <started_at> <workflow_url>
synthesize_terminal_report() {
  local dest="$1"
  local sid="$2"
  local topic="$3"
  local terminal="$4"
  local outgoing="$5"
  local epoch="$6"
  local started_at="$7"
  local workflow_url="$8"

  local now server live_url artifacts_list snap
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  server="${STAGENT_SERVER:-}"
  live_url="-"
  [[ -n "$server" ]] && live_url="${server}/s/${sid}"

  artifacts_list=""
  if [[ -n "$server" ]]; then
    snap="$(curl -sS -m 5 -H "$(_cloud_auth_header)" \
      "${server}/api/sessions/${sid}" 2>/dev/null || echo '{}')"
    artifacts_list="$(printf '%s' "$snap" | jq -r '
      .artifacts[]? |
      "- **" + .stage + "** — epoch " + (.epoch|tostring) +
      ", result `" + (.result // "—") + "`, " +
      ((.content | length) | tostring) + " bytes"' 2>/dev/null)"
  fi
  [[ -z "$artifacts_list" ]] && artifacts_list="- _(no artifacts visible on server)_"

  cat > "$dest" <<EOF
---
epoch: ${epoch}
result: ${terminal}
---
# ${terminal} — auto-generated run summary

> ⚠️  This summary was **auto-generated** by \`update-status.sh\` because
> the main agent did not write \`${terminal}-report.md\` before the
> terminal transition. A richer, human-written summary belongs here
> whenever possible — the content below is strictly what the state
> machine itself can observe.

## Run metadata

| Field | Value |
|---|---|
| Topic | ${topic:-?} |
| Workflow | ${workflow_url:-default} |
| Session | ${sid} |
| Started | ${started_at:-?} |
| Ended | ${now} |
| Final epoch | ${epoch} |
| Transitioned from | ${outgoing:-?} |
| Terminal | ${terminal} |

## Latest artifact per stage

${artifacts_list}

## Live view

${live_url}

## Note

The agent did not provide a human-friendly summary for this run.
Open the live view above and browse each stage's artifact for the
actual content.
EOF
}

cloud_delete_artifact() {
  local sid="$1" stage="$2"
  cloud_require_env || return 1
  if ! _cloud_curl_retry DELETE \
        "${STAGENT_SERVER}/api/sessions/${sid}/artifacts/${stage}"; then
    _cloud_warn "$sid" "cloud_delete_artifact failed after retries: stage=${stage}"
    return 1
  fi
  return 0
}

cloud_post_archive() {
  local sid="$1"
  cloud_require_env || return 1
  if ! _cloud_curl_retry POST "${STAGENT_SERVER}/api/sessions/${sid}/archive"; then
    _cloud_warn "$sid" "cloud_post_archive failed after retries"
    return 1
  fi
  return 0
}

cloud_post_cancel() {
  local sid="$1"
  cloud_require_env || return 1
  if ! _cloud_curl_retry POST "${STAGENT_SERVER}/api/sessions/${sid}/cancel"; then
    _cloud_warn "$sid" "cloud_post_cancel failed after retries"
    return 1
  fi
  return 0
}

# Check whether the server still considers $sid an active workflow.
# Echoes one of: 'active', 'inactive' (terminal or archived), 'missing'
# (404), 'unknown' (network / non-2xx). Used by cancel-workflow.sh's
# fallback path to decide whether to fire a server-side cancel when no
# local shadow exists for the session.
cloud_session_status_class() {
  local sid="$1"
  cloud_require_env || { echo "unknown"; return 1; }
  if [[ -z "$sid" ]]; then
    echo "missing"
    return 1
  fi
  local body http
  body="$(mktemp -t dw-status-XXXXXX)"
  http="$(curl -sS -o "$body" -w "%{http_code}" --max-time 5 \
    -H "$(_cloud_auth_header)" \
    "${STAGENT_SERVER}/api/sessions/${sid}" 2>/dev/null)" || http="000"
  case "$http" in
    404) rm -f "$body"; echo "missing"; return 0 ;;
    200) ;;
    *)   rm -f "$body"; echo "unknown"; return 1 ;;
  esac
  local active archived
  active="$(jq -r '.session.active // false' "$body" 2>/dev/null)"
  archived="$(jq -r '.session.archived_at // empty' "$body" 2>/dev/null)"
  rm -f "$body"
  if [[ "$active" == "true" ]] && [[ -z "$archived" ]]; then
    echo "active"
  else
    echo "inactive"
  fi
  return 0
}

cloud_delete_session() {
  local sid="$1"
  cloud_require_env || return 1
  if ! _cloud_curl_retry DELETE "${STAGENT_SERVER}/api/sessions/${sid}"; then
    _cloud_warn "$sid" "cloud_delete_session failed after retries"
    return 1
  fi
  return 0
}

# ──────────────────────────────────────────────────────────────
# Cross-machine takeover
# ──────────────────────────────────────────────────────────────
#
# Rebuild a full local shadow for a cloud session by pulling every
# artifact, workflow file, state field, and baseline from the server.
# Used by continue-workflow.sh when the user runs `/stagent:continue
# --session <id>` on a machine that has never seen this session before.
#
# Side effects:
#   Wipes and recreates ${CLOUD_SCRATCH_BASE}/<sid>/ with state.md,
#   baseline, every <stage>-report.md present on the server, and a
#   .workflow-cache/ populated from the server's workflow_files.
# Does NOT register the session — callers decide which key(s) to write.
# On success: echoes the absolute scratch dir path and returns 0.
# On failure: prints error to stderr and returns non-zero.
cloud_pull_shadow() {
  local sid="$1"
  cloud_require_env || return 1
  if [[ -z "$sid" ]]; then
    echo "❌ cloud_pull_shadow: session_id required" >&2
    return 1
  fi

  local _pull_tmp _pull_http
  _pull_tmp="$(mktemp -t dw-pull-XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$_pull_tmp'" RETURN
  _pull_http="$(curl -sS -o "$_pull_tmp" -w "%{http_code}" \
      -H "$(_cloud_auth_header)" \
      "${STAGENT_SERVER}/api/sessions/${sid}" 2>/dev/null)" || _pull_http="000"
  if [[ "$_pull_http" == "404" ]]; then
    echo "❌ session ${sid} was deleted from the server (HTTP 404)" >&2
    return 2
  fi
  if [[ "$_pull_http" != "200" ]]; then
    echo "❌ could not fetch session ${sid} from server (HTTP ${_pull_http})" >&2
    return 1
  fi
  local snapshot
  snapshot="$(cat "$_pull_tmp")"
  if ! printf '%s' "$snapshot" | jq empty 2>/dev/null; then
    echo "❌ server returned non-JSON for session ${sid}" >&2
    return 1
  fi
  if [[ "$(printf '%s' "$snapshot" | jq 'has("session")')" != "true" ]]; then
    echo "❌ session ${sid} not found on server" >&2
    return 1
  fi

  local shadow="${CLOUD_SCRATCH_BASE}/${sid}"
  rm -rf "$shadow"
  mkdir -p "${shadow}/.workflow-cache"

  # workflow.json
  printf '%s' "$snapshot" | jq '.workflow' > "${shadow}/.workflow-cache/workflow.json"

  # Per-stage workflow files — fetched individually since the snapshot
  # only lists filenames (content lives behind GET /api/.../files/<name>).
  local fname
  while read -r fname; do
    [[ -z "$fname" ]] && continue
    curl -sS -fL -H "$(_cloud_auth_header)" \
      -o "${shadow}/.workflow-cache/${fname}" \
      "${STAGENT_SERVER}/api/sessions/${sid}/files/${fname}" 2>/dev/null || {
      echo "⚠️  could not fetch workflow file ${fname}" >&2
    }
  done < <(printf '%s' "$snapshot" | jq -r '.workflow_files[]?.filename')

  # Artifacts — written to <stage>-report.md with frontmatter intact.
  local count i=0
  count="$(printf '%s' "$snapshot" | jq '.artifacts | length')"
  while [[ $i -lt $count ]]; do
    local stage content
    stage="$(printf '%s' "$snapshot" | jq -r ".artifacts[$i].stage")"
    content="$(printf '%s' "$snapshot" | jq -r ".artifacts[$i].content")"
    if [[ -n "$stage" ]] && [[ "$content" != "null" ]]; then
      printf '%s' "$content" > "${shadow}/${stage}-report.md"
    fi
    i=$((i + 1))
  done

  # state.md — rebuilt from the snapshot's session row. Keeps the
  # server-side session_id so cloud_post_* helpers target the same row.
  local topic status epoch resume project_root fingerprint worktree workflow_url
  topic="$(printf '%s' "$snapshot" | jq -r '.session.topic // ""')"
  status="$(printf '%s' "$snapshot" | jq -r '.session.status // ""')"
  epoch="$(printf '%s' "$snapshot" | jq -r '.session.epoch // 1')"
  resume="$(printf '%s' "$snapshot" | jq -r '.session.resume_status // ""')"
  project_root="$(printf '%s' "$snapshot" | jq -r '.session.project_root // ""')"
  fingerprint="$(printf '%s' "$snapshot" | jq -r '.session.project_fingerprint // ""')"
  worktree="$(printf '%s' "$snapshot" | jq -r '.session.worktree // ""')"
  workflow_url="$(printf '%s' "$snapshot" | jq -r '.session.workflow_url // ""')"

  cat > "${shadow}/state.md" <<EOF
---
active: true
status: $status
epoch: $epoch
resume_status: $resume
topic: "$topic"
session_id: $sid
worktree: "$worktree"
workflow_dir: "${shadow}/.workflow-cache"
project_root: "$project_root"
project_fingerprint: $fingerprint
mode: cloud
pulled_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

  # Baseline — pulled from /diff endpoint so cloud_post_diff on this
  # machine produces diffs against the same reference the original
  # machine used.
  local diff_resp baseline
  diff_resp="$(curl -sS -fL -H "$(_cloud_auth_header)" \
               "${STAGENT_SERVER}/api/sessions/${sid}/diff" 2>/dev/null || echo "{}")"
  baseline="$(printf '%s' "$diff_resp" | jq -r '.baseline // ""')"
  if [[ -n "$baseline" ]] && [[ "$baseline" != "null" ]]; then
    echo "$baseline" > "${shadow}/baseline"
  else
    echo "EMPTY" > "${shadow}/baseline"
  fi

  # run_files — restore the captured setup-time values so Claude has the
  # same context on this machine as on the original. Stored in
  # session.run_files as { name: content } in the server snapshot.
  local run_files_json
  run_files_json="$(printf '%s' "$snapshot" | jq -c '.session.run_files // empty' 2>/dev/null || true)"
  if [[ -n "$run_files_json" ]] && [[ "$run_files_json" != "null" ]]; then
    local rf_name rf_content
    while IFS= read -r rf_name; do
      [[ -z "$rf_name" ]] && continue
      rf_content="$(printf '%s' "$run_files_json" | jq -r --arg k "$rf_name" '.[$k] // ""')"
      printf '%s' "$rf_content" > "${shadow}/${rf_name}"
    done < <(printf '%s' "$run_files_json" | jq -r 'keys[]')
  fi

  echo "$shadow"
  return 0
}

# Capture the working-tree diff against the session's baseline SHA and
# upload it to the server. Called from setup (initial empty diff),
# update-status (every transition), and stop-hook reconcile.
#
# If the project was pre-git at setup time (baseline=EMPTY, fingerprint
# empty) but now has git, backfill them first via
# ensure_baseline_and_fingerprint — that's how a workflow that starts in
# a fresh dir and later gets `git init`'d picks up diffs automatically.
#
# All branches are best-effort: missing git, missing baseline, or a
# failed POST just logs a warning and returns — never blocks the workflow.
cloud_post_diff() {
  local sid="$1"
  cloud_require_env || return 1

  local shadow="${CLOUD_SCRATCH_BASE}/${sid}"
  [[ -d "$shadow" ]] || return 0

  # Workflows that don't touch the worktree (e.g. create-workflow, which
  # writes to ~/.config/stagent/) opt out of the diff pipeline.
  # The UI renders a placeholder for these sessions instead of a noisy
  # full-worktree diff.
  if [[ "$(_session_modifies_worktree "$shadow")" == "false" ]]; then
    return 0
  fi

  # Try to backfill baseline/fingerprint if the project became git since setup.
  if [[ -f "${shadow}/state.md" ]]; then
    ensure_baseline_and_fingerprint "${shadow}/state.md" || true
  fi

  local baseline_file="${shadow}/baseline"
  [[ -f "$baseline_file" ]] || return 0
  local baseline; baseline="$(cat "$baseline_file" 2>/dev/null)"
  [[ -z "$baseline" ]] && return 0
  [[ "$baseline" == "EMPTY" ]] && return 0

  local proot=""
  if [[ -f "${shadow}/state.md" ]]; then
    proot="$(_read_fm_field "${shadow}/state.md" project_root)"
  fi
  [[ -z "$proot" ]] && return 0

  git -C "$proot" rev-parse --git-dir >/dev/null 2>&1 || return 0

  local head diff diff_ref="$baseline" current_tree=""
  head="$(git -C "$proot" rev-parse HEAD 2>/dev/null || echo "")"

  # Prefer the baseline-tree snapshot (captures worktree state at
  # workflow start, including uncommitted pre-existing files). Falls
  # back to the commit baseline if the tree was never captured
  # (legacy sessions) or has been GC'd.
  if [[ -s "${shadow}/baseline-tree" ]]; then
    local btree
    btree="$(cat "${shadow}/baseline-tree" 2>/dev/null || true)"
    if [[ -n "$btree" ]] && git -C "$proot" cat-file -e "${btree}^{tree}" 2>/dev/null; then
      diff_ref="$btree"
      # Compute a matching "current" tree via the same temp-index pattern
      # so the diff includes untracked-but-unignored files that appeared
      # since baseline. `git diff <tree>` against the worktree ignores
      # untracked files, which would hide workflow-created new files.
      local cur_idx="${shadow}/.current-index.tmp"
      if git -C "$proot" read-tree --index-output="$cur_idx" HEAD 2>/dev/null; then
        # Scope to project_root via `-- .` and tolerate per-path errors
        # via `--ignore-errors` — same reasoning as _capture_baseline_tree.
        # We deliberately don't gate write-tree on add's exit code:
        # partial-tree current is still useful for diffing.
        GIT_INDEX_FILE="$cur_idx" git -C "$proot" add -A --ignore-errors -- . 2>/dev/null || true
        current_tree="$(GIT_INDEX_FILE="$cur_idx" git -C "$proot" write-tree 2>/dev/null || true)"
        # Narrow current_tree to project_root subtree so it matches the
        # (also-narrowed) baseline-tree. Without this, baseline is a
        # subtree but current is whole-repo and the diff is incoherent
        # (every sibling-project file shows as "added"). Falls back to
        # whole tree if narrowing fails.
        if [[ -n "$current_tree" ]] && [[ "$current_tree" =~ ^[0-9a-f]{40}$ ]]; then
          local cur_proj
          cur_proj="$(_extract_project_subtree "$proot" "$current_tree")"
          [[ -n "$cur_proj" && "$cur_proj" =~ ^[0-9a-f]{40}$ ]] && current_tree="$cur_proj"
        fi
      fi
      rm -f "$cur_idx"
    fi
  fi

  # Denylist of path patterns that are tool-level state / unrelated
  # subprojects, not workflow output. Applied to every diff computation
  # so monorepos and projects that run multiple CC/OMC-family tools
  # don't pollute the panel. The list is intentionally small and named
  # — blanket-excluding all `.xxx` would also hide legitimate config
  # edits like .github/, .eslintrc*, .env.example, .gitignore, etc.
  # Future work: expose `diff_exclude` in workflow.json for user overrides.
  # CRITICAL: `:(top)` magic anchors the pathspec to the repo root, not the
  # $proot passed to `git -C`. When project_root is a monorepo subdir (e.g.
  # /Users/jie/code/snake2 within /Users/jie/code/.git), plain `:(exclude).omc`
  # would only match `snake2/.omc/`, missing the root-level `.omc/` that's
  # actually producing the noise. `:(top)` + `:(top,glob)` together cover
  # both the repo root and any nested occurrence.
  local -a DIFF_EXCLUDES=(
    ':(top,exclude).stagent' ':(top,exclude).stagent/**'
    ':(top,exclude,glob)**/.stagent/**'
    ':(top,exclude).omc' ':(top,exclude).omc/**'
    ':(top,exclude,glob)**/.omc/**'
    ':(top,exclude).omx' ':(top,exclude).omx/**'
    ':(top,exclude,glob)**/.omx/**'
    ':(top,exclude).playwright-mcp' ':(top,exclude).playwright-mcp/**'
    ':(top,exclude,glob)**/.playwright-mcp/**'
  )

  if [[ -n "$current_tree" ]] && [[ "$current_tree" =~ ^[0-9a-f]{40}$ ]]; then
    # Tree-to-tree diff — includes untracked (because they were staged
    # into the temp index on both sides). `--ignore-submodules=all`
    # drops submodule pointer changes, which are almost always noise
    # from unrelated activity in another repo.
    diff="$(git -C "$proot" diff --no-color --ignore-submodules=all \
            "$diff_ref" "$current_tree" -- "${DIFF_EXCLUDES[@]}" 2>/dev/null || echo "")"
  else
    # Legacy path: commit-ish baseline vs worktree, misses untracked.
    diff="$(git -C "$proot" diff --no-color --ignore-submodules=all \
            "$diff_ref" -- "${DIFF_EXCLUDES[@]}" 2>/dev/null || echo "")"
  fi

  # Dedup: postwrite-hook fires on every Write/Edit, which would spam the
  # server with identical diffs if the write didn't actually change anything
  # relevant (e.g. touched a file but kept the content). Key on
  # (baseline, current_tree) so any worktree-content shift busts the cache
  # while no-op turns stay silent. Tracker lives in the shadow; wiped on
  # terminal along with the rest.
  local dedup_key="${baseline}:${current_tree:-none}"
  local dedup_file="${shadow}/.last-posted-tree"
  if [[ -f "$dedup_file" ]]; then
    local last_key
    last_key="$(cat "$dedup_file" 2>/dev/null || true)"
    if [[ "$last_key" == "$dedup_key" ]]; then
      return 0
    fi
  fi

  local payload
  payload="$(jq -n \
      --arg baseline "$baseline" \
      --arg head "$head" \
      --arg content "$diff" \
      '{baseline: $baseline, head: $head, content: $content}')"

  if ! _cloud_post_json "${STAGENT_SERVER}/api/sessions/${sid}/diff" "$payload"; then
    _cloud_warn "$sid" "cloud_post_diff failed after retries: baseline=${baseline:0:10} head=${head:0:10}"
    return 1
  fi
  # Only update the dedup marker AFTER a successful POST, so a failed
  # POST doesn't lock us out of retrying with the same content.
  printf '%s' "$dedup_key" > "$dedup_file"
  return 0
}

# POST a tool-use activity log entry to the server. Always runs in the
# background — exits instantly, curl completes asynchronously. Uses a
# 1-second hard timeout so a flaky network can't stall the agent.
# Returns 0 unconditionally (fire-and-forget; failures are silent).
cloud_post_activity() {
  # Args (positional):
  #   1 sid, 2 stage, 3 epoch, 4 tool, 5 summary,
  #   6 tool_input_json (raw JSON string — may be empty),
  #   7 tool_result_json (raw JSON string — may be empty),
  #   8 is_error ("true" / "false" / empty)
  #
  # Extra fields are optional for backward compat; callers that only
  # pass 1-5 still work (legacy activity recording with summary only).
  local sid="$1" stage="$2" epoch="$3" tool="$4" summary="$5"
  local tin="${6:-}" tres="${7:-}" ierr="${8:-false}"
  cloud_require_env 2>/dev/null || return 0
  local server; server="$(_cloud_server "$sid")"
  [[ -z "$server" ]] && return 0
  # Default unset JSON payloads to null (valid JSON); validate each
  # arg parses so a broken caller can't poison the server row.
  [[ -z "$tin"  ]] || echo "$tin"  | jq -e . >/dev/null 2>&1 || tin=""
  [[ -z "$tres" ]] || echo "$tres" | jq -e . >/dev/null 2>&1 || tres=""
  [[ "$ierr" == "true" || "$ierr" == "false" ]] || ierr="false"
  local payload
  payload="$(jq -n \
      --arg stage   "$stage" \
      --arg tool    "$tool" \
      --arg summary "$summary" \
      --argjson epoch "${epoch:-0}" \
      --argjson input  "${tin:-null}" \
      --argjson result "${tres:-null}" \
      --argjson is_error "$ierr" \
      '{stage: $stage, tool: $tool, summary: $summary, epoch: $epoch,
        tool_input: $input, tool_result: $result, is_error: $is_error}')" || return 0
  curl -sS --max-time 1 \
    -X POST "${server}/api/sessions/${sid}/activity" \
    -H "Content-Type: application/json" \
    -H "$(_cloud_auth_header)" \
    --data "$payload" \
    >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# Record the prompt context a workflow subagent received for a
# specific (stage, epoch) run. The webapp surfaces this under the
# "Runtime prompt" panel.
#
# Synchronous by design: the sole caller (subagent-bootstrap.sh)
# passes a `--data-binary @<tmp_file>` payload and then exits,
# clearing the tmp file via its EXIT trap. A backgrounded curl
# would race the trap and lose the file mid-read. A short blocking
# POST (max-time 3s) is acceptable — this fires at most once per
# subagent dispatch, not per tool call.
#
# Args: sid stage epoch prompt_file
cloud_post_stage_prompt() {
  local sid="$1" stage="$2" epoch="$3" prompt_file="$4"
  cloud_require_env 2>/dev/null || return 0
  local server; server="$(_cloud_server "$sid")"
  [[ -z "$server" ]] && return 0
  [[ -f "$prompt_file" ]] || return 0
  local url="${server}/api/sessions/${sid}/stage-prompts/${stage}?epoch=${epoch:-0}"
  curl -sS --max-time 3 \
    -X POST "$url" \
    -H "Content-Type: text/plain" \
    -H "$(_cloud_auth_header)" \
    --data-binary "@${prompt_file}" \
    >/dev/null 2>&1 || true
  return 0
}

# ──────────────────────────────────────────────────────────────
# Deferred baseline / fingerprint backfill
# ──────────────────────────────────────────────────────────────
#
# setup-workflow.sh records baseline + project_fingerprint from the git
# state at setup time. If the project is pre-git then (e.g. a greenfield
# scaffold that will `git init` a few minutes later), both get recorded
# as EMPTY / empty. Without backfill, cloud_post_diff would short-circuit
# forever — the UI would show an empty diff panel for the entire run and
# cross-machine continue would skip the verify check.
#
# This helper re-reads the project each time it's called; once git shows
# up, it writes the real values into state.md + the baseline file and
# (in cloud mode) pushes the updated fingerprint to the server so
# verify_project_match works on future resume.
#
# Snapshot the project's worktree as a dangling tree object so the
# diff panel can render "changes since workflow start" precisely,
# including pre-existing uncommitted state at t=0.
#
# Without this, cloud_post_diff runs `git diff $baseline` (baseline is
# a commit SHA) which also includes uncommitted changes that existed
# BEFORE the session started — those get mis-attributed to the workflow.
#
# Strategy: seed a temporary index from HEAD, stage the entire worktree
# into it (respecting .gitignore), write-tree to get a tree SHA. The
# tree is a dangling object — no ref, no branch, no HEAD change. The
# user's real index / stash / branches are completely untouched. Default
# `git gc --auto` prunes unreachable objects after gc.pruneExpire (2
# weeks default), which is slack enough for any sane workflow lifetime.
#
# User-visible footprint in their repo: a single tree object + blobs
# for any new-since-HEAD content. No ref, no branch, no HEAD change.
# `git status` / `git log` / `git branch` / `git stash list` are all
# unaffected.
#
# Resolve modifies_worktree for an in-flight session by reading its
# workflow.json via state.md.workflow_dir. Used by cloud_post_diff and
# ensure_baseline_and_fingerprint where CONFIG_FILE isn't guaranteed
# to point at the session's own workflow.
_session_modifies_worktree() {
  local shadow="$1"
  local state_file="${shadow}/state.md"
  [[ -f "$state_file" ]] || { echo "true"; return 0; }
  local wf_dir
  wf_dir="$(_read_fm_field "$state_file" workflow_dir 2>/dev/null)"
  [[ -z "$wf_dir" ]] && { echo "true"; return 0; }
  local cfg="${wf_dir}/workflow.json"
  [[ -f "$cfg" ]] || { echo "true"; return 0; }
  local v
  # Raw read (no `//` — see config_modifies_worktree comment).
  v="$(jq -r '.modifies_worktree' "$cfg" 2>/dev/null)"
  case "$v" in
    false) echo "false" ;;
    *) echo "true" ;;
  esac
}

# Given a whole-repo tree SHA and the project_root path, return the tree
# SHA representing only the project_root subtree. The returned SHA's
# entries are relative to project_root (so paths look like "src/App.jsx",
# not "diary2/src/App.jsx") — which is exactly what every downstream
# consumer (cloud_post_diff, audit stages, terminal summaries) needs to
# scope output to the project. Reuses the parent repo's object store via
# `git rev-parse <tree>:<path>`; produces no new git state.
#
# Echoes the subtree SHA on success. On failure or when narrowing is a
# no-op (project_root == repo_root, no .git, malformed input), echoes
# the input tree unchanged so the caller can fall back gracefully.
_extract_project_subtree() {
  local proot="$1" whole_tree="$2"
  [[ -z "$whole_tree" || ! "$whole_tree" =~ ^[0-9a-f]{40}$ ]] && { echo "$whole_tree"; return 0; }
  [[ -z "$proot" ]] && { echo "$whole_tree"; return 0; }

  local repo_root
  repo_root="$(git -C "$proot" rev-parse --show-toplevel 2>/dev/null)" || { echo "$whole_tree"; return 0; }
  [[ -z "$repo_root" ]] && { echo "$whole_tree"; return 0; }

  # project_root == repo_root: whole tree IS the project tree.
  if [[ "$proot" == "$repo_root" ]]; then
    echo "$whole_tree"; return 0
  fi

  # Compute the project's path relative to the repo root, stripping any
  # trailing slash. If the prefix-strip is a no-op (proot wasn't actually
  # under repo_root, e.g. via symlink), `rev-parse` will fail and we fall
  # back to the whole tree.
  local proj_rel="${proot#$repo_root/}"
  proj_rel="${proj_rel%/}"
  if [[ -z "$proj_rel" || "$proj_rel" == "$proot" ]]; then
    echo "$whole_tree"; return 0
  fi

  local sub
  sub="$(git -C "$proot" rev-parse "${whole_tree}:${proj_rel}" 2>/dev/null || true)"
  if [[ -n "$sub" && "$sub" =~ ^[0-9a-f]{40}$ ]]; then
    echo "$sub"
  else
    # Path missing in tree (e.g. project_root is a brand-new dir not yet
    # in HEAD and somehow not picked up by add -A). Degrade to whole tree.
    echo "$whole_tree"
  fi
}

# Idempotent: no-op if $shadow/baseline-tree already exists and is
# non-empty. Best-effort: bails quietly on missing git / missing HEAD.
# Callers are responsible for gating on config_modifies_worktree /
# _session_modifies_worktree — this helper does not read config itself.
_capture_baseline_tree() {
  local shadow="$1" proot="$2"
  local tree_file="${shadow}/baseline-tree"
  local sid; sid="$(basename "$shadow" 2>/dev/null)"
  # Idempotent no-op — already captured. No _cloud_warn here; this fires
  # once per stop-hook and would spam the log.
  [[ -s "$tree_file" ]] && return 0
  if [[ ! -d "$shadow" ]]; then
    _cloud_warn "$sid" "_capture_baseline_tree: shadow dir missing ($shadow)"
    return 0
  fi
  if ! git -C "$proot" rev-parse --git-dir >/dev/null 2>&1; then
    _cloud_warn "$sid" "_capture_baseline_tree: not a git repo ($proot)"
    return 0
  fi
  if ! git -C "$proot" rev-parse HEAD >/dev/null 2>&1; then
    _cloud_warn "$sid" "_capture_baseline_tree: no HEAD commit ($proot)"
    return 0
  fi

  local tmp_index="${shadow}/.baseline-index.tmp"
  # Seed the temp index from HEAD so tracked-file metadata is correct.
  if ! git -C "$proot" read-tree --index-output="$tmp_index" HEAD 2>/dev/null; then
    _cloud_warn "$sid" "_capture_baseline_tree: read-tree failed"
    rm -f "$tmp_index"
    return 0
  fi
  # Stage worktree files into the temp index, scoped to project_root
  # via the `-- .` pathspec. Without scoping, `git add -A` walks the
  # entire git repo: when project_root is a subdir (monorepo or a
  # junk-drawer repo at $HOME/code/), a single broken nested repo in
  # an unrelated sibling dir can fail the whole add and we'd lose the
  # baseline-tree (downstream falls back to a path that misses
  # untracked files). `--ignore-errors` keeps partial progress if a
  # nested repo INSIDE project_root itself is broken — coarse baseline
  # beats no baseline.
  local add_ok=1
  if ! GIT_INDEX_FILE="$tmp_index" git -C "$proot" add -A --ignore-errors -- . 2>/dev/null; then
    add_ok=0
    _cloud_warn "$sid" "_capture_baseline_tree: add -A had errors; using partial / HEAD-only tree"
  fi
  local tree_sha
  tree_sha="$(GIT_INDEX_FILE="$tmp_index" git -C "$proot" write-tree 2>/dev/null || true)"
  rm -f "$tmp_index"
  if [[ "$tree_sha" =~ ^[0-9a-f]{40}$ ]]; then
    # Narrow to project_root subtree so monorepo siblings don't bleed
    # into the diff. Falls back to the whole tree if narrowing isn't
    # applicable (proot == repo_root) or fails (unusual paths).
    local proj_tree
    proj_tree="$(_extract_project_subtree "$proot" "$tree_sha")"
    [[ -n "$proj_tree" && "$proj_tree" =~ ^[0-9a-f]{40}$ ]] && tree_sha="$proj_tree"
    echo "$tree_sha" > "$tree_file"
    if [[ "$add_ok" == "1" ]]; then
      _cloud_warn "$sid" "_capture_baseline_tree: captured ${tree_sha:0:10}"
    else
      _cloud_warn "$sid" "_capture_baseline_tree: captured ${tree_sha:0:10} (partial — some paths skipped)"
    fi
  else
    _cloud_warn "$sid" "_capture_baseline_tree: write-tree returned '$tree_sha'"
  fi
}

# Idempotent: a no-op if baseline/fingerprint are already populated, or
# if the project still has no git. Safe to call from any convergence
# point (update-status, stop-hook, cloud_post_diff).
ensure_baseline_and_fingerprint() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0

  local shadow; shadow="$(dirname "$state_file")"
  local sid; sid="$(basename "$shadow")"
  local proot; proot="$(_read_fm_field "$state_file" project_root)"
  [[ -z "$proot" ]] && return 0
  git -C "$proot" rev-parse --git-dir >/dev/null 2>&1 || return 0

  local changed_baseline="false"
  local changed_fpr="false"

  # Baseline backfill. We treat "EMPTY", empty string, or a non-SHA-looking
  # value as unset. Git root HEAD becomes the new baseline — it's the best
  # approximation of "when this workflow started" given the data we have.
  local baseline_file="${shadow}/baseline"
  local cur_baseline=""
  [[ -f "$baseline_file" ]] && cur_baseline="$(cat "$baseline_file" 2>/dev/null)"
  if [[ -z "$cur_baseline" ]] || [[ "$cur_baseline" == "EMPTY" ]]; then
    local head_sha
    head_sha="$(git -C "$proot" rev-parse HEAD 2>/dev/null || echo "")"
    if [[ -n "$head_sha" ]]; then
      echo "$head_sha" > "$baseline_file"
      _cloud_warn "$sid" "baseline backfilled from local git: ${head_sha:0:10}"
      changed_baseline="true"
    fi
  fi

  # Fingerprint backfill. Written into state.md via the atomic
  # set_fm_field helper; no impact on the skill that may be reading
  # state.md concurrently because the rename is atomic.
  local cur_fpr
  cur_fpr="$(_read_fm_field "$state_file" project_fingerprint)"
  if [[ -z "$cur_fpr" ]] || [[ "$cur_fpr" == "EMPTY" ]]; then
    local new_fpr
    new_fpr="$(git_project_fingerprint "$proot")"
    if [[ -n "$new_fpr" ]]; then
      set_fm_field "$state_file" project_fingerprint "$new_fpr"
      _cloud_warn "$sid" "project_fingerprint backfilled: ${new_fpr:0:10}"
      changed_fpr="true"

      # Sync the new fingerprint to the server via the state endpoint
      # (which now accepts project_fingerprint as an optional field).
      if is_cloud_session "$sid"; then
        local cs ce
        cs="$(_read_fm_field "$state_file" status)"
        ce="$(_read_fm_field "$state_file" epoch)"
        cloud_post_state "$sid" "$cs" "${ce:-1}" "" "true" "" "$new_fpr" || true
      fi
    fi
  fi

  # Capture a worktree-snapshot tree too, so diffs precisely reflect
  # "changes since workflow start" (not "changes since the last commit").
  # Idempotent — does nothing if already captured. Gated on the
  # workflow's modifies_worktree flag (default true for back-compat).
  if [[ "$(_session_modifies_worktree "$shadow")" == "true" ]]; then
    _capture_baseline_tree "$shadow" "$proot"
  fi

  # Return value isn't currently used by callers, but document intent:
  # 0 = nothing backfilled OR backfill succeeded; non-zero reserved for
  # future use if callers want to know that state.md was mutated.
  [[ "$changed_baseline" == "true" ]] || [[ "$changed_fpr" == "true" ]]
}

# ──────────────────────────────────────────────────────────────
# Git baseline helpers
# ──────────────────────────────────────────────────────────────

# Ensure <proot> has a git repo with at least one commit so that
# "git rev-parse HEAD" is always valid (required by run_file init
# commands that capture the baseline SHA).
# Sets _ENSURE_GIT_MSG with human-readable notes; safe to call
# repeatedly (no-ops when a HEAD already exists).
_ENSURE_GIT_MSG=""
ensure_git_baseline() {
  local proot="$1" topic="${2:-}"
  _ENSURE_GIT_MSG=""
  if ! git -C "$proot" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$proot" init -q
    _ENSURE_GIT_MSG="   (no git repo found — ran 'git init')"
  fi
  if ! git -C "$proot" rev-parse HEAD >/dev/null 2>&1; then
    git -C "$proot" add -A 2>/dev/null || true
    local has_files
    has_files="$(git -C "$proot" diff --cached --name-only 2>/dev/null | head -1 || true)"
    git -C "$proot" \
      -c user.name='stagent' \
      -c user.email='stagent@local' \
      commit --allow-empty -q -m "stagent: initial baseline (topic=${topic})"
    if [[ -n "$has_files" ]]; then
      _ENSURE_GIT_MSG="${_ENSURE_GIT_MSG:+${_ENSURE_GIT_MSG}
}   (committed existing files as initial baseline)"
    else
      _ENSURE_GIT_MSG="${_ENSURE_GIT_MSG:+${_ENSURE_GIT_MSG}
}   (created empty initial commit as baseline)"
    fi
  fi
}

# Run all declared run_file init commands into <dest_dir>.
# Each init command is executed with <proot> as CWD.
# Exits (or returns non-zero) on the first missing init command.
generate_run_files() {
  local dest_dir="$1" proot="$2"
  local _rf_name _rf_init
  while IFS= read -r _rf_name; do
    [[ -z "$_rf_name" ]] && continue
    _rf_init="$(config_run_file_init "$_rf_name")"
    if [[ -z "$_rf_init" ]]; then
      echo "❌ run_file '$_rf_name' has no init command in workflow.json" >&2
      return 1
    fi
    (cd "$proot" && bash -c "$_rf_init") > "${dest_dir}/${_rf_name}"
  done < <(config_run_file_names)
}

# ──────────────────────────────────────────────────────────────
# Cloud state reconciliation
# ──────────────────────────────────────────────────────────────
#
# Safety net for drift between local shadow and the server. Pulls the
# current server snapshot, compares against the local state.md and the
# latest local artifact for the current stage; re-pushes anything that
# diverged. Called from stop-hook.sh on every fire (cloud mode, non-
# terminal only) so every turn-end is an implicit convergence point.
#
# Design notes:
# - Uses _cloud_curl_once for the snapshot GET (short timeout, no retry)
#   so a flaky network doesn't block the stop hook for 10+ seconds.
#   Missing a reconcile cycle is fine; the next turn-end tries again.
# - The re-push goes through cloud_post_state / cloud_post_artifact,
#   which themselves retry — so a recovered server gets the update on
#   the first reconcile cycle it's reachable.
# - Never blocks, never errors: returns 0 unconditionally.
cloud_reconcile_state() {
  local sid="$1"
  [[ -z "$sid" ]] && return 0
  cloud_require_env 2>/dev/null || return 0

  local shadow; shadow="$(cloud_registry_get "$sid" scratch_dir)"
  [[ -z "$shadow" ]] && shadow="${CLOUD_SCRATCH_BASE}/${sid}"
  [[ -f "$shadow/state.md" ]] || return 0

  local local_status local_epoch
  local_status="$(_read_fm_field "$shadow/state.md" status)"
  local_epoch="$(_read_fm_field "$shadow/state.md" epoch)"
  [[ -z "$local_status" ]] && return 0

  # Pull server snapshot (short timeout, single shot).
  local snapshot
  snapshot="$(curl -sS -fL --max-time 3 \
              -H "$(_cloud_auth_header)" \
              "${STAGENT_SERVER}/api/sessions/${sid}" 2>/dev/null)" || return 0
  printf '%s' "$snapshot" | jq empty 2>/dev/null || return 0

  local server_status server_epoch
  server_status="$(printf '%s' "$snapshot" | jq -r '.session.status // ""')"
  server_epoch="$(printf '%s' "$snapshot" | jq -r '.session.epoch // ""')"

  # State reconcile — higher epoch wins (Model 2: local-first + server mirror).
  # Write path: update-status.sh → set_fm_field (local) → cloud_post_state (server).
  # Local is written first for latency and offline resilience; the server is the
  # cross-machine coordination point but NOT a blanket authority. The reconcile
  # closes the gap in either direction using the monotonic per-session epoch:
  #
  #   server.epoch > local.epoch → another machine advanced; pull server → local
  #   server.epoch < local.epoch → prior POST was lost; re-push local → server
  #   equal epoch, different status → POST dropped mid-flight; re-push local
  #   equal and same → in sync; no-op
  #
  # This replaces the old "server always wins" policy, which silently reverted
  # local advances whenever cloud_post_state had a transient failure (network
  # blip between set_fm_field and the next reconcile). The previous "local
  # always wins" policy was worse — the 4/14 diary incident showed it
  # overwriting a healthy server with stale local state. Higher-epoch-wins
  # avoids both failure modes: epochs only go up, so whichever side saw the
  # newer write carries it across.
  #
  # Non-numeric epochs fall back to 0 so a corrupted value can't starve
  # reconcile and leave the two sides permanently diverged.
  local _l_ep=0 _s_ep=0
  [[ "$local_epoch"  =~ ^[0-9]+$ ]] && _l_ep="$local_epoch"
  [[ "$server_epoch" =~ ^[0-9]+$ ]] && _s_ep="$server_epoch"

  if (( _s_ep > _l_ep )); then
    set_fm_field "$shadow/state.md" status "$server_status"
    set_fm_field "$shadow/state.md" epoch "$server_epoch"
    _cloud_warn "$sid" "reconcile: pulled server → local (was local=${local_status}/${local_epoch}, now ${server_status}/${server_epoch})"
  elif (( _s_ep < _l_ep )) || [[ "$server_status" != "$local_status" ]]; then
    local _l_resume _l_active _l_pr _l_fpr
    _l_resume="$(_read_fm_field "$shadow/state.md" resume_status)"
    _l_active="$(_read_fm_field "$shadow/state.md" active)"
    _l_pr="$(_read_fm_field     "$shadow/state.md" project_root)"
    _l_fpr="$(_read_fm_field    "$shadow/state.md" project_fingerprint)"
    [[ -z "$_l_active" ]] && _l_active="true"
    if cloud_post_state "$sid" "$local_status" "$local_epoch" "$_l_resume" "$_l_active" "$_l_pr" "$_l_fpr"; then
      _cloud_warn "$sid" "reconcile: re-pushed local → server (was server=${server_status}/${server_epoch}, now ${local_status}/${local_epoch})"
    else
      _cloud_warn "$sid" "reconcile: push-up failed local=${local_status}/${local_epoch} server=${server_status}/${server_epoch}"
    fi
  fi

  # Artifact reconcile — if the current stage has a local artifact
  # whose byte length differs from the server's, re-upload.
  local local_artifact="${shadow}/${local_status}-report.md"
  if [[ -f "$local_artifact" ]]; then
    local local_bytes server_bytes
    local_bytes="$(wc -c < "$local_artifact" 2>/dev/null | tr -d ' ')"
    server_bytes="$(printf '%s' "$snapshot" \
                    | jq -r --arg s "$local_status" \
                         '((.artifacts[] | select(.stage == $s) | .content) // "") | length')"
    if [[ -n "$local_bytes" ]] && [[ "$local_bytes" != "$server_bytes" ]]; then
      if cloud_post_artifact "$sid" "$local_status" "$local_artifact"; then
        _cloud_warn "$sid" "reconcile: ${local_status}-report.md caught up (local=${local_bytes} server=${server_bytes})"
      fi
    fi
  fi

  return 0
}
