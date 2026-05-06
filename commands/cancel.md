---
description: "Cancel the active dev workflow loop (archives by default, --hard to wipe)"
allowed-tools: ["Bash", "TaskStop"]
---

Cancel the current session's active dev workflow.

**Default behaviour**: archives the run dir to `.stagent/.archive/<YYYYMMDD-HHMMSS>-<topic>-cancelled/` so all stage reports and the baseline survive as an audit trail. The dir name's `-cancelled` suffix distinguishes cancelled runs from natural replacements.

**`--hard`**: skip the archive and `rm -rf` the run dir. Use when you really don't want any artifacts left behind.

**Cloud mode**: POSTs a cancel to the server, then wipes the local shadow dir. The server keeps the audit trail on its side; nothing local is preserved.

## Step 1 — Cancel and surface in-flight subagents

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cancel-workflow.sh" $ARGUMENTS
```

The script archives or wipes the run dir, removes inflight markers, and — if the workflow had a subagent in flight — prints a line of the form:

```
STAGENT_STOP_AGENT_IDS: <id1> <id2> ...
```

## Step 2 — Stop each in-flight subagent

If Step 1 printed a `STAGENT_STOP_AGENT_IDS:` line, call the `TaskStop` tool **once per id** to terminate the orphan subagents. If it didn't print that line, skip this step — there were no in-flight subagents.

Stopping subagents is what prevents post-cancel writes (rogue commits, mid-flight code) from landing in the project after the workflow has been wiped.
