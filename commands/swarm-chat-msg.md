---
name: swarm-chat-msg
description: 向 discuss 圆桌发一条消息，用 @name 点名触发对方接话
---

在 discuss session 里发消息。支持 `@name` 点名——被点名的参与者会收到"最近 N 轮对话 + 当前消息"并接话。

## 执行步骤

1. **先列出当前参与者**（告诉用户可以 @ 谁）：
   ```bash
   echo "当前参与者（可 @点名）："
   "${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" list
   ```

2. **语法提示**：用户输入即消息正文，含 `@name` 则触发该参与者接话。
   - 例如 `/swarm-chat-msg @codex @claude 设计 Redis 缓存方案`
   - 无 @点名 → 仅落盘记录，不触发任何 CLI

3. **校验前提**：
   ```bash
   MODE=$(jq -r '.mode' .swarm/runtime/state.json 2>/dev/null)
   [[ "$MODE" == "discuss" ]] || echo "⚠️ 当前不是 discuss 模式"
   ```

4. **发送**：
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" post \
       --from "user" \
       --content "$ARGUMENTS"
   ```

4. **查看进展**：等 10–20 秒后：
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" tail --last 20
   ```

5. **提示用户**：
   - 被 @ 的参与者正在生成回复，其输出会写进 pane（可 tmux attach 查看原始）
   - 若参与者也 @ 了其他人，对方会继续接话
   - 达到最大轮次（默认 20）会暂停，需要 `SWARM_DISCUSS_MAX_TURNS=40` 重启或 `/swarm-promote` 收尾

## 非 user 发言（CLI 回复落盘）

CLI 回复的落盘目前由用户手动触发（v0.1 限制）：
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" post \
    --from codex \
    --content "我觉得方案 A 更合适，因为... @claude 你怎么看?"
```

后续版本会通过 pane 输出监听自动捕获。

$ARGUMENTS
