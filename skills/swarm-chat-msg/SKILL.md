---
name: swarm-chat-msg
description: Post a message to the discuss roundtable with @-mentions to trigger replies. Use when user wants to "send message to discussion", "@mention a participant", "post to roundtable", "触发 CLI 接话", "发消息", or says "@xxx 讨论 X".
---

# Post message to discuss session

在 discuss session 里发消息。支持 `@name` 点名——被点名者收到"最近 N 轮对话 + 当前消息"并接话。

## 1. 定位 plugin root

```bash
SWARM_ROOT="${SWARM_ROOT:-}"
if [[ -z "$SWARM_ROOT" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -maxdepth 3 -type d -name 'swarmesh' 2>/dev/null | head -1)
    [[ -n "$SWARM_ROOT" ]] && SWARM_ROOT=$(find "$SWARM_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
fi
[[ -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 SWARM_ROOT，请 export SWARM_ROOT=/path/to/swarmesh"; exit 1; }
```

## 2. 先列出当前参与者（告诉用户可 @ 谁）

```bash
echo "当前参与者（可 @点名）："
"$SWARM_ROOT/scripts/lib/discuss-relay.sh" list
```

## 3. 校验前提

```bash
MODE=$(jq -r '.mode' .swarm/runtime/state.json 2>/dev/null)
[[ "$MODE" == "discuss" ]] || { echo "⚠️ 当前不是 discuss 模式"; exit 1; }
```

## 4. 语法提示

用户输入即消息正文，含 `@name` 则触发该参与者接话：
- 例：`@codex @claude 设计 Redis 缓存方案`
- 无 @ → 仅落盘记录，不触发任何 CLI

## 5. 发送

```bash
"$SWARM_ROOT/scripts/lib/discuss-relay.sh" post \
    --from "user" \
    --content "<用户输入的消息正文>"
```

## 6. 查看进展（等 10–20 秒后）

```bash
"$SWARM_ROOT/scripts/lib/discuss-relay.sh" tail --last 20
```

## 7. 提示用户

- 被 @ 的参与者正在生成回复，pane 里可见流式输出
- 若参与者也 @ 了其他人，对方会继续接话
- 达到最大轮次（默认 20）会暂停 — `SWARM_DISCUSS_MAX_TURNS=40` 调整
