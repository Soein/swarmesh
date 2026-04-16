---
name: swarm-leave
description: Remove a role from the running swarm. Use when user says "remove role", "移除 X", "kick out backend", "少一个角色", "leave role".
---

# Remove role from swarm

从运行中的蜂群移除指定角色。

## 1. 定位 plugin root

```bash
SWARM_ROOT="${SWARM_ROOT:-}"
if [[ -z "$SWARM_ROOT" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -maxdepth 3 -type d -name 'swarmesh' 2>/dev/null | head -1)
    [[ -n "$SWARM_ROOT" ]] && SWARM_ROOT=$(find "$SWARM_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
fi
[[ -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 SWARM_ROOT"; exit 1; }
```

## 2. 解析参数

无指定角色时列出供选：
```bash
"$SWARM_ROOT/scripts/swarm-msg.sh" list-roles
```

## 3. 移除

```bash
"$SWARM_ROOT/scripts/swarm-leave.sh" <角色名> --force --reason "<原因>"
```

无原因默认 "手动移除"。

## 4. 确认 + 汇报

```bash
"$SWARM_ROOT/scripts/swarm-msg.sh" list-roles
```
汇报剩余团队成员。
