---
name: tmux-swarm-discuss
description: Use when the user wants to brainstorm, explore, or cross-discuss with multiple CLIs (Codex + Claude + Gemini) in one roundtable before committing to implementation. Triggers on "和 Codex 聊聊 / 碰方案 / 讨论 / 圆桌 / 多 AI 一起聊". Supports @-mention relay with turn cap. When the plan is ready, use /swarm-promote to transition to the execute mode swarm.
---

# tmux-swarm — discuss 模式

一个 tmux session 里把多个 CLI 拉到"圆桌"上共聊。用户用 `@name` 点名触发某个参与者接话；参与者也可以 `@ 其他人` 形成多方交叉讨论。有最大轮次硬上限（默认 20）防止无限互答。

## 何时触发

- 用户想"和 Codex 先聊聊"、"多 AI 一起碰方案"、"讨论架构"
- 方案尚未成型，属于探讨阶段
- 想让两个模型互相点评彼此观点（Codex vs Claude）

**不适用**（改用 `tmux-swarm-execute`）：
- 用户已经有明确任务要落地执行
- 需要 supervisor 拆解任务并派发

## 执行流程

### 1. 启动圆桌

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/swarm-start.sh" \
    --mode discuss \
    --project "<项目路径>" \
    --cli "<首发 cli 命令，如 codex / claude>" \
    --name "<简称，用于 @点名>" \
    --hidden
```

或用 slash 命令：`/swarm-chat <项目路径> <cli> [参与者名]`

### 2. 追加参与者

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" add \
    --name claude --cli "claude"
```

典型圆桌组合：Codex + Claude + Gemini 三方，`@` 点名激活。

### 3. 发消息

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" post \
    --from user \
    --content "@codex @claude 讨论一下 Redis vs DynamoDB 作为会话缓存的取舍"
```

或用 slash 命令：`/swarm-chat-msg @codex @claude 讨论...`

### 4. 观察对话

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" tail --last 30
```

### 5. 结案并转 execute

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" promote --profile minimal
```

或 slash 命令：`/swarm-promote --profile minimal`

升级后：
- 最近 10 轮对话 dump 成 `brief.md`
- discuss session 关闭
- execute 模式拉起，supervisor 把 brief 作为首个任务

## 关键规则

- **只有 `@点名` 才触发对方接话**（v0.1 不做自由抢答，避免刷屏）
- **最大轮次 20 轮**，超限暂停等用户（环境变量 `SWARM_DISCUSS_MAX_TURNS` 调整）
- **喂给每个参与者的上下文** = 最近 10 轮对话摘要 + 当前 @ 消息
- **CLI 回复落盘** v0.1 需手动 `discuss-relay post --from <who> --content "..."`；后续版本会自动捕获 pane 输出

## 相关命令

- `/swarm-chat` — 启动 discuss
- `/swarm-chat-add` — 加参与者
- `/swarm-chat-msg` — 发消息
- `/swarm-promote` — 转 execute
- `/swarm-status` — 看参与者和最近对话
- `/swarm-stop` — 关闭
