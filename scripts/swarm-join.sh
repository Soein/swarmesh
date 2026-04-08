#!/usr/bin/env bash
################################################################################
# swarm-join.sh - 动态注册新角色加入运行中的蜂群
#
# 在运行中的 swarm session 中新建 pane，启动 CLI，更新 state.json，
# 并广播通知现有角色。
#
# 用法:
#   swarm-join.sh <role> --cli <cli_cmd> --config <config_path> [选项]
#
# 参数:
#   role              角色名称（如 security, performance）
#   --cli <cmd>       CLI 启动命令（如 "claude chat", "codex chat"）
#   --config <path>   角色配置文件相对路径（如 quality/security.md）
#   --alias <aliases> 角色别名，逗号分隔（可选）
#   --window <name>   指定加入的窗口名（可选，默认自动选择或新建）
#
# 示例:
#   swarm-join.sh security --cli "claude chat" --config quality/security.md
#   swarm-join.sh database --cli "claude chat" --config core/database.md --alias "db"
#   swarm-join.sh performance --cli "codex chat" --config quality/performance.md --window quality
################################################################################

set -euo pipefail

# =============================================================================
# 配置
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/swarm-lib.sh"

# CLI 启动等待时间
CLI_STARTUP_WAIT="${CLI_STARTUP_WAIT:-3}"

# =============================================================================
# 参数解析
# =============================================================================

ROLE=""
CLI_CMD=""
CONFIG_PATH=""
ALIAS=""
TARGET_WINDOW=""
INITIAL_TASK=""
CATEGORY=""  # 可选: management/quality/core；未传则从 --config 路径推断

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cli)      CLI_CMD="$2"; shift 2 ;;
        --config)   CONFIG_PATH="$2"; shift 2 ;;
        --category) CATEGORY="$2"; shift 2 ;;
        --alias)    ALIAS="$2"; shift 2 ;;
        --window)   TARGET_WINDOW="$2"; shift 2 ;;
        --task)     INITIAL_TASK="$2"; shift 2 ;;
        --cli-wait) CLI_STARTUP_WAIT="$2"; shift 2 ;;
        -h|--help)
            cat <<'EOF'
swarm-join.sh - 动态注册新角色加入蜂群

用法:
  swarm-join.sh <role> --cli <cmd> --config <path> [选项]

必需参数:
  role              角色名称
  --cli <cmd>       CLI 启动命令
  --config <path>   角色配置文件路径（相对于 config/roles/）

可选参数:
  --category <c>    权限分类 (management/quality/core)，
                    未传则从 --config 路径前缀推断
  --alias <aliases> 角色别名，逗号分隔
  --window <name>   加入的窗口名（默认自动选择）
  --task <task>     加入后立即派发的任务（可选）
  --cli-wait <sec>  CLI 启动等待时间（默认: 3）

示例:
  swarm-join.sh security --cli "claude chat" --config quality/security.md
  swarm-join.sh database --cli "claude chat" --config core/database.md --alias "db"
  swarm-join.sh database --cli "claude chat" --config core/database.md --task "请设计 users 表"
EOF
            exit 0
            ;;
        -*)
            die "未知选项: $1"
            ;;
        *)
            if [[ -z "$ROLE" ]]; then
                ROLE="$1"
            else
                die "多余参数: $1"
            fi
            shift
            ;;
    esac
done

# 参数检查
[[ -n "$ROLE" ]]     || die "请指定角色名称"
[[ -n "$CLI_CMD" ]]  || die "请指定 CLI 命令 (--cli)"
[[ -n "$CONFIG_PATH" ]] || die "请指定配置文件 (--config)"

# =============================================================================
# 前置检查
# =============================================================================

log_info "准备加入蜂群: 角色=$ROLE, CLI=$CLI_CMD"

command -v tmux &>/dev/null || die "需要安装 tmux"
command -v jq &>/dev/null   || die "需要安装 jq"

# session 必须存在
tmux has-session -t "$SESSION_NAME" 2>/dev/null \
    || die "Session '$SESSION_NAME' 不存在，请先启动蜂群 (swarm-start.sh)"

# state.json 必须存在
[[ -f "$STATE_FILE" ]] || die "state.json 不存在: $STATE_FILE"

