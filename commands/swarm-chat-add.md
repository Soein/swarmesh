---
name: swarm-chat-add
description: 在运行中的 discuss 圆桌加入新的 CLI 参与者
---

向正在运行的 discuss session 加一位新参与者（新开 pane + 启动指定 CLI）。

## 执行步骤

1. **解析参数**：
   - 格式: `<参与者名> <cli 命令>`
   - 例如: `claude "claude"` / `cx "codex chat"` / `gem gemini`
   - 参与者名建议短、唯一，用于 `@点名`

2. **校验前提**：
   ```bash
   jq -r '.mode' .swarm/runtime/state.json 2>/dev/null
   # 必须是 "discuss"，否则提示用户先 /swarm-chat
   ```

3. **加入参与者**：
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" add \
       --name "<参与者名>" \
       --cli "<cli 命令>"
   ```

4. **确认**：
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" list
   ```

5. 向用户汇报：新参与者 pane 坐标、当前圆桌成员、可以开始 @ 点名对话

$ARGUMENTS
