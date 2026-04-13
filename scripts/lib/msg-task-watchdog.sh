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

# WATCHDOG_INTERVAL / TASK_PROCESSING_TTL 由 config/defaults.conf 统一定义

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

    # 读取重试信息（兼容旧 JSON: // 0 / // 3）
    local retry_count max_retries
    retry_count=$(jq -r '.retry_count // 0' "$task_file" 2>/dev/null)
    max_retries=$(jq -r '.max_retries // 3' "$task_file" 2>/dev/null)

    local new_count=$((retry_count + 1))
    local now_ts
    now_ts=$(get_timestamp)

    # 构造 retry_history 条目
    local history_entry
    history_entry=$(jq -n \
        --arg failed_at "$now_ts" \
        --arg reason "watchdog:$reason" \
        --arg failed_by "$original_claimer" \
        '{failed_at: $failed_at, reason: $reason, failed_by: $failed_by}')

    local reason_text=""
    case "$reason" in
        liveness) reason_text="工蜂 pane 已崩溃" ;;
        ttl)      reason_text="处理超时 (TTL=${TASK_PROCESSING_TTL}s)" ;;
    esac

    if [[ $new_count -gt $max_retries ]]; then
        # === 重试耗尽: 移入 failed/ ===
        mkdir -p "$TASKS_DIR/failed"
        local tmp="$TASKS_DIR/processing/${tid}.json.tmp"
        if ! jq \
            --argjson new_count "$new_count" \
            --arg now_ts "$now_ts" \
            --argjson entry "$history_entry" \
            '
            .status = "failed"
            | .claimed_by = null
            | .claimed_at = null
            | .retry_count = $new_count
            | .failed_at = $now_ts
            | .fail_reason = "watchdog: 重试耗尽"
            | .retry_history = ((.retry_history // []) + [$entry])
            | .flow_log = ((.flow_log // []) + [{
                ts: $now_ts, action: "watchdog_exhausted",
                from_status: "processing", to_status: "failed",
                actor: "watchdog", detail: "重试耗尽"
              }])
            ' "$task_file" > "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            return 1
        fi

        if ! mv "$tmp" "$TASKS_DIR/failed/$tid.json" 2>/dev/null; then
            rm -f "$tmp"
            return 0
        fi
        rm -f "$task_file"
        rm -f "$TASKS_DIR/processing/${tid}.op.lock" "$TASKS_DIR/processing/${tid}.compose.lock" 2>/dev/null
        # 任务永久失败（终态），用 tolerant 释放以便锁表损坏时打标记
        type _release_resources_tolerant &>/dev/null && _release_resources_tolerant "$tid"

        emit_event "task.exhausted" "" "task_id=$tid" "retry_count=$new_count" "max_retries=$max_retries" "reason=watchdog:$reason"

        # 通知 inspector（高优先级）
        _unified_notify "inspector" \
            "[任务失败] 任务 $tid 重试耗尽 ($new_count/$max_retries)。原因: ${reason_text}。原认领者: ${original_claimer}。请人工介入。" \
            "task.exhausted" "high"

        log_info "[watchdog] 任务重试耗尽: $tid ($new_count/$max_retries, 原因: $reason_text, 原认领者: $original_claimer)"

        # 级联失败：依赖此任务的 blocked 任务也标记为 failed
        type _cascade_fail_blocked &>/dev/null && _cascade_fail_blocked "$tid"
    else
        # === 正常恢复: 移回 pending/ ===
        # 计算退避延迟（使用 WATCHDOG_INTERVAL 作为基础，避免快速翻车循环）
        local delay=$(( (1 << new_count) * ${TASK_RETRY_BASE_DELAY:-60} ))
        local retry_after
        retry_after=$(date -v+${delay}S "+$LOG_TIMESTAMP_FORMAT" 2>/dev/null \
            || date -d "+${delay} seconds" "+$LOG_TIMESTAMP_FORMAT" 2>/dev/null \
            || echo "")

        mkdir -p "$TASKS_DIR/pending"
        local tmp="$TASKS_DIR/processing/${tid}.json.tmp"
        if ! jq \
            --argjson new_count "$new_count" \
            --arg now_ts "$now_ts" \
            --arg retry_after "$retry_after" \
            --argjson entry "$history_entry" \
            '
            .status = "pending"
            | .claimed_by = null
            | .claimed_at = null
            | .retry_count = $new_count
            | .failed_at = $now_ts
            | .retry_after = $retry_after
            | .retry_history = ((.retry_history // []) + [$entry])
            | .flow_log = ((.flow_log // []) + [{
                ts: $now_ts, action: "watchdog_retry",
                from_status: "processing", to_status: "pending",
                actor: "watchdog", detail: ("重试 " + ($new_count | tostring))
              }])
            ' "$task_file" > "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            return 1  # jq 失败，保留原文件不动
        fi

        # 原子 mv 到 pending/（防并发重复恢复）
        if ! mv "$tmp" "$TASKS_DIR/pending/$tid.json" 2>/dev/null; then
            rm -f "$tmp"
            return 0  # 被其他进程抢先处理
        fi
        rm -f "$task_file"
        rm -f "$TASKS_DIR/processing/${tid}.op.lock" "$TASKS_DIR/processing/${tid}.compose.lock" 2>/dev/null
        # 任务回 pending，原 claimed_by 可能离线，必须释放锁否则死锁
        type _release_resources &>/dev/null && _release_resources "$tid"

        # 发射恢复事件（含 retry_count）
        emit_event "task.recovered.${reason}" "" "task_id=$tid" "original_claimer=$original_claimer" "retry_count=$new_count"

        # 通知 inspector（高优先级）
        _unified_notify "inspector" \
            "[任务恢复] 任务 $tid 已从 processing 恢复到 pending (重试 $new_count/$max_retries)。原因: ${reason_text}。原认领者: ${original_claimer}。" \
            "task.recovered" "high"

        log_info "[watchdog] 已恢复任务: $tid (重试 $new_count/$max_retries, 原因: $reason_text, 原认领者: $original_claimer)"
    fi
}

# 发送空闲告警到 inspector
# 参数:
#   $1 - 任务 ID
#   $2 - 认领者角色名
_watchdog_idle_warning() {
    local tid="$1"
    local claimer="$2"

    emit_event "task.idle_warning" "" "task_id=$tid" "claimer=$claimer"

    _unified_notify "inspector" \
        "[空闲告警] 工蜂 $claimer 的 pane 处于空闲状态，但任务 $tid 仍未完成。请检查是否需要介入。" \
        "task.idle_warning"

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

    # --- 检测 1: pane 存活检测 ---（claimed_by 存储的是 instance）
    local pane_target=""
    if [[ -f "$STATE_FILE" ]]; then
        pane_target=$(_resolve_pane_by_id "$claimed_by")
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
        claimed_epoch=$(date -j -f "${LOG_TIMESTAMP_FORMAT:-%Y-%m-%d %H:%M:%S}" "$claimed_at" +%s 2>/dev/null \
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
# 日志轮转检查（集成到看门狗巡检循环）
# =============================================================================

# _file_mtime / _file_size 定义在 swarm-lib.sh 中

# 检查并轮转所有日志文件 + 统一归档清理
_check_and_rotate_logs() {
    local now
    now=$(date +%s)

    (  # subshell 隔离 nullglob，避免提前退出时影响调用者
    shopt -s nullglob

    # === 1. 角色日志: 按大小轮转（copy-truncate，无需中断 pipe-pane） ===
    for log_file in "$LOGS_DIR"/*.log; do
        [[ -f "$log_file" ]] || continue
        local file_size
        file_size=$(_file_size "$log_file")
        if [[ "$file_size" -ge "$LOG_MAX_SIZE" ]]; then
            _rotate_file "$log_file"
            log_info "[watchdog] 日志轮转: $log_file (大小: $file_size)"
        fi
    done

    # === 2. 事件日志: 按大小轮转 ===
    if [[ -f "$EVENTS_LOG" ]]; then
        local events_size
        events_size=$(_file_size "$EVENTS_LOG")
        if [[ "$events_size" -ge "$LOG_MAX_SIZE" ]]; then
            (flock -x 200; _rotate_file "$EVENTS_LOG") 200>"${EVENTS_LOG}.lock"
            log_info "[watchdog] 事件日志轮转: $EVENTS_LOG (大小: $events_size)"
        fi
    fi

    # === 3. 质量门日志: 按 GATE_LOG_TTL 清理 ===
    local gate_logs_dir="${GATE_LOGS_DIR:-$RUNTIME_DIR/gate-logs}"
    if [[ -d "$gate_logs_dir" ]]; then
        for gate_log in "$gate_logs_dir"/*.log; do
            [[ -f "$gate_log" ]] || continue
            if [[ $(( now - $(_file_mtime "$gate_log") )) -ge "$GATE_LOG_TTL" ]]; then
                rm -f "$gate_log"
                log_info "[watchdog] 清理过期质量门日志: $gate_log"
            fi
        done
    fi

    # === 4. 统一归档清理: 所有轮转副本按 LOG_RETENTION_TTL 清理 ===
    # 覆盖: 角色日志轮转副本 + 事件日志轮转副本
    local retention="$LOG_RETENTION_TTL"
    local cleaned=0

    # 角色日志轮转副本: runtime/logs/*.log.YYYY-MM-DD*
    for f in "$LOGS_DIR"/*.log.*; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *.lock ]] && continue
        if [[ $(( now - $(_file_mtime "$f") )) -ge "$retention" ]]; then
            rm -f "$f"
            ((cleaned++)) || true
        fi
    done

    # 事件日志轮转副本: runtime/events.jsonl.YYYY-MM-DD*
    for f in "${EVENTS_LOG}."*; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *.lock ]] && continue
        if [[ $(( now - $(_file_mtime "$f") )) -ge "$retention" ]]; then
            rm -f "$f"
            ((cleaned++)) || true
        fi
    done

    # swarm-stop 归档文件: runtime/logs/archive/*.tar.gz
    local archive_dir="$LOGS_DIR/archive"
    if [[ -d "$archive_dir" ]]; then
        for f in "$archive_dir"/*.tar.gz; do
            [[ -f "$f" ]] || continue
            if [[ $(( now - $(_file_mtime "$f") )) -ge "$retention" ]]; then
                rm -f "$f"
                ((cleaned++)) || true
            fi
        done
    fi

    [[ $cleaned -gt 0 ]] && log_info "[watchdog] 归档清理: 删除 $cleaned 个超过 ${retention}s 的旧日志"

    )  # subshell end
}

# =============================================================================
# 子任务停滞检测
# =============================================================================

# 检查已拆分的父任务是否存在子任务停滞
# 遍历 processing/ 中 split_status="split" 的父任务，检测子任务进度
_watchdog_check_subtask_stall() {
    shopt -s nullglob
    for f in "$TASKS_DIR/processing/"*.json; do
        [[ -f "$f" ]] || continue

        local split_status
        split_status=$(jq -r '.split_status // ""' "$f" 2>/dev/null)
        [[ "$split_status" == "split" ]] || continue

        local parent_id
        parent_id=$(jq -r '.id' "$f" 2>/dev/null)

        # 统计子任务进度
        local completed=0 failed=0 processing=0 pending=0 blocked=0
        local latest_activity=0

        while IFS= read -r sub_id; do
            [[ -z "$sub_id" ]] && continue
            if [[ -f "$TASKS_DIR/completed/$sub_id.json" ]]; then
                ((completed++)) || true
                local sub_completed_at
                sub_completed_at=$(jq -r '.completed_at // ""' "$TASKS_DIR/completed/$sub_id.json" 2>/dev/null)
                if [[ -n "$sub_completed_at" ]]; then
                    local sub_cat_epoch
                    sub_cat_epoch=$(date -j -f "${LOG_TIMESTAMP_FORMAT:-%Y-%m-%d %H:%M:%S}" "$sub_completed_at" +%s 2>/dev/null \
                        || date -d "$sub_completed_at" +%s 2>/dev/null || echo "0")
                    [[ "$sub_cat_epoch" -gt "$latest_activity" ]] && latest_activity="$sub_cat_epoch"
                fi
            elif [[ -f "$TASKS_DIR/failed/$sub_id.json" ]]; then
                ((failed++)) || true
            elif [[ -f "$TASKS_DIR/processing/$sub_id.json" ]]; then
                ((processing++)) || true
                local clat
                clat=$(jq -r '.claimed_at // ""' "$TASKS_DIR/processing/$sub_id.json" 2>/dev/null)
                if [[ -n "$clat" ]]; then
                    local clat_epoch
                    clat_epoch=$(date -j -f "${LOG_TIMESTAMP_FORMAT:-%Y-%m-%d %H:%M:%S}" "$clat" +%s 2>/dev/null \
                        || date -d "$clat" +%s 2>/dev/null || echo "0")
                    [[ "$clat_epoch" -gt "$latest_activity" ]] && latest_activity="$clat_epoch"
                fi
            elif [[ -f "$TASKS_DIR/pending/$sub_id.json" ]]; then
                ((pending++)) || true
            elif [[ -f "$TASKS_DIR/blocked/$sub_id.json" ]]; then
                ((blocked++)) || true
            fi
        done < <(jq -r '.subtasks // [] | .[]' "$f" 2>/dev/null)

        # 如果有子任务在 processing → 跳过（已有 liveness/TTL 检测覆盖）
        [[ $processing -gt 0 ]] && continue

        # 如果有失败的子任务 → 通知 inspector "建议 re-split"（小时级去重）
        if [[ $failed -gt 0 ]]; then
            local hour_window=$(( $(date +%s) / 3600 ))
            local notify_id="sys-subtask-fail-${hour_window}-${parent_id}"
            mkdir -p "${MESSAGES_DIR}/inbox/inspector"
            # 同一小时内不重复发送
            [[ -f "${MESSAGES_DIR}/inbox/inspector/${notify_id}.json" ]] && continue
            jq -n \
                --arg id "$notify_id" \
                --arg from "watchdog" \
                --arg to "inspector" \
                --arg content "[子任务失败] 父任务 $parent_id 有 $failed 个子任务失败 (完成: $completed, 待认领: $pending, 阻塞: $blocked)。建议执行 re-split: swarm-msg.sh re-split $parent_id" \
                --arg timestamp "$(get_timestamp)" \
                --arg status "pending" \
                --arg priority "high" \
                --arg category "task.subtask_failed" \
                '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority, category:$category}' \
                | safe_write "${MESSAGES_DIR}/inbox/inspector/${notify_id}.json" --lock
            log_info "[watchdog] 子任务失败告警: 父任务 $parent_id ($failed 个失败)"
            continue
        fi

        # 无活动时间 → 回退到父任务 claimed_at
        if [[ "$latest_activity" -eq 0 ]]; then
            local parent_claimed
            parent_claimed=$(jq -r '.claimed_at // ""' "$f" 2>/dev/null)
            if [[ -n "$parent_claimed" ]]; then
                latest_activity=$(date -j -f "${LOG_TIMESTAMP_FORMAT:-%Y-%m-%d %H:%M:%S}" "$parent_claimed" +%s 2>/dev/null \
                    || date -d "$parent_claimed" +%s 2>/dev/null || echo "0")
            fi
        fi

        # 距今超过 SUBTASK_STALL_TTL → 通知 inspector "子任务停滞"（小时级去重）
        if [[ "$latest_activity" -gt 0 ]]; then
            local now
            now=$(date +%s)
            if [[ $((now - latest_activity)) -ge ${SUBTASK_STALL_TTL:-7200} ]]; then
                local hour_window=$(( now / 3600 ))
                local notify_id="sys-subtask-stall-${hour_window}-${parent_id}"
                mkdir -p "${MESSAGES_DIR}/inbox/inspector"
                # 同一小时内不重复发送
                [[ -f "${MESSAGES_DIR}/inbox/inspector/${notify_id}.json" ]] && continue
                jq -n \
                    --arg id "$notify_id" \
                    --arg from "watchdog" \
                    --arg to "inspector" \
                    --arg content "[子任务停滞] 父任务 $parent_id 的子任务超过 ${SUBTASK_STALL_TTL:-7200}s 无活动 (完成: $completed, 待认领: $pending, 阻塞: $blocked)。请检查。" \
                    --arg timestamp "$(get_timestamp)" \
                    --arg status "pending" \
                    --arg priority "high" \
                    --arg category "task.subtask_stall" \
                    '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority, category:$category}' \
                    | safe_write "${MESSAGES_DIR}/inbox/inspector/${notify_id}.json" --lock
                log_info "[watchdog] 子任务停滞: 父任务 $parent_id (无活动超过 ${SUBTASK_STALL_TTL:-7200}s)"
            fi
        fi
    done

    # === 检测 escalated 超时（上报后 supervisor 迟迟未处理）===
    for f in "$TASKS_DIR/processing/"*.json; do
        [[ -f "$f" ]] || continue

        local esc_status esc_at
        esc_status=$(jq -r '.escalated.status // ""' "$f" 2>/dev/null)
        [[ "$esc_status" == "pending" ]] || continue

        local tid
        tid=$(jq -r '.id' "$f" 2>/dev/null)

        esc_at=$(jq -r '.escalated.escalated_at // ""' "$f" 2>/dev/null)
        [[ -n "$esc_at" && "$esc_at" != "null" ]] || continue

        local esc_epoch
        esc_epoch=$(date -j -f "${LOG_TIMESTAMP_FORMAT:-%Y-%m-%d %H:%M:%S}" "$esc_at" +%s 2>/dev/null \
            || date -d "$esc_at" +%s 2>/dev/null || echo "0")
        [[ "$esc_epoch" -gt 0 ]] || continue

        local now
        now=$(date +%s)
        if [[ $((now - esc_epoch)) -ge ${ESCALATE_STALL_TTL:-3600} ]]; then
            local hour_window=$(( now / 3600 ))
            local base_notify_id="sys-escalate-stall-${hour_window}-${tid}"
            # 通知所有 supervisor 实例
            while IFS='|' read -r _p _inst; do
                [[ -z "$_inst" ]] && continue
                local per_inst_id="${base_notify_id}-${_inst}"
                mkdir -p "${MESSAGES_DIR}/inbox/${_inst}"
                [[ -f "${MESSAGES_DIR}/inbox/${_inst}/${per_inst_id}.json" ]] && continue
                jq -n \
                    --arg id "$per_inst_id" \
                    --arg from "watchdog" \
                    --arg to "$_inst" \
                    --arg content "[上报超时] 任务 $tid 已上报超过 ${ESCALATE_STALL_TTL:-3600}s 未被处理。请尽快使用 expand-subtask 展开或用 claim 重新认领。" \
                    --arg timestamp "$(get_timestamp)" \
                    --arg status "pending" \
                    --arg priority "high" \
                    --arg category "task.escalate_stall" \
                    '{id:$id,from:$from,to:$to,content:$content,timestamp:$timestamp,status:$status,reply_to:null,priority:$priority,category:$category}' \
                    | safe_write "${MESSAGES_DIR}/inbox/${_inst}/${per_inst_id}.json" --lock
            done < <(resolve_role_to_all_panes "supervisor")
            log_info "[watchdog] 上报超时: 任务 $tid (上报超过 ${ESCALATE_STALL_TTL:-3600}s)"
        fi
    done

    shopt -u nullglob
}

# =============================================================================
# pending_review 超时检测
# =============================================================================

# 检查 pending_review/ 中任务是否超过 PENDING_REVIEW_TTL 未被审批
# 超时后通知 human 介入
_watchdog_check_pending_review() {
    [[ -d "$TASKS_DIR/pending_review" ]] || return 0

    shopt -s nullglob
    for f in "$TASKS_DIR/pending_review/"*.json; do
        [[ -f "$f" ]] || continue

        local tid review_requested_at
        tid=$(jq -r '.id' "$f" 2>/dev/null)
        review_requested_at=$(jq -r '.review_requested_at // ""' "$f" 2>/dev/null)
        [[ -n "$review_requested_at" && "$review_requested_at" != "null" ]] || continue

        # 解析时间戳: 先尝试提取纯日期时间部分（去掉时区等后缀），再解析
        local req_epoch=0
        local clean_ts="${review_requested_at%% [A-Z]*}"  # "2025-01-01 12:00:00 CST" → "2025-01-01 12:00:00"
        req_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$clean_ts" +%s 2>/dev/null \
            || date -d "$review_requested_at" +%s 2>/dev/null || echo "0")
        [[ "$req_epoch" -gt 0 ]] || continue

        local now
        now=$(date +%s)
        if [[ $((now - req_epoch)) -ge ${PENDING_REVIEW_TTL:-1800} ]]; then
            # 小时级去重
            local hour_window=$(( now / 3600 ))
            local notify_id="sys-review-timeout-${hour_window}-${tid}"
            mkdir -p "${MESSAGES_DIR}/inbox/human"
            [[ -f "${MESSAGES_DIR}/inbox/human/${notify_id}.json" ]] && continue

            local task_title claimed_by
            task_title=$(jq -r '.title // .id' "$f" 2>/dev/null)
            claimed_by=$(jq -r '.claimed_by // "unknown"' "$f" 2>/dev/null)

            jq -n \
                --arg id "$notify_id" \
                --arg from "watchdog" \
                --arg to "human" \
                --arg content "[审批超时] 任务 $tid ($task_title) 在 pending_review 状态超过 ${PENDING_REVIEW_TTL:-1800}s 未被审批。原工蜂: $claimed_by。请手动处理: swarm-msg.sh approve-task $tid 或 swarm-msg.sh reject-task $tid" \
                --arg timestamp "$(get_timestamp)" \
                --arg status "pending" \
                --arg priority "high" \
                --arg category "task.review_timeout" \
                '{id:$id,from:$from,to:$to,content:$content,timestamp:$timestamp,status:$status,reply_to:null,priority:$priority,category:$category}' \
                | safe_write "${MESSAGES_DIR}/inbox/human/${notify_id}.json" --lock

            # 也再次提醒 inspector
            _unified_notify "inspector" \
                "[审批超时] 任务 $tid ($task_title) 等待审批已超时。请尽快处理。" \
                "task.review_timeout" "high"

            log_info "[watchdog] 审批超时: 任务 $tid (等待超过 ${PENDING_REVIEW_TTL:-1800}s)"
        fi
    done
    shopt -u nullglob
}

# =============================================================================
# Pending 任务堆积检测
# =============================================================================

# 检测 pending/ 中是否有大量任务堆积，超阈值时通知 supervisor 评估
# 看门狗只负责检测和通知，不做扩展决策
_watchdog_check_pending_pileup() {
    [[ -d "$TASKS_DIR/pending" ]] || return 0

    local pending_count=0
    local now_epoch
    now_epoch=$(date +%s)

    shopt -s nullglob
    for f in "$TASKS_DIR/pending/"*.json; do
        [[ -f "$f" ]] || continue
        # 排除 retry_after 尚未到期的任务
        local retry_after
        retry_after=$(jq -r '.retry_after // ""' "$f" 2>/dev/null)
        if [[ -n "$retry_after" && "$retry_after" != "null" ]]; then
            local clean_ts="${retry_after%% [A-Z]*}"
            local retry_epoch
            retry_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$clean_ts" +%s 2>/dev/null \
                || date -d "$retry_after" +%s 2>/dev/null || echo "0")
            [[ "$retry_epoch" -gt "$now_epoch" ]] && continue
        fi
        ((pending_count++)) || true
    done
    shopt -u nullglob

    # 未超阈值，直接返回
    [[ $pending_count -ge ${PENDING_PILEUP_THRESHOLD:-5} ]] || return 0

    # 固定间隔去重: 同一窗口内不重复通知（默认 30min，可配置 PENDING_PILEUP_NOTIFY_INTERVAL）
    local notify_interval="${PENDING_PILEUP_NOTIFY_INTERVAL:-1800}"
    local notify_window=$(( now_epoch / notify_interval ))
    local notify_id="sys-pending-pileup-${notify_window}"

    # 通知所有 supervisor 实例
    local notified=false
    while IFS='|' read -r _pane _inst _role; do
        [[ -n "$_inst" ]] || continue
        local per_inst_id="${notify_id}-${_inst}"
        mkdir -p "${MESSAGES_DIR}/inbox/${_inst}"
        [[ -f "${MESSAGES_DIR}/inbox/${_inst}/${per_inst_id}.json" ]] && continue

        jq -n \
            --arg id "$per_inst_id" \
            --arg from "watchdog" \
            --arg to "$_inst" \
            --arg content "[任务堆积] 当前有 ${pending_count} 个 pending 任务未被认领（阈值: ${PENDING_PILEUP_THRESHOLD:-5}）。请评估是否需要: 1) 加入更多工蜂角色 2) 扩展 supervisor 编排能力 (swarm-msg.sh request-supervisor \"原因\")" \
            --arg timestamp "$(get_timestamp)" \
            --arg status "pending" \
            --arg priority "high" \
            --arg category "task.pending_pileup" \
            '{id:$id,from:$from,to:$to,content:$content,timestamp:$timestamp,status:$status,reply_to:null,priority:$priority,category:$category}' \
            | safe_write "${MESSAGES_DIR}/inbox/${_inst}/${per_inst_id}.json" --lock
        notified=true
    done < <(resolve_role_to_all_panes "supervisor")

    [[ "$notified" == "true" ]] && \
        log_info "[watchdog] 任务堆积告警: ${pending_count} 个 pending 任务 (阈值: ${PENDING_PILEUP_THRESHOLD:-5})"
}

# =============================================================================
# 主函数: 启动看门狗守护进程
# =============================================================================

# 启动后台守护进程，定期巡检 processing/ 中的任务 + 日志轮转
# 输出: 守护进程 PID (stdout)
start_task_watchdog() {
    (
        # 等待运行时目录就绪
        while [[ ! -d "$TASKS_DIR/processing" ]]; do sleep 1; done

        local last_rotate_check=0

        while true; do
            sleep "$WATCHDOG_INTERVAL"

            # 原有：任务健康检查
            shopt -s nullglob
            for f in "$TASKS_DIR/processing/"*.json; do
                _watchdog_check_one_task "$f"
            done
            shopt -u nullglob

            # 子任务停滞检测
            _watchdog_check_subtask_stall

            # pending_review 审批超时检测
            _watchdog_check_pending_review

            # pending 任务堆积检测（通知 supervisor 评估）
            _watchdog_check_pending_pileup

            # 日志轮转检查（按 LOG_ROTATE_INTERVAL 频率）
            local now
            now=$(date +%s)
            if (( now - last_rotate_check >= LOG_ROTATE_INTERVAL )); then
                _check_and_rotate_logs
                last_rotate_check=$now
            fi
        done
    ) >/dev/null &
    echo $!
}
