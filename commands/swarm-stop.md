---
name: swarm-stop
description: 停止蜂群并可选清理数据
---

停止运行中的蜂群（execute 或 discuss 模式皆可）。

## 执行步骤

1. 先执行 `${CLAUDE_PLUGIN_ROOT}/scripts/swarm-status.sh` 查看当前状态，向用户汇报
2. 询问用户是否需要同时清理运行时数据（messages、tasks、state、events、discuss）
3. 执行停止命令：
   - 普通停止: `${CLAUDE_PLUGIN_ROOT}/scripts/swarm-stop.sh --force`
   - 停止并清理: `${CLAUDE_PLUGIN_ROOT}/scripts/swarm-stop.sh --force --clean`
4. 确认蜂群已停止: `tmux has-session -t "$(jq -r '.session_name' .swarm/runtime/state.json 2>/dev/null || echo swarm)" 2>/dev/null && echo "仍在运行" || echo "已停止"`

$ARGUMENTS
