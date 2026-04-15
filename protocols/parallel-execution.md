# Protocol: Parallel Execution
# Loaded on-demand by Autopilot when a Flow B task has parallelizable steps.
# Location: ~/MCPs/autopilot/protocols/parallel-execution.md

## Parallel Execution Protocol

When Autopilot plans a multi-service task (Flow B), steps that don't depend on each other can run simultaneously via parallel Agent subagents. This cuts wall-clock time dramatically — setting up 3 independent services takes the time of the slowest one, not the sum of all three.

**But parallelism introduces coordination risk.** Two agents writing to the same file, both trying to acquire credentials interactively, or one agent depending on another's output — these break things silently. This protocol defines when to parallelize, how to coordinate, and how to recover from partial failures.

---

## When to Parallelize

A step group is safe to parallelize when ALL of the following hold:

1. **No data dependency.** Step B does not consume the output of Step A (e.g., Step B doesn't need a database URL that Step A creates).
2. **No file overlap.** The steps write to different files. Two agents writing `.env`, `package.json`, or the same config file is a race condition.
3. **No shared credential acquisition.** If two steps both need the user to log into a service or complete a CAPTCHA, they can't both pause and wait — run them sequentially.
4. **No shared CLI state.** Steps that both run `vercel link` or `supabase init` in the same project directory will conflict. One must finish first.
5. **Independent rollback.** If Step A fails, rolling it back doesn't undo Step B's work.

### Quick Decision Matrix

| Situation | Parallel? | Reason |
|-----------|-----------|--------|
| Set up Supabase + Configure Stripe | Yes | Different services, different files, different credentials |
| Deploy to Vercel + Set up DNS | No | DNS configuration needs the deployment URL |
| Install 3 CLI tools | Yes | No shared state, no file overlap |
| Create DB tables + Seed DB | No | Seeding requires tables to exist |
| Configure Stripe + Configure Razorpay | Yes | Independent payment providers, separate API keys |
| Set up Supabase + Add Supabase auth | No | Auth config depends on Supabase project existing |
| Run tests + Deploy preview | No | Deploy should only happen if tests pass |
| Generate API keys for 3 services | Depends | Yes if all credentials are in keychain; No if any need user interaction |
| Write Vercel config + Write Supabase migrations | Yes | Different files in different directories |
| Write Vercel config + Write next.config.js | No | Both modify project root config, possible conflicts |

---

## How to Split a Plan into Parallel Groups

During Flow B planning (step 3: Analyze), the Opus orchestrator builds a **dependency graph** of the plan steps. Steps are then grouped into **execution waves** — each wave runs in parallel, and waves run sequentially.

### Step 1: Identify Dependencies

For each step in the plan, determine:
- **Inputs**: What does this step need that another step produces? (URLs, credentials, file paths, service IDs)
- **Outputs**: What does this step produce that another step consumes?
- **Files touched**: What files does this step read or write?
- **Credentials needed**: Does this step need user interaction for credential acquisition?

### Step 2: Build Execution Waves

Group steps into ordered waves where:
- All steps within a wave can run simultaneously (no dependencies between them)
- Every step in wave N+1 depends on at least one step in wave N (or earlier)
- Steps that need user interaction for credentials go in their own wave (or are serialized within a wave)

### Step 3: Present the Plan with Waves

When showing the Flow B plan to the user, mark parallel groups clearly:

```
Plan for: Set up production infrastructure

  Wave 1 (parallel):
    [1a] Install Vercel CLI and link project
    [1b] Install Supabase CLI and create project
    [1c] Create Stripe account and get API keys

  Wave 2 (parallel, after Wave 1):
    [2a] Deploy to Vercel preview (needs 1a)
    [2b] Run Supabase migrations (needs 1b)
    [2c] Configure Stripe webhooks (needs 1c)

  Wave 3 (serial):
    [3] Wire environment variables — Supabase URL, Stripe keys into Vercel env
        (needs 2a + 2b + 2c)

  Wave 4 (serial):
    [4] Deploy to production and verify
        (needs 3)
```

The user approves the whole plan once with "proceed." Autopilot then executes wave by wave.

---

## Coordination Mechanism: File-Based Locks

When parallel agents need to touch shared resources (rare but possible), use the lockfile script at `~/MCPs/autopilot/bin/lockfile.sh`.

### Lock Categories

| Lock Name | Protects |
|-----------|----------|
| `env-file` | Writing to `.env` or `.env.local` |
| `package-json` | Modifying `package.json` or running `npm install` |
| `vercel-config` | Modifying `vercel.json` or running `vercel link` |
| `supabase-config` | Modifying `supabase/config.toml` or running `supabase init` |
| `git-operations` | Any `git commit`, `git push`, or branch operations |
| `browser-session` | Playwright browser automation (only one browser at a time) |
| `keychain-write` | Writing new credentials to keychain (reads are safe) |
| `project-config-<file>` | Any other shared config file, named by file |

### Lock Protocol for Subagents

Each parallel subagent MUST follow this protocol when touching shared resources:

```bash
# 1. Acquire lock before touching shared resource
~/MCPs/autopilot/bin/lockfile.sh acquire "env-file" 30

# 2. Do the work
echo "SUPABASE_URL=..." >> .env.local

# 3. Release lock immediately after
~/MCPs/autopilot/bin/lockfile.sh release "env-file"
```

If a lock can't be acquired within the timeout, the subagent should:
1. Report that it's waiting on a shared resource
2. Retry once after 5 seconds
3. If still blocked, report back to the orchestrator for serialization

### Lock Rules

1. **Hold locks for the minimum time.** Acquire, write, release. Don't hold a lock while running a long CLI command unless the lock protects that command's side effects.
2. **Always release in all code paths.** Use trap handlers or ensure the lock is released even on errors.
3. **Never nest locks.** If a step needs two locks, acquire them in alphabetical order to prevent deadlocks. But prefer restructuring so each step needs at most one lock.
4. **Stale lock recovery.** If a subagent dies, its locks become stale. The orchestrator runs `lockfile.sh clean` between waves to clear dead locks.

---

## Spawning Parallel Subagents

The Opus orchestrator uses the `Agent` tool to spawn parallel subagents. Each subagent gets a complete, self-contained prompt.

### Subagent Prompt Template

When spawning a parallel subagent, include:

```
You are an Autopilot subagent executing one step of a parallel plan.

TASK: {specific task description}
PROJECT ROOT: {absolute path}
WAVE: {wave number} — running in parallel with: {other tasks in this wave}

SHARED RESOURCES:
- If you need to modify {file}, acquire lock "{lock-name}" first:
  ~/MCPs/autopilot/bin/lockfile.sh acquire "{lock-name}" 30
  ...do work...
  ~/MCPs/autopilot/bin/lockfile.sh release "{lock-name}"

CREDENTIALS:
- {service} token: $(~/MCPs/autopilot/bin/keychain.sh get {service} api-token)
- Never print credentials. Use subshell expansion.

OUTPUT: When done, report:
1. Status: success | failed | partial
2. What was created/configured
3. Any values the next wave needs (URLs, IDs, etc.)
4. Any warnings or issues
```

### Model Selection for Subagents

Follow the model-routing protocol. Parallel subagents are typically Sonnet-tier tasks:

| Task Type | Model | Rationale |
|-----------|-------|-----------|
| CLI setup + deploy | Sonnet | Standard single-service task |
| Browser credential acquisition | Sonnet | Playwright automation |
| Research/docs lookup | Haiku | Read-only, no side effects |
| Complex multi-step within one service | Sonnet | Needs more reasoning than Haiku |
| Anything involving L3+ decisions | Keep on Opus | Never delegate dangerous decisions |

---

## Handling Partial Failures

When running parallel agents, some may succeed while others fail. The orchestrator must handle this cleanly.

### Failure Modes

| Mode | What Happened | Orchestrator Action |
|------|---------------|---------------------|
| **Clean success** | All subagents in wave succeeded | Proceed to next wave |
| **Single failure** | One subagent failed, others succeeded | Keep successful results. Retry failed step (once, possibly with different approach). If retry fails, assess: can remaining waves proceed without it? |
| **Multiple failures** | Several subagents failed | Stop. Report all failures to user. Recommend either retrying individual steps or falling back to serial execution. |
| **Deadlock** | Subagents waiting on each other's locks | Should not happen if lock rules are followed. Run `lockfile.sh clean`, then re-run the wave serially. |
| **Partial + dependency** | Step 1a failed, but Step 2a depends on 1a | Skip Step 2a in the next wave. Run remaining wave steps that don't depend on 1a. Retry 1a, then 2a in a recovery wave. |

### Recovery Flow

```
1. Wave N completes — collect results from all subagents
2. For each subagent:
   a. Parse result: success / failed / partial
   b. If failed: log error, check if retryable
   c. If partial: log what succeeded, what didn't
3. Run lockfile.sh clean (clear any stale locks from crashed agents)
4. Build Wave N+1:
   a. Include steps whose dependencies all succeeded
   b. Defer steps whose dependencies failed
   c. Add retry attempts for failed Wave N steps (if retryable)
5. If too many failures (>50% of wave), pause and consult user
```

### Result Aggregation

After all waves complete, the orchestrator collects outputs into a unified result. Each subagent reports back through the Agent tool's return value. The orchestrator merges these into the session state:

```bash
~/MCPs/autopilot/bin/session.sh update '{
  "parallel_results": {
    "wave_1": {
      "1a_vercel": {"status": "success", "preview_url": "https://..."},
      "1b_supabase": {"status": "success", "project_url": "https://...", "db_url": "postgresql://..."},
      "1c_stripe": {"status": "failed", "error": "CAPTCHA required", "retryable": true}
    }
  },
  "notes": "Wave 1: 2/3 succeeded. Stripe needs user CAPTCHA. Proceeding with Wave 2 for Vercel and Supabase. Stripe retry deferred."
}'
```

---

## Serial vs Parallel: Full Example

### The Task

> "Set up this Next.js app with Supabase database, Stripe payments, and deploy to Vercel."

### Serial Execution (current behavior)

```
[1] Install Vercel CLI .............. 15s
[2] Link and deploy preview ........ 45s
[3] Install Supabase CLI ........... 15s
[4] Create Supabase project ........ 30s
[5] Run migrations ................. 20s
[6] Get Stripe API keys ............ 60s  (browser automation)
[7] Configure Stripe webhooks ...... 20s
[8] Wire env vars into Vercel ...... 15s
[9] Production deploy .............. 45s
[10] Verify ........................ 10s
                                    -----
                          Total:    275s  (~4.5 minutes)
```

### Parallel Execution (with this protocol)

```
Wave 1 — Setup (parallel):                        Max: 60s
  [1a] Install Vercel CLI + link ......... 40s  |
  [1b] Install Supabase CLI + project .... 45s  |  (all 3 run at once)
  [1c] Get Stripe API keys .............. 60s  |

Wave 2 — Configure (parallel):                    Max: 20s
  [2a] Deploy Vercel preview ............. 45s  |
  [2b] Run Supabase migrations ........... 20s  |  (all 3 run at once)
  [2c] Configure Stripe webhooks ......... 20s  |

Wave 3 — Wire (serial):                           15s
  [3]  Set env vars in Vercel ............ 15s

Wave 4 — Ship (serial):                           55s
  [4a] Production deploy ................. 45s
  [4b] Verify all services ............... 10s
                                          -----
                          Total:          150s  (~2.5 minutes)
                          Savings:        ~45% wall-clock time
```

The token cost is roughly the same (same work gets done), but the user waits significantly less.

---

## Integration with Existing Protocols

### Flow B Modifications

When the Opus orchestrator builds a Flow B plan and identifies parallelizable groups:

1. **Plan phase**: Present the wave-grouped plan (as shown above)
2. **Snapshot phase**: Create snapshot before Wave 1 (existing behavior, unchanged)
3. **Session phase**: Save session with wave structure in the plan field
4. **Execution phase**: Execute wave by wave, spawning parallel agents per wave
5. **Between waves**: Run `lockfile.sh clean`, update session state, check for failures
6. **Post-task**: Record procedure with wave structure so future runs use the same parallelization

### Model Routing Interaction

Parallel execution multiplies the cost savings from model routing. Instead of one Opus agent doing everything serially, you get:
- Opus: orchestrator only (planning + coordination + result aggregation)
- Sonnet: parallel subagents doing the actual work
- Haiku: parallel research/lookup subagents

A 3-service parallel setup might cost: Opus orchestration (~$0.10) + 3x Sonnet agents (~$0.06) = ~$0.16, compared to Opus doing everything serially (~$0.50).

### Review Gate Interaction

- Each parallel subagent checks its own step's decision level
- L3+ steps within a parallel wave get reviewed by the Sonnet review gate individually
- The orchestrator does NOT re-review steps that subagents already reviewed
- If a review gate rejects a step, that subagent reports back and the orchestrator handles it in the recovery flow

### Session Persistence

If Autopilot crashes or hits a rate limit mid-parallel-execution:
- The session file records which wave was in progress and which subagents completed
- On resume, the orchestrator checks session state and re-runs only the incomplete steps from the interrupted wave
- Completed waves are never re-run

---

## Safety Rules

1. **Never parallelize credential acquisition that needs user input.** If two services both need the user to complete a CAPTCHA or approve a login, run them sequentially. The user can only interact with one prompt at a time.
2. **Never parallelize L2+ operations.** Real money operations get serial attention so costs are clearly flagged.
3. **Maximum 3 parallel subagents per wave.** More than 3 risks overwhelming system resources (browser sessions, CLI processes) and makes failures harder to diagnose.
4. **Each subagent gets a 5-minute timeout.** If a subagent hasn't reported back in 5 minutes, the orchestrator treats it as failed and proceeds with recovery.
5. **The orchestrator never delegates its own role.** Planning, wave construction, failure recovery, and result aggregation stay on Opus. Only execution steps get delegated.
6. **Browser automation is serialized by default.** Only one Playwright session can run at a time. If multiple wave steps need browser automation, they must acquire the `browser-session` lock — effectively serializing them even within a parallel wave.

---

## Adding This Protocol to autopilot.md

Add the following entry to the "On-Demand Protocols" section in `agent/autopilot.md`:

```markdown
### When a multi-service task has parallelizable steps:
-> Read `~/MCPs/autopilot/protocols/parallel-execution.md`
This contains wave-based parallel execution, file-based lock coordination, subagent spawning patterns, partial failure recovery, and integration with model routing.
```

And reference the lockfile script in the "Key Paths" table:

```markdown
| Lockfile | `~/MCPs/autopilot/bin/lockfile.sh` |
```