# max_cli 限制检查
MAX_CLI=$(jq -r '.max_cli // 0' "$STATE_FILE" 2>/dev/null)
if [[ "$MAX_CLI" -gt 0 ]]; then
    CURRENT_CLI_COUNT=$(jq '.panes | length' "$STATE_FILE" 2>/dev/null)
    if [[ "$CURRENT_CLI_COUNT" -ge "$MAX_CLI" ]]; then
        # 自动通知 human：CLI 预算不足
        mkdir -p "$MESSAGES_DIR/inbox/human"
        NOTIFY_ID="sys-maxcli-$(date +%s)"
        jq -n \
            --arg id "$NOTIFY_ID" \
            --arg content "CLI 数量已达上限 ($CURRENT_CLI_COUNT/$MAX_CLI)，无法加入角色 $ROLE。如需扩容，请执行: swarm-msg.sh set-limit <新上限>" \
            --arg timestamp "$(get_timestamp)" \
            '{id: $id, from: "system", to: "human", content: $content, timestamp: $timestamp, status: "pending", reply_to: null, priority: "high"}' \
            > "$MESSAGES_DIR/inbox/human/${NOTIFY_ID}.json" 2>/dev/null || true
        die "CLI 数量已达上限 ($CURRENT_CLI_COUNT/$MAX_CLI)。无法加入角色 $ROLE。已通知 human，请等待上限调整后重试"
    fi
    log_info "CLI 数量: $CURRENT_CLI_COUNT/$MAX_CLI"
fi

# Join 级互斥锁: 防止并发 join 生成重复实例名
# 保护范围: 实例名生成 → 资源创建 → state.json 写入
JOIN_LOCK_FILE="${RUNTIME_DIR}/.swarm-join.lock"
exec 201>"$JOIN_LOCK_FILE"
flock -x 201

# 生成实例名（首实例 instance==role，后续 role-2, role-3, ...）
INSTANCE=$(generate_instance_name "$ROLE" "$STATE_FILE")

# inspector 不允许多实例（supervisor 多实例通过 profile 或 swarm-join.sh 添加）
if [[ "$ROLE" == "inspector" ]] && [[ "$INSTANCE" != "$ROLE" ]]; then
    die "管理角色 'inspector' 不支持多实例"
fi

log_info "实例名: $INSTANCE (角色: $ROLE)"

# 配置文件检查
CONFIG_FILE="$CONFIG_DIR/roles/$CONFIG_PATH"
[[ -f "$CONFIG_FILE" ]] || die "配置文件不存在: $CONFIG_FILE"

# =============================================================================
# 选择或创建窗口 + pane
# =============================================================================

PANES_PER_WINDOW=$(jq -r '.panes_per_window // 2' "$STATE_FILE")
LAYOUT=$(jq -r '.layout // "even-horizontal"' "$STATE_FILE")

if [[ -n "$TARGET_WINDOW" ]]; then
    # 用户指定了窗口名
    WINDOW_IDX=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index} #{window_name}' \
        | grep " ${TARGET_WINDOW}$" | head -1 | awk '{print $1}')
    if [[ -z "$WINDOW_IDX" ]]; then
        # 指定窗口不存在，创建新窗口
        log_info "窗口 '$TARGET_WINDOW' 不存在，创建新窗口..."
        tmux new-window -t "$SESSION_NAME" -n "$TARGET_WINDOW"
        WINDOW_IDX=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index} #{window_name}' \
            | grep " ${TARGET_WINDOW}$" | head -1 | awk '{print $1}')
        PANE_TARGET="${WINDOW_IDX}.0"
    else
        # 在现有窗口中分割新 pane
        CURRENT_PANES=$(tmux list-panes -t "$SESSION_NAME:$WINDOW_IDX" 2>/dev/null | wc -l | tr -d ' ')
        if [[ $CURRENT_PANES -ge $PANES_PER_WINDOW ]]; then
            log_info "窗口 '$TARGET_WINDOW' 已满 ($CURRENT_PANES/$PANES_PER_WINDOW)，创建新窗口..."
            tmux new-window -t "$SESSION_NAME" -n "${TARGET_WINDOW}-ext"
            WINDOW_IDX=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' | tail -1)
            PANE_TARGET="${WINDOW_IDX}.0"
        else
            tmux split-window -t "$SESSION_NAME:$WINDOW_IDX" -h
            tmux select-layout -t "$SESSION_NAME:$WINDOW_IDX" "$LAYOUT" 2>/dev/null || true
            PANE_IDX=$(tmux list-panes -t "$SESSION_NAME:$WINDOW_IDX" -F '#{pane_index}' | tail -1)
            PANE_TARGET="${WINDOW_IDX}.${PANE_IDX}"
        fi
    fi
