# Stage: deploy

_Runtime config (canonical): `workflow.json` → `stages.deploy`_

**Purpose:** deploy the webapp to Vercel via the Vercel CLI and record the production URL — maximize automation, minimize user prompts.
**Output artifact:** write to the absolute path provided in your prompt
**Valid results this stage writes:** `pending` (deploy in progress / awaiting user action), `deployed` (production deploy succeeded and smoke-checked)

This is an interruptible stage — but the design goal is **zero user prompts in the common case**. User interaction is only triggered when truly unavoidable (CLI not logged in; Marketplace integrations or unknown KEYs that require user action; persistent deploy / smoke failure). All other paths should be silent.

## Inputs

- **Required:**
  - `planning` report — read for: Vercel project name, scope, production env-var KEY names, build command override, deployment notes
  - `qa-ing` report — confirms QA passed (the state machine only routes here on `qa-ing.PASS`)

## Operating principles

1. **Silent-by-default**: no user-visible message unless a step explicitly says so.
2. **At most one batched ask** (Step 4) for everything that genuinely needs user action — never one message per item.
3. **Token sourcing**: never invent a custom token cache. Use, in this order: `$VERCEL_TOKEN` → CLI's own auth state (via `vercel whoami`) → ask the user to run `vercel login` once. Vercel CLI persists creds at its own standard location (macOS `~/Library/Application Support/com.vercel.cli/`, Linux `~/.local/share/com.vercel.cli/`) — do not copy or cache those files yourself.

## Step 1 — Token resolution (silent)

Try in order, stop on first hit:

1. `$VERCEL_TOKEN` set → from now on, every `vercel ...` call below MUST be invoked with `--token=$VERCEL_TOKEN`.
2. Run `vercel whoami` (no `--token`). Exit 0 → CLI is logged in; subsequent calls do **not** need `--token`.
3. Both failed → this is the **only** reason this stage ever asks the user about login. Send a single short message:

   > "I need a Vercel token. In another terminal run `vercel login`, then reply `ok` here and I'll continue."

   Keep `result: pending` while waiting. When the user replies `ok`, re-run `vercel whoami`. If still not logged in, repeat the wait — do **not** advance to Step 2 until `vercel whoami` succeeds.

Record which mode won (`env-token` / `cli-session` / `user-login-then-cli-session`) for the deploy report.

## Step 2 — Project link (silent)

- If `.vercel/project.json` exists → already linked. Continue.
- Else read the plan's `## Deployment (Vercel)` section for project name and scope. Defaults if the plan didn't fill them: name = `basename(cwd)`, scope = personal (no `--scope`).
- Run non-interactively:
  ```bash
  vercel link --yes --project=<name> [--scope=<scope>] [--token=...]
  ```
- On failure → jump to Step 7 (persistent-failure fallback) with a short diagnostic.

## Step 3 — Env-var resolution & classification (silent)

1. **Pull remote keys**:
   ```bash
   vercel env pull --environment=production .vercel-env-pulled [--token=...]
   ```
   Parse the resulting file to get the set of KEY names already configured for the Vercel production environment. (Values are not needed here — only KEY presence.)

2. **Aggregate local sources** (precedence, earlier wins): `.env.production.local` → `.env.local` → `.env.production` → `process env`. From process env, only consider KEYs the plan listed — don't pollute production with arbitrary shell vars.

3. **Compute missing**: `missing = plan_required_keys − (vercel_production_keys ∪ local_aggregated_keys)`.

4. **Local-but-not-Vercel KEYs**: for each KEY present in the local aggregate but not in Vercel production, push it silently:
   ```bash
   printf '%s' "<value>" | vercel env add <K> production [--token=...]
   ```

