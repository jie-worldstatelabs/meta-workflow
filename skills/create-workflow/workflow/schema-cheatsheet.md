# Stagent Workflow Cheatsheet — Schema + Claude Code Runtime Constraints

This is your **internal toolkit reference** — you (the create-workflow
planner or writer) read this so you know what's available. The schema +
runtime tables apply to both stages; the sections tagged `[Planner]`
are only relevant when you're the planner talking to the user. Writers
can skim those.

---

## Top-level fields of `workflow.json`

| Field | Required | Purpose / when to use |
|---|---|---|
| `initial_stage` | yes | Stage name where the run begins |
| `terminal_stages` | yes | Array of result values that end the workflow. Convention: `["complete", "escalated", "cancelled"]` |
| `stages` | yes | Object keyed by stage name |
| `max_epoch` | no (default 20) | Cap on FAIL→retry loops; forces `escalated` when exceeded. Only meaningful if the workflow has loop-back edges (e.g. `verify FAIL → execute`). *Planner: ask the user to consider a lower cap when a loop is expensive. Writer: emit only what the plan specifies.* |
| `modifies_worktree` | no (default true) | Set to `false` when the workflow writes **nothing** to the project dir. Example: `create-workflow` (writes to `~/.config/stagent/`), `publish-workflow` (pure HTTP calls). When `false`, the plugin skips worktree-diff capture and UI hides the diff panel. |
| `run_files` | no | `{name: {description, init}}`. Each `init` is a shell command run at setup; stdout becomes the file content. Use for setup-time constants (git SHA baseline, current date, env var snapshot). Stages read them via `from_run_file`. |

---

## Per-stage fields

