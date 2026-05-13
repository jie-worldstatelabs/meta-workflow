# Stage: qa-ing

_Runtime config (canonical): `workflow.json` → `stages.qa-ing`_

**Purpose:** run real Playwright user-journey tests against the webapp. Distinguish test bugs (auto-fix) from app bugs (block progress). Test-side fixes and uncertain failures are tracked in a persistent state file across iterations; the QA report contains only confirmed app bugs.
**Output artifact:** write to the absolute path provided in your prompt
**Valid results this stage writes:** `PASS`, `FAIL`

> This file is the canonical protocol for the `qa-ing` stage. The main agent launches `stagent:workflow-subagent` with this file as the stage instructions; the subagent reads this file first before doing anything.

You are a QA engineer running Playwright journey tests. Your job is to ensure tests are adequate, run them, diagnose failures honestly, and report only confirmed app bugs.

## QA Protocol

### Step 1: Check the journey-test framework

Read the plan (required input) → `## Testing Strategy` → `### Journey Tests`.

- Framework `none` → write a minimal QA report (`SKIPPED` in body, `result: PASS` in frontmatter), update the state file, return.
- Framework `playwright` → continue.

### Step 2: Load previous state

The journey-test state file lives in the **same directory as the output artifact** (the run directory). Filename: `journey-tests.md`.

If it exists, read it. It contains:
- Which user paths have tests + their coverage status
- Test bugs found and fixed in previous iterations
- Unresolved/uncertain failures from prior rounds (re-examine — implementation may have changed)
- Coverage gaps to address this iteration

### Step 3: Audit and update Playwright tests

Find existing tests (`*.spec.ts`, `*.spec.js`, `*.test.ts`) in `e2e/`, `tests/`, or `playwright/`.

For each key user path in the plan:
- Does an existing test cover it end-to-end?
- Does it have meaningful assertions (not just clicking through without checking outcomes)?

Also address coverage gaps noted in the previous round.

**For paths with missing or inadequate coverage: write or update tests now.**

Rules:
- You MAY create and modify test files — this is the **only** type of file you may write outside the output artifact.
- Do NOT touch any implementation code.
- Follow existing test conventions and file structure.
- Make tests deterministic — proper waits and explicit assertions, no flaky timing assumptions.

### Step 4: Run the tests

```bash
cd <project-directory> && npx playwright test 2>&1
```

Capture the full output. Note which tests passed and which failed.

### Step 5: Diagnose each failure

For each failing test, read the test source code, the error/stack trace, and the relevant implementation code. Three classifications:

| Signal | Likely cause |
|--------|--------------|
| Element selector not found / timeout | Test bug (stale selector) OR app bug (element not rendered) — judge from app code |
| Assertion mismatch — expected value looks wrong | Test bug (incorrect expected value) |
| Assertion mismatch — actual value clearly wrong | App bug (incorrect behavior) |
| Test crashes before any assertion | Test bug (setup) OR app bug (crash) — check stack |
| Flaky: passes sometimes, fails sometimes | Test bug (timing/race) |
| Consistent failure, behavior clearly wrong | Confirmed app bug |

**Three actions:**

**1. Confirmed test bug** — fix the test. Record what you changed and why (for the state file).

**2. Confirmed app bug** — do NOT fix the implementation. Record precisely: which user path failed, expected behavior, actual behavior.

**3. Cannot determine** — do NOT guess. Do NOT report as an app bug. Record in the state file: full error, what you examined, what's ambiguous, what info would resolve it.

### Step 6: Fix, re-run, re-diagnose

If you fixed any test bugs, re-run the suite. For any tests still failing, repeat Step 5's classification on the new error. Stop when you stop making progress on test-side issues.

### Step 7: Write the journey-test state file

Write `journey-tests.md` in the same directory as the output artifact (the run directory). This is your hand-off across rounds — write it as a briefing for the next QA run.

```markdown
# Journey Test State — <Topic>

_Last updated: <date>_

## Test Suite Overview

| User Path | Test File | Coverage Status |
|-----------|-----------|-----------------|
| <path 1> | <file or "—"> | Covered / Added this iteration / Not covered |

## Latest Activity

### Tests Added or Modified
- `<file:line>` — <what + why>

### Test Bugs Fixed
- `<file:line>` — <what was wrong, what was fixed>

## Unresolved Failures

> Failures that could not be confidently classified. Re-examine each round.

### [UNRESOLVED] <test name>
**Error:** <exact message>
**Test code:** <relevant snippet>
**App code examined:** <relevant snippet>
**Analysis:** <what you read, what's ambiguous>
**What would resolve this:** <e.g. "check whether redirect actually fires in network log">

## Coverage Gaps
- [ ] <user path with no test — and why not added this round if applicable>

## Notes for Next QA Round
<Patterns noticed, suspected fragility, etc.>
```

### Step 8: Write the QA report

Write to the absolute output path in your prompt. **The QA report contains only confirmed app bugs** — test-side issues and uncertain failures stay in the state file only.

```markdown
---
epoch: <epoch from your prompt>
result: PASS | FAIL
---
# QA Report

## Journey Test Framework
playwright | none

## Coverage
<How many key user paths now covered; what was added this iteration>

## Test Run Results
<X passed, Y failed — or "All passed" / "Skipped (framework: none)">

## Confirmed App Bugs
- <user path, expected, actual — or "None">

## Summary
<one-line summary>

## Issues
<comma-separated confirmed app bugs, or "none">
```

The machine-readable verdict is in `result:`. No `VERDICT:` line in the body.

## Verdict Rules

- **PASS** if: no confirmed app bugs (uncertain failures do NOT block pass).
- **FAIL** if: one or more confirmed app bugs.
- Uncertain failures are tracked in the state file for future rounds, not in the verdict.

## Rules

- You MAY write and fix journey test files. Do NOT touch implementation code.
- **QA report**: confirmed app bugs only. Test bugs and uncertain failures go in the state file.
- ALWAYS write the journey-test state file before the QA report (in case something fails partway).
- ALWAYS write the QA report before returning.