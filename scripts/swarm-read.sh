#!/usr/bin/env bash
# swarm-read.sh - 读取 tmux pane 输出工具
# 用途: 读取和监控蜂群中各角色的输出
# 依赖: bash 5.0+, tmux, jq

set -euo pipefail

#==========================================
# 配置部分
#==========================================

# 从脚本位置推导项目根目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_ROOT="${SWARM_ROOT:-$(dirname "$SCRIPT_DIR")}"
STATE_FILE="${SWARM_ROOT}/runtime/state.json"
RESULTS_DIR="${SWARM_ROOT}/runtime/results"
SESSION_NAME="${SWARM_SESSION:-swarm}"

# 默认读取行数
DEFAULT_LINES=50

# 颜色定义
COLOR_RESET='\033[0m'
COLOR_ROLE='\033[1;36m'      # 青色粗体
COLOR_TIME='\033[0;90m'      # 灰色
COLOR_OUTPUT='\033[0;37m'    # 白色
COLOR_ERROR='\033[1;31m'     # 红色粗体
COLOR_SUCCESS='\033[1;32m'   # 绿色粗体
COLOR_SEPARATOR='\033[0;34m' # 蓝色

#==========================================
# 工具函数
#==========================================

# 打印错误信息
error() {
    echo -e "${COLOR_ERROR}错误: $*${COLOR_RESET}" >&2
}

# 打印成功信息
success() {
    echo -e "${COLOR_SUCCESS}✓ $*${COLOR_RESET}"
}

# 打印信息
info() {
    echo -e "$*"
}