5. **Classify each KEY in `missing`** into exactly one of three buckets by name pattern:

   **(a) Vercel first-party storage — auto-provision (NO user action):**

   | KEY pattern | Provision command |
   |---|---|
   | `POSTGRES_URL`, `POSTGRES_PRISMA_URL`, `POSTGRES_URL_NON_POOLING`, `POSTGRES_USER`, `POSTGRES_HOST`, `POSTGRES_PASSWORD`, `POSTGRES_DATABASE` | `vercel storage create postgres <project>-db --link [--token=...]` |
   | `KV_URL`, `KV_REST_API_URL`, `KV_REST_API_TOKEN`, `KV_REST_API_READ_ONLY_TOKEN` | `vercel storage create kv <project>-kv --link [--token=...]` |
   | `BLOB_READ_WRITE_TOKEN` | `vercel storage create blob <project>-blob --link [--token=...]` |
   | `EDGE_CONFIG` | `vercel storage create edge-config <project>-config --link [--token=...]` |

   Run each provision command (one per matched group) sequentially, each with a 60s timeout. The CLI binds the resulting KEYs to the project's production env automatically — no user input needed. Record what was created and which KEYs it satisfied.

   **(b) Known Marketplace integrations — one-click deep links (user must click):**

   For each KEY in `missing` not satisfied by (a), match against this table. If matched, queue a deep link of the form `https://vercel.com/integrations/<slug>/new?teamSlug=<scope>&projectId=<id>` for Step 4.

   | KEY pattern | Marketplace slug |
   |---|---|
   | `DATABASE_URL` (and not already covered by Postgres pattern in (a)) | `neon` |
   | `REDIS_URL`, `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN` | `upstash` |
   | `OPENAI_API_KEY` | `openai` |
   | `ANTHROPIC_API_KEY` | `anthropic` |
   | `RESEND_API_KEY` | `resend` |
   | `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` | `stripe` |
   | `CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY` | `clerk` |
   | `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | `supabase` |

   To get `projectId` for the deep link, read it from `.vercel/project.json` (after Step 2 ensures it exists).

   **(c) Unknown / truly private KEYs**: anything not matched by (a) or (b) → queue for Step 4 as "user must paste a value".

6. **Browser-assisted acquisition (best-effort, drains queues before Step 4)**: for any KEY still in queues (b) or (c), if you have a browser-automation tool available in your runtime, attempt to obtain the value yourself instead of bothering the user:

   - Open a **visible** (non-headless) browser to the provider's API-keys / dashboard page (e.g. for OpenAI, the API keys settings page; for the Marketplace deep link in (b), the link itself).
   - If the user is not logged in, leave the page open with a one-line nudge: "Sign in to <provider> in the open browser window — I'll grab the key once you're in." Wait silently for the post-login page to appear.
   - Once authenticated, click "Create new key" / equivalent, copy the resulting value, then immediately `printf '%s' '<value>' | vercel env add <K> production [--token=...]` and drop `<K>` from the queue. Close the page.
   - Per KEY: at most one browser attempt, at most ~2 minutes wait for the user to finish login. On any failure (no browser tool available, provider page changed, user closed window, timeout, captcha, MFA the agent can't observe), silently fall back: leave `<K>` in its original queue and proceed.
   - **Do not** attempt to type the user's password, accept ToS, or click through OAuth scopes on their behalf. Driving "Create key" after the user is already signed in is fine; impersonating the login itself is not.
   - **Do not** persist the obtained value anywhere except via `vercel env add` — no logs, no tmp files, no copy into the report.

7. After the browser pass, if both queues (b) and (c) are now empty (everything either auto-provisioned in (a), drained by the browser pass, or never missing), **skip Step 4 entirely** and go straight to Step 5. This is the zero-prompt path.

## Step 4 — Single batched ask (only if Step 3 queued anything)

Send **one** message with up to three sections — omit any section whose queue is empty:

```
✅ Auto-provisioned (FYI, no action needed):
- <type> <name> → keys: <K1, K2, ...>
- ...

🔗 One-click Marketplace integrations (click each link to install; they auto-bind env vars):
- <slug>: https://vercel.com/integrations/<slug>/new?teamSlug=<scope>&projectId=<id>
- ...

