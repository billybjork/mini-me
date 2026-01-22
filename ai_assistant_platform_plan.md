# Mini Me: AI Assistant Platform Architecture Plan

---

## Executive Summary

A multi-tenant AI assistant platform providing users with isolated, sandboxed virtual environments where AI agents execute complex, multi-step tasks autonomously. The platform combines a lightweight orchestration layer (Elixir/Phoenix) with persistent execution environments (Fly.io Sprites).

**Core Value Proposition**: "Your AI that can actually *do things* — safely, reliably, and autonomously."

**Target Use Cases**:
- "Download my bank statements and ingest into tracker"
- "Download this video, transcribe, summarize, create cutdown"
- "Propose email lists to unsubscribe from"
- "Send daily Slack summary with action items"
- "Prep message before each meeting based on context"
- "Find restaurant, check availability, make reservation"

---

## Design Principles

These principles guide all architectural decisions:

1. **Minimize User Complexity**  
   Auto-retry, auto-checkpoint, auto-evict. User sees "agent minutes" not infrastructure.

2. **Fail Loud, Recover Quietly**  
   Fix problems automatically. Only surface to user if action needed.

3. **Separation of Concerns**  
   Brain (Elixir/outer loop) vs. Hands (Sprite/inner loop). Never mix orchestration with execution.

4. **Idempotency by Default**  
   All write operations get dedupe keys. Safe to retry anything.

5. **Confirmation as Conversation**  
   No modal dialogs. Ask naturally in chat flow.

6. **Privacy First**  
   Credentials injected only for task duration. Logs auto-expire. User can delete all data.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              USER INTERFACES                                │
│  Web Dashboard  │  SMS  │  Slack  │  Discord  │  Email  │  Webhooks         │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    OUTER LOOP — "The Brain" (Elixir/Phoenix)                │
│                                                                             │
│  • Intent classification & routing (fast LLM: Claude Haiku/)                │
│  • Task decomposition & orchestration                                       │
│  • Sprite lifecycle management (wake, checkpoint, restore)                  │
│  • User auth, billing, permissions                                          │
│  • Progress monitoring & user communication                                 │
│  • Fault tolerance & retry logic                                            │
│                                                                             │
│  Key: Stateless request handling + stateful user sessions (GenServer)       │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │ Sprite API (REST + WebSocket)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    INNER LOOP — "The Hands" (Fly.io Sprite)                 │
│                                                                             │
│  • Task execution with full Linux environment                               │
│  • Tool orchestration (ffmpeg, browser, APIs)                               │
│  • File system state (repos, downloads, outputs)                            │
│  • Heavy LLM work (Sonnet/Opus for coding, reasoning)                       │
│  • Concurrent jobs via multiple exec sessions (Sprite API)                  │
│                                                                             │
│  Key: Persistent state that survives hibernation. "Context is king."        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why Two Loops?

| Concern | Outer Loop (Elixir) | Inner Loop (Sprite) |
|---------|---------------------|---------------------|
| **Primary job** | Orchestrate | Execute |
| **LLM type** | Fast, cheap (routing) | Capable, expensive (work) |
| **State** | User session in memory | Files, deps, context on disk |
| **Lifecycle** | Always running | Hibernates when idle |
| **Failure mode** | Restart task | Checkpoint & restore |

This separation of concerns (brain vs. hands) matches proven orchestrator-worker patterns.

---

## Core Entities

### Entity Relationship Overview

```
User
 ├── Tasks (1:many) ──── Repo (many:1, optional)
 │    ├── Messages (1:many)
 │    └── ExecutionSessions (1:many)
 │         └── Messages (1:many, optional)
 │
 ├── Repos (1:many) ──── registered GitHub repos
 │
 ├── Credentials (1:many)
 ├── Connectors (1:many)
 └── Schedules (1:many)

Sprite (shared, single instance for MVP)
 └── Checkpoints
```

**Note**: For MVP, all users share a single default sprite. The outer loop manages repo locking to ensure only one active task uses a given repo at a time.

### Key Entities