# 显示使用帮助
usage() {
    cat <<EOF
用法: $(basename "$0") [选项] <角色名>

读取蜂群中指定角色的 tmux pane 输出。

选项:
    -n, --lines <N>     读取最后 N 行 (默认: ${DEFAULT_LINES})
    -a, --all           读取全部输出
    -f, --follow        持续监控输出 (类似 tail -f)
    -s, --save          保存输出到 results/ 目录
    -c, --no-color      禁用颜色输出
    -h, --help          显示此帮助信息

参数:
    角色名              角色名称或别名 (例如: frontend, 前端专家)

示例:
    $(basename "$0") frontend                  # 读取前端专家最后 50 行
    $(basename "$0") -n 100 backend            # 读取后端专家最后 100 行
    $(basename "$0") -a reviewer               # 读取代码审查员全部输出
    $(basename "$0") -f frontend               # 持续监控前端专家输出
    $(basename "$0") -s -n 200 backend         # 读取后端专家 200 行并保存

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

# 检查 tmux session 是否存在
check_session() {
    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        error "tmux session '$SESSION_NAME' 不存在"
        error "请先使用 swarm-start.sh 启动蜂群"
        exit 1
    fi
}

# 检查 state.json 是否存在
check_state_file() {
    if [[ ! -f "$STATE_FILE" ]]; then
        error "状态文件不存在: $STATE_FILE"
        error "请先使用 swarm-start.sh 启动蜂群"
        exit 1
    fi
}

# 根据角色名或别名查找 pane 信息
find_pane() {
    local role_query="$1"

    # 从 state.json 中查找匹配的角色
    local pane_info
    pane_info=$(jq -r --arg query "$role_query" '
        .panes[] |
        select(.role == $query or (.alias // "" | split(",") | index($query))) |
        "\(.pane)|\(.role)|\(.cli)"
    ' "$STATE_FILE" | head -1)

    if [[ -z "$pane_info" ]]; then
        error "未找到角色: $role_query"
        error "可用角色列表:"
        jq -r '.panes[] | "  - \(.role) (\(.alias))"' "$STATE_FILE"
        exit 1
    fi

    echo "$pane_info"
}

# 格式化输出
format_output() {
    local role_name="$1"
    local model="$2"
    local use_color="$3"

    local timestamp
    timestamp=$(date '+%H:%M:%S')

    if [[ "$use_color" == "true" ]]; then
        echo -e "${COLOR_SEPARATOR}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
        echo -e "${COLOR_ROLE}[$role_name]${COLOR_RESET} ${COLOR_TIME}@$timestamp${COLOR_RESET} ${COLOR_TIME}(model: $model)${COLOR_RESET}"
        echo -e "${COLOR_SEPARATOR}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "[$role_name] @$timestamp (model: $model)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
}

# 读取 pane 输出
read_pane_output() {
    local pane_target="$1"
    local lines="$2"
    local read_all="$3"

    if [[ "$read_all" == "true" ]]; then
        # 读取全部历史
        tmux capture-pane -t "${SESSION_NAME}:${pane_target}" -p -S -
    else
        # 读取最后 N 行
        tmux capture-pane -t "${SESSION_NAME}:${pane_target}" -p | tail -n "$lines"
    fi
}

# 持续监控 pane 输出
follow_pane_output() {
    local pane_target="$1"
    local role_name="$2"
    local model="$3"
    local use_color="$4"

    info "开始监控 $role_name 输出... (按 Ctrl+C 停止)"
    echo ""

    # 记录上次读取的内容哈希
    local last_hash=""

    while true; do
        # 读取当前内容
        local current_output
        current_output=$(tmux capture-pane -t "${SESSION_NAME}:${pane_target}" -p)

        # 计算哈希值
        local current_hash
        current_hash=$(echo "$current_output" | md5sum 2>/dev/null | cut -d' ' -f1 || md5 2>/dev/null)

        # 如果内容有变化,显示新内容
        if [[ "$current_hash" != "$last_hash" ]]; then
            clear
            format_output "$role_name" "$model" "$use_color"
            echo "$current_output"
            last_hash="$current_hash"
        fi

        sleep 1
    done
}

# 保存输出到文件
save_output() {
    local role_name="$1"
    local output="$2"

    # 确保目录存在
    mkdir -p "$RESULTS_DIR"

    # 生成文件名
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local filename="${RESULTS_DIR}/${role_name}_${timestamp}.txt"

    # 保存输出
    echo "$output" > "$filename"

    success "输出已保存到: $filename"
}

#==========================================
# 主函数
#==========================================

main() {
    # 参数解析
    local role_name=""
    local lines=$DEFAULT_LINES
    local read_all="false"
    local follow="false"
    local save="false"
    local use_color="true"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--lines)
                if [[ -z "${2:-}" ]] || [[ "$2" =~ ^- ]]; then
                    error "选项 $1 需要一个数值参数"
                    exit 1
                fi
                lines="$2"
                shift 2
                ;;
            -a|--all)
                read_all="true"
                shift
                ;;
            -f|--follow)
                follow="true"
                shift
                ;;
            -s|--save)
                save="true"
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
                if [[ -n "$role_name" ]]; then
                    error "只能指定一个角色名"
                    usage
                fi
                role_name="$1"
                shift
                ;;
        esac
    done

    # 检查参数
    if [[ -z "$role_name" ]]; then
        error "缺少角色名参数"
        usage
    fi

    # 验证 lines 是数字
    if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
        error "行数必须是正整数: $lines"
        exit 1
    fi

    # 检查依赖和环境
    check_dependencies
    check_session
    check_state_file

    # 查找 pane
    local pane_info
    pane_info=$(find_pane "$role_name")

    # 解析 pane 信息
    IFS='|' read -r pane_target role_display model <<< "$pane_info"

    # 检查 pane 是否存在
    if ! tmux list-panes -t "${SESSION_NAME}:${pane_target}" &>/dev/null; then
        error "Pane 不存在: ${SESSION_NAME}:${pane_target}"
        exit 1
    fi

    # 根据模式执行
    if [[ "$follow" == "true" ]]; then
        # 持续监控模式
        follow_pane_output "$pane_target" "$role_display" "$model" "$use_color"
    else
        # 单次读取模式
        format_output "$role_display" "$model" "$use_color"

        local output
        output=$(read_pane_output "$pane_target" "$lines" "$read_all")

        echo "$output"
        echo ""

        # 如果需要保存
        if [[ "$save" == "true" ]]; then
            save_output "$role_display" "$output"
        fi

        # 显示统计信息
        local line_count
        line_count=$(echo "$output" | wc -l | tr -d ' ')
        info "共 ${line_count} 行输出"
    fi
}

# 执行主函数
main "$@"