| Field | Required | Purpose |
|---|---|---|
| `interruptible` | yes | `true` = stop-hook allows session pause mid-stage (for user Q&A or long pauses). `false` = the agent must drive the stage to a terminal result in one pass. **Subagent stages MUST be `false`** (validator rejects otherwise — the main agent blocks on the Agent tool, so the stop hook can't fire). |
| `execution` | yes | `{"type":"inline"}` OR `{"type":"subagent", "model":"opus"\|"sonnet"\|"haiku"}`. Model is optional; default is sonnet. |
| `transitions` | yes | `{<result>: <next-stage-or-terminal>}`. Values are plain strings. Result names are *your* convention — common ones: `done`, `pass`, `fail`, `approved`, `skipped`, custom names for branching. |
| `inputs` | yes | `{required: [...], optional: [...]}`. Each entry is `{from_stage: <name>, description: <text>}` OR `{from_run_file: <name>, description: <text>}`. `required` inputs are enforced at transition time — `update-status.sh` refuses to move INTO this stage if any required-input artifact is missing. |

---

## [Planner] Design levers — map user-described needs to schema

When the user describes what they want, listen for these signals:

| User-described need | Schema lever |
|---|---|
| "pause for input" / "ask user" / "review before next" | `interruptible: true` + `inline` execution |
| "hard thinking" / "generate code" / "analyze design" | `subagent` + `model: opus` |
| "quick classification" / "fan-out simple task" | `subagent` + `model: sonnet` |
| "run a test" / "check syntax" / "call a script" | `inline` (cheap, no subagent needed) |
| "keep retrying until X" | loop transition + consider `max_epoch` lower bound |
| "don't touch my project files" | `modifies_worktree: false` |
| "remember this setup-time value" (git SHA, date, caller context) | `run_files` |
| "branch on the result" | multiple `transitions` keys → different next stages |

---

## Claude Code runtime constraints (NOT validator-checked)

The validator only checks structural JSON correctness. The constraints
below come from how Claude Code actually executes the stages — violating
them produces valid-but-broken workflows that pass validation and then
crash at runtime. Plan around them.

| Constraint | Why it exists | Design rule |
|---|---|---|
| **Subagent stages cannot dispatch sub-subagents** | The `Agent` / `Task` tool is reserved for the main agent. `stagent:workflow-subagent` runs with a fixed allowlist that excludes it. | Any "fan-out N parallel researchers / reviewers / map-reduce workers" pattern MUST live in an `inline` stage (where the main agent can call `Task` itself). A subagent stage that needs concurrency has to use shell-level parallelism (`&` + `wait`). |
| **Subagent stages cannot ask the user questions** | `AskUserQuestion` is a main-agent-only tool. Subagents have no UI surface. | Any human-in-the-loop gate (approval, clarification, "which option?") MUST be an **interruptible inline** stage. Reserve subagent stages for autonomous heads-down work. |
| **Subagent stages start with an empty conversation** | The subagent only sees the prompt the plugin builds (this `.md` file + paths to input artifacts). No main-agent chat history. | If downstream needs the subagent's reasoning, the stage prompt MUST tell the subagent to write that reasoning into its **output artifact**. The artifact is the entire handoff. |
| **Subagent tool allowlist is fixed** | `stagent:workflow-subagent` ships with `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `WebFetch`, `WebSearch`, `NotebookEdit`. No `Agent`, no `AskUserQuestion`, no MCP-only tools, no custom slash-commands. | If a stage needs a tool outside this set (e.g. project MCP server, custom command), it MUST be an inline stage. |
| **Subagent stages run once, then end** | There is no background subagent or daemon. The invocation terminates when `result:` is written. | "Watch this file" / "keep polling until X" don't work in subagent stages. Use **inline interruptible** with explicit pause points, or split the wait into kick-off + check stages. |
| **Stop hook can't fire inside a subagent** | The main agent blocks on `Agent` until the subagent returns. (This is what the `subagent ⇒ interruptible:false` rule below codifies.) | Subagent stages must drive themselves to a terminal `result:` in one pass — no "pause and wait for the user." |
| **Loop-back stages do NOT roll back prior-epoch side effects** | When `FAIL → retry` rewinds, files written, commits made, hub publishes from the previous epoch are still there. | Stage prompts touching external state should either (a) check current state and no-op when already done, or (b) clean up first. Treat every stage entry as "epoch N may already have effects from epoch N-1." |
| **Bash defaults to a 2-minute timeout** | Same Bash tool, same default cap, in both inline and subagent stages. | Slow steps (build, big test suite, network sync) must use `run_in_background: true` and check status, OR be split across kick-off + wait stages. |
| **Subagent context window is bounded (~200K tokens)** | Same Claude limits. Loading 80 files into context blows it. | Stage prompts for subagent stages must explicitly tell the subagent what to read (`from_stage` inputs + named files), NOT "scan the whole repo." |

These constraints are NOT enforced by `setup-workflow.sh --validate-only`.
A workflow that violates them will validate, publish, and then fail when
a user tries to run it. Catch them at design and write time.

---

## Hard rules the validator enforces (don't violate)

- Subagent stages → `interruptible: false` always
- Stage `<name>.md` file lives **directly next to** `workflow.json` (not in a `stages/` subdir)
- Every `from_stage` reference must name a declared stage; every `from_run_file` reference must name a key in top-level `run_files`
- Every transition target must be a declared stage OR a value in `terminal_stages`
- Terminal stage names go ONLY in the `terminal_stages` array — do NOT also add them as keys in `stages`
- `transitions` values are plain strings, not nested objects like `{"target":"x"}`
- No `subagent_type` field on stages (all subagents run under the plugin's generic runner)
- No top-level `name` / `version` / `description` fields (readme.md is the description)

---

## [Planner] Things to NOT bother the user about

These are implementation details with sane defaults — pick silently:

- `terminal_stages` → default `["complete", "escalated", "cancelled"]` unless the user explicitly proposes others
- `max_epoch` → leave off unless the user mentions runaway loops (20 default is fine)
- Default model for subagents → sonnet (pick opus only for clearly heavy stages; haiku for clearly cheap)
- Stage `.md` file names → always `<stage>.md` matching the stage key

Use these defaults silently in the plan; the user sees the structure, not the boilerplate. (Writers: the plan already encodes these decisions — just emit them.)
