#!/usr/bin/env bash
# swarm-status.sh - 蜂群状态查看工具
# 用途: 显示蜂群的运行状态和各角色信息
# 依赖: bash 5.0+, tmux, jq

set -euo pipefail

#==========================================
# 配置部分
#==========================================

# 路径配置（统一由 swarm-lib.sh 管理）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/swarm-lib.sh"

# 颜色定义
COLOR_RESET='\033[0m'
COLOR_TITLE='\033[1;35m'     # 紫色粗体
COLOR_RUNNING='\033[1;32m'   # 绿色粗体
COLOR_STOPPED='\033[1;31m'   # 红色粗体
COLOR_ACTIVE='\033[0;32m'    # 绿色
COLOR_IDLE='\033[0;33m'      # 黄色
COLOR_ERROR='\033[0;31m'     # 红色
COLOR_LABEL='\033[0;36m'     # 青色
COLOR_VALUE='\033[0;37m'     # 白色
COLOR_SEPARATOR='\033[0;34m' # 蓝色

# 表情符号
EMOJI_RUNNING="🚀"
EMOJI_STOPPED="🛑"
EMOJI_ACTIVE="✨"
EMOJI_IDLE="💤"
EMOJI_ERROR="❌"
EMOJI_FRONTEND="🎨"
EMOJI_BACKEND="⚙️"
EMOJI_REVIEWER="🔍"
EMOJI_TASK="📋"

#==========================================
# 工具函数
#==========================================

# 打印错误信息
error() {
    echo -e "${COLOR_ERROR}错误: $*${COLOR_RESET}" >&2
}

# 打印信息
info() {
    echo -e "$*"
}

# 显示使用帮助
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

显示蜂群的运行状态和各角色信息。

选项:
    -w, --watch         持续监控状态 (每 2 秒刷新)
    -j, --json          以 JSON 格式输出
    -c, --no-color      禁用颜色输出
    -h, --help          显示此帮助信息

示例:
    $(basename "$0")                # 显示当前状态
    $(basename "$0") -w             # 持续监控状态
    $(basename "$0") -j             # JSON 格式输出

环境变量:
    SWARM_ROOT          蜂群主目录 (默认: 脚本所在目录的父目录)
    SWARM_SESSION       tmux session 名称 (默认: swarm)
EOF
    exit 0
}

# 检查依赖
check_dependencies() {
    local deps=(tmux jq)
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "缺少依赖: ${missing[*]}"
        error "请通过系统包管理器安装: ${missing[*]}"
        exit 1
    fi
}

# 检查 session 是否运行
check_session_status() {
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 获取运行时长
get_uptime() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "未知"
        return
    fi

    local started_at
    started_at=$(jq -r '.started_at // empty' "$STATE_FILE")

    if [[ -z "$started_at" ]]; then
        echo "未知"
        return
    fi

    local start_epoch current_time
    # macOS: date -j -f, Linux: date -d
    start_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$started_at" +%s 2>/dev/null \
        || date -d "$started_at" +%s 2>/dev/null \
        || echo "0")
    current_time=$(date +%s)

    if [[ "$start_epoch" == "0" ]]; then
        echo "未知"
        return
    fi

    local elapsed=$((current_time - start_epoch))

    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
}

# 获取角色表情符号
get_role_emoji() {
    local role_name="$1"

    case "$role_name" in
        *前端*|*frontend*|*Frontend*)
            echo "$EMOJI_FRONTEND"
            ;;
        *后端*|*backend*|*Backend*)
            echo "$EMOJI_BACKEND"
            ;;
        *审查*|*reviewer*|*Reviewer*)
            echo "$EMOJI_REVIEWER"
            ;;
        *)
            echo "👤"
            ;;
    esac
}

# 检查 pane 状态
check_pane_status() {
    local pane_target="$1"

    if ! tmux list-panes -t "${SESSION_NAME}:${pane_target}" &>/dev/null; then
        echo "error"
        return
    fi

    # 检查 pane 最近是否有活动
    # 通过读取最后几行内容判断
    local recent_output
    recent_output=$(tmux capture-pane -t "${SESSION_NAME}:${pane_target}" -p | tail -10)

    # 简单判断:如果有内容且最后一行不为空,认为是活跃
    if [[ -n "$recent_output" ]]; then
        local last_line
        last_line=$(echo "$recent_output" | tail -1 | tr -d '[:space:]')
        if [[ -n "$last_line" ]]; then
            echo "active"
        else
            echo "idle"
        fi
    else
        echo "idle"
    fi
}

