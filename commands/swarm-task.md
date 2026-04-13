---
name: swarm-task
description: 向蜂群派发任务（execute 模式），默认发给 supervisor 编排
---

向蜂群派发高层任务。默认发给 supervisor（编排者），由其自动拆解、派发、监控。

**⚠️ 仅 execute 模式可用。** discuss 模式请用 `/swarm-chat-msg`。

## 执行步骤

### 0. 检查 mode

```bash
MODE=$(jq -r '.mode // "execute"' .swarm/runtime/state.json 2>/dev/null)
```
如果 `$MODE` 不是 `execute`，提示用户先用 `/swarm-stop` 再 `/swarm-start --mode execute`，或直接用 `/swarm-chat-msg`。

### 1. 解析参数

从用户输入中提取任务内容和可选的目标角色：
- 格式 A（推荐）: `<任务描述>` — 自动发给 supervisor
- 格式 B: `<角色名> <任务描述>` — 发给指定角色
- 例如:
  - `做一个用户注册系统` → 发给 supervisor
  - `backend 实现登录 API` → 发给 backend

判断规则：第一个词如果是已知角色名就当角色参数，否则整体当任务描述。
用以下命令检查第一个词是否是角色：
```bash
jq -r '.panes[].role' .swarm/runtime/state.json 2>/dev/null
```

### 2. 发送任务

通过消息系统发送（不是直接 paste 到 pane）：
```bash
SWARM_ROLE=human ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh send <目标角色> "<任务内容>"
```

目标角色默认为 `supervisor`。发送成功后记下返回的消息 ID。

### 3. 等待结果

任务发出后，等待蜂群回报结果。采用**轮询 human 收件箱**方式：

```bash
for i in $(seq 1 40); do
    RESULT=$(SWARM_ROLE=human ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh read 2>/dev/null)
    if [[ "$RESULT" != *"没有新消息"* ]]; then
        echo "$RESULT"
        break
    fi
    sleep 15
done
```

如果等待期间收到消息，立即展示给用户。

如果 10 分钟后仍无消息，告知用户蜂群仍在工作中，可以：
- 再次执行 `/swarm-task` 不带参数查看最新消息
- 执行 `/swarm-status` 查看蜂群状态

### 4. 查看收件箱（无参数调用时）

如果用户执行 `/swarm-task` 不带任何参数，直接读取 human 收件箱：
```bash
SWARM_ROLE=human ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh read 2>/dev/null
```

同时检查任务队列状态：
```bash
SWARM_ROLE=human ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh list-tasks --all 2>/dev/null
```

### 5. 汇报结果

向用户汇报：
- 收到的蜂群消息（来自谁、内容摘要）
- 任务队列进度（已完成/进行中/待认领）
- 如果有需要人类决策的问题，提示用户

## 回复蜂群消息

```bash
SWARM_ROLE=human ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh reply <消息ID> "<回复内容>"
```

或直接发送新消息给指定角色：
```bash
SWARM_ROLE=human ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh send <角色名> "<消息内容>"
```

## CLI 预算管理

```bash
SWARM_ROLE=human ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh set-limit <新上限>
SWARM_ROLE=human ${CLAUDE_PLUGIN_ROOT}/scripts/swarm-msg.sh set-limit
```

$ARGUMENTS
