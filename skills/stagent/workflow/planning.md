# Stage: planning

_Runtime config (canonical): `workflow.json` → `stages.planning`_

**Purpose:** produce an agreed implementation plan and record user approval. Webapp-focused — the plan must specify the frontend framework, key pages/flows, test strategy, and Vercel deployment details.
**Output artifact:** write to the absolute path provided in your prompt
**Valid results this stage writes:** `pending` (plan drafted, awaiting user approval), `approved` (user has explicitly confirmed)

<HARD-GATE>
Do NOT transition out of this stage until the user explicitly confirms the plan.
Write `result: approved` only after they have said so.
</HARD-GATE>

This is an interruptible stage — the stop hook allows natural pauses for Q&A.

## Explore context

Understand the project state (files, conventions, framework, package manager). New project → note it, suggest a starting framework. Existing codebase → respect patterns before proposing anything.

## Ask clarifying questions

You MUST use the `AskUserQuestion` tool for every clarifying question — do NOT ask in plain prose. The picker renders inline in the user's CLI and shows them their options at a glance.

Rules:
- One `AskUserQuestion` call per turn (the tool itself batches up to 4 questions per call when they're tightly related; otherwise prefer one focused question).
- Each question MUST be multiple-choice (2–4 options) with a clear `label` and a one-line `description` that names the trade-off. The user can always pick "Other" to free-type.
- Recommended option goes first and ends with `(Recommended)`.
- Typically 3–6 questions total across the stage; stop asking when you have enough to draft the plan.
- Flag multi-subsystem scopes early and help decompose.

After each answer, briefly acknowledge the choice in prose, then either ask the next question (another `AskUserQuestion` call) or move on to "Propose approaches" once you have enough signal.

## Propose approaches

2-3 options with trade-offs; lead with your recommendation. You may render this as another `AskUserQuestion` so the user picks the approach directly.

## Present design

Architecture, components, data flow, tech stack, error handling, deployment target. Iterate until agreed.

## Write the plan into the output artifact

Write the output artifact (use the current epoch for the frontmatter):

```markdown
---
epoch: <epoch>
result: pending
---
# Planning Report: <Topic>

## Design Summary
<agreed architecture, framework, key decisions>

## Implementation Steps
1. ...

## File Structure
<files / directories to create or modify>

## Acceptance Criteria
- [ ] ...

## Testing Strategy

### Quick Tests
- Framework: <e.g. vitest / jest / pytest — or "none">
- Coverage target: <e.g. 80%>
- Key test cases:
  - [ ] ...

### Journey Tests
- Framework: playwright (default for webapp) | none
- Key user paths:
  - [ ] ...

## Deployment (Vercel)
- Project name: <vercel project slug; will be set on first deploy via `vercel link`>
- Scope: <personal | team-slug>
- Production env vars (names only — values supplied at deploy time):
  - <NAME>
- Build command: <auto-detected, or override>
- Notes: <any deploy-time considerations — protected branches, edge runtimes, etc.>
```

`result: pending` signals "plan written but not approved yet."

## Get user approval

Before the approval picker, print where the plan lives so the user can open it locally or share the cloud link with reviewers on other machines:

- **Local:** the absolute artifact path you just wrote to (the `Output:` value from your stage prompt).
- **Cloud:** `<STAGENT_SERVER>/s/<session-id>` — defaults to `https://stagent.worldstatelabs.com/s/<session-id>`. Read `<session-id>` from the `session_id:` field in `state.md`; respect `$STAGENT_SERVER` if it's set.

Then call `AskUserQuestion`:

```
AskUserQuestion({
  questions: [{
    question: "Plan saved — approve to start execution?",
    header: "Approve plan",
    multiSelect: false,
    options: [
      { label: "Approve and start executing (Recommended)", description: "Sets result: approved and advances to the executing stage." },
      { label: "Request changes",                           description: "Tell me what to revise; I'll update the plan and re-ask." }
    ]
  }]
})
```

If the user requests changes, iterate on the plan body — keep `result: pending`.

## Finalize

Once the user explicitly approves, edit the output artifact: change `result: pending` → `result: approved`.

That is the only action needed here. The main loop reads the artifact's `result:` and calls `update-status.sh` to advance the state machine — do NOT call it yourself from this stage file.
