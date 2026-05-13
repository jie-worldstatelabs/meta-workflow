# Stage: writing

_Runtime config (canonical): `workflow.json` → `stages.writing`_

**Purpose:** Produce `workflow.json` + one `<stage>.md` per declared stage + `readme.md` in the target directory, matching the approved plan and the schema the validator accepts. On a loop-back (validator `FAIL` from the previous epoch), address every `❌` line and try again.
**Output artifact:** write to the absolute path provided in your prompt
**Valid results this stage writes:** `done`

> This file is the canonical protocol for the `writing` stage. The main agent launches `workflow-subagent` with this file as the stage instructions; the subagent reads this file first, then proceeds.

You are the writer subagent for the create-workflow loop. Your job is to produce files that pass `setup-workflow.sh --validate-only` on the first try, or — if `validating` sent feedback from a previous iteration — to incorporate that feedback and try again.

## Inputs

Read every input path from your prompt — do NOT construct or hardcode paths.

- **Required:** `planning` report — the approved design (suffix, target dir, stage decomposition, transitions, inputs, run_files, readme blurb).
- **Optional:** `validating` report from the previous epoch — contains the validator's stdout/stderr with every `❌` line. If present, every listed error MUST be addressed in this pass.
- **Optional:** `final_review` report from the previous publish round — present only when the user reviewed a published draft and chose `revise`. The body under `# User Review Feedback` is the user's verbatim change request. **Read it FIRST and treat every point as a required change for this iteration**, taking priority over the planner's original design where they conflict. Address each one explicitly in your report's "User feedback addressed" section.

## Read the plugin's canonical reference first

Run this Bash call so the canonical schema, runtime constraints, and stage-file style all flow into your context:

````bash
P=$(cat ~/.config/stagent/plugin-root 2>/dev/null)
[[ -n $P && -d $P/scripts ]] || P=$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)
# Writer toolkit (lives in create-workflow/ — schema rules, Claude Code
# runtime constraints, and the run_files patterns reference).
echo "===== schema-cheatsheet.md ====="
cat "$P/skills/create-workflow/workflow/schema-cheatsheet.md"
echo
echo "===== run_files_catalog.md ====="
cat "$P/skills/create-workflow/workflow/run_files_catalog.md"
echo
# Demo workflow — shape and stage-file voice reference. Copy the JSON
# shape and the prose voice, NOT the specific stage identities (your
# workflow uses whatever names the plan defines). readme.md isn't in
# this loop — writing.md's own `## Readme shape` section already gives
# the template.
for f in workflow.json planning.md executing.md reviewing.md qa-ing.md deploy.md; do
  echo "===== $f ====="; cat "$P/skills/stagent/workflow/$f"; echo
done
````

Copy the JSON **shape** and the stage-file **style** — NOT the specific stage identities. Your workflow uses whatever names the plan defines.

## Writer-specific reminders

The cheatsheet above is the canonical list of schema rules and runtime
constraints — don't restate it here. The bullets below are only the
writer-specific bits that don't fit in a planner-facing reference:

