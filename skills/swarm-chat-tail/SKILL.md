---
name: swarm-chat-tail
description: View recent N turns of discuss session history from jsonl (without tmux attach). Use when user asks to "show discussion history", "what did they say", "回看讨论", "看下讨论历史", or needs to catch up on recent conversation.
---

# Tail discuss history

查看当前 discuss session 的最近对话，不用 tmux attach。

## 1. 定位 plugin root

```bash
# Locate swarmesh plugin root (优先 $SWARM_ROOT env)
if [[ -z "${SWARM_ROOT:-}" || ! -d "$SWARM_ROOT/scripts" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -type d -name scripts 2>/dev/null \
        | grep -E '/swarmesh/[^/]+/scripts$' | head -1 | sed 's|/scripts$||')
fi
[[ -n "${SWARM_ROOT:-}" && -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 swarmesh plugin root，请 export SWARM_ROOT=/path/to/swarmesh"; exit 1; }
```

## 2. 参数

可选轮次 N（默认 20）。例如 `$swarm-chat-tail 50` 看最近 50 轮。

## 3. 校验前提

```bash
MODE=$(jq -r '.mode' .swarm/runtime/state.json 2>/dev/null)
[[ "$MODE" == "discuss" ]] || { echo "⚠️ 当前不是 discuss 模式"; exit 1; }
```

## 4. 输出历史

```bash
N="${ARGUMENTS:-20}"
"$SWARM_ROOT/scripts/lib/discuss-relay.sh" tail --last "$N"
```

## 5. 提示后续动作

- 发新消息：`$swarm-chat-msg "@name <内容>"`
- 发起投票：`$swarm-vote "<问题>"`
- 结案转 execute：`$swarm-promote --profile <X>`
