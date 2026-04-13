---
name: swarm-start
description: 启动蜂群协作环境（execute 模式，supervisor 编排完整蜂群）
---

启动 AI Swarm 蜂群协作环境（execute 模式）。

## 执行步骤

1. **解析参数**：从用户输入中提取项目路径和可选的 profile
   - 格式: `<项目路径> [profile名]`
   - 例如: `~/my-app web-dev`
   - 如果只传了一个参数，判断是路径还是 profile
   - 如果没有指定项目路径，询问用户

2. 执行 `ls ${CLAUDE_PLUGIN_ROOT}/config/profiles/` 列出可用 profile，如果未指定 profile 则让用户选择

3. 执行启动命令（后台模式，不 attach）：
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-start.sh --mode execute --project <项目路径> --profile <profile> --hidden
   ```

4. 启动后执行 `${CLAUDE_PLUGIN_ROOT}/scripts/swarm-status.sh` 查看蜂群状态

5. 向用户汇报：项目目录、哪些角色已上线、窗口分配

## 注意事项
- `--project` 是必需参数，指定蜂群要开发的目标项目目录
- 所有角色的 CLI 都在该项目目录下工作
- runtime 数据写入 `<项目路径>/.swarm/runtime/`
- 如果提示 session 已存在，告知用户可以用 `/swarm-stop` 先停止
- 使用 `--hidden` 模式，避免 attach 到 tmux 导致当前终端挂起
- 如需 discuss 模式（与多个 CLI 圆桌讨论），使用 `/swarm-chat` 代替

$ARGUMENTS
