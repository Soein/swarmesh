---
name: swarm-chat-list
description: List current participants of the discuss-mode roundtable (show who can be @-mentioned). Use when user asks "who's in the discussion", "list participants", "who can I @", "看下有谁", "列出参与者".
---

# List discuss participants

列出当前 discuss session 的所有参与者。帮助用户知道可以 `@` 谁。

## 1. 定位 plugin root

```bash
SWARM_ROOT="${SWARM_ROOT:-}"
if [[ -z "$SWARM_ROOT" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -maxdepth 3 -type d -name 'swarmesh' 2>/dev/null | head -1)
    [[ -n "$SWARM_ROOT" ]] && SWARM_ROOT=$(find "$SWARM_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
fi
[[ -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 SWARM_ROOT，请 export SWARM_ROOT=/path/to/swarmesh"; exit 1; }
```

## 2. 校验前提

```bash
MODE=$(jq -r '.mode' .swarm/runtime/state.json 2>/dev/null)
[[ "$MODE" == "discuss" ]] || { echo "⚠️ 当前不是 discuss 模式，先运行 \$swarm-chat 启动"; exit 1; }
```

## 3. 列参与者

```bash
"$SWARM_ROOT/scripts/lib/discuss-relay.sh" list
```

## 4. 提示用户

- 用 `$swarm-chat-msg "@<name> <内容>"` 发消息
- 同时 @ 多人：`$swarm-chat-msg "@cx @cl 讨论下缓存方案"`
- 无 @ 则仅记录，不触发任何 CLI 接话
