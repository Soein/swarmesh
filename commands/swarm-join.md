---
name: swarm-join
description: 动态添加角色到运行中的蜂群（execute 模式）
---

向运行中的蜂群（execute 模式）动态添加新角色。

## 执行步骤

1. **解析参数**：从用户输入中提取角色名和可选参数
   - 格式: `<角色名> [选项]`
   - 例如: `database --task "设计用户表"`

2. **检查可用角色配置**：
   ```bash
   ls ${CLAUDE_PLUGIN_ROOT}/config/roles/core/ ${CLAUDE_PLUGIN_ROOT}/config/roles/quality/ ${CLAUDE_PLUGIN_ROOT}/config/roles/management/
   ```
   如果用户指定的角色有对应配置文件，自动使用；否则让用户选择

3. **执行加入命令**：
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-join.sh <角色名> --cli "claude code" --config <config_path> --force [--task "任务"]
   ```

   常用 CLI 选项:
   - Claude Code: `claude code`
   - Codex: `codex chat`
   - Gemini CLI: `gemini`

   **多实例支持**: 同角色可多次加入，实例名自动编号（首实例 = 角色名，后续: `角色名-2`、`角色名-3`）。
   管理角色（supervisor、inspector）不支持多实例。

4. **确认加入成功**：执行 `${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh list-roles` 确认新实例已在线

5. 向用户汇报新实例的 pane 位置、实例名和当前团队成员

$ARGUMENTS
