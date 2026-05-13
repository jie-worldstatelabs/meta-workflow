# Stage: planning

_Runtime config (canonical): `workflow.json` → `stages.planning`_

**Purpose:** Produce an approved plan the writer subagent can consume deterministically. Works for both **create from scratch** and **edit an existing workflow** — the difference is the starting point.
**Output artifact:** write to the absolute path provided in your I/O context
**Valid results this stage writes:** `pending` (plan drafted, awaiting user approval), `approved` (user has explicitly confirmed)

<HARD-GATE>
Do NOT transition out of this stage until the user explicitly confirms the plan.
Write `result: approved` only after they have said so.
</HARD-GATE>

This is an interruptible stage — the stop hook allows natural pauses for Q&A.

## Step 0 — Know your toolkit (internal reference)

Before talking to the user, load the full schema into your context so
you'll notice when their described need maps to an optional lever
(`max_epoch`, `modifies_worktree`, `run_files`, model variants, etc.).
You still speak plain language with them — this is just so you don't
silently omit schema options they'd want.

```bash
P=$(cat ~/.config/stagent/plugin-root 2>/dev/null)
[[ -n $P && -d $P/scripts ]] || P=$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)
cat "$P/skills/create-workflow/workflow/schema-cheatsheet.md"
echo
cat "$P/skills/create-workflow/workflow/run_files_catalog.md"
```

## Step 1 — Detect mode and load context

Read the `setup_context` input at the absolute path shown in your I/O context. It contains JSON with these fields:

- `mode`: `"create"` or `"edit"`
- `description`: the original natural-language description the user passed to `/stagent:create` (may be empty). **This is the only place the description shows up** — it is NOT in `state.md`'s `topic:` field.
- `source_dir`: (edit mode only) absolute path to the existing workflow to edit

Log the parsed `mode` and `description` before proceeding:

