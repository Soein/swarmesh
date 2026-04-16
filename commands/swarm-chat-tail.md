---
name: swarm-chat-tail
description: 查看 discuss session 最近 N 轮对话（从 jsonl 读取）
---

查看当前 discuss session 的最近对话记录。不用 tmux attach 就能回看历史。

## 执行步骤

1. **参数**：$ARGUMENTS 可传数字 N（默认 20 轮）
   - 例如 `/swarm-chat-tail 50` 看最近 50 轮

2. **校验前提**：
   ```bash
   MODE=$(jq -r '.mode' .swarm/runtime/state.json 2>/dev/null)
   [[ "$MODE" == "discuss" ]] || echo "⚠️ 当前不是 discuss 模式"
   ```

3. **输出历史**：
   ```bash
   N="${ARGUMENTS:-20}"
   "${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" tail --last "$N"
   ```

4. **提示用户**：
   - 想发新消息：`/swarm-chat-msg "@name <内容>"`
   - 想结案转 execute：`/swarm-promote --profile <name>`
   - 想发起投票：`/swarm-vote "<问题>"`

$ARGUMENTS
