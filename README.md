# stagent

**English** | [简体中文](./README.zh-CN.md) | [日本語](./README.ja.md) | [한국어](./README.ko.md) | [Français](./README.fr.md) | [Deutsch](./README.de.md) | [Español](./README.es.md)

A Claude Code plugin that runs **config-driven development workflows** as a state machine. You declare stages, transitions, and inputs in a single `workflow.json`; the plugin's hooks and scripts drive the loop.

Two modes:
- **Cloud** (default) — state mirrored to a [hosted webapp](https://stagent.worldstatelabs.com/) with a live browser viewer, cross-machine resume, and zero project-dir footprint.
- **Local** — state and artifacts live under `<project>/.stagent/`, no network.

## Quick Start

### Installation

Run these slash commands **inside a Claude Code session**. 

```
/plugin marketplace add jie-worldstatelabs/stagent
/plugin install stagent@stagent
```

Already installed? Update with:

```
/plugin update stagent@stagent
```

Requires: [Claude Code](https://claude.ai/claude-code), `jq`, `curl`, `git` (cloud mode also relies on standard POSIX tools like `sha256sum` / `shasum`).

### Run a workflow

**Optional but recommended:** sign in first to claim session ownership and better manage your past sessions.

```
/stagent:login
```

Start the default development workflow — it builds what you describe:

```
/stagent:start --flow=cloud://demo "Build a journaling app with MBTI insights inferred from journal entries"
```

The skill prints a live UI URL. Without sign-in, this is an **anonymous, publicly viewable** session — anyone with the link can watch the state machine run in real time (stage timeline, rendered artifacts, `git diff baseline..HEAD` updating via SSE), and there is no owner.

For a fully offline run, switch to local mode:

```
/stagent:start --mode=local "Build a journaling app with MBTI insights inferred from journal entries"
```

### Create your own workflow template

Define your own workflow from a natural-language prompt — stagent scaffolds the stages:

```
/stagent:create "plan, implement, critique & score UX"
```

This defaults to **cloud** mode: the new template is published to your hub account after the planning + writing stages finish. Sign in first if you haven't already:

```
/stagent:login
```

For a fully offline run (template stays on disk under `~/.config/stagent/workflows/<name>/`, nothing pushed to the hub), switch to local mode:

```
/stagent:create --mode=local "plan, implement, critique & score UX"
```

Need inspiration? Browse the [cookbook](https://stagent.worldstatelabs.com/cookbook) for twelve battle-tested workflow templates you can fork or remix.

## The Default Workflow

With no `--flow` flag:

- **Cloud mode** (default) fetches `cloud://demo` from the hub — a hosted template that may evolve independently of this README
- **Local mode** uses the plugin-bundled workflow at `skills/stagent/workflow/` (offline fallback) — the canonical source for the cycle described below

The bundled workflow runs a **plan → execute → verify → review → QA → deploy** cycle:

1. **Planning** *(interruptible)* — inline Q&A with you: clarifying questions, proposed approaches, plan file. You confirm before anything gets built.
2. **Executing** — subagent (opus) implements the plan: tests-first when specified, minimal focused changes.
3. **Verifying** — quick tests (unit/integration) run inline. FAIL → loop to Execute; PASS/SKIPPED → Review.
4. **Reviewing** — subagent runs adversarial code review against the baseline commit. PASS → QA; FAIL → loop to Execute.
5. **QA-ing** — subagent runs real user journey tests (Playwright, XcodeBuildMCP, etc.). Distinguishes test bugs from app bugs — only confirmed app bugs block progress. PASS → Deploy; FAIL → loop to Execute.
6. **Deploy** *(interruptible)* — inline Vercel CLI flow: `vercel whoami`, `vercel link` on first run, sync production env vars, `vercel --prod`, smoke-check the URL. Interruptible because first-run setup may need `vercel login` in another terminal or env-var values from you. Done → terminal `complete`.

The `execute → verify → review → QA` loop runs **autonomously** after you approve the plan. A Stop hook guarantees the loop runs to completion (until QA passes; deploy then runs as the final, interruptible stage). The loop stops on one of: deploy completes (terminal `complete`), `max_epoch` is hit (default `20`, configured in `workflow.json` → `.max_epoch`; breaks runaway iteration by forcing terminal `escalated`), or you intervene with `/stagent:interrupt` (pauses) or `/stagent:cancel` (terminal `cancelled`). All three — `complete`, `escalated`, `cancelled` — are declared in `workflow.json` → `.terminal_stages`.

## Custom Workflows

The plugin is **generic** — any stage shape works as long as it follows the schema. Running `/stagent:create` (see Quick Start) dispatches an internal stagent that interviews you, writes `workflow.json` + per-stage instruction files under `~/.config/stagent/workflows/<name>/`, validates them in a retry loop, and publishes the bundle to the hub (cloud mode only). Reuse it with:

```
/stagent:start --flow=cloud://<you>/<name> <task>
```

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the `workflow.json` schema.

Need ideas for what to turn into a workflow? See the [cookbook](https://stagent.worldstatelabs.com/cookbook) — twelve ready-to-run workflows for common Claude Code failure modes (goal pursuit, research-first, end-to-end v1, scope lock-down, invariant guardrails, root-cause forced, real bug hunt, strict TDD, real-journey suite, visual QA gate, perf gate, compliance gate), each launchable with `/stagent:start --flow=cloud://...`.

## Commands

| Command | Purpose |
|---|---|
| `/stagent:start [--mode=cloud\|local] [--flow=<ref>] <task>` | Start a new run |
| `/stagent:interrupt` | Pause the active run without clearing state (can be called mid-stage; resume with `/stagent:continue`) |
| `/stagent:continue [--session <id>]` | Resume an interrupted run (`--session` for cross-machine cloud takeover) |
| `/stagent:cancel [--hard]` | Cancel the run. Default archives; `--hard` hard-deletes. Local-mode files are archived/removed accordingly; in cloud mode the local shadow is wiped either way and the difference is only on the server (archived vs hard-deleted) |
| `/stagent:create [--mode=cloud\|local] [--flow=<ref>] <description>` | Create a new workflow or edit an existing one |
| `/stagent:publish <dir> [--name <n>] [--description <d>] [--dry-run]` | Publish a local workflow to the hub |
| `/stagent:login` / `:logout` / `:whoami` | Manage your hub identity |

**`--flow=<ref>`** accepts:
- *(omitted)* — cloud mode fetches `cloud://demo` from the hub; local mode uses the plugin-bundled workflow
- `cloud://author/name` — fetched from the hub (cloud mode)
- `/abs/path` or `./rel/path` — local workflow directory
- `<bare-name>` — resolved against the plugin-bundled workflows first, then `cloud://<bare-name>` on the hub

**Env vars:**

| Variable | Default | Effect |
|---|---|---|
| `STAGENT_DEFAULT_MODE` | `cloud` | Set to `local` to flip the default for every run in the shell |

## Local vs Cloud

| Concern | Local | Cloud |
|---|---|---|
| Authoritative state | `<project>/.stagent/<session>/state.md` | Postgres `sessions` row; local shadow mirrors |
| Where the files live on your disk | Project worktree | `~/.cache/stagent/sessions/<session>/` — wiped on terminal |
| Live viewer | None — read the files | `https://stagent.worldstatelabs.com/s/<session_id>` |
| Cross-machine continue | Not supported | `/stagent:continue --session <id>` with project-fingerprint verification |
| `.gitignore` entry needed | `echo '/.stagent/' >> .gitignore` | None |

### Cross-machine / cross-clone takeover caveat

`/stagent:continue --session <id>` mirrors the workflow's **state** (`state.md`, stage reports, plus the `baseline` run-file — the git SHA captured at workflow start) to the new machine. It does **not** copy the project's source code. Code lives in your git repo, not in the plugin.

`continue-workflow.sh` verifies:

1. The new workdir is the same repo (root-commit fingerprint).
2. The new workdir's HEAD is not behind / diverged from the HEAD the workflow last saw (`last_seen_head` in `state.md`, updated on every stage transition and on `/interrupt`). A behind / diverged HEAD is a **hard block** unless `--force-project-mismatch` is passed — the resumed stage would otherwise run against stale code and re-do or contradict finished work.
3. Uncommitted changes in the new workdir emit a soft warning — they may conflict with the next stage's output.

If the original session committed its subagent work before interrupting, `git fetch && git checkout <last_seen_head>` (or merge that branch) on the new machine brings you in sync before `/continue`.

## Key Design Decisions

- **Config-driven** — stages, transitions, interruptible flags, subagent types/models, and input dependencies all live in `workflow.json`. Adding a stage or changing a transition is a config edit, not a code change.
- **One generic subagent** — every subagent stage runs under a single `workflow-subagent`; the per-stage protocol lives in `<workflow-dir>/<stage>.md`, which the subagent reads at runtime. No per-stage `subagent_type` field.
- **Required inputs block transitions** — `update-status.sh` refuses to move into a stage if any `required` input artifact is missing. State-machine-level enforcement.
- **Epoch-stamped artifacts** — each stage's artifact carries the epoch that was current when it was produced. The stop hook only trusts artifacts whose epoch matches `state.md` — stale artifacts from previous iterations are ignored.
- **Self-contained** — the skill instructs the agent not to invoke external skills, to prevent flow hijacking.
- **Graceful exit auto-interrupts** — when a Claude Code session exits cleanly (e.g. `/exit`, window close), stagent's `SessionEnd` hook flips the active workflow to `interrupted` so another Claude session can pick it up via `/stagent:continue`. Crashes / `kill -9` don't trigger this; in cloud mode, server-side stale detection is the backstop.
- **One session = one run** — each Claude session's run lives in its own session-keyed subdir. Multiple Claude sessions in the same worktree can run independent workflows without interfering.

## Architecture & Internals

See [ARCHITECTURE.md](./ARCHITECTURE.md) for:
- Plugin directory layout
- Runtime file layout (local + cloud)
- `workflow.json` schema reference
- State machine protocol (epoch, result, transitions)
- Stop-hook behavior
- End-to-end cycle walkthrough

## License

MIT
