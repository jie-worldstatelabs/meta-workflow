# Security Controls

This document describes the security knobs available in this fork of stagent.
See the [original repo](https://github.com/jie-worldstatelabs/stagent) for
general project documentation.

> **Fork base:** upstream v1.1.2 (commit `511d0f2`). Security patches
> are applied as a single commit on top of the unmodified upstream tree.

---

## Cloud Mode Data Exposure

### Background

In cloud mode, stagent sends telemetry to the configured `STAGENT_SERVER`
(default `https://stagent.worldstatelabs.com`). Two data flows carry
potentially sensitive content:

1. **Activity hook** (`hooks/activity-hook.sh`) — POSTs `tool_input` +
   `tool_result` JSON for every tool call (both PreToolUse started events
   and PostToolUse finished events). These fields can contain full file
   contents (Read/Write), Bash command output, API responses, etc.

2. **Post-write hook** (`hooks/postwrite-hook.sh`) — POSTs a full
   `git diff` of the working tree to the server on every agent write.
   This diff includes *all* modified file contents since workflow start.

---

## Fix #1 — Telemetry Level (`STAGENT_TELEMETRY_LEVEL`)

Controls how much data the activity hook sends to the server.

| Value | Behavior |
|---|---|
| `summary` **(default)** | Strips `tool_input` and `tool_result` from all cloud payloads. Server receives only: stage, tool name, one-line summary, `is_error`, `agent_id`, `tool_use_id`. |
| `full` | Opt-in: sends full `tool_input` and `tool_result`. Original upstream behavior. |

**Sensitive tool class** (`Read`, `Write`, `Edit`, `MultiEdit`, `Bash`):
both fields are always stripped at `summary` level regardless of other
settings. These tools routinely emit file contents or shell output that
may contain secrets, PII, or proprietary code.

**Started events:** At `summary` level, `tool_input` is also stripped
from PreToolUse (started) events for sensitive tools. The `tool_use_id`
pairing and live pending-row UI still work correctly — the webapp pairs
events by `tool_use_id`, not payload content.

```bash
# Default safe mode (no action needed — summary is the new default)
export STAGENT_TELEMETRY_LEVEL=summary

# Opt-in to full telemetry (trusted server + non-sensitive codebase only)
export STAGENT_TELEMETRY_LEVEL=full
```

---

## Fix #2 — Diff Upload Opt-Out (`STAGENT_DISABLE_DIFF_UPLOAD`)

Prevents the post-write hook from uploading working-tree diffs to the server.

| Value | Behavior |
|---|---|
| `0` **(default)** | Diffs uploaded on every agent write (original behavior). |
| `1` | Diff upload disabled. UI diff panel will not update. |

```bash
# Disable for proprietary or sensitive codebases
export STAGENT_DISABLE_DIFF_UPLOAD=1
```

### Recommended env for sensitive codebases

```bash
# Add to ~/.zshrc / ~/.bashrc or Claude Code environment config
export STAGENT_TELEMETRY_LEVEL=summary   # default in this fork; no action needed
export STAGENT_DISABLE_DIFF_UPLOAD=1     # disable if UI diff panel not needed
```

---

## Anonymous Session ACL

Unauthenticated sessions have no server-side access control. Any party
with the session UUID can read the full audit trail (at whatever telemetry
level is configured). Run `/stagent:login` before starting a cloud workflow
to scope the session to your account.

---

## `bypassPermissions` on Subagents

The upstream workflow hardcodes `mode: bypassPermissions` for all subagent
dispatch (`hooks/agent-guard.sh`). No per-stage permission scoping exists.

**Status:** No code change applied — load-bearing for the default workflow.
Tracked for a follow-up PR.

**Workaround:** Use `--mode=local` for workflows that do not need the cloud
UI, or audit `workflow.json` templates before running with `bypassPermissions`.

---

## Reporting

This is a fork maintained for internal use. For upstream security issues,
contact the original authors at `https://github.com/jie-worldstatelabs/stagent`.
