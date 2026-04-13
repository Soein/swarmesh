---
name: swarm-status
description: 查看蜂群当前状态和未读消息
---

查看蜂群的当前运行状态、任务进度和 human 收件箱。同时兼容 execute / discuss 两种模式。

## 执行步骤

1. 执行 `${CLAUDE_PLUGIN_ROOT}/scripts/swarm-status.sh` 查看整体状态（含当前 mode）
2. 执行 `SWARM_ROLE=human ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh list-roles` 查看在线角色/参与者列表
3. 检查 human 收件箱（蜂群给主控的消息）：
   ```bash
   SWARM_ROLE=human ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh read 2>/dev/null
   ```
4. 如果当前 mode 为 execute，额外检查任务队列状态：
   ```bash
   SWARM_ROLE=human ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh list-tasks --all 2>/dev/null
   ```
5. 如果当前 mode 为 discuss，额外展示最近对话：
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh tail 2>/dev/null
   ```
6. 检查事件日志最近的活动：
   ```bash
   tail -20 .swarm/runtime/events.jsonl 2>/dev/null | jq -r '[.ts, .type, .role, (.data | tostring)] | join(" | ")' 2>/dev/null
   ```
7. 向用户汇报：
   - 当前 mode（execute / discuss）
   - 哪些角色/参与者在线
   - human 收件箱是否有未读消息
   - 任务队列进度（execute 模式）或最近对话（discuss 模式）
   - 最近的活动事件

$ARGUMENTS
