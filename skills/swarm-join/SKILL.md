---
name: swarm-join
description: Dynamically add a role to the running swarm (execute mode). Use when user says "add a role", "加个角色", "加 database engineer", "bring backend online", "need another engineer".
---

# Dynamic add role to swarm

向运行中的蜂群（execute 模式）动态添加新角色。

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

格式：`<角色名> [选项]`
- 例：`database --task "设计用户表"`

## 3. 检查可用角色配置

```bash
ls "$SWARM_ROOT/config/roles/core/" \
   "$SWARM_ROOT/config/roles/quality/" \
   "$SWARM_ROOT/config/roles/management/"
```

有匹配自动用，否则让用户选。

## 4. 加入

```bash
"$SWARM_ROOT/scripts/swarm-join.sh" <角色名> \
    --cli "claude code" \
    --config <config_path> \
    --force \
    [--task "任务"]
```

CLI 选项：`claude code` / `codex chat` / `gemini`

**多实例**：同角色可多次加入，实例名自动编号（首 = 角色名，后续 `角色名-2` ...）。supervisor/inspector 不支持多实例。

## 5. 确认

```bash
"$SWARM_ROOT/scripts/swarm-msg.sh" list-roles
```

汇报 pane 位置、实例名、当前团队。
