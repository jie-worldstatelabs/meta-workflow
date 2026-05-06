---
description: "Pause the active dev workflow loop without clearing state — resume later with /stagent:continue"
argument-hint: "[--session <id>]  (omit to interrupt this Claude session's own workflow)"
allowed-tools: ["Bash", "TaskStop"]
---

Pause the dev workflow at the current stage, preserving all state for resumption.

- **No arguments**: interrupts the workflow owned by THIS Claude session (resolved via PPID / cwd cache).
- **`--session <id>`**: interrupts a specific cloud session — useful when you want to pause a workflow that's running in another Claude Code window or on another machine.

## Step 1 — Flip state and surface in-flight subagents

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/interrupt-workflow.sh" $ARGUMENTS
```

The script flips the workflow to `interrupted`, removes inflight markers, and — if the workflow had a subagent in flight — prints a line of the form:

```
STAGENT_STOP_AGENT_IDS: <id1> <id2> ...
```

## Step 2 — Stop each in-flight subagent

If Step 1 printed a `STAGENT_STOP_AGENT_IDS:` line, call the `TaskStop` tool **once per id** to terminate the orphan subagents. If it didn't print that line, skip this step — there were no in-flight subagents.

Stopping subagents is what prevents post-interrupt writes (orphan reports, mid-flight code) from contaminating the resumed run.
