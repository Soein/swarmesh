#!/usr/bin/env bash
################################################################################
# swarm-detect.sh - AI CLI 完成检测器
#
# 功能: 检测某个角色的 AI CLI 是否完成了当前响应
#
# 检测策略（双重验证）:
#   1. 静默检测: 日志文件超过 N 秒无新内容
#   2. 提示符检测: pane 最后几行是否出现 CLI 提示符
#
# 用法:
#   swarm-detect.sh <role> [选项]
#
# 选项:
#   --timeout <秒>      超时时间 (默认: 300)
#   --silence <秒>      静默阈值，多久没输出算完成 (默认: 5)
#   --poll <秒>         轮询间隔 (默认: 2)
#   --json              以 JSON 格式输出结果
#
# 返回码:
#   0 - 检测到完成
#   1 - 超时
#   2 - 错误
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SWARM_ROOT="${SWARM_ROOT:-$(dirname "$SCRIPT_DIR")}"
readonly STATE_FILE="${SWARM_ROOT}/runtime/state.json"
readonly SESSION_NAME="${SWARM_SESSION:-swarm}"

# 加载共享事件库
source "${SCRIPT_DIR}/swarm-lib.sh"

# 默认配置
TIMEOUT=300
SILENCE_THRESHOLD=5
POLL_INTERVAL=2
JSON_OUTPUT=false

# PROMPT_PATTERNS 和 check_prompt() 已由 swarm-lib.sh 提供

# ============================================================================
# 工具函数
# ============================================================================

die() { echo "[ERROR] $*" >&2; exit 2; }

log() { [[ "$JSON_OUTPUT" == "false" ]] && echo "[detect] $*" >&2 || true; }

# 获取日志文件最后修改时间（epoch 秒）
get_file_mtime() {
    local file="$1"
    if [[ -f "$file" ]]; then
        stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# ============================================================================
# 核心检测逻辑
# ============================================================================

detect_completion() {
    local role="$1"

    # 解析角色信息
    local info
    info=$(resolve_role_full "$role")
    local pane_target cli log_file
    pane_target=$(echo "$info" | cut -d'|' -f1)
    local role_name
    role_name=$(echo "$info" | cut -d'|' -f2)
    cli=$(echo "$info" | cut -d'|' -f3)
    log_file=$(echo "$info" | cut -d'|' -f4)

    log "开始检测 [$role_name] 完成状态..."
    log "Pane: $pane_target | CLI: $cli"
    log "日志: $log_file"
    log "超时: ${TIMEOUT}s | 静默阈值: ${SILENCE_THRESHOLD}s | 轮询: ${POLL_INTERVAL}s"

    local start_time
    start_time=$(date +%s)

    # 记录检测开始时的日志大小
    local initial_size=0
    [[ -f "$log_file" ]] && initial_size=$(wc -c < "$log_file" | tr -d ' ')

    local last_change_time=$start_time
    local last_size=$initial_size
    local completed=false

    while true; do
        local now
        now=$(date +%s)
        local elapsed=$((now - start_time))

        # 超时检查
        if [[ $elapsed -ge $TIMEOUT ]]; then
            log "超时！已等待 ${elapsed}s"
            output_result "TIMEOUT" "$role_name" "$elapsed" "$pane_target"
            return 1
        fi

        # 获取当前日志大小
        local current_size=0
        [[ -f "$log_file" ]] && current_size=$(wc -c < "$log_file" | tr -d ' ')

        # 日志有新内容 → 更新最后变化时间
        if [[ $current_size -ne $last_size ]]; then
            last_change_time=$now
            last_size=$current_size
        fi

        # 计算静默时长
        local silence_duration=$((now - last_change_time))

        # 静默检测：日志超过阈值时间没有更新
        if [[ $silence_duration -ge $SILENCE_THRESHOLD ]]; then
            # 检查提示符是否存在
            if check_prompt "$pane_target"; then
                # 场景 1: 日志有增长 → 任务执行完成
                # 场景 2: 日志无增长但已等待足够久 → CLI 已经处于空闲状态
                if [[ $current_size -gt $initial_size ]] || [[ $elapsed -ge $((SILENCE_THRESHOLD * 2)) ]]; then
                    log "检测到完成！静默 ${silence_duration}s + 提示符确认"
                    completed=true
                    output_result "COMPLETED" "$role_name" "$elapsed" "$pane_target"
                    return 0
                fi
            fi
        fi

        # 显示进度
        if [[ $((elapsed % 10)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            local size_diff=$((current_size - initial_size))
            log "等待中... ${elapsed}s | 新增输出: ${size_diff} bytes | 静默: ${silence_duration}s"
        fi

        sleep "$POLL_INTERVAL"
    done
}

# 输出结果
output_result() {
    local status="$1"
    local role="$2"
    local elapsed="$3"
    local pane="$4"

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        cat <<EOF
{
  "status": "$status",
  "role": "$role",
  "elapsed_seconds": $elapsed,
  "pane": "$pane",
  "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    else
        echo "$status"
    fi
}

# ============================================================================
# 参数解析和主入口
# ============================================================================

show_help() {
    cat <<EOF
swarm-detect - AI CLI 完成检测器

用法:
  swarm-detect.sh <role> [选项]

选项:
  --timeout <秒>      超时时间 (默认: 300)
  --silence <秒>      静默阈值 (默认: 5)
  --poll <秒>         轮询间隔 (默认: 2)
  --json              JSON 格式输出
  --help              显示帮助

示例:
  swarm-detect.sh frontend
  swarm-detect.sh backend --timeout 60 --json
  swarm-detect.sh database --silence 8
EOF
}

main() {
    local role=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout)  TIMEOUT="$2"; shift 2 ;;
            --silence)  SILENCE_THRESHOLD="$2"; shift 2 ;;
            --poll)     POLL_INTERVAL="$2"; shift 2 ;;
            --json)     JSON_OUTPUT=true; shift ;;
            --help|-h)  show_help; exit 0 ;;
            -*)         die "未知选项: $1" ;;
            *)          role="$1"; shift ;;
        esac
    done

    [[ -n "$role" ]] || die "请指定角色名称"

    # 检查 tmux session
    tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "Session '$SESSION_NAME' 不存在"

    detect_completion "$role"
}

main "$@"
