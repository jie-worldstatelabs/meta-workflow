#!/bin/bash
#
# loop-tick.sh — single source of truth for the main agent's loop state.
#
# Prints a JSON object describing the current stage of the active
# stagent. The main agent calls this once per loop iteration and
# reads every field via `jq`, instead of hand-parsing `state.md` or
# `workflow.json` with `grep` / `sed` (which has repeatedly broken on
# quote handling, YAML escapes, and JSON traversal).
#
# Usage:
#   loop-tick.sh [--topic <name>] [--session <id>]
#
# Output (stable JSON):
#   {
#     "status": "<stage name or terminal name>",
#     "epoch": <int>,
#     "is_terminal": <bool>,
#     "execution_type": "inline" | "subagent" | null,
#     "model": "<model name>" | null,
#     "interruptible": <bool> | null,
#     "stage_instructions_path": "<abs path>" | null,
#     "output_artifact_path": "<abs path>" | null,
#     "transition_keys": [ "<key>", ... ],
#     "required_inputs": [ { "type": ..., "key": ..., "description": ..., "path": ... }, ... ],
#     "optional_inputs": [ ... ],
#     "view_url": "<server>/s/<session_id>" | null
#   }
#
# Non-zero exit with a diagnostic on stderr when no active workflow is
# resolvable or the workflow config is invalid.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TOPIC_ARG=""
SESSION_ARG=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --topic=*)   TOPIC_ARG="${1#--topic=}";     shift ;;
    --topic)     TOPIC_ARG="$2";                shift 2 ;;
    --session=*) SESSION_ARG="${1#--session=}"; shift ;;
    --session)   SESSION_ARG="$2";              shift 2 ;;
    *)
      echo "Warning: unknown argument: $1" >&2
      shift
      ;;
  esac
done

if [[ -n "$TOPIC_ARG" ]]; then
  DESIRED_TOPIC="$TOPIC_ARG"
fi
if [[ -n "$SESSION_ARG" ]]; then
  DESIRED_SESSION="$SESSION_ARG"
fi

if ! resolve_state; then
  echo "❌ loop-tick: no active workflow" >&2
  exit 1
fi
resolve_workflow_dir_from_state
if ! config_check; then
  # Drop the bootstrap-edge marker BEFORE exiting — otherwise the
  # stop-hook's `decision: block` branch (introduced together with
  # this change) would force claude to keep re-invoking
  # `stagent:stagent`, each call landing right back here, each call
  # bouncing off the same `config_check` failure. That turns a fixable
  # config error into a livelock the user can only break with
  # `/stagent:cancel`. Removing the marker means the next stop-hook
  # invocation falls through to the regular uninterruptible-stage
  # branch, which surfaces a clear error instead of looping.
  rm -f "$(dirname "$STATE_FILE")/.bootstrap_pending" 2>/dev/null || true
  echo "❌ loop-tick: workflow config invalid" >&2
  exit 1
fi

# Clear the bootstrap-edge marker. Its presence meant "state.md was
# just materialised but stagent:stagent has not yet started driving
# the loop"; once we've reached this point the loop IS driving — the
# stop hook should fall back to its normal interruptible-pause path
# on the next turn, not the bootstrap-nudge path. Safe to `rm -f`
# regardless of whether the marker is there (continue, dry-runs, etc).
rm -f "$(dirname "$STATE_FILE")/.bootstrap_pending"

STATUS=$(_read_fm_field "$STATE_FILE" status)
EPOCH_RAW=$(_read_fm_field "$STATE_FILE" epoch)
EPOCH="${EPOCH_RAW:-0}"
[[ "$EPOCH" =~ ^[0-9]+$ ]] || EPOCH=0

# ── Terminal / corrupt short-circuit ──
if [[ -z "$STATUS" ]]; then
  echo "❌ loop-tick: state.md has no status" >&2
  exit 1
fi

VIEW_URL=""
if is_cloud_session "$RUN_DIR_NAME" && [[ -n "${STAGENT_SERVER:-}" ]]; then
  VIEW_URL="${STAGENT_SERVER}/s/${RUN_DIR_NAME}"
fi

if is_terminal_status "$STATUS"; then
  jq -n \
    --arg s "$STATUS" \
    --argjson e "$EPOCH" \
    --arg vu "$VIEW_URL" \
    '{
      status: $s,
      epoch: $e,
      is_terminal: true,
      execution_type: null,
      model: null,
      interruptible: null,
      stage_instructions_path: null,
      output_artifact_path: null,
      transition_keys: [],
      required_inputs: [],
      optional_inputs: [],
      view_url: (if $vu == "" then null else $vu end)
    }'
  exit 0
fi

if ! config_is_stage "$STATUS"; then
  echo "❌ loop-tick: '$STATUS' is not a declared stage" >&2
  exit 1
fi

# ── Active stage: assemble the full snapshot ──
EXEC_TYPE=$(config_execution_type "$STATUS")
MODEL=$(config_model "$STATUS")
INTERRUPTIBLE=false
config_is_interruptible "$STATUS" && INTERRUPTIBLE=true

INSTR_PATH=$(config_stage_instructions_path "$STATUS")
ARTIFACT_PATH=$(config_artifact_path "$STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")

# Transition keys → JSON array
TKEYS_JSON=$(config_transition_keys "$STATUS" | jq -R . | jq -s .)

# Inputs → JSON array with resolved absolute paths
inputs_json() {
  local kind="$1" stage="$2"
  local source_fn="config_${kind}_inputs"
  local items='[]'
  while IFS=$'\t' read -r type key description; do
    [[ -z "$key" ]] && continue
    local path
    if [[ "$type" == "run_file" ]]; then
      path=$(config_run_file_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT" 2>/dev/null || echo "")
    else
      path=$(config_artifact_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")
    fi
    items=$(jq -c --arg t "$type" --arg k "$key" --arg d "$description" --arg p "$path" \
      '. += [{type: $t, key: $k, description: $d, path: $p}]' <<<"$items")
  done < <($source_fn "$stage")
  printf '%s' "$items"
}

REQUIRED_JSON=$(inputs_json required "$STATUS")
OPTIONAL_JSON=$(inputs_json optional "$STATUS")

jq -n \
  --arg s "$STATUS" \
  --argjson e "$EPOCH" \
  --arg et "$EXEC_TYPE" \
  --arg m "$MODEL" \
  --argjson intr "$INTERRUPTIBLE" \
  --arg ip "$INSTR_PATH" \
  --arg op "$ARTIFACT_PATH" \
  --argjson tkeys "$TKEYS_JSON" \
  --argjson req "$REQUIRED_JSON" \
  --argjson opt "$OPTIONAL_JSON" \
  --arg vu "$VIEW_URL" \
  '{
    status: $s,
    epoch: $e,
    is_terminal: false,
    execution_type: (if $et == "" then null else $et end),
    model: (if $m == "" then null else $m end),
    interruptible: $intr,
    stage_instructions_path: (if $ip == "" then null else $ip end),
    output_artifact_path: (if $op == "" then null else $op end),
    transition_keys: $tkeys,
    required_inputs: $req,
    optional_inputs: $opt,
    view_url: (if $vu == "" then null else $vu end)
  }'