# 统计任务数量（直接按子目录计数，任务文件存放在 pending/processing/completed 等子目录中）
count_tasks() {
    local status="$1"

    if [[ ! -d "$TASKS_DIR/$status" ]]; then
        echo 0
        return
    fi

    local count=0
    shopt -s nullglob
    for task_file in "$TASKS_DIR/$status/"*.json; do
        [[ -f "$task_file" ]] && ((count++)) || true
    done
    shopt -u nullglob

    echo "$count"
}

collect_task_rows() {
    local rows='[]'
    local status_dir
    for status_dir in pending processing blocked completed failed; do
        [[ -d "$TASKS_DIR/$status_dir" ]] || continue
        while IFS= read -r task_file; do
            [[ -f "$task_file" ]] || continue
            local task_json
            task_json=$(jq -c --arg status "$status_dir" \
                '{
                    id: .id,
                    title: .title,
                    status: $status,
                    phase: (.phase // ""),
                    owner: (.phase_owner // .assigned_to // ""),
                    blocked_reason: (.blocked_reason // ""),
                    resource_blocked_by: (.resource_blocked_by // ""),
                    resource_keys: (.resource_keys // []),
                    priority: (.priority // "normal")
                }' "$task_file" 2>/dev/null) || continue
            rows=$(jq -c --argjson task "$task_json" '. + [$task]' <<<"$rows")
        done < <(find "$TASKS_DIR/$status_dir" -maxdepth 1 -name '*.json' -type f | sort)
    done
    echo "$rows"
}

# 获取日志文件大小
get_log_size() {
    local role_name="$1"

    local log_file="${LOGS_DIR}/${role_name}.log"
    if [[ -f "$log_file" ]]; then
        local size
        size=$(du -h "$log_file" | cut -f1)
        echo "$size"
    else
        echo "0B"
    fi
}

# 格式化状态显示
format_status() {
    local use_color="$1"
    local session_status="$2"

    # 检查状态文件
    if [[ ! -f "$STATE_FILE" ]]; then
        if [[ "$use_color" == "true" ]]; then
            info "${COLOR_STOPPED}${EMOJI_STOPPED} 蜂群状态: 未初始化${COLOR_RESET}"
        else
            info "蜂群状态: 未初始化"
        fi
        info "请先使用 swarm-start.sh 启动蜂群"
        return
    fi

    # 获取基本信息
    local uptime
    uptime=$(get_uptime)

    local pending_count
    local processing_count
    local completed_count
    local blocked_count
    pending_count=$(count_tasks "pending")
    processing_count=$(count_tasks "processing")
    completed_count=$(count_tasks "completed")
    blocked_count=$(count_tasks "blocked")
    local task_rows
    task_rows=$(collect_task_rows)

    # 显示标题
    if [[ "$use_color" == "true" ]]; then
        echo -e "${COLOR_SEPARATOR}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
        echo -e "${COLOR_TITLE}              蜂群状态报告${COLOR_RESET}"
        echo -e "${COLOR_SEPARATOR}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "              蜂群状态报告"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi

    echo ""

    # 显示整体状态
    if [[ "$use_color" == "true" ]]; then
        if [[ "$session_status" == "running" ]]; then
            info "${COLOR_RUNNING}${EMOJI_RUNNING} 蜂群状态:${COLOR_RESET} ${COLOR_VALUE}运行中${COLOR_RESET}"
        else
            info "${COLOR_STOPPED}${EMOJI_STOPPED} 蜂群状态:${COLOR_RESET} ${COLOR_VALUE}已停止${COLOR_RESET}"
        fi
        info "${COLOR_LABEL}运行时长:${COLOR_RESET} ${COLOR_VALUE}${uptime}${COLOR_RESET}"
    else
        info "蜂群状态: $session_status"
        info "运行时长: $uptime"
    fi

    echo ""

    # 如果 session 未运行,不显示角色状态
    if [[ "$session_status" != "running" ]]; then
        return
    fi

    # 显示角色状态
    if [[ "$use_color" == "true" ]]; then
        echo -e "${COLOR_LABEL}角色状态:${COLOR_RESET}"
    else
        echo "角色状态:"
    fi

    local total_roles=0
    local active_roles=0

    # 读取所有角色
    while IFS='|' read -r role_name alias window pane model; do
        ((total_roles++)) || true

        local pane_target="${window}.${pane}"
        local status
        status=$(check_pane_status "$pane_target")

        local emoji
        emoji=$(get_role_emoji "$role_name")

        local status_emoji
        local status_text
        local status_color

        case "$status" in
            active)
                status_emoji="$EMOJI_ACTIVE"
                status_text="活跃"
                status_color="$COLOR_ACTIVE"
                ((active_roles++)) || true
                ;;
            idle)
                status_emoji="$EMOJI_IDLE"
                status_text="空闲"
                status_color="$COLOR_IDLE"
                ;;
            error)
                status_emoji="$EMOJI_ERROR"
                status_text="错误"
                status_color="$COLOR_ERROR"
                ;;
        esac

        local log_size
        log_size=$(get_log_size "$role_name")

        if [[ "$use_color" == "true" ]]; then
            printf "  %s ${COLOR_VALUE}%-15s${COLOR_RESET} ${COLOR_LABEL}(%-10s)${COLOR_RESET} - %s ${status_color}%-6s${COLOR_RESET} ${COLOR_LABEL}[pane %s]${COLOR_RESET} ${COLOR_LABEL}(log: %s)${COLOR_RESET}\n" \
                "$emoji" "$role_name" "$model" "$status_emoji" "$status_text" "$pane_target" "$log_size"
        else
            printf "  %s %-15s (%-10s) - %s %-6s [pane %s] (log: %s)\n" \
                "$emoji" "$role_name" "$model" "$status_emoji" "$status_text" "$pane_target" "$log_size"
        fi
    done < <(jq -r '.panes[] | "\(.role)|\(.alias)|\(.pane)|\(.cli)"' "$STATE_FILE" | awk -F'|' '{split($3, a, "."); print $1"|"$2"|"a[1]"|"a[2]"|"$4}')

    echo ""

    # 显示活跃角色统计
    if [[ "$use_color" == "true" ]]; then
        info "${COLOR_LABEL}活跃角色:${COLOR_RESET} ${COLOR_VALUE}${active_roles}/${total_roles}${COLOR_RESET}"
    else
        info "活跃角色: ${active_roles}/${total_roles}"
    fi

    echo ""

    # 显示任务统计
    if [[ "$use_color" == "true" ]]; then
        echo -e "${COLOR_LABEL}${EMOJI_TASK} 任务统计:${COLOR_RESET}"
        printf "  ${COLOR_LABEL}待处理:${COLOR_RESET} ${COLOR_VALUE}%d${COLOR_RESET}\n" "$pending_count"
        printf "  ${COLOR_LABEL}进行中:${COLOR_RESET} ${COLOR_VALUE}%d${COLOR_RESET}\n" "$processing_count"
        printf "  ${COLOR_LABEL}阻塞中:${COLOR_RESET} ${COLOR_VALUE}%d${COLOR_RESET}\n" "$blocked_count"
        printf "  ${COLOR_LABEL}已完成:${COLOR_RESET} ${COLOR_VALUE}%d${COLOR_RESET}\n" "$completed_count"
    else
        echo "任务统计:"
        printf "  待处理: %d\n" "$pending_count"
        printf "  进行中: %d\n" "$processing_count"
        printf "  阻塞中: %d\n" "$blocked_count"
        printf "  已完成: %d\n" "$completed_count"
    fi

    if [[ "$(jq 'length' <<<"$task_rows")" -gt 0 ]]; then
        echo ""
        if [[ "$use_color" == "true" ]]; then
            echo -e "${COLOR_LABEL}关键任务:${COLOR_RESET}"
        else
            echo "关键任务:"
        fi
        jq -r '
            map(select(.status == "processing" or .status == "blocked" or .status == "pending"))
            | sort_by(
                if .status == "processing" then 0
                elif .status == "blocked" then 1
                else 2
                end
            )
            | .[:8]
            | .[]
            | "  [\(.status)] \(.id) | \(.title) | phase=\(.phase)\(.owner | if . != \"\" then \" | owner=\" + . else \"\" end)\(.resource_keys | if length > 0 then \" | resources=\" + (join(\",\")) else \"\" end)\(.blocked_reason | if . != \"\" then \" | blocked=\" + . else \"\" end)\(.resource_blocked_by | if . != \"\" then \"(\" + . + \")\" else \"\" end)"
        ' <<<"$task_rows"
    fi

    echo ""
    if [[ "$use_color" == "true" ]]; then
        echo -e "${COLOR_SEPARATOR}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
}

# JSON 格式输出
format_json() {
    local session_status="$1"

    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"status":"uninitialized","message":"请先使用 swarm-start.sh 启动蜂群"}'
        return
    fi

    local uptime
    uptime=$(get_uptime)

    local pending_count
    local processing_count
    local completed_count
    local blocked_count
    pending_count=$(count_tasks "pending")
    processing_count=$(count_tasks "processing")
    completed_count=$(count_tasks "completed")
    blocked_count=$(count_tasks "blocked")
    local task_rows
    task_rows=$(collect_task_rows)

    # 构建角色状态数组
    local roles_json="[]"

    if [[ "$session_status" == "running" ]]; then
        roles_json=$(jq -c '[.panes[] | {
            name: .role,
            alias: .alias,
            model: .cli,
            pane: .pane
        }]' "$STATE_FILE")

        # 为每个角色添加状态
        local temp_roles="[]"
        while IFS='|' read -r role_name alias window pane model; do
            local pane_target="${window}.${pane}"
            local status
            status=$(check_pane_status "$pane_target")

            local log_size
            log_size=$(get_log_size "$role_name")

            local role_obj
            role_obj=$(jq -n \
                --arg name "$role_name" \
                --arg alias "$alias" \
                --arg model "$model" \
                --arg pane "$pane_target" \
                --arg status "$status" \
                --arg log_size "$log_size" \
                '{name: $name, alias: $alias, model: $model, pane: $pane, status: $status, log_size: $log_size}')

            temp_roles=$(echo "$temp_roles" | jq --argjson obj "$role_obj" '. + [$obj]')
        done < <(jq -r '.panes[] | "\(.role)|\(.alias)|\(.pane)|\(.cli)"' "$STATE_FILE" | awk -F'|' '{split($3, a, "."); print $1"|"$2"|"a[1]"|"a[2]"|"$4}')

        roles_json="$temp_roles"
    fi

    # 构建完整 JSON
    jq -n \
        --arg status "$session_status" \
        --arg uptime "$uptime" \
        --argjson roles "$roles_json" \
        --argjson pending "$pending_count" \
        --argjson processing "$processing_count" \
        --argjson blocked "$blocked_count" \
        --argjson completed "$completed_count" \
        --argjson task_rows "$task_rows" \
        '{
            status: $status,
            uptime: $uptime,
            roles: $roles,
            tasks: {
                pending: $pending,
                processing: $processing,
                blocked: $blocked,
                completed: $completed
            },
            task_rows: $task_rows
        }'
}

# 持续监控模式
watch_status() {
    local use_color="$1"

    info "开始监控蜂群状态... (按 Ctrl+C 停止)"
    echo ""

    while true; do
        clear

        local session_status
        session_status=$(check_session_status)

        format_status "$use_color" "$session_status"

        sleep 2
    done
}

#==========================================
# 主函数
#==========================================

main() {
    # 参数解析
    local watch="false"
    local json_output="false"
    local use_color="true"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -w|--watch)
                watch="true"
                shift
                ;;
            -j|--json)
                json_output="true"
                use_color="false"
                shift
                ;;
            -c|--no-color)
                use_color="false"
                shift
                ;;
            -h|--help)
                usage
                ;;
            -*)
                error "未知选项: $1"
                usage
                ;;
            *)
                error "不支持位置参数: $1"
                usage
                ;;
        esac
    done

    # 检查依赖
    check_dependencies

    # 检查 session 状态
    local session_status
    session_status=$(check_session_status)

    # 根据输出格式显示
    if [[ "$json_output" == "true" ]]; then
        format_json "$session_status"
    elif [[ "$watch" == "true" ]]; then
        watch_status "$use_color"
    else
        format_status "$use_color" "$session_status"
    fi
}

# 执行主函数
main "$@"
