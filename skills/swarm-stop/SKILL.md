---
name: swarm-stop
description: Stop the running swarm (execute or discuss mode) with optional data cleanup. Use when user says "stop swarm", "kill all", "停掉", "结束蜂群", "shutdown", "清理蜂群数据".
---

# Stop swarm

停止运行中的蜂群（execute 或 discuss 模式皆可）。

## 1. 定位 plugin root

```bash
# Locate swarmesh plugin root (优先 $SWARM_ROOT env)
if [[ -z "${SWARM_ROOT:-}" || ! -d "$SWARM_ROOT/scripts" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -type d -name scripts 2>/dev/null \
        | grep -E '/swarmesh/[^/]+/scripts$' | head -1 | sed 's|/scripts$||')
fi
[[ -n "${SWARM_ROOT:-}" && -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 swarmesh plugin root，请 export SWARM_ROOT=/path/to/swarmesh"; exit 1; }
```

## 2. 查看当前状态

```bash
"$SWARM_ROOT/scripts/swarm-status.sh"
```

## 3. 询问清理意向

是否清理运行时数据（messages / tasks / state / events / discuss）？

## 4. 停止

```bash
# 普通停止
"$SWARM_ROOT/scripts/swarm-stop.sh" --force

# 或停止并清理
"$SWARM_ROOT/scripts/swarm-stop.sh" --force --clean
```

## 5. 确认

```bash
tmux has-session -t "$(jq -r '.session_name' .swarm/runtime/state.json 2>/dev/null || echo swarm)" 2>/dev/null \
    && echo "仍在运行" || echo "已停止"
```