- `"mode":"create"` → skip to [Step 2 (create)](#step-2-create--understand-the-request).
- `"mode":"edit"` → skip to [Step 2 (edit)](#step-2-edit--load-existing-workflow).

## Step 2 (create) — Understand the request

Use the `description` from `setup_context` as the user's request. If it's empty or too vague to decompose, ask ONE clarifying question at a time (cap at 5 total). Useful axes:

- What kind of work does this workflow orchestrate? (coding, writing, data analysis, review, research, etc.)
- What are the rough phases? A 3-line sketch is enough — you'll refine it below.
- Any phase where the user should pause for input, answer a question, or approve something? → `interruptible: true` + `inline` execution. Subagents have no UI and can't call `AskUserQuestion`.
- Any phase that needs to **fan out N parallel subagents** (5 researchers, 3 reviewers, map-reduce)? → that phase MUST be `inline` execution. Subagents can't dispatch sub-subagents — the `Agent`/`Task` tool is main-agent-only.
- Any phase that benefits from a stronger model? → subagent stage with `model: opus` (or leave model unspecified for sonnet default).
- Any external validation / test run? → subagent or inline stage that runs a command.
- What's the success terminal? (usually `complete`.)

Stop asking once you can draft a stage decomposition. Skip to [Step 3 — Propose the decomposition](#step-3--propose-the-decomposition).

## Step 2 (edit) — Load existing workflow

**Do NOT verify ownership by calling the cloud API, running `curl`, or piping bundle JSON through `jq` for author/user_id checks.** SKILL.md has already refetched the bundle into `$source_dir` and the setup script has gated on ownership; the fact that `source_dir` is readable is sufficient proof that you're allowed to edit. Any additional probing (curl → jq chains, `python3` JSON parsing, etc.) produces terminal noise and exploration latency without changing the outcome. Treat `source_dir` as authoritative.

Read the source directory (`source_dir` from `setup_context`). Run this so the current design flows into your context:

```bash
SRC="<absolute-path-from-setup_context>"
echo "===== workflow.json ====="; cat "$SRC/workflow.json"
for f in "$SRC"/*.md; do
  echo "===== $(basename "$f") ====="; cat "$f"; echo
done
```

Present the **current design** to the user as a table + transition graph (same format as Step 3 below). Call it out as "current design — propose changes against this."

Treat the `description` from `setup_context` (if non-empty) as the user's change request. If it's empty, ask: **"What changes do you want to make to this workflow?"**

Continue to Step 3 with the current design as the starting point.

## Step 3 — Propose the decomposition

Present the (proposed or updated) design as:

### Stage table

| Stage | Execution | Model | Interruptible | Purpose | Result values → next |
|---|---|---|---|---|---|
| `<name>` | inline / subagent | (if subagent) | true/false | <one-line role> | `<result>` → `<next>` |

### Transition graph

```
<initial_stage> --(<result>)--> <next_stage>
<next_stage>    --(<result>)--> <stage_or_terminal>
...
```

### Inputs per stage

For each stage, list `required` and `optional` inputs using `from_stage <name>` or `from_run_file <name>`. Required inputs are enforced at transition time by `update-status.sh`.

### Run files (optional)

If the workflow needs setup-time constants (e.g. git SHA baseline, current date), list each `run_files` entry: name, description, and the shell init command.

### Workflow-level flags (only when non-default)

Don't put defaults on the user's screen. Surface a flag here ONLY when the design triggers one of these signals:

- **`modifies_worktree: false`** — the workflow writes nothing into the project worktree (writes to `~/.config/`, pure HTTP, etc.). Mention it explicitly so the user knows the diff panel won't show up.
- **`max_epoch: <N>`** — the workflow has expensive loop-back edges AND the user mentioned wanting a tighter cap than the default 20.

If neither applies, skip this block entirely.

## Step 4 — Pick / confirm the suffix

- **Create mode**: derive a short, kebab-case suffix from the description (e.g. "Python library dev with docs and publish" → `python-lib`). Confirm with the user. Target directory: `~/.config/stagent/workflows/<suffix>/`. If the directory already exists, ask whether to overwrite or pick a different name.
- **Edit mode**: suffix = `basename(source_dir)`; target directory = `source_dir` itself (writer will overwrite files in place). Do not ask — this is fixed by the `setup_context`.

## Step 5 — Iterate until approved

Ask: **"Does this design look right? Any changes to stages, order, inputs, or naming?"** Iterate until the user explicitly approves.

If the user says "no changes" in Edit mode, write the plan anyway with the current design verbatim (writing is idempotent — same files get re-emitted).

## Step 6 — Write the plan into the output artifact

Once the user has confirmed the design, write the output artifact (use the current epoch from `state.md`):

```markdown
---
epoch: <epoch>
result: pending
---
# Workflow Plan

## Mode
<create or edit>

## Description
<one paragraph — what this workflow orchestrates>

## Suffix
<kebab-case-suffix>

## Target directory
`/absolute/path/to/dir/`
(absolute path — writer will `mkdir -p` this and write files. For edit mode, this is the existing source_dir — writer overwrites in place.)

## Stages

| Stage | Execution | Model | Interruptible | Purpose | Result values → next |
|---|---|---|---|---|---|
| `<name>` | inline / subagent | (omit / opus / sonnet / haiku) | true / false | <short> | `<result>` → `<next>` |

## Transition graph

```
<initial_stage> --(<result>)--> <next>
...
```

## Inputs per stage

- **`<stage-a>`** — required: (none) — optional: (none)
- **`<stage-b>`** — required: `from_stage <stage-a>` (<description>) — optional: `from_stage <stage-c>` (<description>)
- ...

## Run files

- `<name>` — description: <text> — init: `<shell command>`
- (or: "none")

## Workflow-level flags

(Include ONLY the fields whose values differ from default. Omit this
section entirely when everything is default.)

- `modifies_worktree: false` — <one-line reason, e.g. "writes to ~/.config/stagent, never touches project dir">
- `max_epoch: <N>` — <one-line reason, e.g. "verify→execute loop is expensive, cap lower than 20">

## Readme blurb

<one-line summary that will become the hub card description — punchy, avoid starting with "This workflow">
```

`result: pending` signals "plan written but not approved yet."

## Step 7 — Get user approval

Surface the plan with a **concrete pointer** to where the user can read it. Don't just say "review the plan" — paste the actual URL (cloud mode) or absolute path (local mode) so the link/path is one click / one copy away.

1. Read `publish_intent` from the `setup_context` input you already loaded in Step 1.
2. Build the review pointer:
   - **`publish_intent == "cloud"`**: the live session URL.
     - `SESSION_ID`: read from `state.md` frontmatter (`session_id:` field) — your I/O context tells you which `state.md` file.
     - `SERVER`: read from `~/.cache/stagent/cloud-registry/<SESSION_ID>.json` `.server` field. Falls back to `https://stagent.worldstatelabs.com` if the file or field is missing.
     - URL format: `<SERVER>/s/<SESSION_ID>`
   - **`publish_intent == "local"`**: the absolute path of the artifact you just wrote (the path your I/O context gave you for `planning-report.md`).
3. Print exactly this format (and nothing else — no chatter, no follow-up paragraphs):

   **Cloud mode:**
   ```
   Plan ready for review.

   <SERVER>/s/<SESSION_ID>

   Reply "approve" / "ok" / "lgtm" to start writing, or send any changes you want to the plan.
   ```

   **Local mode:**
   ```
   Plan ready for review.

   <absolute-path-to-planning-report.md>

   Reply "approve" / "ok" / "lgtm" to start writing, or send any changes you want to the plan.
   ```

4. **End the turn.** Keep the artifact at `result: pending` — Step 8 flips it to `approved` only after the user explicitly OKs.

If the user requests changes, iterate on the plan body — keep `result: pending`.

## Step 8 — Finalize

Once the user explicitly approves, edit the artifact: change `result: pending` → `result: approved`.

The main loop reads the artifact's `result:` and calls `update-status.sh` to advance — do NOT call it yourself from this stage file.
