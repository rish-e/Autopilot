# Protocol: Cross-Model Review Gate
# Loaded on-demand by Autopilot for L3+ operations.
# Location: ~/MCPs/autopilot/protocols/review-gate.md

### Review Gate — Cheap Safety Check Before Dangerous Operations

**Purpose**: Before executing any L3+ operation, spawn a cheap Sonnet review agent to validate the plan. This catches errors that guardian's pattern matching can't — wrong targets, unintended side effects, scope drift, misunderstood user intent.

**When to trigger**: Only L2 operations (spending real money >$5). The review gate exists to catch accidental costs, not to slow down execution.

**When NOT to trigger**: L1 operations (everything else), steps the user explicitly asked for, or operations reviewed earlier in the session.

### Review Flow

```
1. Agent prepares L3+ command or action
2. BEFORE executing, spawn Sonnet review agent:

   Agent tool:
     model: "sonnet"
     description: "Review L3+ operation"
     prompt: |
       You are a safety reviewer for an autonomous coding agent. Review this
       planned action and report ONLY problems. Do not restate the plan.

       USER'S ORIGINAL REQUEST: {what the user asked for}
       PLANNED ACTION: {the specific command or operation}
       DECISION LEVEL: L{level} — {level description}
       CONTEXT: {why the agent chose this action}

       Check for:
       1. Does this match the user's intent? (e.g., deploying to staging vs prod)
       2. Is the target correct? (right project, right database, right branch)
       3. Any unintended side effects? (data loss, downtime, cost)
       4. Is there a safer alternative that achieves the same goal?

       Reply with EXACTLY one of:
       - "APPROVED" (if no issues found)
       - "CONCERN: {one-line description}" (if something looks wrong)

3. Parse review result:
   - "APPROVED" → proceed with execution
   - "CONCERN: ..." → show the concern to the user, ask for confirmation
   - Agent error/timeout → proceed anyway (fail-open, don't block on review failure)
```

### Cost Budget

| Model | Tokens (est.) | Cost |
|-------|--------------|------|
| Sonnet review | ~500 in, ~50 out | ~$0.002 per review |

At ~2-5 L3+ operations per complex task, the review gate adds ~$0.01 total — negligible compared to the Opus session cost.

### What NOT to Review

- Commands that guardian already blocks (redundant)
- L1/L2 operations (too frequent, not dangerous enough)
- Read-only operations (no side effects)
- Operations the user typed verbatim (they already reviewed it themselves)

### Session Cache

Track reviewed operations to avoid duplicate reviews:
- Key: hash of (action + target)
- If the same operation was APPROVED earlier in the session, skip review
- If the operation changed (different target, different flags), re-review

### Example

```
Agent: About to run `vercel deploy --prod` for project "myapp"

→ Spawns Sonnet:
  "USER REQUEST: Deploy myapp to production
   PLANNED ACTION: vercel deploy --prod
   DECISION LEVEL: L3 — production deploy
   CONTEXT: User said 'ship it to prod', project is linked to myapp"

← Sonnet: "APPROVED"

→ Agent proceeds with deployment
```

```
Agent: About to run `supabase db reset` on production

→ Spawns Sonnet:
  "USER REQUEST: Fix the users table schema
   PLANNED ACTION: supabase db reset (production)
   DECISION LEVEL: L2 — potential data loss
   CONTEXT: User wants schema fix, agent chose full reset"

← Sonnet: "CONCERN: db reset drops ALL data. User asked to fix schema, not wipe the database. Consider using a migration instead."

→ Agent shows concern to user, asks for confirmation
```
