---
name: swarm-chat-list
description: 列出当前 discuss 会话的所有参与者（可 @点名的名字）
---

列出当前 discuss session 的所有参与者。帮助用户知道可以 `@` 谁。

## 执行步骤

1. **校验前提**：
   ```bash
   MODE=$(jq -r '.mode' .swarm/runtime/state.json 2>/dev/null)
   [[ "$MODE" == "discuss" ]] || echo "⚠️ 当前不是 discuss 模式，先 /swarm-chat 启动"
   ```

2. **列出参与者**：
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" list
   ```

3. **提示用户**：
   - 用 `/swarm-chat-msg @<name> <内容>` 发消息给某个参与者
   - 同时 @ 多人：`/swarm-chat-msg @cx @cl 讨论下缓存方案`
   - 无 @ 则仅记录，不触发任何 CLI 接话

$ARGUMENTS