✏️ Still need values from you (paste back as KEY=value, one per line):
- <K1>=
- <K2>=
```

Then keep `result: pending` and wait for one response.

When the user responds:

- For each pasted `KEY=value`: `printf '%s' '<value>' | vercel env add <K> production [--token=...]`.
- If any Marketplace integrations were listed, re-run `vercel env pull --environment=production .vercel-env-pulled [--token=...]` and recompute `missing` against the original plan KEYs. If still missing, send **at most one** follow-up message listing only the remaining items (same three-section format). Do not loop more than once on this — if a second pass still leaves items missing, jump to Step 7.

## Step 5 — Deploy (auto-retry once on transient errors)

```bash
vercel --prod --yes [--token=...] 2>&1 | tee /tmp/vercel-deploy.log
```

- On success, parse the production URL from the output tail (matches `https://<project>-...vercel.app` or the configured alias).
- On failure, scan `/tmp/vercel-deploy.log` for transient-error markers (case-insensitive): `ENETDOWN`, `ETIMEDOUT`, `ECONNRESET`, HTTP `5\d\d`, `rate limit`. If matched → `sleep 5 && <retry once>`. Record `transient error matched: <pattern>` for the report.
- Second attempt still fails, OR error is non-transient (build error, missing env, permission error) → jump to Step 7.

## Step 6 — Smart smoke check

```bash
curl -sS -I -L --max-time 30 -o /tmp/smoke-headers.txt -w "%{http_code}\n" "<DEPLOY_URL>"
```

- `2xx` → mark `deployed`.
- `401` → check `/tmp/smoke-headers.txt` for any of these markers (case-insensitive):
  - header `x-vercel-protection-bypass-info` present
  - `set-cookie:` line containing `_vercel_jwt`
  - body of a follow-up `curl -sS -L --max-time 30 "<DEPLOY_URL>"` containing `Authentication Required` or `Vercel Authentication`

  Any marker matched → this is **Vercel Deployment Protection**, which is expected for protected previews/prod. Auto-pass: mark `deployed` and note `auto-passed (Vercel Deployment Protection detected)` in the report's Smoke Check section. Do NOT ask the user.

- `3xx` → already followed via `-L`; if still 3xx in the captured headers (redirect loop), jump to Step 7.
- Anything else → jump to Step 7.

## Step 7 — Persistent-failure fallback (only when Steps 5/6 cannot proceed)

Keep `result: pending`. Send **one** message:

```
Deploy stalled at <step>: <one-line cause>.

Last 30 lines of log:
<tail>

Choose:
- reply `retry` — I'll re-run from Step 5
- run `/stagent:cancel` — abort this workflow, you'll handle it manually
```

Then stop and let the stop hook hand control back to the user.

If the user replies `retry`, jump to Step 5. (Do not loop indefinitely — if a retry fails again, send Step 7 again with the new tail; the user can decide whether to keep retrying or cancel.)

## Step 8 — Write the deploy report

Once Step 6 produced an acceptable status, write the artifact at the path given in your prompt:

```markdown
---
epoch: <epoch>
result: deployed
---
# Deploy Report

## Deployment URL
<https://...>

## Vercel Project
- name: <...>
- scope: <...>
- linked via: existing .vercel/project.json | new (vercel link)
- token mode: env-token | cli-session | user-login-then-cli-session

## Environment Variables

### Auto-provisioned (Vercel first-party storage)
- <type> <name> → keys: <K1, K2, ...>

### Installed via Marketplace (one-click)
- <slug> → keys: <K1, ...>

### Set from local sources
- <K> (source: .env.production.local | .env.local | .env.production | process env)

### Set from user input (this run)
- <K> (production)

## Smoke Check
- HTTP status: <200 / 401-auto-passed / ...>
- Auto-pass reason: <none | Vercel Deployment Protection>

## Auto-retries
- deploy attempts: <1 | 2>
- transient error matched: <none | pattern>

## Deploy Log Tail
<last 30 lines of `vercel --prod` output>
```

## Finalize

Once the deploy is live and smoke-checked, set `result: deployed`. The main loop reads `result:` and calls `update-status.sh` to advance to `complete` — do NOT call it yourself from this stage file.

## Rules

- Treat `result: deployed` as the final commit. Don't write it speculatively — only after a successful production deploy whose smoke check either returned 2xx or auto-passed via the Vercel Deployment Protection markers.
- Keep secrets out of the report — record env-var **names** and source bucket, never values.
- Never invent a custom token cache or copy CLI creds out of the CLI's own storage path.
- The "single batched ask" in Step 4 is a hard contract: if you find yourself sending a second user-facing message before deploy succeeds (other than the single Step-7 fallback or one Step-4 follow-up), you've broken the design — go silent and resume.
- If the user wants to abort, they use `/stagent:cancel`. Don't try to "auto-rollback" from this stage.