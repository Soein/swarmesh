---
name: swarm-start
description: Start AI swarm execute mode with multi-role team (supervisor + engineers + reviewers etc). Use when user asks to "start the swarm", "起蜂群", "多角色协作做项目", "launch multi-role team", "需要多个角色一起做 X".
---

# Start AI swarm (execute mode)

启动 AI Swarm 蜂群（execute 模式），supervisor 编排完整团队。

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

格式：`<项目路径> [profile名]`
- 例：`~/my-app web-dev` / `~/my-app full-stack`
- 只传一个参数时判断是路径还是 profile
- 没指定项目路径时询问用户

## 3. 列可用 profile

```bash
ls "$SWARM_ROOT/config/profiles/"
```

用户未指定则从列表选（minimal / web-dev / full-stack 等）。

## 4. 启动

```bash
"$SWARM_ROOT/scripts/swarm-start.sh" --mode execute \
    --project "<项目路径>" \
    --profile "<profile>" \
    --hidden
```

## 5. 查看状态 + 汇报

```bash
"$SWARM_ROOT/scripts/swarm-status.sh"
```

向用户汇报：项目目录 / 上线角色 / 窗口分配。

## 注意

- `--project` 必需
- runtime 写入 `<项目路径>/.swarm/runtime/`
- `--hidden` 避免 attach tmux 导致终端挂起
- 要 discuss 模式请用 `$swarm-chat`
- 已存在 session 时先用 `$swarm-stop` 停掉
