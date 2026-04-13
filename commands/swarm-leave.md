---
name: swarm-leave
description: 从蜂群中移除角色
---

从运行中的蜂群移除指定角色。

## 执行步骤

1. **解析参数**：从用户输入中提取要移除的角色名
   - 如果没有指定角色，执行 `${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh list-roles` 列出角色供用户选择

2. **执行移除命令**：
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-leave.sh <角色名> --force --reason "<原因>"
   ```
   如果用户提供了原因就使用，否则使用默认原因 "手动移除"

3. **确认移除成功**：执行 `${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh list-roles` 确认角色已离线

4. 向用户汇报剩余团队成员

$ARGUMENTS
