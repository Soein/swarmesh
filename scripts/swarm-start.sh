#!/usr/bin/env bash
# swarm-start.sh - 启动 AI Swarm 协作环境
# 创建 tmux session 并根据 profile 配置启动多个 AI CLI
#
# 用法: swarm-start.sh --project <项目路径> [--profile PROFILE] [--hidden] [--panes-per-window N]
#   --project: 蜂群要开发的目标项目目录（必需）
#   --profile: 指定配置文件 (默认: minimal)
#   --hidden:  后台运行,不自动 attach
#   --panes-per-window: 每窗口最大 pane 数 (默认: 2)

set -euo pipefail

# =============================================================================
# 配置参数 (可通过环境变量覆盖)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_ROOT="${SWARM_ROOT:-$(dirname "$SCRIPT_DIR")}"
CONFIG_DIR="${CONFIG_DIR:-$SWARM_ROOT/config}"
RUNTIME_DIR="${RUNTIME_DIR:-$SWARM_ROOT/runtime}"
LOGS_DIR="${LOGS_DIR:-$RUNTIME_DIR/logs}"
TASKS_DIR="${TASKS_DIR:-$RUNTIME_DIR/tasks}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$SWARM_ROOT/scripts}"
SESSION_NAME="${SWARM_SESSION:-swarm}"
LAYOUT="${LAYOUT:-even-horizontal}"
DEFAULT_PROFILE="${DEFAULT_PROFILE:-minimal}"
PROFILES_DIR="${PROFILES_DIR:-$CONFIG_DIR/profiles}"
STATE_FILE="${STATE_FILE:-$RUNTIME_DIR/state.json}"

# PANES_PER_WINDOW 由 config/defaults.conf 统一定义

# CLI 启动等待时间（秒）
CLI_STARTUP_WAIT="${CLI_STARTUP_WAIT:-3}"

# 加载共享事件库
source "${SCRIPT_DIR}/swarm-lib.sh"

# =============================================================================
# 参数解析
# =============================================================================

PROFILE="$DEFAULT_PROFILE"
HIDDEN=false
PROJECT_DIR=""
MAX_CLI=0  # 0=不限制

while [[ $# -gt 0 ]]; do
    case $1 in
        --project)           PROJECT_DIR="$2"; shift 2 ;;
        --profile)           PROFILE="$2"; shift 2 ;;
        --hidden)            HIDDEN=true; shift ;;
        --panes-per-window)  PANES_PER_WINDOW="$2"; shift 2 ;;
        --layout)            LAYOUT="$2"; shift 2 ;;
        --cli-wait)          CLI_STARTUP_WAIT="$2"; shift 2 ;;
        --max-cli)           MAX_CLI="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
用法: $(basename "$0") --project <项目路径> [选项]

必需参数:
  --project PATH             蜂群要开发的目标项目目录

选项:
  --profile PROFILE          指定配置文件 (默认: minimal)
  --hidden                   后台运行,不自动 attach
  --panes-per-window N       每窗口最大 pane 数 (默认: 2)
  --layout LAYOUT            布局模式 (默认: even-horizontal)
  --cli-wait SECONDS         CLI 启动等待时间 (默认: 3)
  --max-cli N                CLI 数量上限，supervisor 在此范围内自主扩容 (0=不限制，默认: 0)
  -h, --help                 显示此帮助信息

布局选项: even-horizontal, even-vertical, tiled, main-horizontal, main-vertical

环境变量:
  SWARM_ROOT        Swarm 根目录 (默认: 脚本所在目录的父目录)
  SESSION_NAME      Tmux session 名称 (默认: swarm)

示例:
  $(basename "$0") --project ~/my-app                              # 最小配置（supervisor 自动注入）
  $(basename "$0") --project ~/my-app --profile web-dev            # Web 开发团队
  $(basename "$0") --project ~/my-app --max-cli 20                 # supervisor 自主组建团队，上限 20
  $(basename "$0") --project ~/my-app --profile web-dev --hidden   # 后台启动
EOF
            exit 0
            ;;
        *)
            die "未知参数: $1 (使用 --help 查看帮助)"
            ;;
    esac
done

# 项目目录必需
[[ -n "$PROJECT_DIR" ]] || die "请指定项目目录 (--project <路径>)"
# 转为绝对路径
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || die "项目目录不存在: $PROJECT_DIR"
load_project_config  # 加载项目级配置覆盖