else
    # 自动选择：找最后一个有空位的窗口，或新建
    PLACED=false
    for win_info in $(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}'); do
        CURRENT_PANES=$(tmux list-panes -t "$SESSION_NAME:$win_info" 2>/dev/null | wc -l | tr -d ' ')
        if [[ $CURRENT_PANES -lt $PANES_PER_WINDOW ]]; then
            WINDOW_IDX="$win_info"
            tmux split-window -t "$SESSION_NAME:$WINDOW_IDX" -h
            tmux select-layout -t "$SESSION_NAME:$WINDOW_IDX" "$LAYOUT" 2>/dev/null || true
            PANE_IDX=$(tmux list-panes -t "$SESSION_NAME:$WINDOW_IDX" -F '#{pane_index}' | tail -1)
            PANE_TARGET="${WINDOW_IDX}.${PANE_IDX}"
            PLACED=true
            break
        fi
    done

    if [[ "$PLACED" == false ]]; then
        # 所有窗口都满了，新建窗口
        log_info "所有窗口已满，创建新窗口..."
        tmux new-window -t "$SESSION_NAME" -n "ext-${INSTANCE}"
        WINDOW_IDX=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' | tail -1)
        PANE_TARGET="${WINDOW_IDX}.0"
    fi
fi

log_success "Pane 已创建: $SESSION_NAME:$PANE_TARGET"

# =============================================================================
# 启动 CLI
# =============================================================================

log_info "启动 CLI: $CLI_CMD"

# 从 state.json 读取项目目录和 worktree 目录
PROJECT_DIR=$(jq -r '.project // ""' "$STATE_FILE" 2>/dev/null)
[[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]] || die "state.json 中未找到有效的项目目录"
load_project_config  # 加载项目级配置覆盖
WORKTREE_DIR=$(jq -r '.worktree_dir // ""' "$STATE_FILE" 2>/dev/null)
[[ -n "$WORKTREE_DIR" ]] || WORKTREE_DIR="$PROJECT_DIR/.swarm-worktrees"

# 创建角色的 git worktree（独立工作目录 + 独立分支）
ROLE_BRANCH="swarm/$INSTANCE"
ROLE_WORKTREE="$WORKTREE_DIR/$INSTANCE"
mkdir -p "$WORKTREE_DIR"
if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$ROLE_BRANCH" 2>/dev/null; then
    git -C "$PROJECT_DIR" worktree add "$ROLE_WORKTREE" "$ROLE_BRANCH"
else
    git -C "$PROJECT_DIR" worktree add "$ROLE_WORKTREE" -b "$ROLE_BRANCH"
fi
log_info "Worktree: $ROLE_WORKTREE (branch: $ROLE_BRANCH)"

# category 缺失时从 config 路径兜底推断
if [[ -z "$CATEGORY" ]]; then
    CATEGORY=$(infer_category_from_config "$CONFIG_PATH")
fi
log_info "Category: $CATEGORY"

# 在角色的 worktree 目录启动 CLI（权限层根据 category 拼接 allowedTools/disallowedTools）
# Codex+management 组合默认被阻断，必要时 export SWARM_ALLOW_CODEX_MGMT=1 后重试
# swarm-join 没有 profile JSON 上下文，权限完全来自 config/permission-defaults.json
if ! launch_cli_in_pane "$PANE_TARGET" "$ROLE" "$INSTANCE" "$ROLE_WORKTREE" "$CLI_CMD" "$CATEGORY" ""; then
    die "启动失败: role=$ROLE category=$CATEGORY cli=$CLI_CMD"
fi

sleep "$CLI_STARTUP_WAIT"

# =============================================================================
# 初始化消息目录
# =============================================================================

mkdir -p "$MESSAGES_DIR/inbox/$INSTANCE" "$MESSAGES_DIR/outbox/$INSTANCE"

# =============================================================================
# 发送初始化消息
# =============================================================================

log_info "发送初始化消息..."

# 构建当前团队成员信息（从 state.json 读取现有角色）
TEAM_INFO=""
while IFS='|' read -r r_instance r_role r_alias; do
    TEAM_INFO+="  - $r_instance"
    [[ "$r_instance" != "$r_role" ]] && TEAM_INFO+=" (角色: $r_role)"
    [[ -n "$r_alias" && "$r_alias" != "" ]] && TEAM_INFO+=" ($r_alias)"
    TEAM_INFO+=$'\n'
done < <(jq -r '.panes[] | "\(.instance // .role)|\(.role)|\(.alias // "")"' "$STATE_FILE")

# 使用共享函数构建并发送初始化消息
INIT_MSG=$(build_init_message "$CONFIG_FILE" "$ROLE_BRANCH" "$TEAM_INFO")
send_init_to_pane "$PANE_TARGET" "$INIT_MSG" "$CLI_CMD"

# =============================================================================
# 启用日志 + Watcher
# =============================================================================

