---
name: swarm-task
description: Dispatch task to swarm (execute mode) — defaults to supervisor for auto-orchestration, or target specific role. Also reads human inbox when called without args. Use when user says "do X" / "实现 Y" / "派给 supervisor" / "让团队做 Z", and when asking for swarm status/replies.
---

# Dispatch task to swarm

向蜂群派发高层任务。默认发给 supervisor（自动拆解/派发/监控）。
**⚠️ 仅 execute 模式可用。** discuss 模式用 `$swarm-chat-msg`。

## 1. 定位 plugin root

```bash
# Locate swarmesh plugin root (优先 $SWARM_ROOT env)
if [[ -z "${SWARM_ROOT:-}" || ! -d "$SWARM_ROOT/scripts" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -type d -name scripts 2>/dev/null \
        | grep -E '/swarmesh/[^/]+/scripts$' | head -1 | sed 's|/scripts$||')
fi
[[ -n "${SWARM_ROOT:-}" && -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 swarmesh plugin root，请 export SWARM_ROOT=/path/to/swarmesh"; exit 1; }
```

## 2. 检查 mode

```bash
MODE=$(jq -r '.mode // "execute"' .swarm/runtime/state.json 2>/dev/null)
```
非 `execute` 时提示先 `$swarm-stop` 再 `$swarm-start --mode execute`，或改用 `$swarm-chat-msg`。

## 3. 解析参数

- 格式 A（推荐）：`<任务描述>` → 发给 supervisor
- 格式 B：`<角色名> <任务描述>` → 发给指定角色
- 判断：第一个词是已知角色名就当角色参数
  ```bash
  jq -r '.panes[].role' .swarm/runtime/state.json 2>/dev/null
  ```

## 4. 发送

```bash
SWARM_ROLE=human "$SWARM_ROOT/scripts/swarm-msg.sh" send <目标角色> "<任务内容>"
```

## 5. 等待结果（轮询 human 收件箱）

```bash
for i in $(seq 1 40); do
    RESULT=$(SWARM_ROLE=human "$SWARM_ROOT/scripts/swarm-msg.sh" read 2>/dev/null)
    if [[ "$RESULT" != *"没有新消息"* ]]; then
        echo "$RESULT"; break
    fi
    sleep 15
done
```

10 分钟无消息提示用户：再跑 `$swarm-task`（无参数）看最新 / 跑 `$swarm-status`。

## 6. 无参数调用 = 查收件箱

```bash
SWARM_ROLE=human "$SWARM_ROOT/scripts/swarm-msg.sh" read 2>/dev/null
SWARM_ROLE=human "$SWARM_ROOT/scripts/swarm-msg.sh" list-tasks --all 2>/dev/null
```

## 7. 汇报

- 收到的蜂群消息（谁说的、内容摘要）
- 任务队列（完成/进行中/待认领）
- 需人类决策的问题

## 回复 / 新消息

```bash
SWARM_ROLE=human "$SWARM_ROOT/scripts/swarm-msg.sh" reply <msg-id> "<回复>"
SWARM_ROLE=human "$SWARM_ROOT/scripts/swarm-msg.sh" send <role> "<消息>"
```

## CLI 预算

```bash
SWARM_ROLE=human "$SWARM_ROOT/scripts/swarm-msg.sh" set-limit <新上限>
```
