---
name: swarm-chat
description: 启动 discuss 模式：与某个 CLI（Codex/Claude/Gemini）在一个会话内圆桌讨论
---

启动 swarmesh 的 **discuss 模式**——与一个或多个 CLI 在同一会话内自由讨论、碰方案。与 `/swarm-start` 的 execute 模式互斥。

## 执行步骤

1. **解析参数**：
   - 格式: `<项目路径> <cli 命令> [参与者名]`
   - 例如: `~/my-app codex` / `~/my-app "codex chat" cx` / `. claude claude1`
   - 最简形式 `/swarm-chat codex` 等价于当前目录 + `codex` 作为启动命令

2. **启动 discuss session**：
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/swarm-start.sh" \
       --mode discuss \
       --project "<项目路径>" \
       --cli "<cli 命令>" \
       ${参与者名:+--name "<参与者名>"} \
       --hidden
   ```

3. **汇报**：参与者名 / pane 坐标 / jsonl 日志路径 / 后续可用命令：
   - `/swarm-chat-add <name> <cli>` 再加一位
   - `/swarm-chat-msg @name 内容` 触发接话
   - `/swarm-promote --profile minimal` 讨论完毕转 execute

## 注意

- discuss 模式和 execute 模式**不能同时跑**（共用 state.json）
- discuss session 名称固定为 `swarm-discuss`，不要与 execute 的 `swarm` session 冲突
- runtime 写入 `<项目路径>/.swarm/runtime/discuss/`

$ARGUMENTS