LOG_FILE="$LOGS_DIR/${INSTANCE}.log"
tmux pipe-pane -t "$SESSION_NAME:$PANE_TARGET" -o "$(_pipe_pane_cmd "$LOG_FILE")"

WATCHER_PID=$(start_pane_watcher "$INSTANCE" "$LOG_FILE" "$PANE_TARGET" "$ROLE_WORKTREE")
log_info "Watcher PID: $WATCHER_PID"

# =============================================================================
# 更新 state.json（原子操作）
# =============================================================================

log_info "更新 state.json..."

# 读取 launch_cli_in_pane 写入的权限快照
PERMS_SNAPSHOT="{}"
if [[ -f "$RUNTIME_DIR/perms/${INSTANCE}.json" ]]; then
    PERMS_SNAPSHOT=$(cat "$RUNTIME_DIR/perms/${INSTANCE}.json")
fi

NEW_PANE_JSON=$(jq -n \
    --arg role "$ROLE" \
    --arg instance "$INSTANCE" \
    --arg pane "$PANE_TARGET" \
    --arg cli "$CLI_CMD" \
    --arg config "$CONFIG_PATH" \
    --arg alias "$ALIAS" \
    --arg log "$LOG_FILE" \
    --argjson watcher_pid "$WATCHER_PID" \
    --arg worktree "$ROLE_WORKTREE" \
    --arg branch "$ROLE_BRANCH" \
    --arg category "$CATEGORY" \
    --argjson permissions "$PERMS_SNAPSHOT" \
    '{
        role: $role,
        instance: $instance,
        pane: $pane,
        cli: $cli,
        config: $config,
        alias: $alias,
        log: $log,
        watcher_pid: $watcher_pid,
        worktree: $worktree,
        branch: $branch,
        category: $category,
        permissions: $permissions
    }')

# 原子更新（flock 加锁，避免并发 join/leave 竞态）
state_json_update \
    '.panes += [$new_pane] | .window_count = (((.panes | length) + 1) / 2 | ceil)' \
    --argjson new_pane "$NEW_PANE_JSON"

log_success "state.json 已更新"

# 释放 join 互斥锁（实例名已写入 state.json，后续操作无需互斥）
flock -u 201

# 刷新所有角色的持久上下文（团队成员变化了）
log_info "刷新持久上下文..."
refresh_all_contexts "$STATE_FILE"

# =============================================================================
# 广播通知现有角色
# =============================================================================

log_info "通知现有角色..."

# 使用共享双通道通知函数
notify_all_roles "join" \
    "新实例 $INSTANCE (角色: $ROLE) 已加入蜂群 (CLI: $CLI_CMD, 配置: $CONFIG_PATH)。你现在可以用 swarm-msg.sh send $INSTANCE \"消息\" 与该实例沟通。执行 swarm-msg.sh list-roles 查看完整团队。" \
    "[Swarm 系统通知] 新实例 $INSTANCE (角色: $ROLE) 已加入蜂群。执行 swarm-msg.sh list-roles 查看团队，swarm-msg.sh read 查看详情。" \
    "$INSTANCE"

# 发射事件（也供 swarm-msg.sh wait 感知）
emit_event "role.joined" "$INSTANCE" "cli=$CLI_CMD" "config=$CONFIG_PATH" "pane=$PANE_TARGET" "role=$ROLE"

# =============================================================================
# 完成
# =============================================================================

# =============================================================================
# 派发初始任务（可选）
# =============================================================================

if [[ -n "$INITIAL_TASK" ]]; then
    log_info "派发初始任务..."
    sleep 2  # 等待 CLI 处理完初始化消息

    TASK_TMP=$(mktemp "${RUNTIME_DIR}/.task-XXXXXX")
    printf '%s' "$INITIAL_TASK" > "$TASK_TMP"
    _pane_locked_paste_enter "$PANE_TARGET" "$TASK_TMP" "$CLI_CMD"
    rm -f "$TASK_TMP"

    log_success "初始任务已派发"
fi

log_success "实例 $INSTANCE (角色: $ROLE) 已成功加入蜂群!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "实例:     $INSTANCE"
echo "角色:     $ROLE"
echo "Pane:     $SESSION_NAME:$PANE_TARGET"
echo "CLI:      $CLI_CMD"
echo "配置:     $CONFIG_PATH"
echo "Worktree: $ROLE_WORKTREE"
echo "分支:     $ROLE_BRANCH"
[[ -n "$ALIAS" ]] && echo "别名:     $ALIAS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "操作:"
echo "  发送任务:  swarm-send.sh $INSTANCE '任务内容'"
echo "  发送消息:  swarm-msg.sh send $INSTANCE '消息内容'"
echo "  查看状态:  swarm-status.sh"
echo ""
