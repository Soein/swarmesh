---
name: swarm-chat
description: Start a discuss-mode roundtable with multiple AI CLIs (Codex/Claude/Gemini) in a single tmux session. Use when user asks to "discuss X with multiple AIs", "start a roundtable", "brainstorm with other CLIs", "start multi-AI conversation", or mentions "discuss 模式" / "圆桌讨论" / "多 AI 讨论".
---

# Start discuss-mode roundtable

启动 swarmesh 的 **discuss 模式**——与一个或多个 CLI 在同一 tmux 会话内自由讨论。

## 1. 定位 plugin root

```bash
SWARM_ROOT="${SWARM_ROOT:-}"
if [[ -z "$SWARM_ROOT" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -maxdepth 3 -type d -name 'swarmesh' 2>/dev/null | head -1)
    [[ -n "$SWARM_ROOT" ]] && SWARM_ROOT=$(find "$SWARM_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
fi
[[ -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 SWARM_ROOT，请 export SWARM_ROOT=/path/to/swarmesh"; exit 1; }
```

## 2. 解析参数

从用户输入提取：
- 项目路径（默认当前目录）
- CLI 命令（如 `codex` / `claude` / `gemini` / `"codex chat"`）
- 参与者名（可选，默认 CLI 名）

例如输入 `~/my-app codex cx` → project=~/my-app, cli=codex, name=cx。

## 3. 启动 discuss session

```bash
"$SWARM_ROOT/scripts/swarm-start.sh" \
    --mode discuss \
    --project "<项目路径>" \
    --cli "<cli 命令>" \
    ${参与者名:+--name "<参与者名>"} \
    --hidden
```

## 4. 汇报结果

告知用户：
- 参与者名 / pane 坐标 / jsonl 日志路径
- 后续可用 skill：
  - `$swarm-chat-add <name> <cli>` 加参与者
  - `$swarm-chat-list` 看谁在
  - `$swarm-chat-msg "@name <内容>"` 发消息
  - `$swarm-promote --profile <X>` 讨论完毕转 execute

## 注意

- discuss 和 execute 模式**互斥**（共用 state.json）
- discuss session 名默认按 PROJECT_DIR 派生（`swarm-discuss-<basename>`），不同项目不冲突
- runtime 写入 `<项目路径>/.swarm/runtime/discuss/`
