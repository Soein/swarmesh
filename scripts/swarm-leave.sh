#!/usr/bin/env bash
################################################################################
# swarm-leave.sh - 从运行中的蜂群移除角色
#
# 关闭指定角色的 CLI pane，更新 state.json，通知其他角色。
#
# 用法:
#   swarm-leave.sh <role> [选项]
#
# 选项:
#   --force    不确认直接移除
#   --reason   移除原因（会通知其他角色）
#
# 示例:
#   swarm-leave.sh database
#   swarm-leave.sh database --reason "数据库设计已完成"
#   swarm-leave.sh database --force
################################################################################

set -euo pipefail

# =============================================================================
# 配置
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_ROOT="${SWARM_ROOT:-$(dirname "$SCRIPT_DIR")}"
RUNTIME_DIR="${RUNTIME_DIR:-$SWARM_ROOT/runtime}"
MESSAGES_DIR="${MESSAGES_DIR:-$RUNTIME_DIR/messages}"
LOGS_DIR="${LOGS_DIR:-$RUNTIME_DIR/logs}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$SWARM_ROOT/scripts}"
STATE_FILE="${STATE_FILE:-$RUNTIME_DIR/state.json}"
SESSION_NAME="${SWARM_SESSION:-swarm}"

source "${SCRIPT_DIR}/swarm-lib.sh"

# =============================================================================
# 工具函数
# =============================================================================

log_info()    { echo "[INFO] $*" >&2; }
log_success() { echo "[SUCCESS] $*" >&2; }
die()         { echo "[ERROR] $*" >&2; exit 1; }

get_timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

# =============================================================================
# 参数解析
# =============================================================================

ROLE=""
FORCE=false
REASON=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)  FORCE=true; shift ;;
        --reason) REASON="$2"; shift 2 ;;
        -h|--help)
            cat <<'EOF'
swarm-leave.sh - 从蜂群移除角色

用法:
  swarm-leave.sh <role> [选项]

选项:
  --force          不确认直接移除
  --reason <text>  移除原因（通知其他角色）

示例:
  swarm-leave.sh database
  swarm-leave.sh database --reason "数据库设计已完成"
  swarm-leave.sh database --force
EOF
            exit 0
            ;;
        -*)  die "未知选项: $1" ;;
        *)
            [[ -z "$ROLE" ]] && ROLE="$1" || die "多余参数: $1"
            shift
            ;;
    esac
done

[[ -n "$ROLE" ]] || die "请指定要移除的角色名"

# =============================================================================
# 前置检查
# =============================================================================

command -v tmux &>/dev/null || die "需要安装 tmux"
command -v jq &>/dev/null   || die "需要安装 jq"

[[ -f "$STATE_FILE" ]] || die "state.json 不存在"
tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "Session '$SESSION_NAME' 不存在"