# =============================================================================
# 前置检查
# =============================================================================

log_info "开始启动 AI Swarm..."
log_info "项目目录: $PROJECT_DIR"
log_info "Profile: $PROFILE"
log_info "Session: $SESSION_NAME"
log_info "每窗口 pane 数: $PANES_PER_WINDOW"

check_command tmux
check_command jq
check_command git

PROFILE_FILE="$PROFILES_DIR/$PROFILE.json"
[[ -f "$PROFILE_FILE" ]] || die "Profile 文件不存在: $PROFILE_FILE"

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    die "Session '$SESSION_NAME' 已存在,请先停止 (tmux kill-session -t $SESSION_NAME)"
fi

# 项目目录必须是 git 仓库（worktree 需要）
git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null \
    || die "项目目录不是 git 仓库: $PROJECT_DIR (请先 git init)"

# Worktree 目录
WORKTREE_DIR="$PROJECT_DIR/.swarm-worktrees"

# =============================================================================
# 初始化运行时环境
# =============================================================================

log_info "初始化运行时环境..."

mkdir -p "$RUNTIME_DIR" "$LOGS_DIR" "$TASKS_DIR"/{pending,processing,completed,failed,blocked,groups} \
    "$RUNTIME_DIR/stories" "$RUNTIME_DIR/gate-logs"

# 初始化消息目录
MESSAGES_DIR="$RUNTIME_DIR/messages"
mkdir -p "$MESSAGES_DIR/inbox" "$MESSAGES_DIR/outbox"

# 创建 human 收件箱（主控 Claude Code 通过此收件箱接收蜂群汇报）
mkdir -p "$MESSAGES_DIR/inbox/human" "$MESSAGES_DIR/outbox/human"

