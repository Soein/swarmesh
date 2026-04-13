# Swarmesh

[English](#english) | [中文](#中文) | [🔌 Claude Code 插件安装](#-claude-code-插件安装)

---

## 🔌 Claude Code 插件安装

Swarmesh 现在可作为 **Claude Code 插件**使用，提供两种协作模式：

| 模式 | 何时用 | 启动命令 |
|---|---|---|
| **discuss** | 想和多个 CLI（Codex / Claude / Gemini）圆桌讨论、碰方案 | `/swarm-chat <项目> <cli>` |
| **execute** | 方案已定，要由 supervisor 拆任务派发给全角色团队 | `/swarm-start <项目> [profile]` |

### 安装

```bash
# 在 Claude Code 中：
/plugin marketplace add <你的 GitHub 用户>/tmux-swarm
/plugin install tmux-swarm
```

或本地测试：

```bash
claude --plugin-dir ~/项目/tmux并行
```

### discuss 模式速览

```bash
/swarm-chat ~/my-app codex cx          # 首发 Codex
/swarm-chat-add claude "claude"        # 再加 Claude
/swarm-chat-msg "@cx @claude 讨论 Redis vs Dynamo 做会话缓存"
/swarm-chat-msg "@cx 基于上面对比，结论是？"
/swarm-promote --profile minimal       # 讨论成熟后转 execute 落地
```

关键规则：
- 只有 `@点名` 才触发对方接话（防刷屏）
- 默认最大轮次 20（`SWARM_DISCUSS_MAX_TURNS` 调整）
- 每次喂给 CLI 的上下文 = 最近 10 轮对话（`SWARM_DISCUSS_CONTEXT_TURNS` 调整）
- v0.1：CLI 回复目前需要 `discuss-relay post --from <who> --content "..."` 手动落盘；后续版本自动捕获

### execute 模式速览

```bash
/swarm-start ~/my-app minimal    # 起 4 角色团队
/swarm-task "实现用户注册系统"    # 派发给 supervisor，自动拆解
/swarm-status                    # 观察进度
/swarm-stop                      # 结束
```

### 平台支持

- ✅ macOS / Linux
- ❌ Windows 原生（需 WSL）

### Slash Commands

| 命令 | 模式 | 作用 |
|---|---|---|
| `/swarm-start` | execute | 启动蜂群 |
| `/swarm-task` | execute | 派发任务 |
| `/swarm-join` / `/swarm-leave` | execute | 动态增删角色 |
| `/swarm-chat` | discuss | 启动圆桌 |
| `/swarm-chat-add` | discuss | 加参与者 |
| `/swarm-chat-msg` | discuss | 发消息（@点名） |
| `/swarm-promote` | discuss→execute | 结案转落地 |
| `/swarm-status` | 通用 | 查看状态 |
| `/swarm-stop` | 通用 | 停止 |

### 依赖检测

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/check-deps.sh
```

SessionStart hook 会自动检测；缺依赖时打印安装建议但不阻塞会话。

---

<a id="english"></a>

## English

A tmux-based multi-AI CLI swarm collaboration framework. Orchestrate multiple AI CLI instances (Claude Code, Gemini CLI, Codex, etc.) within a single tmux session, enabling autonomous collaboration through a messaging system to tackle complex tasks.

### Core Concept

```
You (human)               swarm-start.sh
   │                         │
   │  --profile minimal      │
   └────────────────────────►│
                             │
                    ┌────────┼────────┐
                    ▼        ▼        ▼
               ┌────────┐┌────────┐┌────────┐
               │frontend││backend ││reviewer│  ← tmux pane
               │Gemini  ││Claude  ││Codex   │  ← different AI CLIs
               └───┬────┘└───┬────┘└───┬────┘
                   │         │         │
                   └────►inbox/outbox◄─┘  ← file-based messaging
                         + paste-buffer   ← instant notification
```

Each role runs in an isolated tmux pane with its own role configuration, inbox, and optional git worktree. Roles communicate autonomously via `swarm-msg.sh` — no human relay needed.

### Quick Start

#### Dependencies

- tmux
- jq
- At least one AI CLI ([Claude Code](https://github.com/anthropics/claude-code), [Gemini CLI](https://github.com/google-gemini/gemini-cli), [Codex](https://github.com/openai/codex), etc.)

#### Universal CLI (Recommended)

`swarm-cli.sh` is the universal control entry point, usable from any terminal:

```bash
# Start swarm (interactive profile selection)
./scripts/swarm-cli.sh start ~/my-app

# Start swarm (specify profile)
./scripts/swarm-cli.sh start ~/my-app web-dev

# Check swarm status (roles, inboxes, tasks, events)
./scripts/swarm-cli.sh status

# Dispatch task to supervisor (auto-orchestration)
./scripts/swarm-cli.sh task "Implement user registration"

# Dispatch task to a specific role
./scripts/swarm-cli.sh task backend "Implement login API"

# View inbox and task queue
./scripts/swarm-cli.sh task

# Dynamically add/remove roles (interactive selection)
./scripts/swarm-cli.sh join
./scripts/swarm-cli.sh leave

# Pass-through messaging commands
./scripts/swarm-cli.sh msg send reviewer "Please review PR #42"
./scripts/swarm-cli.sh msg broadcast "v1 API finalized"

# Stop swarm (optional data cleanup)
./scripts/swarm-cli.sh stop
./scripts/swarm-cli.sh stop --clean
```

Each subcommand supports `--help` for detailed usage: `./scripts/swarm-cli.sh start --help`

#### Claude Code Users

If you use Claude Code as your controller, you can use slash commands directly (same underlying logic):

- `/swarm-start` — Start swarm
- `/swarm-stop` — Stop swarm
- `/swarm-status` — View status
- `/swarm-task` — Dispatch task
- `/swarm-join` — Add role
- `/swarm-leave` — Remove role

#### Low-level Scripts

You can also call the underlying scripts directly:

```bash
# Start
./scripts/swarm-start.sh --project /path/to/your/project --profile minimal --hidden

# Resume previous session (recover orphan tasks, reuse config)
./scripts/swarm-start.sh --resume

# Status
./scripts/swarm-status.sh

# Stop
./scripts/swarm-stop.sh --force
```

### Messaging System

Roles communicate via `swarm-msg.sh`, called directly within each role's pane:

```bash
# Send message
swarm-msg.sh send backend "Please design the auth API"

# Broadcast to all roles
swarm-msg.sh broadcast "v1 API spec finalized, please review"

# Check inbox
swarm-msg.sh read

# Reply to message
swarm-msg.sh reply <msg-id> "Got it, starting now"

# List team members
swarm-msg.sh list-roles

# Wait for new messages (zero-polling, blocks until message arrives)
swarm-msg.sh wait --timeout 60

# Mark messages as read
swarm-msg.sh mark-read <msg-id>
swarm-msg.sh mark-read --all

# Create task group
swarm-msg.sh create-group "User auth module"

# Publish task (V2 contract required, no backward compatibility with --assign)
swarm-msg.sh publish develop "Implement login page" \
  --contract '{"phase":"implement","phase_assignments":{"research":"frontend","synthesize":"frontend","implement":"frontend","integrate":"integrator","verify":"reviewer"},"inputs":["Build login page"],"expected_outputs":["Code changes","Review conclusion"],"acceptance_criteria":["verify passed"],"impact_scope":"write","execution_mode":"exclusive","resource_keys":["repo:frontend/login"],"handoff_format":"markdown"}'

# List tasks
swarm-msg.sh list-tasks

# Claim task
swarm-msg.sh claim <task-id>

# Complete task (triggers quality gate)
swarm-msg.sh complete-task <task-id> "Implemented and tested"

# For orchestrate tasks, synthesize must return capability-based structured JSON:
swarm-msg.sh complete-task <task-id> '{"spec":{"summary":"Turn research into executable spec"},"orchestration_plan":{"steps":[{"id":"backend-api","title":"Implement backend API","required_capability":"backend_dev","resolution":{"suggested_role":"backend","suggested_dispatch_mode":"existing_role","suggested_join_command":""}}]}}'

# If implement inherits that synthesize plan, it must return execution receipts before integrate:
swarm-msg.sh complete-task <task-id> '{"summary":"Plan dispatched","executed_plan_step_ids":["backend-api"],"published_tasks":["task-101"],"dispatch_receipts":[{"step_id":"backend-api","required_capability":"backend_dev","suggested_role":"backend","suggested_dispatch_mode":"existing_role","final_role":"backend","final_dispatch_mode":"existing_role","resolution_source":"auto","resolution_reason":"","resolution_risk":"","published_task_id":"task-101"}]}'

# Capability / playbook helpers
bash scripts/swarm-insights.sh validate-capabilities
bash scripts/swarm-insights.sh resolve-capability backend_dev
bash scripts/swarm-insights.sh suggest-playbook <group-id>
bash scripts/swarm-insights.sh approve-playbook runtime/playbook-candidates/<file>.json --as parallel-feature-v2

# View task group status
swarm-msg.sh group-status <group-id>

# Task group summary report (with timing info)
swarm-msg.sh group-report <group-id>

# Pause task (processing → paused)
swarm-msg.sh pause-task <task-id> "Waiting for external dependency"

# Resume paused task (paused → processing/pending)
swarm-msg.sh resume-task <task-id>

# Cancel task (cascades to dependencies and subtasks)
swarm-msg.sh cancel-task <task-id> "Requirements changed"

# View task audit trail
swarm-msg.sh flow-log <task-id>

# Set task priority
swarm-msg.sh set-priority <task-id> high   # high/normal/low

# Associate PRD to task group
swarm-msg.sh set-prd <group-id> "PRD content..."

# Manual approval (inspector only, used in strict quality gate mode)
swarm-msg.sh approve-task <task-id> "Approved after manual review"
swarm-msg.sh reject-task <task-id> "Test coverage insufficient"
```

Messages are persisted via the file system (inbox/outbox) and instantly pushed to target panes using tmux paste-buffer.

### Dynamic Scaling

```bash
# Add new role at runtime
./scripts/swarm-join.sh --role security --cli "claude chat" --config quality/security.md

# Remove role
./scripts/swarm-leave.sh database --reason "Database design complete"
```

### Quality Assurance

#### Project Scanning

On startup, the target project structure is automatically scanned, collecting key config files (`package.json`, `go.mod`, `Cargo.toml`, etc.) into `runtime/project-info.json`. Scripts only collect raw facts; LLM roles interpret the tech stack themselves.

#### Story Files

Each task group auto-generates a Story file (`runtime/stories/<group-id>.json`) recording sub-task status, acceptance records, and progress timeline. Data is stored in JSON and rendered as markdown for display:

```bash
swarm-msg.sh story-view <group-id>
```

#### Quality Gates

When a worker calls `complete-task`, verification commands (build/test/lint) run automatically. If checks fail, the task stays in processing state — the worker must fix issues and resubmit.

For multi-phase `orchestrate` tasks, runtime now also enforces planning artifacts:

1. `synthesize` must submit structured JSON containing `spec.summary` and capability-based `orchestration_plan.steps[].required_capability`.
2. If `implement` inherits that synthesize plan, it must submit `executed_plan_step_ids`, `published_tasks`, and `dispatch_receipts` before it can advance to `integrate`.

Formal internal priors live under `config/orchestration/playbooks/`, but they are capability-based, not role- or instance-based. Runtime assignment is resolved later against the current online team and optional `swarm-join.sh` expansion.

`dispatch_receipts` are the authoritative execution trace: they record whether a step followed the default suggestion (`resolution_source=auto`) or was manually overridden by supervisor (`resolution_source=manual_override`).

Candidate priors are generated into `runtime/playbook-candidates/` and do not take effect automatically.

Verification command priority (low → high):

1. **Runtime**: `runtime/project-info.json` `verify_commands` (configured by inspector via `set-verify`)
2. **Project-level**: `.swarm/verify.json` (user-created)
3. **Task-level**: `publish --verify '{"test":"go test ./..."}'` (specified at publish time)

```bash
# Inspector configures verification by role
swarm-msg.sh set-verify '{"build":"go build ./...","test":"go test ./..."}' --role backend
swarm-msg.sh set-verify '{"build":"npm run build","test":"npm test"}' --role frontend

# Or specify at task publish time
swarm-msg.sh publish develop "Implement API" \
  --contract '{"phase":"implement","phase_assignments":{"research":"backend","synthesize":"backend","implement":"backend","integrate":"integrator","verify":"reviewer"},"inputs":["Implement API"],"expected_outputs":["Code changes","Verification result"],"acceptance_criteria":["API works","verify passed"],"impact_scope":"write","execution_mode":"exclusive","resource_keys":["repo:backend/api"],"handoff_format":"markdown"}' \
  --verify '{"build":"go build ./..."}'
```

`resource_keys` combined with `execution_mode` controls real concurrency:

- **`execution_mode: "exclusive"` + non-empty `resource_keys`** → the task acquires an exclusive lock on every listed key at `claim` time. If any key is already held by another processing task, `claim` is rejected; the task stays in `pending/` with `resource_blocked_by` pointing at the holder. When the holder finishes, waiters are automatically unblocked and their owners are notified.
- **`execution_mode: "parallel"` (default)** or empty `resource_keys` → no lock is taken; multiple tasks may share the same keys.

Holdings are persisted in `runtime/resource_locks.json`. Use `swarm-cli.sh status` to see who holds what (section **🔒 Resources**) and which tasks are waiting (**⏸ Resource wait queue**). Lock-related events in `runtime/events.jsonl`: `resource.acquired` / `resource.released` / `resource.conflict` / `resource.unblocked` / `resource.lock_system_error`.

If the lock table itself becomes unwritable (disk full, corrupted JSON), `claim` fails fast with `resource.lock_system_error` rather than silently succeeding. A task that terminates while the lock release cannot persist is marked `resource_lock_stale: true` on the final JSON for operator follow-up.

#### Subtask System

Complex tasks can be decomposed into subtasks with dependency management and multi-level nesting.
Note: here `--assign` is still valid because it assigns subtasks, not `publish`:

```bash
# Split a task into subtasks
swarm-msg.sh split-task <parent-task-id> \
  --subtask "Design API schema" --assign architect \
  --subtask "Implement endpoints" --assign backend --depends 0

# Expand a subtask into finer-grained subtasks (flattened to same level)
swarm-msg.sh expand-subtask <subtask-id> \
  --subtask "Write unit tests" --assign backend \
  --subtask "Write integration tests" --assign tester

# Reset split (keeps completed subtasks, cancels pending ones)
swarm-msg.sh re-split <parent-task-id>
```

Related configuration: `SUBTASK_MAX_DEPTH` (max nesting depth), `SUBTASK_MAX_COUNT` (max subtasks per parent), `SUBTASK_STALL_TTL` (stall detection threshold).

#### Task Retry & Escalation

Workers can report failures (auto-retry with exponential backoff) or escalate tasks to the supervisor:

```bash
# Report task failure (auto-retry with exponential backoff)
swarm-msg.sh fail-task <task-id> "Build failed: missing dependency"

# Escalate complex task to supervisor for re-splitting
swarm-msg.sh escalate-task <task-id> "Involves 3 independent modules, suggest splitting"

# Recover stuck tasks (assigned to offline workers)
swarm-msg.sh recover-tasks
```

Related configuration: `TASK_MAX_RETRIES` (max retries, 0 = fail immediately), `TASK_RETRY_BASE_DELAY` (base delay in seconds, actual delay = 2^retry_count * base), `ESCALATE_STALL_TTL` (escalation timeout).

#### Task Intervention

Running tasks can be paused, resumed, or cancelled at any time:

```bash
# Pause a processing task
swarm-msg.sh pause-task <task-id> "Waiting for API spec finalization"

# Resume a paused task
swarm-msg.sh resume-task <task-id>

# Cancel a task (cascades to dependent tasks and subtasks)
swarm-msg.sh cancel-task <task-id> "Requirements changed"
```

#### Task Audit Trail

Every task state transition is recorded in an audit log. Use `flow-log` to view the complete history of a task:

```bash
swarm-msg.sh flow-log <task-id>
```

#### Multi-Supervisor Orchestration

By default, swarm starts with a single supervisor. Supervisors can dynamically scale up based on workload:

- **Watchdog detection**: When pending tasks exceed `PENDING_PILEUP_THRESHOLD`, the watchdog notifies supervisors
- **Supervisor decision**: Supervisor evaluates the situation and decides whether to scale
- **Controlled expansion**: `request-supervisor` command with built-in safeguards (max count, cooldown, CLI budget check)
- **Context handoff**: New supervisors receive a task queue snapshot on join

```bash
# Supervisor requests scaling (only supervisor/human can call)
swarm-msg.sh request-supervisor "Multiple task groups in parallel, overloaded"
```

When multiple supervisors are active, they coordinate through a shared task queue (claim-based). When a supervisor splits a task into many subtasks (count >= `COUNCIL_THRESHOLD`), an orchestration bulletin is broadcast to all other supervisors.

#### Strict Quality Gate & Manual Approval

When `GATE_STRICT_MODE=true`, quality gates become stricter:
- Commands exiting with code 127 (command not found) are treated as failures instead of being skipped
- Failed quality gates move tasks to `pending_review` state instead of staying in `processing`
- Tasks in `pending_review` require manual approval from an inspector:

```bash
# Inspector approves a task after manual review
swarm-msg.sh approve-task <task-id> "Approved after manual review"

# Inspector rejects a task back to the worker
swarm-msg.sh reject-task <task-id> "Test coverage insufficient"
```

If a task stays in `pending_review` longer than `PENDING_REVIEW_TTL`, the watchdog notifies the human operator.

#### System Maintenance

```bash
# Clean up expired messages, completed tasks, and gate logs
swarm-msg.sh cleanup --ttl 3600 --gate-logs

# View/set CLI instance limit
swarm-msg.sh set-limit        # View current limit
swarm-msg.sh set-limit 20     # Set limit to 20
swarm-msg.sh set-limit 0      # Remove limit
```

### Session Resume

Swarm sessions can be resumed after being stopped, preserving tasks, messages, and context:

```bash
# Resume previous session
./scripts/swarm-start.sh --resume

# Or short flag
./scripts/swarm-start.sh -r
```

On resume, the framework:
- Validates previous `state.json` is resumable
- Recovers orphan tasks stuck in `processing` state (configurable via `RESUME_ORPHAN_RECOVERY`)
- Regenerates per-role context summaries (git commits, task progress, recent messages)
- Injects resume summaries into each role's initialization message

### Configuration Reference

All parameters are centralized in `config/defaults.conf` with 3-tier priority: env vars > project-level `.swarm/swarm.conf` > defaults.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `LOG_TIMESTAMP_FORMAT` | `%Y-%m-%d %H:%M:%S` | Unified timestamp format |
| `LOG_MAX_SIZE` | 10485760 | Max log file size in bytes (10MB) |
| `LOG_ROTATE_INTERVAL` | 300 | Log rotation check interval (seconds) |
| `LOG_RETENTION_TTL` | 604800 | Log max retention time (seconds, 7 days) |
| `GATE_TIMEOUT` | 120 | Quality gate check timeout per command (seconds) |
| `GATE_LOG_TTL` | 86400 | Quality gate log retention (seconds) |
| `SKIP_GATE_TYPES` | `review design architecture audit document plan` | Task types that skip quality gates |
| `GATE_STRICT_MODE` | false | Strict mode: exit 127 = failure, failed gates → manual approval |
| `WATCHDOG_INTERVAL` | 60 | Task watchdog patrol interval (seconds) |
| `TASK_PROCESSING_TTL` | 21600 | Max task processing duration (seconds, 0 = disable) |
| `TASK_MAX_RETRIES` | 3 | Max retry count (0 = fail immediately) |
| `TASK_RETRY_BASE_DELAY` | 60 | Retry base delay in seconds (actual: 2^retry * base) |
| `SUBTASK_MAX_DEPTH` | 3 | Max subtask nesting depth (0 = disable splitting) |
| `SUBTASK_MAX_COUNT` | 10 | Max subtasks per parent task |
| `SUBTASK_STALL_TTL` | 7200 | Subtask group stall detection threshold (seconds) |
| `ESCALATE_STALL_TTL` | 3600 | Escalated task unhandled timeout (seconds) |
| `CLEANUP_TTL` | 3600 | Expired message/task TTL (seconds) |
| `SILENCE_THRESHOLD` | 5 | Pane watcher silence threshold (seconds, how long no output = done) |
| `STALL_THRESHOLD` | 1800 | Active pane no-output threshold (seconds, triggers stall notification) |
| `PASTE_DELAY` | 0.3 | Delay after paste-buffer (seconds) |
| `CODEX_PASTE_DELAY` | 0.5 | Delay after Codex CLI paste-buffer (seconds, Kitty keyboard protocol needs longer wait) |
| `RESUME_ORPHAN_RECOVERY` | true | Recover orphan tasks in processing/ on resume |
| `RESUME_SUMMARY_MAX_COMMITS` | 20 | Max git commits in resume summary |
| `RESUME_SUMMARY_MAX_TASKS` | 10 | Max completed/pending tasks in resume summary |
| `RESUME_PANE_LINES` | 50 | Capture last N lines of each pane for resume |
| `RESUME_SUMMARY_MAX_MESSAGES` | 10 | Max recent messages in resume summary |
| `DEFAULT_SUPERVISOR_COUNT` | 1 | Initial supervisor count on startup (scales dynamically) |
| `SUPERVISOR_MAX_COUNT` | 5 | Max supervisor count (prevents unbounded scaling) |
| `SUPERVISOR_SCALE_COOLDOWN` | 300 | Min interval between supervisor expansions (seconds) |
| `PENDING_PILEUP_THRESHOLD` | 5 | Pending task count threshold to notify supervisor |
| `PENDING_PILEUP_NOTIFY_INTERVAL` | 1800 | Dedup interval for pileup notifications (seconds) |
| `COUNCIL_THRESHOLD` | 5 | Broadcast orchestration bulletin when subtask count >= this |
| `PENDING_REVIEW_TTL` | 1800 | Pending review timeout (seconds, notify human on expiry) |
| `PANES_PER_WINDOW` | 2 | Tmux panes per window |

### Project Structure

```
swarmesh/
├── scripts/                 # Core scripts
│   ├── swarm-cli.sh         # Universal control entry (all subcommands)
│   ├── swarm-start.sh       # Start swarm
│   ├── swarm-stop.sh        # Stop swarm
│   ├── swarm-msg.sh         # Inter-CLI messaging
│   ├── swarm-scan.sh        # Project structure scanner
│   ├── swarm-join.sh        # Dynamically add role
│   ├── swarm-leave.sh       # Dynamically remove role
│   ├── swarm-status.sh      # Status viewer
│   ├── swarm-relay.sh       # Message relay (human → role)
│   ├── swarm-send.sh        # External message sender
│   ├── swarm-read.sh        # External message reader
│   ├── swarm-detect.sh      # CLI status detection
│   ├── swarm-events.sh      # Event system
│   ├── swarm-workflow.sh    # Workflow engine
│   ├── swarm-lint.sh        # Role config linter
│   ├── swarm-lib.sh         # Shared function library
│   └── lib/                 # swarm-msg submodules
│       ├── msg-story.sh     # Story files
│       ├── msg-quality-gate.sh  # Quality gates
│       ├── msg-task-queue.sh    # Task queue
│       └── msg-task-watchdog.sh # Task watchdog
├── config/
│   ├── defaults.conf        # Framework defaults (logging/gates/watchdog/tmux)
│   ├── profiles/            # Team profile presets
│   │   ├── minimal.json     # 3-role minimal team
│   │   ├── web-dev.json     # 6-role web dev team
│   │   └── full-stack.json  # 14-role full team
│   ├── roles/               # Role system prompts
│   │   ├── core/            # Core dev (frontend, backend, database, devops)
│   │   ├── quality/         # QA (tester, reviewer, integrator, security, performance)
│   │   └── management/      # Management (supervisor, architect, auditor, inspector, ui-designer, prd)
│   ├── cli-routing.json     # CLI routing config
│   └── notification-policy.json  # Notification delivery policy
├── workflows/               # Predefined workflows
│   ├── quick-task.json
│   ├── feature-complete.json
│   ├── relay-chain.json
│   └── product-feature.json  # End-to-end product feature workflow
└── runtime/                 # Runtime data (gitignored)
    ├── state.json           # Swarm state
    ├── project-info.json    # Project scan results
    ├── logs/                # Role logs
    ├── messages/            # inbox/outbox
    ├── tasks/               # Task state machine
    ├── pipes/               # FIFO pipes (instant notification)
    ├── stories/             # Task group Story files
    ├── workflows/           # Workflow runtime state
    ├── gate-logs/           # Quality gate check logs
    ├── results/             # Task results
    └── resume/              # Session resume summaries
```

### Profile Presets

| Profile | Roles | Use Case |
|---------|-------|----------|
| `minimal` | 3 | Quick validation, small features |
| `web-dev` | 6 | Web application development |
| `full-stack` | 14 | Large projects, enterprise-level |

Supports mixing different AI CLIs — frontend uses Gemini, backend uses Claude, reviewer uses Codex within the same swarm, each leveraging their strengths.

### Design Principles

- **Pure Bash + filesystem**: No extra dependencies, runs on any machine with tmux
- **CLI-agnostic**: Not tied to any specific AI CLI, switch via profile config
- **Role autonomy**: Roles collaborate autonomously via messaging, no human relay needed
- **Git worktree isolation**: Each role can work on an independent branch, avoiding conflicts
- **Configurable, not hardcoded**: All parameters centralized in `config/defaults.conf`, supporting 3-tier priority override (env vars > project-level `.swarm/swarm.conf` > defaults)

### License

[Business Source License 1.1 (BSL 1.1)](https://mariadb.com/bsl11/)

- Change Date: 2030-02-27
- Change License: GPL-2.0-or-later

---

<a id="中文"></a>

## 中文

基于 tmux 的多 AI CLI 蜂群协作框架。在一个 tmux session 中编排多个 AI CLI 实例（Claude Code、Gemini CLI、Codex 等），让它们通过消息系统自主协作完成复杂任务。

### 核心思路

```
你（人类）                swarm-start.sh
   │                         │
   │  --profile minimal      │
   └────────────────────────►│
                             │
                    ┌────────┼────────┐
                    ▼        ▼        ▼
               ┌────────┐┌────────┐┌────────┐
               │frontend││backend ││reviewer│  ← tmux pane
               │Gemini  ││Claude  ││Codex   │  ← 不同 AI CLI
               └───┬────┘└───┬────┘└───┬────┘
                   │         │         │
                   └────►inbox/outbox◄─┘  ← 文件消息系统
                         + paste-buffer   ← 即时通知
```

每个角色运行在独立 tmux pane 中，拥有自己的角色配置、收件箱和可选的 git worktree。角色之间通过 `swarm-msg.sh` 自主通讯，无需人类中转。

### 快速开始

#### 依赖

- tmux
- jq
- 至少一个 AI CLI（[Claude Code](https://github.com/anthropics/claude-code)、[Gemini CLI](https://github.com/google-gemini/gemini-cli)、[Codex](https://github.com/openai/codex) 等）

#### 通用 CLI（推荐）

`swarm-cli.sh` 是通用主控入口，任何终端都能使用：

```bash
# 启动蜂群（交互式选择 profile）
./scripts/swarm-cli.sh start ~/my-app

# 启动蜂群（指定 profile）
./scripts/swarm-cli.sh start ~/my-app web-dev

# 查看蜂群状态（含角色、收件箱、任务、事件）
./scripts/swarm-cli.sh status

# 派发任务给 supervisor（自动编排）
./scripts/swarm-cli.sh task 实现用户注册功能

# 派发任务给指定角色
./scripts/swarm-cli.sh task backend 实现登录 API

# 查看收件箱和任务队列
./scripts/swarm-cli.sh task

# 动态加入/移除角色（交互式选择）
./scripts/swarm-cli.sh join
./scripts/swarm-cli.sh leave

# 透传消息系统命令
./scripts/swarm-cli.sh msg send reviewer "请 review PR #42"
./scripts/swarm-cli.sh msg broadcast "v1 接口已定稿"

# 停止蜂群（可选清理数据）
./scripts/swarm-cli.sh stop
./scripts/swarm-cli.sh stop --clean
```

每个子命令支持 `--help` 查看详细用法：`./scripts/swarm-cli.sh start --help`

#### Claude Code 用户

如果你使用 Claude Code 作为主控，可以直接用 slash command（底层逻辑相同）：

- `/swarm-start` — 启动蜂群
- `/swarm-stop` — 停止蜂群
- `/swarm-status` — 查看状态
- `/swarm-task` — 派发任务
- `/swarm-join` — 加入角色
- `/swarm-leave` — 移除角色

#### 底层脚本

也可以直接调用底层脚本：

```bash
# 启动
./scripts/swarm-start.sh --project /path/to/your/project --profile minimal --hidden

# 恢复上次会话（回收孤儿任务，复用配置）
./scripts/swarm-start.sh --resume

# 状态
./scripts/swarm-status.sh

# 停止
./scripts/swarm-stop.sh --force
```

### 消息系统

角色之间通过 `swarm-msg.sh` 通讯，每个角色在自己的 pane 内直接调用：

```bash
# 发消息
swarm-msg.sh send backend "请设计用户认证 API"

# 广播给所有角色
swarm-msg.sh broadcast "v1 API 接口已定稿，请查收"

# 查看收件箱
swarm-msg.sh read

# 回复消息
swarm-msg.sh reply <msg-id> "收到，开始实现"

# 查看团队成员
swarm-msg.sh list-roles

# 等待新消息（零轮询，阻塞直到有新消息）
swarm-msg.sh wait --timeout 60

# 标记消息已读
swarm-msg.sh mark-read <msg-id>
swarm-msg.sh mark-read --all

# 创建任务组
swarm-msg.sh create-group "用户认证模块"

# 发布任务（V2 contract 必填，不再兼容 --assign）
swarm-msg.sh publish develop "实现登录页面" \
  --contract '{"phase":"implement","phase_assignments":{"research":"frontend","synthesize":"frontend","implement":"frontend","integrate":"integrator","verify":"reviewer"},"inputs":["实现登录页面"],"expected_outputs":["代码变更","审查结论"],"acceptance_criteria":["verify 通过"],"impact_scope":"write","execution_mode":"exclusive","resource_keys":["repo:frontend/login"],"handoff_format":"markdown"}'

# 查看任务列表
swarm-msg.sh list-tasks

# 领取任务
swarm-msg.sh claim <task-id>

# 完成任务（触发质量门检查）
swarm-msg.sh complete-task <task-id> "已实现并测试通过"

# 对 orchestrate 任务，synthesize 必须提交 capability-based 结构化 JSON：
swarm-msg.sh complete-task <task-id> '{"spec":{"summary":"把调研转成可执行 spec"},"orchestration_plan":{"steps":[{"id":"backend-api","title":"实现后端 API","required_capability":"backend_dev","resolution":{"suggested_role":"backend","suggested_dispatch_mode":"existing_role","suggested_join_command":""}}]}}'

# 如果 implement 承接了这份 synthesize 计划，进入 integrate 前必须回报执行回执：
swarm-msg.sh complete-task <task-id> '{"summary":"已按计划派发","executed_plan_step_ids":["backend-api"],"published_tasks":["task-101"],"dispatch_receipts":[{"step_id":"backend-api","required_capability":"backend_dev","suggested_role":"backend","suggested_dispatch_mode":"existing_role","final_role":"backend","final_dispatch_mode":"existing_role","resolution_source":"auto","resolution_reason":"","resolution_risk":"","published_task_id":"task-101"}]}'

# capability / playbook 辅助命令
bash scripts/swarm-insights.sh validate-capabilities
bash scripts/swarm-insights.sh resolve-capability backend_dev
bash scripts/swarm-insights.sh suggest-playbook <group-id>
bash scripts/swarm-insights.sh approve-playbook runtime/playbook-candidates/<file>.json --as parallel-feature-v2

# 查看任务组状态
swarm-msg.sh group-status <group-id>

# 任务组汇总报告（含耗时信息）
swarm-msg.sh group-report <group-id>

# 暂停任务（processing → paused）
swarm-msg.sh pause-task <task-id> "等待外部依赖"

# 恢复暂停的任务（paused → processing/pending）
swarm-msg.sh resume-task <task-id>

# 取消任务（级联取消依赖和子任务）
swarm-msg.sh cancel-task <task-id> "需求变更"

# 查看任务流转审计记录
swarm-msg.sh flow-log <task-id>

# 修改任务优先级
swarm-msg.sh set-priority <task-id> high   # high/normal/low

# 关联 PRD 到任务组
swarm-msg.sh set-prd <group-id> "PRD 内容..."

# 人工审批（仅 inspector，质量门严格模式下使用）
swarm-msg.sh approve-task <task-id> "审核通过"
swarm-msg.sh reject-task <task-id> "测试覆盖率不足"
```

消息通过文件系统（inbox/outbox）持久化，同时用 tmux paste-buffer 即时推送通知到目标 pane。

### 动态扩缩容

```bash
# 运行中加入新角色
./scripts/swarm-join.sh --role security --cli "claude chat" --config quality/security.md

# 移除角色
./scripts/swarm-leave.sh database --reason "数据库设计已完成"
```

### 质量保障

#### 项目扫描

启动时自动扫描目标项目结构，收集关键配置文件（`package.json`、`go.mod`、`Cargo.toml` 等）信息到 `runtime/project-info.json`。脚本只收集原始事实，LLM 角色自行解读技术栈。

#### Story 文件

每个任务组自动生成 Story 文件（`runtime/stories/<group-id>.json`），记录子任务状态、验收记录和进度时间线。数据用 JSON 存储，展示时渲染为 markdown：

```bash
swarm-msg.sh story-view <group-id>
```

#### 质量门

工蜂 `complete-task` 时自动执行验证命令（build/test/lint），检查失败则任务保持 processing，工蜂需修复后重新提交。

对多阶段 `orchestrate` 任务，runtime 还会强制检查计划产物：

1. `synthesize` 必须提交包含 `spec.summary` 和 capability-based `orchestration_plan.steps[].required_capability` 的结构化 JSON。
2. 如果 `implement` 承接了这份 synthesize 计划，那么进入 `integrate` 前必须提交 `executed_plan_step_ids`、`published_tasks` 和 `dispatch_receipts`。

正式内部先验位于 `config/orchestration/playbooks/`，并且只绑定 capability，不绑定 role 或 instance。真正的角色落位要结合当前在线团队和 `swarm-join.sh` 动态扩容能力，在当次 `orchestration_plan` 中解析。

`dispatch_receipts` 是实现阶段的权威执行回执：它会记录某个 step 是按默认建议派发（`resolution_source=auto`），还是由 supervisor 人工改派（`resolution_source=manual_override`）。

自动总结出的候选先验只写入 `runtime/playbook-candidates/`，不会自动生效；需要人工通过 `approve-playbook` 显式入库。

验证命令三层优先级（低→高）：
1. **运行时**: `runtime/project-info.json` 的 `verify_commands`（inspector 通过 `set-verify` 配置）
2. **项目级**: `.swarm/verify.json`（用户手动创建）
3. **任务级**: `publish --verify '{"test":"go test ./..."}'`（发布任务时指定）

```bash
# inspector 按角色配置验证命令
swarm-msg.sh set-verify '{"build":"go build ./...","test":"go test ./..."}' --role backend
swarm-msg.sh set-verify '{"build":"npm run build","test":"npm test"}' --role frontend

# 或发布任务时指定
swarm-msg.sh publish develop "实现 API" \
  --contract '{"phase":"implement","phase_assignments":{"research":"backend","synthesize":"backend","implement":"backend","integrate":"integrator","verify":"reviewer"},"inputs":["实现 API"],"expected_outputs":["代码变更","验证结果"],"acceptance_criteria":["接口可运行","verify 通过"],"impact_scope":"write","execution_mode":"exclusive","resource_keys":["repo:backend/api"],"handoff_format":"markdown"}' \
  --verify '{"build":"go build ./..."}'
```

`resource_keys` 配合 `execution_mode` 控制真实并发语义：

- **`execution_mode: "exclusive"` 且 `resource_keys` 非空** → 任务 `claim` 时会对每个 key 申请**独占锁**。若任一 key 已被其他 processing 任务持有，`claim` 会被拒绝，任务留在 `pending/` 并把 `resource_blocked_by` 指向持有者。持有者完成后，等待任务会自动解阻塞并通知其 assignee。
- **`execution_mode: "parallel"`（默认）** 或 `resource_keys` 为空 → 不占锁，多个任务可共享相同 key。

持有记录存在 `runtime/resource_locks.json`。用 `swarm-cli.sh status` 可看到**🔒 资源锁**（谁持有什么资源）和**⏸ 资源等待队列**（哪些任务在等谁）。`runtime/events.jsonl` 相关事件：`resource.acquired` / `resource.released` / `resource.conflict` / `resource.unblocked` / `resource.lock_system_error`。

若锁表本身无法写入（磁盘满、JSON 损坏），`claim` 会发 `resource.lock_system_error` 并快速失败而非静默通过。任务在终态（completed/failed）释放锁失败时，会在任务 JSON 上标记 `resource_lock_stale: true` 便于人工排查。

#### 子任务拆分

复杂任务可拆分为子任务，支持依赖管理和多层嵌套。
注意：这里的 `--assign` 仍然有效，因为它分配的是子任务，不是 `publish`：

```bash
# 拆分任务为子任务
swarm-msg.sh split-task <parent-task-id> \
  --subtask "设计 API schema" --assign architect \
  --subtask "实现接口" --assign backend --depends 0

# 展开子任务为更细粒度的子任务（打平到同层）
swarm-msg.sh expand-subtask <subtask-id> \
  --subtask "编写单元测试" --assign backend \
  --subtask "编写集成测试" --assign tester

# 重置拆分（保留已完成子任务，取消未完成的）
swarm-msg.sh re-split <parent-task-id>
```

相关配置：`SUBTASK_MAX_DEPTH`（最大嵌套深度）、`SUBTASK_MAX_COUNT`（单个父任务最大子任务数）、`SUBTASK_STALL_TTL`（子任务组停滞检测阈值）。

#### 任务重试与上报

工蜂可报告任务失败（自动指数退避重试）或上报任务给 supervisor：

```bash
# 报告任务失败（自动指数退避重试）
swarm-msg.sh fail-task <task-id> "构建失败：缺少依赖"

# 上报复杂任务给 supervisor 重新拆分
swarm-msg.sh escalate-task <task-id> "需求涉及 3 个独立模块，建议拆分"

# 恢复卡在 processing 的任务（认领者已离线）
swarm-msg.sh recover-tasks
```

相关配置：`TASK_MAX_RETRIES`（最大重试次数，0=不重试直接失败）、`TASK_RETRY_BASE_DELAY`（重试基础延迟秒数，实际延迟 = 2^重试次数 × 基础值）、`ESCALATE_STALL_TTL`（上报任务未处理超时阈值）。

#### 任务干预

运行中的任务可随时暂停、恢复或取消：

```bash
# 暂停正在处理的任务
swarm-msg.sh pause-task <task-id> "等待 API 规范定稿"

# 恢复暂停的任务
swarm-msg.sh resume-task <task-id>

# 取消任务（级联取消依赖任务和子任务）
swarm-msg.sh cancel-task <task-id> "需求变更"
```

#### 任务流转审计链

每次任务状态变更都记录在审计日志中，用 `flow-log` 查看完整流转历史：

```bash
swarm-msg.sh flow-log <task-id>
```

#### 多 Supervisor 编排

蜂群默认启动 1 个 supervisor，按需动态扩展：

- **看门狗检测**：pending 任务数超过 `PENDING_PILEUP_THRESHOLD` 时通知 supervisor
- **supervisor 决策**：supervisor 评估后决定是否扩展
- **可控扩展**：`request-supervisor` 命令内置安全检查（数量上限、冷却时间、CLI 预算）
- **上下文传递**：新 supervisor 加入时自动收到任务队列快照

```bash
# supervisor 请求扩展（仅 supervisor/human 可调用）
swarm-msg.sh request-supervisor "多任务组并行，编排负载过高"
```

多个 supervisor 通过共享任务队列协作（claim 竞争认领）。当 supervisor 拆分任务产生大量子任务（数量 >= `COUNCIL_THRESHOLD`）时，会向其他 supervisor 广播编排通报，协调分工。

#### 质量门严格模式与人工审批

当 `GATE_STRICT_MODE=true` 时，质量门检查更严格：
- 命令返回 127（command not found）视为失败，不再跳过
- 质量门失败的任务进入 `pending_review` 状态，而非停留在 `processing`
- `pending_review` 状态的任务需要 inspector 人工审批：

```bash
# inspector 审批通过
swarm-msg.sh approve-task <task-id> "审核通过"

# inspector 驳回任务，退回给工蜂
swarm-msg.sh reject-task <task-id> "测试覆盖率不足"
```

如果任务在 `pending_review` 状态超过 `PENDING_REVIEW_TTL`，看门狗会通知人类操作者。

#### 系统维护

```bash
# 清理过期消息、已完成任务和质量门日志
swarm-msg.sh cleanup --ttl 3600 --gate-logs

# 查看/设置 CLI 数量上限
swarm-msg.sh set-limit        # 查看当前上限
swarm-msg.sh set-limit 20     # 设置上限为 20
swarm-msg.sh set-limit 0      # 取消上限
```

### 会话恢复

蜂群停止后可恢复，保留任务、消息和上下文：

```bash
# 恢复上次会话
./scripts/swarm-start.sh --resume

# 或短参数
./scripts/swarm-start.sh -r
```

恢复时框架会：
- 校验上次 `state.json` 的可恢复性
- 回收卡在 `processing` 状态的孤儿任务（可通过 `RESUME_ORPHAN_RECOVERY` 配置）
- 为每个角色重新生成上下文摘要（git commit、任务进度、最近消息）
- 将恢复摘要注入到角色的初始化消息中

### 配置参考

所有参数集中定义在 `config/defaults.conf`，支持三层优先级：环境变量 > 项目级 `.swarm/swarm.conf` > 默认值。

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `LOG_TIMESTAMP_FORMAT` | `%Y-%m-%d %H:%M:%S` | 统一时间戳格式 |
| `LOG_MAX_SIZE` | 10485760 | 单文件最大字节（10MB） |
| `LOG_ROTATE_INTERVAL` | 300 | 日志轮转检查间隔（秒） |
| `LOG_RETENTION_TTL` | 604800 | 日志最大保留时间（秒，7 天） |
| `GATE_TIMEOUT` | 120 | 质量门单条命令超时（秒） |
| `GATE_LOG_TTL` | 86400 | 质量门日志保留时间（秒） |
| `SKIP_GATE_TYPES` | `review design architecture audit document plan` | 跳过质量门检查的任务类型 |
| `GATE_STRICT_MODE` | false | 严格模式: exit 127 视为失败，失败后进入人工审批 |
| `WATCHDOG_INTERVAL` | 60 | 任务看门狗巡检间隔（秒） |
| `TASK_PROCESSING_TTL` | 21600 | 任务最大处理时长（秒，0=禁用） |
| `TASK_MAX_RETRIES` | 3 | 最大重试次数（0=不重试直接失败） |
| `TASK_RETRY_BASE_DELAY` | 60 | 重试基础延迟（秒，实际: 2^重试次数 × 基础值） |
| `SUBTASK_MAX_DEPTH` | 3 | 子任务最大嵌套深度（0=禁止拆分） |
| `SUBTASK_MAX_COUNT` | 10 | 单个父任务最大子任务数 |
| `SUBTASK_STALL_TTL` | 7200 | 子任务组停滞检测阈值（秒） |
| `ESCALATE_STALL_TTL` | 3600 | 上报任务未处理超时阈值（秒） |
| `CLEANUP_TTL` | 3600 | 过期消息/任务 TTL（秒） |
| `SILENCE_THRESHOLD` | 5 | Pane 静默阈值（秒，多久没输出算完成） |
| `STALL_THRESHOLD` | 1800 | Active 状态无新输出阈值（秒，触发 stall 通知） |
| `PASTE_DELAY` | 0.3 | paste-buffer 后等待延迟（秒） |
| `CODEX_PASTE_DELAY` | 0.5 | Codex CLI paste 后等待延迟（秒，Kitty keyboard protocol 需要更长等待） |
| `RESUME_ORPHAN_RECOVERY` | true | 恢复时是否回收 processing 中的孤儿任务 |
| `RESUME_SUMMARY_MAX_COMMITS` | 20 | 恢复摘要中最多包含的 git commit 数 |
| `RESUME_SUMMARY_MAX_TASKS` | 10 | 恢复摘要中最多包含的已完成/未完成任务数 |
| `RESUME_PANE_LINES` | 50 | 捕获 pane 最后 N 行用于恢复 |
| `RESUME_SUMMARY_MAX_MESSAGES` | 10 | 恢复摘要中的最近消息数 |
| `DEFAULT_SUPERVISOR_COUNT` | 1 | 启动时 supervisor 数量（按需动态扩展） |
| `SUPERVISOR_MAX_COUNT` | 5 | supervisor 最大数量上限（防无限扩展） |
| `SUPERVISOR_SCALE_COOLDOWN` | 300 | 两次扩展之间的最小间隔（秒） |
| `PENDING_PILEUP_THRESHOLD` | 5 | pending 任务堆积阈值（超过通知 supervisor 评估） |
| `PENDING_PILEUP_NOTIFY_INTERVAL` | 1800 | 堆积通知去重间隔（秒，默认 30min） |
| `COUNCIL_THRESHOLD` | 5 | 子任务数 >= 此值时广播编排通报给其他 supervisor |
| `PENDING_REVIEW_TTL` | 1800 | pending_review 超时阈值（秒，超时通知人类） |
| `PANES_PER_WINDOW` | 2 | 每窗口 pane 数 |

### 项目结构

```
swarmesh/
├── scripts/                 # 核心脚本
│   ├── swarm-cli.sh         # 通用主控入口（整合所有子命令）
│   ├── swarm-start.sh       # 启动蜂群
│   ├── swarm-stop.sh        # 停止蜂群
│   ├── swarm-msg.sh         # CLI 间消息通讯
│   ├── swarm-scan.sh        # 项目结构扫描
│   ├── swarm-join.sh        # 动态加入角色
│   ├── swarm-leave.sh       # 动态移除角色
│   ├── swarm-status.sh      # 状态查看
│   ├── swarm-relay.sh       # 消息中继（人类→角色）
│   ├── swarm-send.sh        # 外部发送消息
│   ├── swarm-read.sh        # 外部读取消息
│   ├── swarm-detect.sh      # CLI 状态检测
│   ├── swarm-events.sh      # 事件系统
│   ├── swarm-workflow.sh    # 工作流引擎
│   ├── swarm-lint.sh        # 角色配置完整性检查
│   ├── swarm-lib.sh         # 共享函数库
│   └── lib/                 # swarm-msg 拆分模块
│       ├── msg-story.sh     # Story 文件
│       ├── msg-quality-gate.sh  # 质量门
│       ├── msg-task-queue.sh    # 任务队列
│       └── msg-task-watchdog.sh # 任务看门狗
├── config/
│   ├── defaults.conf        # 框架默认配置（日志/质量门/看门狗/tmux 等）
│   ├── profiles/            # 团队配置预设
│   │   ├── minimal.json     # 3 角色最小团队
│   │   ├── web-dev.json     # 6 角色 Web 开发团队
│   │   └── full-stack.json  # 14 角色完整团队
│   ├── roles/               # 角色 system prompt
│   │   ├── core/            # 核心开发（frontend, backend, database, devops）
│   │   ├── quality/         # 质量保障（tester, reviewer, integrator, security, performance）
│   │   └── management/      # 管理协调（supervisor, architect, auditor, inspector, ui-designer, prd）
│   ├── cli-routing.json     # CLI 路由配置
│   └── notification-policy.json  # 通知投递策略
├── workflows/               # 预定义工作流
│   ├── quick-task.json
│   ├── feature-complete.json
│   ├── relay-chain.json
│   └── product-feature.json  # 端到端产品特性开发工作流
└── runtime/                 # 运行时数据（gitignore）
    ├── state.json           # 蜂群状态
    ├── project-info.json    # 项目扫描结果
    ├── logs/                # 角色日志
    ├── messages/            # inbox/outbox
    ├── tasks/               # 任务状态机
    ├── pipes/               # FIFO 管道（即时通知）
    ├── stories/             # 任务组 Story 文件
    ├── workflows/           # 工作流运行时状态
    ├── gate-logs/           # 质量门检查日志
    ├── results/             # 任务结果
    └── resume/              # 会话恢复摘要
```

### Profile 预设

| Profile | 角色数 | 适用场景 |
|---------|--------|---------|
| `minimal` | 3 | 快速验证、小功能开发 |
| `web-dev` | 6 | Web 应用开发 |
| `full-stack` | 14 | 大型项目、企业级开发 |

支持混合不同 AI CLI —— 同一蜂群中 frontend 用 Gemini、backend 用 Claude、reviewer 用 Codex，各取所长。

### 设计原则

- **纯 Bash + 文件系统**：无额外依赖，任何有 tmux 的机器都能跑
- **CLI 无关**：不绑定特定 AI CLI，通过 profile 配置切换
- **角色自治**：角色通过消息系统自主协作，不依赖人类中转
- **Git worktree 隔离**：每个角色可在独立分支上工作，避免冲突
- **可配置不硬编码**：所有参数集中定义在 `config/defaults.conf`，支持三层优先级覆盖（环境变量 > 项目级 `.swarm/swarm.conf` > 默认值）

### License

[Business Source License 1.1 (BSL 1.1)](https://mariadb.com/bsl11/)

- Change Date: 2030-02-27
- Change License: GPL-2.0-or-later
