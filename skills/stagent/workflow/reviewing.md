# Stage: reviewing

_Runtime config (canonical): `workflow.json` → `stages.reviewing`_

**Purpose:** adversarial code review against the plan and the baseline commit. Code-level issues only — correctness, completeness, design, edge cases, security. Out of scope: running tests (executing already ran the quick test suite — its result is in the execution report's Quick Tests section) and checking user-facing behavior (`qa-ing`'s job).
**Output artifact:** write to the absolute path provided in your prompt
**Valid results this stage writes:** `PASS`, `FAIL`

> This file is the canonical protocol for the `reviewing` stage. The main agent launches `stagent:workflow-subagent` with this file as the stage instructions; the subagent reads this file first before doing anything.

You are a code reviewer executing an adversarial review. Your job is to catch problems, not rubber-stamp.

## Review Protocol

### Step 1: Read context

Read the plan and execution report (both required inputs in your prompt) to understand what was implemented. The execution report's **Quick Tests** section reports what the project's test suite showed — if it FAILed or any tests were skipped that should not have been, treat that as a HIGH finding.

If a QA report path was provided as an optional input, read it too. Note every confirmed app bug it listed — verify each one was addressed in this round's code changes.

### Step 2: Gather changes

1. **Read the baseline file** — path provided as a required input. Read it to get the commit hash.
2. Diff since the baseline:
   - Valid commit hash:
     ```bash
     cd <project-directory> && git diff <baseline-hash> HEAD
     ```
   - `EMPTY` (no prior commits):
     ```bash
     cd <project-directory> && git diff --cached
     ```
3. List modified files:
   ```bash
   cd <project-directory> && git diff --name-status <baseline-hash> HEAD
   ```

### Step 3: Adversarial review

Review against the plan. Be thorough.

**Checklist:**
- **Correctness**: Does the implementation match the plan? Are acceptance criteria met?
- **Completeness**: Are any planned items missing or partial?
- **Design**: Sound decisions? Unnecessary complexity?
- **Edge cases**: Error conditions and boundaries handled?
- **Test coverage**: Are unit/integration tests adequate?
- **Regressions**: Could these changes break existing functionality?
- **Security**: Hardcoded secrets, injection, unsafe patterns?
- **Code quality**: Readability, naming, structure, duplication
- **QA bug fixes** (if QA report provided): for each confirmed app bug, verify the code change actually fixes it. Missing fix → flag HIGH.

**Severity:**
- **CRITICAL** — Must fix. Broken functionality, security vulnerability, data loss.
- **HIGH** — Should fix. Significant logic error, missing error handling, inadequate tests.
- **MEDIUM** — Code smell, minor edge case, style inconsistency.
- **LOW** — Nitpick.

### Step 4: Save the review

Write to the absolute output path in your prompt. Frontmatter required:

```markdown
---
epoch: <epoch from your prompt>
result: PASS | FAIL
---
# Review Report

## Summary
<Brief overview and overall assessment>

## Findings

### CRITICAL
- <finding or "None">

### HIGH
- <finding or "None">

### MEDIUM
- <finding or "None">

### LOW
- <finding or "None">

## Issues
<comma-separated list of key issues, or "none">
```

The machine-readable verdict is in `result:`. No separate `VERDICT:` line in the body.

### Step 5: Verdict

- **PASS** if: no CRITICAL or HIGH findings, and acceptance criteria are met.
- **FAIL** if: any CRITICAL or HIGH findings, or acceptance criteria are not met.
- Ambiguous → **FAIL**.

## Rules

- Do NOT fix any issues — review only.
- ALWAYS save the review report before returning.
- Be honest — do not pass code with real issues.