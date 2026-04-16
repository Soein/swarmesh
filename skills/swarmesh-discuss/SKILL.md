---
name: swarmesh-discuss
description: Use when the user wants to brainstorm, explore, cross-discuss, or run an isolated consensus vote across multiple CLIs (Codex + Claude + Gemini) in one roundtable before committing to implementation. Triggers on "和 Codex 聊聊 / 碰方案 / 讨论 / 圆桌 / 多 AI 一起聊 / 投票 / consensus / 独立意见". Supports auto @-mention relay (v0.2 pane watcher), turn cap, and isolated voting via /swarm-vote. When the plan is ready, use /swarm-promote to transition to the execute mode swarm.
---

# swarmesh — discuss 模式

一个 tmux session 里把多个 CLI 拉到"圆桌"上共聊。用户用 `@name` 点名触发某个参与者接话；参与者也可以 `@ 其他人` 形成多方交叉讨论。有最大轮次硬上限（默认 20）防止无限互答。

## 何时触发

- 用户想"和 Codex 先聊聊"、"多 AI 一起碰方案"、"讨论架构"
- 方案尚未成型，属于探讨阶段
- 想让两个模型互相点评彼此观点（Codex vs Claude）

**不适用**（改用 `swarmesh-execute`）：
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

- **只有 `@点名` 才触发对方接话**（防刷屏）
- **最大轮次 20 轮**，超限暂停等用户（环境变量 `SWARM_DISCUSS_MAX_TURNS` 调整）
- **喂给每个参与者的上下文** = 最近 10 轮对话摘要 + 当前 @ 消息
- **CLI 回复自动落盘**（v0.2 新增）：discuss-watcher 后台进程轮询每个 pane，识别 CLI 答完后自动把回答 post 回 jsonl，并解析内嵌 `@ 其他人` 继续派发。不想自动可 `SWARM_DISCUSS_AUTO_WATCH=0` 降级回半自动。
- **防回环**：`@ 自己` 会被跳过，不会把自己的回答回推给自己
- **Codex trust prompt 自动接受**：首次进入新目录时 watcher 会自动回 "1"+Enter（`DISCUSS_CODEX_TRUST_AUTO=1`，默认开）

## 隔离投票（/swarm-vote）

当需要"三个模型独立判断、互不可见、结构化对比"时用投票模式——对标 pal consensus：

```bash
/swarm-vote "Redis vs DynamoDB 做会话缓存？"
```

过程：
- 同一问题同时 paste 给每个参与者，严格隔离（不广播）
- 半自动 collect：按时间戳从各 pane 提取"问题之后的新文本"作为答案
- report：生成结构化 markdown，每人一节 + 关键词统计

与 @点名讨论的区别：
| 场景 | 用 |
|---|---|
| 三个 AI 独立意见避免羊群效应 | `/swarm-vote` |
| 三个 AI 互相辩论、升级方案 | `/swarm-chat-msg @...` |

## 相关命令

- `/swarm-chat` — 启动 discuss
- `/swarm-chat-add` — 加参与者
- `/swarm-chat-msg` — 发消息
- `/swarm-promote` — 转 execute
- `/swarm-status` — 看参与者和最近对话
- `/swarm-stop` — 关闭
