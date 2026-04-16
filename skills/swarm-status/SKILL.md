---
name: swarm-status
description: Show current swarm state (execute or discuss mode), online roles/participants, human inbox messages, task queue progress. Use when user asks "what's going on", "swarm status", "现在咋样了", "进度如何", "谁在线", "看下状态".
---

# Swarm status

查看当前运行状态 + 任务进度 + human 收件箱。兼容 execute / discuss 两种模式。

## 1. 定位 plugin root

```bash
# Locate swarmesh plugin root (优先 $SWARM_ROOT env)
if [[ -z "${SWARM_ROOT:-}" || ! -d "$SWARM_ROOT/scripts" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -type d -name scripts 2>/dev/null \
        | grep -E '/swarmesh/[^/]+/scripts$' | head -1 | sed 's|/scripts$||')
fi
[[ -n "${SWARM_ROOT:-}" && -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 swarmesh plugin root，请 export SWARM_ROOT=/path/to/swarmesh"; exit 1; }
```

## 2. 整体状态（含当前 mode）

```bash
"$SWARM_ROOT/scripts/swarm-status.sh"
```

## 3. 在线角色/参与者

```bash
SWARM_ROLE=human "$SWARM_ROOT/scripts/swarm-msg.sh" list-roles
```

## 4. Human 收件箱

```bash
SWARM_ROLE=human "$SWARM_ROOT/scripts/swarm-msg.sh" read 2>/dev/null
```

## 5. 按 mode 补充信息

**execute 模式**：
```bash
SWARM_ROLE=human "$SWARM_ROOT/scripts/swarm-msg.sh" list-tasks --all 2>/dev/null
```

**discuss 模式**：
```bash
"$SWARM_ROOT/scripts/lib/discuss-relay.sh" tail 2>/dev/null
```

## 6. 最近事件

```bash
tail -20 .swarm/runtime/events.jsonl 2>/dev/null \
  | jq -r '[.ts, .type, .role, (.data | tostring)] | join(" | ")' 2>/dev/null
```

## 7. 向用户汇报

- 当前 mode（execute / discuss）
- 在线角色/参与者
- human 收件箱是否有未读
- 任务队列进度 or 最近对话
- 最近的活动事件