# 清理旧 worktree（如果有残留）
if [[ -d "$WORKTREE_DIR" ]]; then
    log_info "清理旧 worktree..."
    for wt in "$WORKTREE_DIR"/*/; do
        [[ -d "$wt" ]] && git -C "$PROJECT_DIR" worktree remove --force "$wt" 2>/dev/null || true
    done
    rm -rf "$WORKTREE_DIR"
fi

# 确保 .swarm-worktrees 在 .gitignore 中
if ! grep -q '\.swarm-worktrees' "$PROJECT_DIR/.gitignore" 2>/dev/null; then
    echo '.swarm-worktrees/' >> "$PROJECT_DIR/.gitignore"
    log_info ".swarm-worktrees/ 已添加到 .gitignore"
fi

# 清理旧日志
rm -f "$LOGS_DIR"/*.log

# 初始化事件日志
> "$EVENTS_LOG"

log_success "运行时环境初始化完成"

# =============================================================================
# 扫描项目结构
# =============================================================================

PROJECT_INFO_FILE="$RUNTIME_DIR/project-info.json"
if [[ -x "$SCRIPTS_DIR/swarm-scan.sh" ]]; then
    log_info "扫描项目技术栈..."
    "$SCRIPTS_DIR/swarm-scan.sh" "$PROJECT_DIR" "$PROJECT_INFO_FILE" 2>&1 | while IFS= read -r line; do
        log_info "  $line"
    done

    if [[ -f "$PROJECT_INFO_FILE" ]]; then
        key_file_count=$(jq '.key_files | length' "$PROJECT_INFO_FILE" 2>/dev/null || echo 0)
        log_info "收集到 $key_file_count 个关键配置文件，LLM 角色将自行分析技术栈"
    fi
else
    log_warn "swarm-scan.sh 不可用，跳过项目扫描"
fi

# =============================================================================
# 读取和解析 Profile 配置
# =============================================================================

log_info "读取 profile 配置: $PROFILE_FILE"

PROFILE_JSON=$(cat "$PROFILE_FILE")
DESCRIPTION=$(echo "$PROFILE_JSON" | jq -r '.description // "N/A"')
log_info "描述: $DESCRIPTION"

ROLES_JSON=$(echo "$PROFILE_JSON" | jq -c '.roles // []')

# 自动注入 supervisor（编排者）——蜂群的大脑，必须存在
HAS_SUPERVISOR=$(echo "$ROLES_JSON" | jq '[.[] | select(.name == "supervisor")] | length')
if [[ "$HAS_SUPERVISOR" -eq 0 ]]; then
    log_info "自动注入 supervisor 角色（编排者）"
    SUPERVISOR_ENTRY='{"name":"supervisor","cli":"claude chat","config":"management/supervisor.md","alias":"sup,supervisor","title":"编排者","description":"蜂群编排者，负责任务拆解、角色调度和进度监控"}'
    ROLES_JSON=$(echo "$ROLES_JSON" | jq --argjson sup "$SUPERVISOR_ENTRY" '. + [$sup]')
fi

# 自动注入 inspector（督查员）——质量门守护者，必须存在
HAS_INSPECTOR=$(echo "$ROLES_JSON" | jq '[.[] | select(.name == "inspector")] | length')
if [[ "$HAS_INSPECTOR" -eq 0 ]]; then
    log_info "自动注入 inspector 角色（督查员）"
    INSPECTOR_ENTRY='{"name":"inspector","cli":"claude chat","config":"management/inspector.md","alias":"insp,inspector","title":"督查员","description":"督查员，负责质量门配置、任务验收和产出质量把关"}'
    ROLES_JSON=$(echo "$ROLES_JSON" | jq --argjson insp "$INSPECTOR_ENTRY" '. + [$insp]')
fi

ROLES_COUNT=$(echo "$ROLES_JSON" | jq 'length')

[[ $ROLES_COUNT -eq 0 ]] && die "Profile 中没有定义角色"
log_info "角色数量: $ROLES_COUNT"

# 计算窗口分配
WINDOW_COUNT=$(( (ROLES_COUNT + PANES_PER_WINDOW - 1) / PANES_PER_WINDOW ))
log_info "窗口数量: $WINDOW_COUNT (每窗口最多 $PANES_PER_WINDOW 个 pane)"

# 窗口命名策略
declare -a WINDOW_NAMES
if [[ $WINDOW_COUNT -le 3 ]]; then
    WINDOW_NAMES=("core-dev" "quality" "management")
else
    for ((w=0; w<WINDOW_COUNT; w++)); do
        WINDOW_NAMES+=("team-$((w+1))")
    done
fi

# =============================================================================
# 创建 Tmux Session 和多窗口
# =============================================================================

log_info "创建 tmux session: $SESSION_NAME"

# 创建 session（第一个窗口自动创建）
tmux new-session -d -s "$SESSION_NAME" -n "${WINDOW_NAMES[0]}"

# 创建额外的窗口
for ((w=1; w<WINDOW_COUNT; w++)); do
    tmux new-window -t "$SESSION_NAME" -n "${WINDOW_NAMES[$w]}"
done

log_success "Session 创建完成 ($WINDOW_COUNT 个窗口)"

# =============================================================================
# 在各窗口中创建 Panes 并启动 CLI
# =============================================================================

log_info "创建 panes 并启动 AI CLI..."

declare -a PANE_MAPPINGS=()

# 预提取所有角色信息到数组（单次 jq 调用代替循环内 N*7 次 jq）
declare -a ALL_NAMES ALL_CLIS ALL_CONFIGS ALL_ALIASES ALL_DESCS
while IFS=$'\t' read -r _name _cli _config _alias _desc; do
    ALL_NAMES+=("$_name")
    ALL_CLIS+=("$_cli")
    ALL_CONFIGS+=("$_config")
    ALL_ALIASES+=("$_alias")
    ALL_DESCS+=("$_desc")
done < <(echo "$ROLES_JSON" | jq -r '.[] | [.name, .cli, .config, (.alias // ""), (.description // "")] | @tsv')

for ((i=0; i<ROLES_COUNT; i++)); do
    # 计算窗口和 pane 位置
    WINDOW_IDX=$((i / PANES_PER_WINDOW))
    PANE_IN_WINDOW=$((i % PANES_PER_WINDOW))

    # 从预提取数组读取角色信息（零 jq 调用）
    ROLE="${ALL_NAMES[$i]}"
    CLI="${ALL_CLIS[$i]}"
    CONFIG="${ALL_CONFIGS[$i]}"
    ALIAS="${ALL_ALIASES[$i]}"

    log_info "  [$i] $ROLE → $CLI (window: $WINDOW_IDX, pane: $PANE_IN_WINDOW)"

    if [[ $PANE_IN_WINDOW -eq 0 ]]; then
        # 第一个 pane 已在窗口创建时存在
        PANE_TARGET="$WINDOW_IDX.0"
    else
        # 分割创建新 pane
        tmux split-window -t "$SESSION_NAME:$WINDOW_IDX" -h
        # 重新应用布局以均匀分配空间
        tmux select-layout -t "$SESSION_NAME:$WINDOW_IDX" "$LAYOUT" 2>/dev/null || true
        PANE_TARGET="$WINDOW_IDX.$PANE_IN_WINDOW"
    fi

    # 创建角色的 git worktree（独立工作目录 + 独立分支）
    ROLE_BRANCH="swarm/$ROLE"
    ROLE_WORKTREE="$WORKTREE_DIR/$ROLE"
    mkdir -p "$WORKTREE_DIR"
    if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$ROLE_BRANCH" 2>/dev/null; then
        # 分支已存在（上次残留），复用
        git -C "$PROJECT_DIR" worktree add "$ROLE_WORKTREE" "$ROLE_BRANCH"
    else
        # 创建新分支（基于当前 HEAD）
        git -C "$PROJECT_DIR" worktree add "$ROLE_WORKTREE" -b "$ROLE_BRANCH"
    fi
    log_info "      Worktree: $ROLE_WORKTREE (branch: $ROLE_BRANCH)"

    # 在角色的 worktree 目录启动 CLI
    tmux send-keys -t "$SESSION_NAME:$PANE_TARGET" "cd \"$ROLE_WORKTREE\" && export SWARM_ROLE=\"$ROLE\" && $CLI" C-m

    # 等待 CLI 启动
    sleep "$CLI_STARTUP_WAIT"
    sleep 0.5

    # 创建角色的收件箱/发件箱目录
    mkdir -p "$MESSAGES_DIR/inbox/$ROLE" "$MESSAGES_DIR/outbox/$ROLE"

    # 发送增强初始化消息（使用 paste-buffer 避免 TUI 输入问题）
    CONFIG_FILE="$CONFIG_DIR/roles/$CONFIG"
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "      发送配置: $CONFIG"

        # 构建团队成员信息（从预提取数组读取，零 jq 调用）
        TEAM_INFO=""
        for ((j=0; j<ROLES_COUNT; j++)); do
            [[ $j -eq $i ]] && continue  # 跳过自己
            TEAM_INFO+="  - ${ALL_NAMES[$j]}"
            [[ -n "${ALL_ALIASES[$j]}" ]] && TEAM_INFO+=" (${ALL_ALIASES[$j]})"
            [[ -n "${ALL_DESCS[$j]}" ]] && TEAM_INFO+=": ${ALL_DESCS[$j]}"
            TEAM_INFO+=$'\n'
        done

        # 使用共享函数构建初始化消息（与 swarm-join.sh 统一）
        INIT_MSG=$(build_init_message "$CONFIG_FILE" "$ROLE_BRANCH" "$TEAM_INFO")

        INIT_TMP=$(mktemp "${RUNTIME_DIR}/.init-XXXXXX")
        printf '%s' "$INIT_MSG" > "$INIT_TMP"
        tmux load-buffer "$INIT_TMP"
        tmux paste-buffer -t "$SESSION_NAME:$PANE_TARGET"
        sleep 0.3
        tmux send-keys -t "$SESSION_NAME:$PANE_TARGET" Enter
        rm -f "$INIT_TMP"
        sleep 1
    fi

    # 启用日志记录
    LOG_FILE="$LOGS_DIR/${ROLE}.log"
    tmux pipe-pane -t "$SESSION_NAME:$PANE_TARGET" -o "$(_pipe_pane_cmd "$LOG_FILE")"

    # 启动 pane watcher 守护进程（事件驱动完成检测）
    WATCHER_PID=$(start_pane_watcher "$ROLE" "$LOG_FILE" "$PANE_TARGET" "$ROLE_WORKTREE")
    log_info "      Watcher PID: $WATCHER_PID"

    # 记录 pane 映射（含 watcher_pid）
    PANE_MAPPINGS+=("{\"role\":\"$ROLE\",\"pane\":\"$PANE_TARGET\",\"cli\":\"$CLI\",\"config\":\"$CONFIG\",\"alias\":\"$ALIAS\",\"log\":\"$LOG_FILE\",\"watcher_pid\":$WATCHER_PID,\"worktree\":\"$ROLE_WORKTREE\",\"branch\":\"$ROLE_BRANCH\"}")
done

# 最终应用布局到所有窗口
for ((w=0; w<WINDOW_COUNT; w++)); do
    tmux select-layout -t "$SESSION_NAME:$w" "$LAYOUT" 2>/dev/null || true
done

# 选中第一个窗口
tmux select-window -t "$SESSION_NAME:0"

log_success "所有 panes 创建完成"

# =============================================================================
# 启动任务看门狗
# =============================================================================

# 加载 watchdog 模块（需要 swarm-lib.sh 已加载）
source "${SCRIPT_DIR}/lib/msg-task-watchdog.sh"

WATCHDOG_PID=$(start_task_watchdog)
log_info "任务看门狗 PID: $WATCHDOG_PID"

# =============================================================================
# 保存运行状态
# =============================================================================

log_info "保存运行状态到 $STATE_FILE"

PANES_JSON=$(printf '%s\n' "${PANE_MAPPINGS[@]}" | jq -s '.')

STATE_JSON=$(jq -n \
    --arg session "$SESSION_NAME" \
    --arg profile "$PROFILE" \
    --arg project "$PROJECT_DIR" \
    --arg worktree_dir "$WORKTREE_DIR" \
    --arg started_at "$(get_timestamp)" \
    --arg layout "$LAYOUT" \
    --argjson panes_per_window "$PANES_PER_WINDOW" \
    --argjson window_count "$WINDOW_COUNT" \
    --argjson max_cli "$MAX_CLI" \
    --argjson watchdog_pid "$WATCHDOG_PID" \
    --argjson panes "$PANES_JSON" \
    '{
        session: $session,
        profile: $profile,
        project: $project,
        worktree_dir: $worktree_dir,
        started_at: $started_at,
        layout: $layout,
        panes_per_window: $panes_per_window,
        window_count: $window_count,
        max_cli: $max_cli,
        watchdog_pid: $watchdog_pid,
        panes: $panes
    }')

echo "$STATE_JSON" | jq '.' > "$STATE_FILE"

log_success "状态保存完成"

# 生成所有角色的持久上下文文件（CLAUDE.md / AGENTS.md 等）
log_info "生成角色持久上下文..."
refresh_all_contexts "$STATE_FILE"
log_success "持久上下文生成完成"

# =============================================================================
# 完成
# =============================================================================

log_success "AI Swarm 启动完成!"

# 发射启动事件
emit_event "system.started" "" "profile=$PROFILE" "session=$SESSION_NAME" "roles=$ROLES_COUNT"
echo ""
echo "Session 信息:"
echo "  名称: $SESSION_NAME"
echo "  项目: $PROJECT_DIR"
echo "  Worktrees: $WORKTREE_DIR"
echo "  Profile: $PROFILE"
echo "  窗口: $WINDOW_COUNT 个"
echo "  角色: $ROLES_COUNT 个"
echo "  布局: $LAYOUT"
echo ""
echo "角色分支:"
for ((i=0; i<ROLES_COUNT; i++)); do
    rname=$(echo "$ROLES_JSON" | jq -r ".[$i].name")
    echo "  $rname → swarm/$rname"
done
echo ""
echo "窗口导航:"
for ((w=0; w<WINDOW_COUNT; w++)); do
    local_start=$((w * PANES_PER_WINDOW))
    local_end=$((local_start + PANES_PER_WINDOW - 1))
    [[ $local_end -ge $ROLES_COUNT ]] && local_end=$((ROLES_COUNT - 1))
    roles_in_window=""
    for ((r=local_start; r<=local_end; r++)); do
        rname=$(echo "$ROLES_JSON" | jq -r ".[$r].name")
        roles_in_window+="$rname "
    done
    echo "  Ctrl-b $w → ${WINDOW_NAMES[$w]}: $roles_in_window"
done
echo ""
echo "常用命令:"
echo "  查看 session:  tmux attach -t $SESSION_NAME"
echo "  派发任务:      swarm-send.sh <role> '<task>'"
echo "  查看状态:      swarm-status.sh"
echo "  停止 swarm:    swarm-stop.sh"
echo ""

# 如果不是 hidden 模式,自动 attach
if [[ "$HIDDEN" == false ]]; then
    log_info "Attaching to session..."
    tmux attach -t "$SESSION_NAME"
fi