- **`max_epoch` ↔ `escalated`** — if the plan sets `max_epoch`, the workflow MUST include `"escalated"` in `terminal_stages` for the cap to actually take effect. Otherwise the validator warns and the cap is silently skipped.
- **Read the plan's "Workflow-level flags" section** — emit `max_epoch` / `modifies_worktree` in `workflow.json` ONLY if the planner listed them with non-default values. If the section is missing or empty, omit those fields entirely (defaults apply).
- **Translating the runtime constraints into stage `.md` bodies** — the cheatsheet's "Claude Code runtime constraints" table is design-time. When you write the prose body of each `<stage>.md`, also enforce them at the instruction level:
  - Subagent stage bodies must NOT instruct the agent to use `Task` / `Agent` / `AskUserQuestion` (the subagent doesn't have those tools).
  - Subagent stage bodies must NOT reference "the conversation" or "what the user said earlier" — only input artifact paths.
  - Slow `Bash` calls in any stage body should use `run_in_background: true` (2-min default timeout).
  - Loop-back stages must be idempotent — prefer `Write` (overwrite) over `Edit`-with-assumptions about prior epoch state.
- If the plan would force a runtime-constraint violation (e.g. parks a "fan out 5 reviewers in parallel" phase in a `subagent` stage), surface it in the writer report under a `## Plan concerns` section instead of silently writing a broken workflow.

## Writing protocol

1. **Create the target directory** from the plan's `Target directory` line:
   ```bash
   mkdir -p "<absolute-target-dir>"
   ```

2. **Write `workflow.json`** strictly matching the plan and the schema above.

3. **Write one `<stage>.md` per declared stage** directly in the target dir (NOT in a subdirectory). Follow the [Stage file style](#stage-file-style) section below.

4. **Write `readme.md`** for the workflow (see [Readme shape](#readme-shape)).

5. **Post-write sanity check** — run this before producing the report:
   ```bash
   DIR="<absolute-target-dir>"
   ls -1 "$DIR"
   echo "--- declared stages ---"
   jq -r '.stages | keys[]' "$DIR/workflow.json"
   ```
   Every name printed under `--- declared stages ---` MUST appear above as `<name>.md`. If any is missing, write it before producing the report.

6. **Write the execution report** (see [Execution report](#execution-report) below).

## Stage file style

Every stage file should contain:
- Header: `# Stage: <name>`
- Purpose line
- The valid `result:` values this stage writes — MUST exactly match the keys in that stage's `transitions` in `workflow.json` (plus `pending` for interruptible inline stages)
- The frontmatter block the stage's agent must write into its output artifact:
  ```
  ---
  epoch: <epoch>
  result: <one of the valid values>
  ---
  ```

**Inline stages** (execution.type = `inline`): address the body to the main agent (it reads this file and executes the stage directly).
- `interruptible: true` — the body should tell the main agent to: (1) read `state.md` for the current epoch, (2) immediately write the artifact at the path shown in its I/O context with `result: pending` so the stop hook knows the stage is in progress, (3) do the work, pausing for user input as needed, (4) overwrite the artifact with the final `result:` when done.
- `interruptible: false` — the body should tell the main agent to: read `state.md` for the epoch, run autonomously without pausing, write the artifact with the final `result:` when done.

For both variants: the stage file should tell the agent to **read each required input from the path shown in its I/O context — never construct or hardcode paths**.

**Subagent stages** (execution.type = `subagent`): address the body to `workflow-subagent`. Instruct it to read the epoch and all input paths **from its prompt** (injected by agent-guard — NOT from `state.md`), do the work, and write the output artifact with the frontmatter at the absolute path given in its prompt.

Stage files must NEVER instruct the agent to call `update-status.sh` — that is the main loop's job, not the stage's.

## Readme shape

Use this template (adapt to the workflow's actual domain):

````markdown
# <Workflow title — human-readable, not the suffix slug>

<One-line summary of what this workflow does. Kept punchy — this line is lifted verbatim for the hub card description. Avoid starting with "This workflow"; lead with the outcome.>

## Overview

<2–4 sentences describing the topology in prose: what the initial stage does, how the loop progresses, what each transition decides. Name the stages inline with backticks.>

## Stages

| Stage | Execution | Model | Purpose |
|---|---|---|---|
| `<name>` | inline / subagent | <omit col if all inline> | <short> |

## Flow

```
<initial_stage> --(<result>)--> <next_stage>
<next_stage>    --(<result>)--> <terminal>
```

## Usage

```
/stagent:start --flow <author>/<suffix> <your task description>
```
````

Rules:
- The blurb line (below the `# Title`) must be a single non-heading sentence — it's what the hub card lifts.
- Stage names in monospace. Terminal stage names in the flow graph are fine in prose (no backticks required).
- Do NOT embed the full stage instruction protocols — users already see those via the stage files. The readme is an overview, not a reference manual.

## Execution report

Write the output artifact to the absolute path given in your prompt:

```markdown
---
epoch: <epoch from your prompt>
result: done
---
# Writer Report

## Target directory
<absolute path>

## Files written
- `workflow.json`
- `<stage-name-1>.md`
- `<stage-name-2>.md`
- ... (one line per declared stage)
- `readme.md`

## Post-write sanity check
<paste the output of step 5 verbatim — `ls -1` and `jq .stages | keys[]`>

## Validator feedback addressed
(Include this section ONLY if the optional `validating` input was provided this epoch. Otherwise omit it.)

- [ ] <❌ line 1 copied from validating report> — <what file changed and how>
- [ ] <❌ line 2 copied from validating report> — <what file changed and how>

## User feedback addressed
(Include this section ONLY if the optional `final_review` input was provided this epoch — i.e. the user reviewed a published draft and chose `revise`. Otherwise omit it.)

- [ ] <feedback point 1, copied verbatim from final_review body> — <what file changed and how>
- [ ] <feedback point 2 ...> — <...>
```

## Rules

- Do NOT skip the post-write sanity check — it's the guard against missing stage files or wrong-filename bugs.
- Do NOT call `setup-workflow.sh --validate-only` yourself — that is the next stage's job.
- If validator feedback is provided, address every `❌` line. If a line can't be addressed, document why in the report's "Validator feedback addressed" section rather than silently dropping it.
- If final_review feedback is provided, treat it as the highest-priority change list — overrides the planner's original design where they conflict (the user has seen the published draft and is asking for changes against IT, not against the original plan). Address every point and document it in "User feedback addressed".
