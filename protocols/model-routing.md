# Protocol: Model Routing
# Loaded on-demand by Autopilot when needed. Not part of the core prompt.
# Location: ~/MCPs/autopilot/protocols/model-routing.md

## Model Routing Protocol

Autopilot runs on Opus, but most subtasks don't need Opus. Delegating to cheaper models saves 60-90% on token costs without losing quality. **Use the right model for the job, not the biggest one.**

### Model Capabilities & Costs

| Model | Strengths | Weaknesses | Relative Cost |
|-------|-----------|------------|---------------|
| **Opus** | Complex reasoning, multi-step planning, architecture decisions, debugging | Expensive, slower | 1x (baseline) |
| **Sonnet** | Code generation, deployments, standard tasks, browser automation | Struggles with very complex orchestration | ~0.2x |
| **Haiku** | Research, lookups, simple file ops, status checks, formatting | Can't handle complex multi-step logic | ~0.04x |

### Routing Rules

**The main Autopilot agent (Opus) acts as the orchestrator.** It analyzes the task, makes the plan, and delegates subtasks to the cheapest capable model via the `Agent` tool with `model` parameter.

#### Use Haiku (cheapest — ~96% savings) for:
- **Research tasks**: WebSearch, WebFetch, reading documentation
- **Status checks**: checking service health, verifying deployments, reading logs
- **Simple file operations**: reading config files, checking if files exist
- **Formatting**: generating markdown reports, formatting output
- **Service research**: looking up CLI docs, API documentation (during Service Resolution)
- **Playbook lookup**: checking if a playbook exists, listing available playbooks

#### Use Sonnet (mid-tier — ~80% savings) for:
- **Standard deployments**: `vercel deploy`, `supabase db push`, `gh pr create`
- **Browser automation**: Playwright login flows, credential acquisition, form filling
- **Single-service tasks**: anything involving one service with a clear procedure
- **Code generation**: writing config files, scripts, migration files
- **CLI operations**: running build commands, installing packages
- **Memory operations**: recording procedures, logging errors, caching services

#### Keep on Opus (orchestrator) for:
- **Task planning**: analyzing complex tasks, creating multi-step plans (Flow B)
- **Multi-service orchestration**: coordinating 3+ services in a single task
- **Debugging**: diagnosing failures that span multiple services or require deep reasoning
- **Decision-making**: L2+ decisions (cost implications), security-sensitive operations
- **Error recovery**: when the Adaptive Resolution Engine needs creative problem-solving
- **Architecture decisions**: choosing between approaches, evaluating tradeoffs

### How to Delegate

When the Autopilot agent identifies a subtask that can use a cheaper model, spawn a subagent:

```
Use the Agent tool with:
  model: "haiku"  (or "sonnet")
  prompt: "<clear, complete description of the subtask>"
  description: "<3-5 word summary>"
```

**Rules for delegation:**
1. **Give complete context.** The subagent has no memory of the current session. Include everything it needs: file paths, service names, what to do, what to return.
2. **One task per subagent.** Don't ask a Haiku agent to do three things — it will lose track. One clear task, one clear output.
3. **Validate the result.** When the subagent returns, verify the output makes sense before using it. Cheaper models can hallucinate or miss edge cases.
4. **Fall back up, not down.** If a Sonnet subagent fails at a task, retry on Opus — not on Haiku.
5. **Never delegate security decisions.** Credential handling, guardian rule evaluation, and L2+ decisions (cost) stay on Opus.
6. **Parallel when possible.** Independent subtasks on cheap models should run concurrently via multiple Agent tool calls in a single message.

### Cost Tracking

After every task, record the model used and estimated cost:

```bash
python3 ~/MCPs/autopilot/lib/memory.py record-run "{task_name}" "success" \
    --tokens {total_tokens} --cost {estimated_cost_usd}
```

**Estimating cost** (per 1M tokens, approximate):
- Opus input: $15 / output: $75
- Sonnet input: $3 / output: $15
- Haiku input: $0.25 / output: $1.25

### CascadeFlow Routing (SOTA)

Instead of assigning models at plan time, use **adaptive escalation**: start cheap, escalate on failure.

```
For each delegated subtask:
  1. Try on HAIKU first (if task type supports it)
     → Success? Done. Cost: ~4% of Opus.
     → Failed or low-quality output? ↓

  2. Retry on SONNET
     → Success? Done. Cost: ~20% of Opus.
     → Failed? ↓

  3. Execute on OPUS (guaranteed quality)
     → Always succeeds or reports genuine blocker.
```

**When to use CascadeFlow vs Static Routing:**
- **CascadeFlow**: Best for tasks where you're unsure of required complexity (research that might be simple or complex, code generation that might need iteration).
- **Static routing**: Best when you KNOW the complexity upfront (deployment commands → always Sonnet, doc lookup → always Haiku).

**CascadeFlow rules:**
- Never cascade security decisions — always Opus.
- Never cascade browser automation — always Sonnet minimum (Haiku can't handle multi-step browser flows).
- Track cascade patterns: if Haiku fails 3+ times on a task TYPE, auto-promote that type to Sonnet-minimum in future.
- Log escalations to memory.py for cost optimization analysis.

### Token Budget Estimation

Before executing a complex task, estimate the cost:

```bash
python3 ~/MCPs/autopilot/lib/memory.py estimate-cost "{task_description}" --services "{service1},{service2}"
```

If the estimate returns high confidence and the cost exceeds $0.50, mention it to the user in the plan:
"Estimated cost: ~$X.XX based on N similar tasks."

After every task, track actual vs estimated for calibration.

### When NOT to Route

Don't bother routing for:
- **Very short tasks** (< 5 tool calls). The overhead of spawning a subagent costs more than the savings.
- **Tasks you're already executing.** Don't stop mid-flow to spawn a subagent for the next step — just do it. Route at the **planning stage**, not mid-execution.
- **Interactive tasks** that need back-and-forth with the user. Keep those on the main Opus agent.

### Flow Integration

**Flow A (simple tasks):** Usually no routing needed — the task is so simple that spawning a subagent adds overhead. Just execute directly on Opus. Exception: if the simple task is pure research or a status check, route to Haiku.

**Flow B (complex tasks):** After creating the plan, classify each step:
1. Assign a model to each step based on the routing rules above
2. Group independent steps by model for parallel execution
3. Execute: cheap steps first (fast, parallel) → expensive steps after (sequential, validated)
4. The Opus orchestrator stays in control, only delegating execution

### Example

Task: "Set up Supabase for my new project and deploy to Vercel"

```
Plan:
  Step 1: Check credentials (Opus — already running, quick check)
  Step 2: Research Supabase project setup (Haiku — just docs lookup)
  Step 3: Create Supabase project via CLI (Sonnet — standard CLI task)
  Step 4: Run database migrations (Sonnet — standard CLI task)
  Step 5: Deploy to Vercel preview (Sonnet — standard CLI task)
  Step 6: Configure env vars on Vercel (Sonnet — standard CLI task)
  Step 7: Verify everything works (Haiku — status checks)

Cost without routing: ~$0.50 (all Opus)
Cost with routing:    ~$0.12 (1 Opus + 4 Sonnet + 2 Haiku)
Savings: ~76%
```
