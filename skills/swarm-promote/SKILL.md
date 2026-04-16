---
name: swarm-promote
description: Promote discuss conclusion to execute mode—dump brief, kill discuss, start full swarm, dispatch to supervisor. Use when user says "结案" / "讨论好了开干" / "promote to execute" / "finalize discussion and dispatch" / "讨论结束开始做".
---

# Promote discuss → execute

当 discuss 讨论出可执行方案后，用此 skill：
1. 把最近对话 dump 成 `brief.md`
2. 关闭 discuss session
3. 拉起 execute 模式的完整蜂群
4. 把 brief 作为首个任务喂给 supervisor

## 1. 定位 plugin root

```bash
SWARM_ROOT="${SWARM_ROOT:-}"
if [[ -z "$SWARM_ROOT" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -maxdepth 3 -type d -name 'swarmesh' 2>/dev/null | head -1)
    [[ -n "$SWARM_ROOT" ]] && SWARM_ROOT=$(find "$SWARM_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
fi
[[ -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 SWARM_ROOT，请 export SWARM_ROOT=/path/to/swarmesh"; exit 1; }
```

## 2. 解析参数

`[--profile <profile>]`，默认 `minimal`。

## 3. 校验前提

```bash
MODE=$(jq -r '.mode' .swarm/runtime/state.json)
[[ "$MODE" == "discuss" ]] || { echo "⚠️ 必须在 discuss 模式"; exit 1; }
```

## 4. 执行升级

```bash
"$SWARM_ROOT/scripts/lib/discuss-relay.sh" promote --profile "<profile>"
```

## 5. 观察

```bash
"$SWARM_ROOT/scripts/swarm-status.sh"
SWARM_ROLE=human "$SWARM_ROOT/scripts/swarm-msg.sh" read
```

## 6. 向用户汇报

- brief.md 路径
- 已起哪些角色
- supervisor 收到的首条消息
