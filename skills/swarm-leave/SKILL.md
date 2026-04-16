---
name: swarm-leave
description: Remove a role from the running swarm. Use when user says "remove role", "移除 X", "kick out backend", "少一个角色", "leave role".
---

# Remove role from swarm

从运行中的蜂群移除指定角色。

## 1. 定位 plugin root

```bash
# Locate swarmesh plugin root (优先 $SWARM_ROOT env)
if [[ -z "${SWARM_ROOT:-}" || ! -d "$SWARM_ROOT/scripts" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -type d -name scripts 2>/dev/null \
        | grep -E '/swarmesh/[^/]+/scripts$' | head -1 | sed 's|/scripts$||')
fi
[[ -n "${SWARM_ROOT:-}" && -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 swarmesh plugin root，请 export SWARM_ROOT=/path/to/swarmesh"; exit 1; }
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
