#!/usr/bin/env bash
################################################################################
# swarm-relay.sh - 多 CLI 消息中继器
#
# 核心功能: 等待角色A完成 → 捕获输出 → 自动发送给角色B
#
# 这是实现多 CLI 自动协作的关键脚本。
#
# 用法:
#   swarm-relay.sh <from_role> <to_role> [选项]
#
# 选项:
#   --prompt <text>     附加提示（前缀），告诉角色B如何使用角色A的输出
#   --timeout <秒>      等待角色A完成的超时时间 (默认: 300)
#   --lines <N>         捕获角色A最后 N 行输出 (默认: 100)
#   --save              将中继内容保存到 results/ 目录
#   --chain             中继完成后继续等待角色B完成（用于链式传递）
#   --json              JSON 格式输出中继报告
#
# 流程:
#   1. 等待 from_role 完成响应（调用 swarm-detect.sh）
#   2. 捕获 from_role 的 pane 输出
#   3. 清理输出（去除 ANSI 转义码、提示符等）
#   4. 组合 prompt + 清理后的输出
#   5. 通过 send-keys 发送给 to_role
#   6. 可选: 保存中继记录
#
# 示例:
#   # 数据库设计完成后自动传给后端
#   swarm-relay.sh database backend --prompt "基于以下数据库设计实现 API："
#
#   # 链式中继: database → backend → frontend
#   swarm-relay.sh database backend --prompt "实现 API" --chain
#   swarm-relay.sh backend frontend --prompt "调用以下 API"
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SWARM_ROOT="${SWARM_ROOT:-$(dirname "$SCRIPT_DIR")}"
readonly SCRIPTS_DIR="${SWARM_ROOT}/scripts"
readonly STATE_FILE="${SWARM_ROOT}/runtime/state.json"
readonly RESULTS_DIR="${SWARM_ROOT}/runtime/results"
readonly SESSION_NAME="${SWARM_SESSION:-swarm}"

# 加载共享事件库
source "${SCRIPT_DIR}/swarm-lib.sh"

# 默认配置
TIMEOUT=300
CAPTURE_LINES=100
PROMPT_PREFIX=""
SAVE_RESULT=false
CHAIN_MODE=false
JSON_OUTPUT=false

# ============================================================================
# 工具函数
# ============================================================================

info() { echo -e "\033[0;34m[relay]\033[0m $*" >&2; }
success() { echo -e "\033[0;32m[relay]\033[0m $*" >&2; }

# ============================================================================
# 捕获和清理输出
# ============================================================================

# 从日志文件精确提取本次响应（基于 task.sent 时记录的字节偏移量）
# 优于 capture-pane: 无截断、无行数限制、包含完整输出
capture_from_log() {
    local log_file="$1"
    local offset="$2"

    if [[ ! -f "$log_file" ]]; then
        echo ""
        return
    fi

    # tail -c +N: 从第 N 字节开始读到 EOF（1-indexed，所以 +offset+1）
    # 比 dd bs=1 skip=N 快几个数量级
    tail -c "+$((offset + 1))" "$log_file" 2>/dev/null
}

# 从 events.jsonl 获取最近一次 task.sent 事件的日志偏移量
get_log_offset() {
    local role="$1"

    # 反向搜索最近的 task.sent 事件
    local event
    event=$(grep "\"task.sent\"" "$EVENTS_LOG" 2>/dev/null \
        | grep "\"role\":\"$role\"" \
        | tail -1)

    if [[ -n "$event" ]]; then
        echo "$event" | jq -r '.data.log_offset // "0"'
    else
        echo "0"
    fi
}

# 回退方案: 从 pane 截屏捕获（当日志偏移量不可用时）
capture_from_pane() {
    local pane_target="$1"
    local lines="$2"

    tmux capture-pane -t "${SESSION_NAME}:${pane_target}" -p -S "-${lines}" 2>/dev/null
}

