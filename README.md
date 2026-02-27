# Swarmesh

基于 tmux 的多 AI CLI 蜂群协作框架。在一个 tmux session 中编排多个 AI CLI 实例（Claude Code、Gemini CLI、Codex 等），让它们通过消息系统自主协作完成复杂任务。

## 核心思路

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

## 快速开始

### 依赖

- tmux
- jq
- 至少一个 AI CLI（[Claude Code](https://github.com/anthropics/claude-code)、[Gemini CLI](https://github.com/google-gemini/gemini-cli)、[Codex](https://github.com/openai/codex) 等）

### 通用 CLI（推荐）

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

### Claude Code 用户

如果你使用 Claude Code 作为主控，可以直接用 slash command（底层逻辑相同）：

- `/swarm-start` — 启动蜂群
- `/swarm-stop` — 停止蜂群
- `/swarm-status` — 查看状态
- `/swarm-task` — 派发任务
- `/swarm-join` — 加入角色
- `/swarm-leave` — 移除角色

### 底层脚本

也可以直接调用底层脚本：

```bash
# 启动
./scripts/swarm-start.sh --project /path/to/your/project --profile minimal --hidden

# 状态
./scripts/swarm-status.sh

# 停止
./scripts/swarm-stop.sh --force
```

## 消息系统

角色之间通过 `swarm-msg.sh` 通讯，每个角色在自己的 pane 内直接调用：

```bash
# 发消息
swarm-msg.sh send backend "请设计用户认证 API"

# 广播给所有角色
swarm-msg.sh broadcast "v1 API 接口已定稿，请查收"

# 查看收件箱
swarm-msg.sh inbox

# 回复消息
swarm-msg.sh reply <msg-id> "收到，开始实现"

# 查看团队成员
swarm-msg.sh list-roles

# 创建/领取任务
swarm-msg.sh task create "实现登录页面" --assign frontend
swarm-msg.sh task take <task-id>
```

消息通过文件系统（inbox/outbox）持久化，同时用 tmux paste-buffer 即时推送通知到目标 pane。

## 动态扩缩容

```bash
# 运行中加入新角色
./scripts/swarm-join.sh --role security --cli "claude chat" --config quality/security.md

# 移除角色
./scripts/swarm-leave.sh database --reason "数据库设计已完成"
```

## 质量保障

### 项目扫描

启动时自动扫描目标项目结构，收集关键配置文件（`package.json`、`go.mod`、`Cargo.toml` 等）信息到 `runtime/project-info.json`。脚本只收集原始事实，LLM 角色自行解读技术栈。

### Story 文件

每个任务组自动生成 Story 文件（`runtime/stories/<group-id>.json`），记录子任务状态、验收记录和进度时间线。数据用 JSON 存储，展示时渲染为 markdown：

```bash
swarm-msg.sh story-view <group-id>
```

### 质量门

工蜂 `complete-task` 时自动执行验证命令（build/test/lint），检查失败则任务保持 processing，工蜂需修复后重新提交。

验证命令三层优先级（低→高）：
1. **运行时**: `runtime/project-info.json` 的 `verify_commands`（inspector 通过 `set-verify` 配置）
2. **项目级**: `.swarm/verify.json`（用户手动创建）
3. **任务级**: `publish --verify '{"test":"go test ./..."}'`（发布任务时指定）

```bash
# inspector 按角色配置验证命令
swarm-msg.sh set-verify '{"build":"go build ./...","test":"go test ./..."}' --role backend
swarm-msg.sh set-verify '{"build":"npm run build","test":"npm test"}' --role frontend

# 或发布任务时指定
swarm-msg.sh publish develop "实现 API" --verify '{"build":"go build ./..."}'
```

## 项目结构

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
│   └── swarm-lib.sh         # 共享函数库
├── config/
│   ├── profiles/            # 团队配置预设
│   │   ├── minimal.json     # 3 角色最小团队
│   │   ├── web-dev.json     # 7 角色 Web 开发团队
│   │   └── full-stack.json  # 13 角色完整团队
│   ├── roles/               # 角色 system prompt
│   │   ├── core/            # 核心开发（frontend, backend, database, devops）
│   │   ├── quality/         # 质量保障（tester, reviewer, security, performance）
│   │   └── management/      # 管理协调（supervisor, architect, auditor, inspector, ui-designer）
│   └── cli-routing.json     # CLI 路由配置
├── workflows/               # 预定义工作流
│   ├── quick-task.json
│   ├── feature-complete.json
│   └── relay-chain.json
└── runtime/                 # 运行时数据（gitignore）
    ├── state.json           # 蜂群状态
    ├── project-info.json    # 项目扫描结果
    ├── logs/                # 角色日志
    ├── messages/            # inbox/outbox
    ├── tasks/               # 任务状态机
    ├── stories/             # 任务组 Story 文件
    ├── gate-logs/           # 质量门检查日志
    └── results/             # 任务结果
```

## Profile 预设

| Profile | 角色数 | 适用场景 |
|---------|--------|---------|
| `minimal` | 3 | 快速验证、小功能开发 |
| `web-dev` | 7 | Web 应用开发 |
| `full-stack` | 13 | 大型项目、企业级开发 |

支持混合不同 AI CLI —— 同一蜂群中 frontend 用 Gemini、backend 用 Claude、reviewer 用 Codex，各取所长。

## 设计原则

- **纯 Bash + 文件系统**：无额外依赖，任何有 tmux 的机器都能跑
- **CLI 无关**：不绑定特定 AI CLI，通过 profile 配置切换
- **角色自治**：角色通过消息系统自主协作，不依赖人类中转
- **Git worktree 隔离**：每个角色可在独立分支上工作，避免冲突
- **可配置不硬编码**：所有路径、参数均可通过环境变量或配置文件覆盖

## License

[Business Source License 1.1 (BSL 1.1)](https://mariadb.com/bsl11/)

- Change Date: 2030-02-27
- Change License: GPL-2.0-or-later
