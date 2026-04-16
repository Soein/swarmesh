---
name: swarm-chat-add
description: Add a new AI CLI participant to an ongoing discuss-mode roundtable. Use when user asks to "add another AI", "bring in claude/gemini/codex", "add participant to discussion", or mentions "加入讨论" / "加参与者".
---

# Add participant to discuss session

向正在运行的 discuss session 加一位新参与者（新开 pane + 启动指定 CLI）。

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

格式：`<参与者名> <cli 命令>`
- 例如: `cl "claude"` / `cx "codex chat"` / `gem gemini`
- 参与者名建议短、唯一，用于 `@点名`

## 3. 校验前提

```bash
MODE=$(jq -r '.mode' .swarm/runtime/state.json 2>/dev/null)
[[ "$MODE" == "discuss" ]] || { echo "⚠️ 当前不是 discuss 模式，先运行 \$swarm-chat"; exit 1; }
```

## 4. 加入参与者

```bash
"$SWARM_ROOT/scripts/lib/discuss-relay.sh" add \
    --name "<参与者名>" \
    --cli "<cli 命令>"
```

## 5. 确认 + 汇报

```bash
"$SWARM_ROOT/scripts/lib/discuss-relay.sh" list
```

向用户汇报：新参与者 pane 坐标、当前圆桌成员、可以开始 `@` 点名对话。