# 查找角色信息
ROLE_INFO=$(jq -r --arg role "$ROLE" '
    .panes[] | select(.role == $role or (.alias // "" | split(",") | map(gsub("^\\s+|\\s+$"; "")) | index($role) != null))
' "$STATE_FILE" 2>/dev/null)

[[ -n "$ROLE_INFO" ]] || die "找不到角色: $ROLE"

ROLE_NAME=$(echo "$ROLE_INFO" | jq -r '.role')
PANE_TARGET=$(echo "$ROLE_INFO" | jq -r '.pane')
CLI_CMD=$(echo "$ROLE_INFO" | jq -r '.cli')
WATCHER_PID=$(echo "$ROLE_INFO" | jq -r '.watcher_pid // 0')
ROLE_WORKTREE=$(echo "$ROLE_INFO" | jq -r '.worktree // ""')
ROLE_BRANCH=$(echo "$ROLE_INFO" | jq -r '.branch // ""')

# 从 state.json 读取项目目录
PROJECT_DIR=$(jq -r '.project // ""' "$STATE_FILE" 2>/dev/null)

# =============================================================================
# 确认
# =============================================================================

if [[ "$FORCE" == false ]]; then
    echo ""
    echo "即将移除角色: $ROLE_NAME"
    echo "  Pane: $SESSION_NAME:$PANE_TARGET"
    echo "  CLI:  $CLI_CMD"
    [[ -n "$REASON" ]] && echo "  原因: $REASON"
    echo ""
    read -rp "确认移除？[y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) ;;
        *) echo "已取消"; exit 0 ;;
    esac
fi

# =============================================================================
# 执行移除
# =============================================================================

log_info "移除角色: $ROLE_NAME..."

# 1. 停止 watcher 进程
if [[ "$WATCHER_PID" != "0" ]] && kill -0 "$WATCHER_PID" 2>/dev/null; then
    kill "$WATCHER_PID" 2>/dev/null || true
    log_info "Watcher 进程已停止 (PID: $WATCHER_PID)"
fi

# 2. 关闭 pane
if tmux list-panes -t "$SESSION_NAME:${PANE_TARGET%%.*}" 2>/dev/null | wc -l | tr -d ' ' | grep -q '^1$'; then
    # 窗口只剩这一个 pane，关闭整个窗口
    tmux kill-window -t "$SESSION_NAME:${PANE_TARGET%%.*}" 2>/dev/null || true
    log_info "窗口 ${PANE_TARGET%%.*} 已关闭（最后一个 pane）"
else
    # 窗口有多个 pane，只关闭这一个
    tmux kill-pane -t "$SESSION_NAME:$PANE_TARGET" 2>/dev/null || true
    log_info "Pane $PANE_TARGET 已关闭"
fi

# 3. 移除 git worktree（保留分支供人类查看）
if [[ -n "$ROLE_WORKTREE" && -d "$ROLE_WORKTREE" && -n "$PROJECT_DIR" ]]; then
    git -C "$PROJECT_DIR" worktree remove --force "$ROLE_WORKTREE" 2>/dev/null || true
    log_info "Worktree 已移除: $ROLE_WORKTREE (分支 $ROLE_BRANCH 保留)"
fi

# 4. 更新 state.json（flock 加锁，避免并发竞态）
state_json_update \
    '.panes = [.panes[] | select(.role != $role)]' \
    --arg role "$ROLE_NAME"
log_info "state.json 已更新"

# 4. 刷新所有角色的持久上下文（团队成员变化了）
log_info "刷新持久上下文..."
refresh_all_contexts "$STATE_FILE"

# 5. 归档该角色的消息到 outbox
if [[ -d "$MESSAGES_DIR/inbox/$ROLE_NAME" ]]; then
    mkdir -p "$MESSAGES_DIR/outbox/$ROLE_NAME"
    for f in "$MESSAGES_DIR/inbox/$ROLE_NAME"/*.json; do
        [[ -f "$f" ]] && mv "$f" "$MESSAGES_DIR/outbox/$ROLE_NAME/"
    done
    rmdir "$MESSAGES_DIR/inbox/$ROLE_NAME" 2>/dev/null || true
    log_info "收件箱消息已归档"
fi

# 5. 通知其他角色（使用共享双通道通知函数）
notify_all_roles "leave" \
    "角色 $ROLE_NAME 已离开蜂群。${REASON:+原因: $REASON。}该角色的职责需要由其他成员承担，执行 swarm-msg.sh list-roles 查看当前团队。" \
    "[Swarm 系统通知] $ROLE_NAME 已离开蜂群。${REASON:+原因: $REASON。}执行 swarm-msg.sh list-roles 查看当前团队。"

# 6. 发射事件
emit_event "role.left" "$ROLE_NAME" "reason=${REASON:-manual}" "pane=$PANE_TARGET"

# =============================================================================
# 完成
# =============================================================================

log_success "角色 $ROLE_NAME 已移除!"
echo ""
echo "当前剩余角色:"
jq -r '.panes[] | "  - \(.role) -> pane \(.pane)"' "$STATE_FILE"
echo ""
