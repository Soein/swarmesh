---
name: tmux-swarm-execute
description: Use when the user wants to orchestrate a multi-role coding task across Claude Code / Codex / Gemini with a supervisor dispatching work to specialized agents (backend / frontend / reviewer / architect / tester ...). Triggers on "并行 + 多角色 + 编排/拆解" 类需求，例如 "用蜂群实现 X", "并行修复 Y", "让 supervisor 拆任务"。Spawns a tmux swarm (4–15 roles).
---

# tmux-swarm — execute 模式

本 skill 负责把用户"我想让多个 AI 角色协同干活"的需求转成 tmux-swarm 的 execute 模式调用。

## 何时触发

匹配以下场景之一：
- 用户说"开蜂群 / 启动 swarm / 多角色并行 / 让 supervisor 拆任务 / 团队干活"
- 任务明显需要多种专长协同（产品 + 前后端 + 测试 + 审核）
- 用户已经和单个 CLI 讨论成型了方案，要落地执行

**不适用**（改用 `tmux-swarm-discuss`）：
- 用户只想"和 Codex 聊聊"、"讨论方案"、"碰思路"等探讨阶段

## 执行流程

### 1. 确认 profile

```bash
ls "${CLAUDE_PLUGIN_ROOT}/config/profiles/"
```

典型选择：
- `minimal` — 4 角色（前后端 + reviewer + integrator）快速验证
- `web-dev` — Web 开发子集
- `full-stack` — 15 角色完整团队

如果用户没指定，默认推荐 `minimal`。

### 2. 确认目标项目路径

`--project` 必需，指向用户要被开发的代码库（不是插件自身）。runtime 写在 `<project>/.swarm/runtime/`。

### 3. 启动

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/swarm-start.sh" \
    --mode execute \
    --project "<项目路径>" \
    --profile "<profile>" \
    --hidden
```

### 4. 派发任务

```bash
SWARM_ROLE=human "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh" send supervisor "<任务描述>"
```

### 5. 观察进度

用户可以直接执行 `/swarm-status` slash 命令，或：

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/swarm-status.sh"
```

### 6. 收尾

任务完结后：

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/swarm-stop.sh" --force [--clean]
```

## 相关命令

- `/swarm-start` — 启动
- `/swarm-task` — 派发任务
- `/swarm-status` — 查看进度
- `/swarm-join` / `/swarm-leave` — 动态增删角色
- `/swarm-stop` — 停止

## 依赖

- `tmux`、`jq`、`bash ≥ 4`
- 至少一个 AI CLI：`claude` / `codex` / `gemini`
- 依赖检测：`"${CLAUDE_PLUGIN_ROOT}/scripts/check-deps.sh"`
