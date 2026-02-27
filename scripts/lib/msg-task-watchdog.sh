#!/usr/bin/env bash
################################################################################
# msg-task-watchdog.sh - 任务看门狗模块
#
# 两层防护：
#   1. 存活检测（主动）：检查工蜂 pane 是否存活，崩溃则立即恢复任务
#   2. Processing TTL（被动）：基于 claimed_at 时间戳，超时自动恢复
#   3. 空闲检测：pane 存活但处于 idle 状态，提醒 inspector
#
# 由 swarm-msg.sh source 加载，不独立运行。
################################################################################

[[ -n "${_MSG_TASK_WATCHDOG_LOADED:-}" ]] && return 0
_MSG_TASK_WATCHDOG_LOADED=1

# =============================================================================
# 配置
# =============================================================================

# 巡检间隔（秒）
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-60}"

# 任务最大处理时长（秒），0=禁用 TTL 检测（默认 6 小时）
TASK_PROCESSING_TTL="${TASK_PROCESSING_TTL:-21600}"

# =============================================================================
# 内部函数
# =============================================================================

# 恢复单个任务: processing → pending（原子操作）
# 采用 jq-first-then-mv 模式：先在 processing/ 写好 tmp，再 mv 到 pending/，
# 确保 jq 失败时原文件不动，不会产生 status 不一致的中间状态。
#
# 参数:
#   $1 - 任务文件路径 (processing/*.json)
#   $2 - 任务 ID
#   $3 - 恢复原因 (liveness/ttl)
#   $4 - 原认领者
_watchdog_recover_task() {
    local task_file="$1"
    local tid="$2"
    local reason="$3"
    local original_claimer="$4"

    [[ -f "$task_file" ]] || return 0

    # 先在 processing/ 生成更新后的 tmp（jq 失败则不动原文件）
    mkdir -p "$TASKS_DIR/pending"
    local tmp="$TASKS_DIR/processing/${tid}.json.tmp"
    if ! jq '.status = "pending" | .claimed_by = null | .claimed_at = null' \
        "$task_file" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1  # jq 失败，保留原文件不动
    fi

    # 原子 mv 到 pending/（防并发重复恢复）
    if ! mv "$tmp" "$TASKS_DIR/pending/$tid.json" 2>/dev/null; then
        rm -f "$tmp"
        return 0  # 被其他进程抢先处理
    fi
    rm -f "$task_file"

    # 发射恢复事件
    emit_event "task.recovered.${reason}" "" "task_id=$tid" "original_claimer=$original_claimer"

    # 通知 inspector（高优先级消息写入收件箱）
    local notify_id="sys-watchdog-$(date +%s)-${tid}"
    local reason_text=""
    case "$reason" in
        liveness) reason_text="工蜂 pane 已崩溃" ;;
        ttl)      reason_text="处理超时 (TTL=${TASK_PROCESSING_TTL}s)" ;;
    esac

    mkdir -p "${INBOX_DIR}/inspector"
    jq -n \
        --arg id "$notify_id" \
        --arg from "watchdog" \
        --arg to "inspector" \
        --arg content "[任务恢复] 任务 $tid 已从 processing 恢复到 pending。原因: ${reason_text}。原认领者: ${original_claimer}。" \
        --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
        --arg status "pending" \
        --arg priority "high" \
        '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority}' \
        > "${INBOX_DIR}/inspector/${notify_id}.json"

    log_info "[watchdog] 已恢复任务: $tid (原因: $reason_text, 原认领者: $original_claimer)"
}

# 发送空闲告警到 inspector
# 参数:
#   $1 - 任务 ID
#   $2 - 认领者角色名
_watchdog_idle_warning() {
    local tid="$1"
    local claimer="$2"

    emit_event "task.idle_warning" "" "task_id=$tid" "claimer=$claimer"

    local notify_id="sys-idle-warn-$(date +%s)-${tid}"
    mkdir -p "${INBOX_DIR}/inspector"
    jq -n \
        --arg id "$notify_id" \
        --arg from "watchdog" \
        --arg to "inspector" \
        --arg content "[空闲告警] 工蜂 $claimer 的 pane 处于空闲状态，但任务 $tid 仍未完成。请检查是否需要介入。" \
        --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
        --arg status "pending" \
        --arg priority "normal" \
        '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority}' \
        > "${INBOX_DIR}/inspector/${notify_id}.json"

    log_info "[watchdog] 空闲告警: 任务 $tid, 认领者 $claimer"
}

# 检查单个 processing 任务（提取为函数，确保 local 变量作用域正确）
# 参数:
#   $1 - 任务文件路径
_watchdog_check_one_task() {
    local f="$1"
    [[ -f "$f" ]] || return 0

    # 读取任务元数据（单次 jq 调用，SOH 分隔符避免字段含 tab）
    local meta
    meta=$(jq -r '[.id, (.claimed_by // ""), (.claimed_at // "")] | join("\u0001")' "$f" 2>/dev/null) || return 0
    local tid claimed_by claimed_at
    IFS=$'\001' read -r tid claimed_by claimed_at <<< "$meta"

    [[ -n "$tid" && -n "$claimed_by" ]] || return 0

    # --- 检测 1: pane 存活检测 ---
    local pane_target=""
    if [[ -f "$STATE_FILE" ]]; then
        pane_target=$(jq -r --arg role "$claimed_by" \
            '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
    fi

    local pane_alive=true
    if [[ -z "$pane_target" || "$pane_target" == "null" ]]; then
        pane_alive=false
    elif ! tmux display-message -t "${SESSION_NAME}:${pane_target}" -p '#{pane_id}' &>/dev/null; then
        pane_alive=false
    fi

    if [[ "$pane_alive" == false ]]; then
        _watchdog_recover_task "$f" "$tid" "liveness" "$claimed_by"
        return 0
    fi

    # --- 检测 2: TTL 超时检测 ---
    if [[ "$TASK_PROCESSING_TTL" -gt 0 && -n "$claimed_at" ]]; then
        local now claimed_epoch
        now=$(date +%s)
        # macOS: date -j -f, Linux: date -d
        claimed_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$claimed_at" +%s 2>/dev/null \
            || date -d "$claimed_at" +%s 2>/dev/null \
            || echo "0")
        # 时间解析失败（epoch=0）时跳过 TTL 检测，避免误触发恢复
        if [[ "$claimed_epoch" != "0" && $((now - claimed_epoch)) -ge $TASK_PROCESSING_TTL ]]; then
            _watchdog_recover_task "$f" "$tid" "ttl" "$claimed_by"
            return 0
        fi
    fi

    # --- 检测 3: 空闲检测（pane 存活但 idle） ---
    if [[ -n "$pane_target" ]] && check_prompt "$pane_target" 2>/dev/null; then
        _watchdog_idle_warning "$tid" "$claimed_by"
    fi
}

# =============================================================================
# 主函数: 启动看门狗守护进程
# =============================================================================

# 启动后台守护进程，定期巡检 processing/ 中的任务
# 输出: 守护进程 PID (stdout)
start_task_watchdog() {
    (
        # 等待运行时目录就绪
        while [[ ! -d "$TASKS_DIR/processing" ]]; do sleep 1; done

        while true; do
            sleep "$WATCHDOG_INTERVAL"

            # 扫描 processing/ 目录
            shopt -s nullglob
            for f in "$TASKS_DIR/processing/"*.json; do
                _watchdog_check_one_task "$f"
            done
            shopt -u nullglob
        done
    ) &
    echo $!
}