| Entity | Purpose | Key Fields |
|--------|---------|------------|
| **User** | Account & auth | email, tier, status |
| **Task** | Conversation/work unit | title, repo_id (optional), status (active/awaiting_input/idle) |
| **Repo** | GitHub repository | github_url, github_name, default_branch |
| **Message** | Chat message in conversation | task_id, execution_session_id, type, content, tool_data |
| **ExecutionSession** | Agent execution boundary | task_id, sprite_name, session_type, status, started_at, ended_at |
| **Checkpoint** | Sprite state snapshot | sprite_checkpoint_id, label, created_at |
| **Credential** | Encrypted secret | key, type, encrypted_value, permissions |
| **Connector** | Input/output channel | type (sms/slack/etc), config, auth_data |
| **Schedule** | Recurring task | cron_expression, task_template |
| **Tool** | Atomic capability | executable, install_command, permissions |
| **Skill** | Prompt + tools bundle | prompt_template, required_tools |
| **App** | Pre-packaged environment | setup_script, launch_command, port |

**Task**: A task is essentially a conversation - the primary unit of work in the system. Tasks can optionally be associated with a GitHub repo for code-related work, but standalone tasks are equally valid. Task status reflects the conversation state: `active` (agent working), `awaiting_input` (agent finished, user's turn), `idle` (no recent activity, agent suspended).

**Message & ExecutionSession**: Messages are persisted chat records (user, assistant, system, tool_call, error). An ExecutionSession tracks when an agent has active context—messages within a session share that agent's memory. When a session ends (completed/failed/interrupted), subsequent messages start fresh. Messages can exist without a session (general chat) or within one (agent execution). This distinction is surfaced in the UI with visual session boundaries.

**Repo Locking**: For MVP, only one active task can work on a given repo at a time. This prevents file conflicts in the shared sprite. The allocator tracks which task holds the lock and releases it when the task goes idle or is deleted.

### Task State Machine

```
pending → classifying → routing → executing → completed
                           ↓          ↓
                        failed   awaiting_input
                           ↓          ↓
                       [retry]   [user responds]
```

States align with `Platform.TaskProcessor` GenServer states.

---

## Outer Loop: Orchestration

### Request Flow

```
1. INGEST        Connector receives message → create Message record
2. CLASSIFY      Fast LLM determines intent: new_task | continue | query | admin
3. ROUTE         Identify skill/app, estimate duration, check budget
4. DISPATCH      Wake sprite → upload attachments → create checkpoint → start job
5. MONITOR       Stream progress, enforce limits, relay clarifications
6. COMPLETE      Receive artifacts → transfer to storage → notify user
```

### Key Patterns

**User Session as GenServer**
Each active user gets a GenServer that holds context and can sleep while waiting for long-running sprite work, then wake instantly on sprite events.

**Circuit Breaker**
If a user's tasks fail repeatedly, queue incoming tasks and trigger recovery flow (see Fault Tolerance).

**Graceful Degradation**
If sprite is unavailable or recovering, queue tasks rather than fail immediately.

---

## Inner Loop: Execution

### Sprite Lifecycle

```
[Created] → [Active] ←→ [Hibernating] → [Destroyed]
              ↓
         [Checkpoint] → [Restored]
```

- **Hibernates** after 30s inactivity (no compute charges)
- **Wakes** in <1s with full filesystem intact
- **Checkpoints** in ~300ms (copy-on-write)
- **Restores** in <1s to any checkpoint

Inactivity = no active exec sessions. Long-running jobs (video transcode, large download) keep the sprite active until completion.

### Bootstrap Process

When a sprite wakes from hibernation:
1. Control plane receives wake notification
2. Outer loop fetches task context (repo info, pending state)
3. Credentials injected as env vars for the session (scoped, temporary)
4. Sprite is ready to receive `exec()` calls

### Concurrency Model

**Key insight**: Concurrency is managed by the **outer loop**, not inside the sprite.

```
OUTER LOOP (Elixir) — OWNS ALL CONCURRENCY
│
├── User A (GenServer process)
│   ├── Task 1 → Sprite A, exec() → Session 1 (running)
│   ├── Task 2 → Sprite A, exec() → Session 2 (running)  ← concurrent in same sprite
│   └── Task 3 → queued (user at max concurrent limit)
│
├── User B (GenServer process)
│   └── Task 1 → Sprite B, exec() → Session 1 (running)
│
├── User C, D, E... (thousands of concurrent users - Elixir's strength)
│
└── Each user session can sleep while sprite works, wake on events
```

```
USER A'S SPRITE (single VM, multiple sessions)
│
├── Session 1: Inner Agent executing Task 1
├── Session 2: Inner Agent executing Task 2
│
├── /home/user/jobs/
│   ├── task-1/  (Task 1's working directory)
│   └── task-2/  (Task 2's working directory)
│
└── Shared: installed tools, caches, user config
```

**Where concurrency lives**:
| Layer | Concurrent? | How |
|-------|-------------|-----|
| Outer loop | ✅ Yes | Elixir process per user session, async task dispatch |
| Sprite API | ✅ Yes | Multiple exec sessions supported natively |
| Inner agent | ❌ Control | Single decision loop, but tools may spawn parallel subprocesses |

The Sprite API handles session multiplexing. The outer loop handles scheduling. The inner agent's *reasoning* is single-threaded (one LLM call → one action → observe → repeat), but tool execution can be parallel (e.g., concurrent downloads, background processes).

**Concurrency Risks & Mitigations**:
| Risk | Mitigation |
|------|------------|
| Filesystem collisions | Each task works in `/home/user/jobs/{task_id}/` |
| Dependency races | Outer loop serializes install commands (or file lock) |
| Resource contention | Outer loop enforces max concurrent tasks; queues excess |
| Orphaned processes | Outer loop tracks sessions; cleans up on timeout/failure |

### Third-Party Agent Delegation

When delegating to agents like Claude Code:
1. **Checkpoint** before handoff
2. **Spawn** as subprocess with PTY wrapper (intercept I/O)
3. **Monitor** output, relay to user, inject responses to prompts
4. **Capture** result in structured manifest

This is *delegation*, not *transfer of control*. Your agent supervises.

---

## Capabilities: Tools, Skills, Apps

### Hierarchy

```
┌─────────────────────────────────────────────────────────────────┐
│  APPS — User-facing products                                    │
│  "Open Claude Code", "Video Studio", "Inbox Zero"               │
├─────────────────────────────────────────────────────────────────┤
│  SKILLS — Reusable workflows (prompt + tools)                   │
│  "video-processor", "email-manager", "data-analyst"             │
├─────────────────────────────────────────────────────────────────┤
│  TOOLS — Atomic capabilities                                    │
│  ffmpeg, yt-dlp, playwright, run_command, read_file             │
└─────────────────────────────────────────────────────────────────┘
```

### Definitions

| Abstraction | What It Is | Example |
|-------------|-----------|---------|
| **Tool** | Low-level capability with defined I/O | `ffmpeg`, `browser.navigate`, `send_email` |
| **Skill** | Prompt template + required tools for a domain | Video processor (ffmpeg + yt-dlp + prompt about formats) |
| **App** | User-facing mode that bundles skills + UI/config | "Claude Code" (setup script + launch command + port) |

### Tool Permission Model

Tools declare required permissions: `[:read, :write, :execute, :network]`

Users grant permissions per-credential:
- Email: read_only
- GitHub: read_write
- Bank: read_only (never write)

---

## Communication & Connectors

### Supported Channels

| Channel | Direction | Auth Method |
|---------|-----------|-------------|
| Web UI | Bidirectional | Session |
| SMS (Twilio) | Bidirectional | Phone number |
| Slack | Bidirectional | OAuth |
| Discord | Bidirectional | Bot token |
| Email | Bidirectional | OAuth/IMAP |
| Webhook | Inbound | HMAC signature |

### Message Routing

```
Inbound message → Identify user (phone/email/slack ID) → Load context → Route to outer agent
```

### File Transfer

- **In**: Direct attachment (Slack, iMessage, web upload)
- **Out**: Pre-signed Tigris URLs (secure, time-limited download links)

---

## Storage & Lifecycle

### Storage Tiers

| Tier | Location | Cost | Use Case |
|------|----------|------|----------|
| **Hot** | Sprite NVMe | ~$0.0007/GB-hr | Active files, deps, working data |
| **Cold** | Tigris | ~$0.00003/GB-hr | Large files, completed artifacts |

### Hot Storage Limits by Tier

| User Tier | Hot Storage Limit |
|-----------|-------------------|
| Free | 1 GB |
| Pro | 3 GB |
| Max | 10 GB |

### Lifecycle Strategy

1. **Auto-evict** when approaching limit (LRU, prefer re-downloadable files)
2. **Stub replacement** for large files: upload to cold, replace with 0-byte marker
3. **Auto-hydrate** when agent accesses stubbed file
4. **Periodic cleanup** of old job directories, caches, orphaned deps

### Checkpoint Strategy

- Checkpoint **before** risky operations (third-party agents, destructive actions)
- Tag checkpoints as **stable** on successful task completion (used for recovery)
- Keep last **7 days** of checkpoints
- Max **20 checkpoints** per sprite (prune oldest, but always retain most recent stable checkpoint)

---

## Operational Concerns

### Idempotency

All write operations get dedupe keys stored in PostgreSQL. If same key seen twice, return cached result instead of re-executing.

**Key format**: `{user_id}:{action_type}:{content_hash}`

### Approval Matrix

| Action Type | Default Behavior |
|-------------|------------------|
| Read operations | Silent (no confirmation) |
| Create/edit files | Notify after |
| Batch operations | Confirm once for batch |
| Send message/email | Confirm each |
| Reservations, purchases | Always confirm |
| Delete, financial | Block until explicit approval |

Users can override defaults (less restrictive only, never more permissive for blocked actions).

### Data Retention

| Data Type | Retention |
|-----------|-----------|
| Task artifacts | 90 days |
| Detailed logs | 30 days |
| Summary logs | 1 year |
| Checkpoints | 7 days |
| Conversation history | 30 days |

User can export all data (GDPR) or delete account (cascades everything).

### Fault Tolerance

**Outer loop**: OTP supervision trees, auto-restart failed processes.

**Task execution**:
- Auto-retry up to 3x with exponential backoff
- Sprite crash → restore checkpoint → retry
- Timeout → extend budget → retry
- Rate limit → longer backoff → retry
- Non-retryable error → notify user

**Crash context capture**: When a task processor terminates unexpectedly, capture structured context (task state, last action, recent memory) before restart. This enables postmortem analysis without log archaeology. Use OTP's `terminate/2` callback to checkpoint state and emit telemetry before the process dies.

**Circuit breaker & recovery**: If user has 5+ failures in 1 hour, trigger recovery flow:

```
Repeated failures detected
         ↓
Queue incoming tasks (don't reject)
         ↓
Restore to last stable checkpoint (tagged from successful task completion)
         ↓
Agent runs diagnostic (analyze recent failure logs)
         ↓
Categorize root cause:
  ├─ Environment (corrupted deps, disk full) → reset sprite, retry queued tasks
  ├─ Credentials (auth failed, token expired) → prompt user to re-auth
  ├─ Task input (malformed, impossible) → notify user with specifics
  └─ External (API down, rate limited) → extend backoff, retry later
         ↓
Resume processing queue once resolved
Only escalate to user with specific, actionable request
```

Checkpoints are tagged "stable" when tasks complete successfully, so recovery restores to a known-good state rather than mid-failure.

---

## Security & Permissions

### Credential Handling

1. User provides credentials via OAuth flow (platform-proxied) or manual entry
2. Encrypted at rest (libsodium)
3. Injected as env vars only for task duration
4. Never stored in sprite filesystem
5. Revocable by user at any time

### Network Policy

Sprites have egress filtering by default:
- Allow: LLM APIs, common services
- Deny: Everything else unless explicitly allowed per-task

### Isolation

- Firecracker VMs provide hardware-level isolation
- Each user has dedicated sprite (no co-tenancy)
- Jobs within sprite isolated by directory + process group

---

## Billing

### Pricing Model

**User-facing**: "Agent minutes" per tier

| Tier | Price | Agent Minutes | Hot Storage |
|------|-------|---------------|-------------|
| Free | $0 | 30/month | 1 GB |
| Pro | $20/month | 100/month | 3 GB |
| Max | $50/month | 500/month | 10 GB |

**Internal cost tracking** (metered from Sprite API):
- CPU time: $0.07/CPU-hour
- Memory: $0.04/GB-hour  
- Hot storage: $0.0007/GB-hour
- Cold storage: $0.00003/GB-hour

User doesn't see infrastructure details, just minutes consumed.

---

## Key Decisions

| Area | Decision | Rationale |
|------|----------|-----------|
| Architecture | Outer loop (Elixir) + Inner loop (Sprite) | Separation of concerns: orchestration vs execution |
| Sprites | Single shared (MVP), per-user later | MVP simplicity; repo locking prevents conflicts |
| Concurrency | Outer loop manages | Sprite API supports multiple sessions; Elixir handles scheduling |
| Technology | Elixir/Phoenix + PostgreSQL | OTP fault tolerance, LiveView for real-time UI |
| LLM Integration | Custom thin client, no frameworks | Simple API, fewer deps, full control |
| File transfer | Pre-signed Tigris URLs (out), direct upload (in) | S3-compatible, native Fly.io integration |
| Failure handling | Auto-retry with OTP patterns | Minimize user complexity |

---

## MVP Scope

### Included

- Web UI connector
- File processor skill (download, convert, analyze)
- Core task flow: Create → route → execute → complete
- Basic dashboard: Task list, status, download artifacts
- Single "Beta" tier (generous limits, no billing)
- Single task at a time per user

### Success Criteria

1. User can submit task via web UI
2. Task executes in sprite with visible progress
3. Artifacts downloadable on completion
4. Failed tasks auto-retry and eventually surface error
5. <5 min end-to-end for simple file processing task

---

## Implementation Phases

### Phase 1: Foundation (Weeks 1-4)
- [ ] Phoenix project with basic auth
- [ ] PostgreSQL schema (User, Task, Repo, Message, ExecutionSession)
- [ ] Sprite API client (Elixir wrapper)
- [ ] Platform.LLM module (Anthropic client)
- [ ] Web UI skeleton (LiveView)
- [ ] Manual task creation → sprite exec → result display

### Phase 2: Core Loop (Weeks 5-8)
- [ ] Platform.TaskProcessor (GenServer state machine)
- [ ] Task classification & routing
- [ ] Inner agent (Python, basic tool calling)
- [ ] Progress streaming to UI
- [ ] Checkpoint/restore integration

### Phase 3: Reliability (Weeks 9-12)
- [ ] Auto-retry with backoff
- [ ] Idempotency layer
- [ ] Storage management (eviction, limits)
- [ ] Credential vault
- [ ] Error handling & user notifications

### Phase 4: Connectors (Weeks 13-16)
- [ ] SMS (Twilio)
- [ ] Slack
- [ ] Webhook inbound
- [ ] Message routing
- [ ] Approval flow in chat

### Phase 5: Launch Prep (Weeks 17-20)
- [ ] Billing (Stripe)
- [ ] Usage tracking
- [ ] Onboarding flow
- [ ] Documentation
- [ ] Security review
- [ ] Beta launch

### Phase 6: Post-Launch
- [ ] Additional connectors
- [ ] Browser automation
- [ ] Claude Code integration
- [ ] Concurrent tasks
- [ ] Local helper app

---

## Technology Stack

### MVP Stack

| Component | Technology |
|-----------|------------|
| Language | Elixir 1.16+ |
| Framework | Phoenix 1.7+ (LiveView) |
| HTTP Client | Req |
| Background Jobs | Oban |
| Database | PostgreSQL |
| Execution | Fly.io Sprites |
| Inner Agent | Python 3.12 + anthropic SDK |
| Telemetry | :telemetry + TelemetryMetrics |

### Observability Philosophy

Instrument from day one, not as an afterthought. Key events to emit:

| Event | Purpose |
|-------|---------|
| `task.*` (created, classified, completed, failed) | Task lifecycle tracking |
| `sprite.*` (wake, hibernate, checkpoint) | Execution environment health |
| `llm.*` (request, response) | Cost tracking, latency monitoring |

Keep events semantic (what happened) rather than technical (which function ran). Attach to Prometheus/Grafana when needed, but the events themselves are the foundation. Structured crash context (from `terminate/2`) flows through the same telemetry pipeline.

### Custom Modules (No External Agent Frameworks)

**Platform.LLM** (~150 lines) — Thin Anthropic client:
```elixir
defmodule Platform.LLM do
  @moduledoc "Direct Anthropic API client"
  
  def complete(messages, opts \\ []) do
    Req.post("https://api.anthropic.com/v1/messages",
      headers: headers(),
      json: %{
        model: opts[:model] || "claude-sonnet-4-20250514",
        max_tokens: opts[:max_tokens] || 4096,
        messages: messages,
        tools: opts[:tools]
      }
    )
    |> handle_response()
  end
  
  def stream(messages, handler, opts \\ []) do
    Req.post("https://api.anthropic.com/v1/messages",
      headers: headers(),
      json: %{model: opts[:model], messages: messages, stream: true},
      into: &handle_sse(&1, &2, handler)
    )
  end
end
```

**Platform.TaskProcessor** (~200 lines) — GenServer state machine:
```elixir
defmodule Platform.TaskProcessor do
  use GenServer
  
  # States: :pending -> :classifying -> :routing -> :executing -> :completed
  
  def handle_continue(:classify, %{state: :pending} = data) do
    {:ok, intent} = LLM.complete(classification_prompt(data.task))
    {:noreply, %{data | state: :routing, intent: intent}, {:continue, :route}}
  end
  
  def handle_continue(:route, %{state: :routing} = data) do
    skill = Router.select_skill(data.intent)
    {:ok, session} = Sprite.exec(sprite_name, build_command(skill))
    {:noreply, %{data | state: :executing, session: session}}
  end
end
```

### Why No Agent Frameworks

We skip Jido, ReqLLM, LangChain, etc. because:
- The Anthropic API is simple (~150 lines for full client with streaming)
- Task orchestration is a state machine (GenServer is perfect for this)
- OTP already provides supervision, retry, and fault tolerance
- Fewer dependencies = less surface area, more control

We adopt their *patterns* without the dependencies:
- Keep LLM calls pure (return data, don't trigger side effects)
- Explicit state machine (not implicit conditionals)
- Separate "decide" from "do"

### Future Additions

| Phase | Technology | Purpose |
|-------|------------|---------|
| Connectors | Twilio | SMS |
| Connectors | Slack Bolt | Slack integration |
| Launch | Stripe | Billing |
| Scale | Tigris | Cold storage for large files (Fly.io native) |
| Scale | Prometheus + Grafana | Dashboards (telemetry events already emitted) |

---

## Appendix: Example Flows

### Flow 1: Video Processing

```
User (web): "Download https://youtube.com/xyz, transcribe, summarize"

1. Outer agent classifies: new_task, skill=video-processor
2. Create task, wake sprite, checkpoint
3. Inner agent executes:
   - yt-dlp downloads video
   - ffmpeg extracts audio  
   - whisper transcribes
   - Claude summarizes
4. Artifacts uploaded to cold storage
5. User gets notification + download links
```

### Flow 2: Scheduled Briefing

```
User (web): Creates schedule for daily 7am briefing

1. Oban cron triggers at 7am
2. Outer agent creates task from template
3. Inner agent:
   - Fetches calendar
   - Searches Slack for relevant threads
   - Summarizes action items
4. Result sent to user via configured connector
```