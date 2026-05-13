# Run Files Catalog

Run files are created **once at setup time** (before any stage runs) and can be
declared as inputs to any stage via `"from_run_file": "<name>"` in `workflow.json`.

They are distinct from stage artifacts: they are not produced by any stage, they
are not cleared on transitions, and they live in the run directory for the entire
lifetime of the run.

## Declaring a run_file

In `workflow.json`, add a top-level `run_files` object:

```json
"run_files": {
  "<name>": {
    "description": "<what it contains>",
    "init": "<shell command — stdout is written to the file>"
  }
}
```

The `init` command runs with `$PROJECT_ROOT` as the working directory.
Its stdout is written verbatim to `<run-dir>/<name>`.

## Consuming a run_file in a stage

In a stage's `inputs.required` or `inputs.optional`:

```json
{ "from_run_file": "baseline", "description": "Git SHA at workflow start" }
```

`stage-context.sh` (inline stages) and `agent-guard.sh` (subagent stages) will
resolve and inject the absolute path, the same as any stage artifact input.

## Known Patterns

| Name         | init                                              | Purpose                          | When to use                              |
|--------------|---------------------------------------------------|----------------------------------|------------------------------------------|
| `baseline`   | `git rev-parse HEAD 2>/dev/null \|\| echo EMPTY`  | Git SHA at workflow start        | Any stage that diffs code changes        |
| `start_time` | `date -u +%s`                                     | Unix timestamp at workflow start | Stages that measure elapsed time         |

## Custom run_files

Any shell command works as `init`. Examples:

```json
"run_files": {
  "schema_snapshot": {
    "description": "DB schema at workflow start",
    "init": "pg_dump --schema-only mydb 2>/dev/null || echo UNAVAILABLE"
  },
  "env_snapshot": {
    "description": "Relevant environment variables at start",
    "init": "env | grep -E '^(NODE_|PYTHON|GO)' | sort"
  }
}
```

## Validation

`config_validate` (run by `setup-workflow.sh --validate-only`) checks that every
`from_run_file` reference in stage inputs names a key that exists in `.run_files`.
A missing entry is a hard error — the workflow will not start.

