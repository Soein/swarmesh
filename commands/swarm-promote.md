---
name: swarm-promote
description: 把 discuss 圆桌讨论的结论热升级到 execute 模式，由 supervisor 接手落地
---

当 discuss 阶段讨论出可执行方案后，用此命令：
1. 把最近对话 dump 成 `brief.md`
2. 关闭 discuss session
3. 拉起 execute 模式的完整蜂群
4. 把 brief 作为首个任务喂给 supervisor

## 执行步骤

1. **解析参数**：
   - 格式: `[--profile <profile>]`
   - 默认 `minimal`

2. **校验前提**：
   ```bash
   jq -r '.mode' .swarm/runtime/state.json
   # 必须是 "discuss"
   ```

3. **执行升级**：
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-relay.sh" promote --profile "<profile>"
   ```

4. **观察**：
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-status.sh"
   SWARM_ROLE=human "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh" read
   ```

5. 向用户汇报：
   - brief.md 路径
   - 已起哪些角色
   - supervisor 开始干活的第一条消息

$ARGUMENTS