# 清理 AI CLI 输出（去除 ANSI 转义码、提示符、系统信息等）
clean_output() {
    sed -E '
        s/\x1b\[[0-9;]*[a-zA-Z]//g
        s/\x1b\([0-9;]*[a-zA-Z]//g
        s/\x1b\].*\x07//g
        s/\x0f//g
        s/[[:cntrl:]]//g
    ' | grep -vE '^\s*$|^❯|^>|^›|^\$|Type your message|pipe:|pane_index' \
      | sed '/^$/N;/^\n$/d'
}

# ============================================================================
# 核心中继逻辑
# ============================================================================

relay_message() {
    local from_role="$1"
    local to_role="$2"

    # 解析角色信息
    local from_info to_info
    from_info=$(resolve_role_full "$from_role") || die "找不到源角色: $from_role"
    to_info=$(resolve_role_full "$to_role") || die "找不到目标角色: $to_role"

    local from_pane from_name from_cli from_log
    from_pane=$(echo "$from_info" | cut -d'|' -f1)
    from_name=$(echo "$from_info" | cut -d'|' -f2)
    from_cli=$(echo "$from_info" | cut -d'|' -f3)
    from_log=$(echo "$from_info" | cut -d'|' -f4)

    local to_pane to_name to_cli
    to_pane=$(echo "$to_info" | cut -d'|' -f1)
    to_name=$(echo "$to_info" | cut -d'|' -f2)
    to_cli=$(echo "$to_info" | cut -d'|' -f3)

    info "中继: $from_name → $to_name"
    info "等待 $from_name 完成响应..."

    # 发射中继开始事件
    emit_event "relay.started" "$from_name" "to=$to_name"

    # ===== 步骤 1: 等待源角色完成（事件驱动，零轮询）=====
    if ! "$SCRIPTS_DIR/swarm-events.sh" --wait task.completed \
            --role "$from_role" --timeout "$TIMEOUT" 2>/dev/null; then
        emit_event "relay.failed" "$from_name" "to=$to_name" "reason=timeout"
        die "$from_name 响应超时或出错"
    fi

    success "$from_name 响应完成！"

    # ===== 步骤 2: 捕获输出（优先用日志偏移量，完整无截断）=====
    local log_offset raw_output cleaned_output response

    log_offset=$(get_log_offset "$from_name")

    if [[ "$log_offset" != "0" ]] && [[ -f "$from_log" ]]; then
        info "从日志精确提取 $from_name 响应（偏移: $log_offset bytes）..."
        raw_output=$(capture_from_log "$from_log" "$log_offset")
    else
        info "回退: 从 pane 截屏捕获 $from_name 输出（最后 ${CAPTURE_LINES} 行）..."
        raw_output=$(capture_from_pane "$from_pane" "$CAPTURE_LINES")
    fi

    cleaned_output=$(echo "$raw_output" | clean_output)
    response="$cleaned_output"

    # 如果清理后内容太少，尝试 pane 截屏作为回退
    if [[ $(echo "$response" | wc -l | tr -d ' ') -lt 2 ]]; then
        info "日志提取内容不足，回退到 pane 截屏..."
        raw_output=$(capture_from_pane "$from_pane" "$CAPTURE_LINES")
        response=$(echo "$raw_output" | clean_output)
    fi

    local response_lines
    response_lines=$(echo "$response" | wc -l | tr -d ' ')
    info "捕获到 ${response_lines} 行有效输出"

    # ===== 步骤 3: 组装消息 =====
    local message=""
    if [[ -n "$PROMPT_PREFIX" ]]; then
        message="${PROMPT_PREFIX}

--- ${from_name} 的输出 ---

${response}"
    else
        message="以下是 ${from_name} 的工作成果，请基于此继续你的工作：

--- ${from_name} 的输出 ---

${response}"
    fi

    # ===== 步骤 4: 发送给目标角色 =====
    info "发送给 $to_name (pane: $to_pane)..."

    # 将消息写入临时文件，避免 send-keys 长度限制
    local tmp_file
    tmp_file=$(mktemp "${SWARM_ROOT}/runtime/.relay-XXXXXX.txt")
    echo "$message" > "$tmp_file"

    # 使用 tmux load-buffer + paste-buffer 发送长消息
    tmux load-buffer "$tmp_file"
    tmux paste-buffer -t "${SESSION_NAME}:${to_pane}"
    sleep 0.5
    tmux send-keys -t "${SESSION_NAME}:${to_pane}" Enter

    rm -f "$tmp_file"

    success "消息已中继: $from_name → $to_name"

    # 发射中继完成事件
    emit_event "relay.completed" "$from_name" "to=$to_name" "lines=$response_lines"

    # ===== 步骤 5: 保存结果（可选）=====
    if [[ "$SAVE_RESULT" == "true" ]]; then
        mkdir -p "$RESULTS_DIR"
        local result_file="${RESULTS_DIR}/relay-${from_name}-to-${to_name}-$(date +%s).json"
        cat > "$result_file" <<RESULT_EOF
{
  "type": "relay",
  "from": "$from_name",
  "to": "$to_name",
  "timestamp": "$(get_timestamp)",
  "prompt": $(echo "$PROMPT_PREFIX" | jq -Rs .),
  "response_lines": $response_lines,
  "response": $(echo "$response" | jq -Rs .)
}
RESULT_EOF
        info "结果已保存: $result_file"
    fi

    # ===== 步骤 6: 链式模式（可选）=====
    if [[ "$CHAIN_MODE" == "true" ]]; then
        info "链式模式: 继续等待 $to_name 完成..."
        "$SCRIPTS_DIR/swarm-events.sh" --wait task.completed \
            --role "$to_role" --timeout "$TIMEOUT" 2>/dev/null
        success "$to_name 也完成了！可以继续下一段中继。"
    fi

    # 输出中继报告
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        cat <<EOF
{
  "status": "SUCCESS",
  "from": "$from_name",
  "to": "$to_name",
  "response_lines": $response_lines,
  "timestamp": "$(get_timestamp)"
}
EOF
    fi
}

# ============================================================================
# 参数解析和主入口
# ============================================================================

show_help() {
    cat <<'EOF'
swarm-relay - 多 CLI 消息中继器

用法:
  swarm-relay.sh <from_role> <to_role> [选项]

选项:
  --prompt <text>     附加提示前缀
  --timeout <秒>      等待超时 (默认: 300)
  --lines <N>         捕获行数 (默认: 100)
  --save              保存中继记录
  --chain             等待目标角色也完成
  --json              JSON 输出
  --help              帮助

示例:
  # 数据库设计 → 后端实现
  swarm-relay.sh database backend --prompt "基于以下数据库设计实现 REST API："

  # 后端 API → 前端页面
  swarm-relay.sh backend frontend --prompt "调用以下 API 实现登录页面："

  # 链式: 等待后端也完成
  swarm-relay.sh database backend --prompt "实现 API" --chain

  # 并行中继（后台运行）
  swarm-relay.sh database backend --prompt "实现 API" &
  swarm-relay.sh database frontend --prompt "基于数据模型设计 UI" &
  wait
EOF
}

main() {
    local from_role="" to_role=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prompt)   PROMPT_PREFIX="$2"; shift 2 ;;
            --timeout)  TIMEOUT="$2"; shift 2 ;;
            --lines)    CAPTURE_LINES="$2"; shift 2 ;;
            --save)     SAVE_RESULT=true; shift ;;
            --chain)    CHAIN_MODE=true; shift ;;
            --json)     JSON_OUTPUT=true; shift ;;
            --help|-h)  show_help; exit 0 ;;
            -*)         die "未知选项: $1" ;;
            *)
                if [[ -z "$from_role" ]]; then
                    from_role="$1"
                elif [[ -z "$to_role" ]]; then
                    to_role="$1"
                else
                    die "多余参数: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "$from_role" ]] || die "请指定源角色"
    [[ -n "$to_role" ]] || die "请指定目标角色"
    [[ -f "$STATE_FILE" ]] || die "state.json 不存在，蜂群未启动？"
    tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "Session '$SESSION_NAME' 不存在"

    relay_message "$from_role" "$to_role"
}

main "$@"
