#!/usr/bin/env bash
################################################################################
# swarm-msg.sh - CLI-to-CLI 自主消息工具
#
# 让蜂群内的 CLI 角色能够自主通讯，无需外部编排。
# 消息通过文件系统持久化，通过 tmux paste-buffer 即时推送到目标 pane。
#
# 用法:
#   swarm-msg.sh send <to> "<content>"               发送消息
#   swarm-msg.sh reply <msg-id> "<content>"          回复消息
#   swarm-msg.sh read                                读取收件箱未读消息
#   swarm-msg.sh wait [--from <role>] [--timeout 60] 等待新消息
#   swarm-msg.sh list-roles                          列出所有在线角色
#   swarm-msg.sh broadcast "<content>"               广播消息
#   swarm-msg.sh mark-read [msg-id|--all]            标记消息已读
#   swarm-msg.sh publish <type> "<title>" [选项]      发布任务到中心队列
#   swarm-msg.sh list-tasks [选项]                    列出队列任务
#   swarm-msg.sh claim <task-id>                      认领任务
#   swarm-msg.sh complete-task <task-id> "<result>"   完成任务
#
# 环境变量:
#   SWARM_ROLE    当前角色名（swarm-start.sh 自动设置）
#   SWARM_ROOT    Swarm 根目录（默认: 脚本所在目录的父目录）
#   SESSION_NAME  Tmux session 名称（默认: swarm）
################################################################################

set -euo pipefail

# =============================================================================
# 配置
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/swarm-lib.sh"

# 加载子模块
source "${SCRIPT_DIR}/lib/msg-story.sh"
source "${SCRIPT_DIR}/lib/msg-quality-gate.sh"
source "${SCRIPT_DIR}/lib/msg-task-queue.sh"
source "${SCRIPT_DIR}/lib/msg-task-watchdog.sh"

# 加载项目级配置（从 state.json 推断 PROJECT_DIR）
if [[ -z "${PROJECT_DIR:-}" && -f "$STATE_FILE" ]]; then
    PROJECT_DIR=$(jq -r '.project // ""' "$STATE_FILE" 2>/dev/null)
fi
load_project_config

# =============================================================================
# 工具函数
# =============================================================================

info() { echo "[swarm-msg] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }

# 生成消息 ID
gen_msg_id() {
    echo "msg-$(date +%s%N 2>/dev/null || date +%s)-$$-${RANDOM}${RANDOM}"
}

# =============================================================================
# 角色身份检测
# =============================================================================

# 自动检测当前角色（优先用 SWARM_ROLE 环境变量，其次通过 tmux pane 推断）
detect_my_role() {
    # 1. 环境变量
    if [[ -n "${SWARM_ROLE:-}" ]]; then
        echo "$SWARM_ROLE"
        return 0
    fi

    # 2. 通过当前 tmux pane 推断
    if [[ -f "$STATE_FILE" ]] && command -v tmux &>/dev/null; then
        local current_pane
        current_pane=$(tmux display-message -p '#{window_index}.#{pane_index}' 2>/dev/null || true)
        if [[ -n "$current_pane" ]]; then
            local role
            role=$(jq -r --arg pane "$current_pane" \
                '.panes[] | select(.pane == $pane) | .role' "$STATE_FILE" 2>/dev/null || true)
            if [[ -n "$role" && "$role" != "null" ]]; then
                echo "$role"
                return 0
            fi
        fi
    fi

    die "无法检测当前角色。请设置 SWARM_ROLE 环境变量。"
}

# 自动检测当前实例（唯一标识，用于消息路由和 inbox 目录）
detect_my_instance() {
    # 1. SWARM_INSTANCE 环境变量（优先）
    if [[ -n "${SWARM_INSTANCE:-}" ]]; then
        echo "$SWARM_INSTANCE"
        return 0
    fi

    # 2. 通过当前 tmux pane 推断
    if [[ -f "$STATE_FILE" ]] && command -v tmux &>/dev/null; then
        local current_pane
        current_pane=$(tmux display-message -p '#{window_index}.#{pane_index}' 2>/dev/null || true)
        if [[ -n "$current_pane" ]]; then
            local inst
            inst=$(jq -r --arg pane "$current_pane" \
                '.panes[] | select(.pane == $pane) | .instance' "$STATE_FILE" 2>/dev/null || true)
            if [[ -n "$inst" && "$inst" != "null" ]]; then
                echo "$inst"
                return 0
            fi
        fi
    fi

    # 3. 回退: SWARM_ROLE（首实例 instance==role）
    if [[ -n "${SWARM_ROLE:-}" ]]; then
        log_warn "SWARM_INSTANCE 未设置，使用 SWARM_ROLE='$SWARM_ROLE' 回退（多实例场景可能导致身份混淆）"
        echo "$SWARM_ROLE"
        return 0
    fi

    die "无法检测当前实例。请设置 SWARM_INSTANCE 或 SWARM_ROLE 环境变量。"
}

# =============================================================================
# 消息推送（tmux paste-buffer）
# =============================================================================

# 将消息通知推送到目标 pane
# 使用命名 buffer 避免并发广播时全局 buffer 竞态
push_to_pane() {
    local pane_target="$1"
    local notification="$2"

    local tmp_file
    tmp_file=$(mktemp "${RUNTIME_DIR}/.msg-push-XXXXXX")
    trap "rm -f '$tmp_file'" RETURN
    printf '%s' "$notification" > "$tmp_file"

    if ! _pane_locked_paste_enter "$pane_target" "$tmp_file" 2>/dev/null; then
        log_warn "[push_to_pane] paste-buffer 失败: pane=$pane_target"
    fi
}

# =============================================================================
# 子命令: send
# =============================================================================

cmd_send() {
    local to_role="$1"
    local content="$2"
    local priority="${3:-normal}"

    local my_instance
    my_instance=$(detect_my_instance)

    # 解析目标（human 是特殊角色，不在 pane 中）
    local target_pane="" target_instance=""
    if [[ "$to_role" == "human" ]]; then
        target_instance="human"
    else
        local target_info
        target_info=$(resolve_role_to_pane "$to_role")
        target_pane=$(echo "$target_info" | cut -d'|' -f1)
        target_instance=$(echo "$target_info" | cut -d'|' -f2)
    fi

    # 创建消息
    local msg_id
    msg_id=$(gen_msg_id)

    mkdir -p "${INBOX_DIR}/${target_instance}"

    local msg_file="${INBOX_DIR}/${target_instance}/${msg_id}.json"
    jq -n \
        --arg id "$msg_id" \
        --arg from "$my_instance" \
        --arg to "$target_instance" \
        --arg content "$content" \
        --arg timestamp "$(get_timestamp)" \
        --arg status "pending" \
        --arg reply_to "" \
        --arg priority "$priority" \
        '{
            id: $id,
            from: $from,
            to: $to,
            content: $content,
            timestamp: $timestamp,
            status: $status,
            reply_to: (if $reply_to == "" then null else $reply_to end),
            priority: $priority
        }' | safe_write "$msg_file" --lock

    # 发射事件
    emit_event "message.sent" "$my_instance" "msg_id=$msg_id" "to=$target_instance" "priority=$priority"

    # 推送通知到目标 pane（human 没有 pane，只写 inbox）
    if [[ -n "$target_pane" ]]; then
        local notification
        notification="[Swarm 消息] 来自 ${my_instance}:
${content}

回复方式: swarm-msg.sh reply ${msg_id} \"你的回复\""

        push_to_pane "$target_pane" "$notification"
    fi

    info "消息已发送: $my_instance -> $target_instance (${msg_id})"
    echo "$msg_id"
}

# =============================================================================
# 子命令: reply
# =============================================================================

cmd_reply() {
    local original_msg_id="$1"
    local content="$2"

    local my_instance
    my_instance=$(detect_my_instance)

    # 查找原始消息（在自己的收件箱中）
    local original_msg_file=""
    if [[ -d "${INBOX_DIR}/${my_instance}" ]]; then
        original_msg_file=$(find "${INBOX_DIR}/${my_instance}" -name "${original_msg_id}.json" 2>/dev/null | head -1)
    fi
    # 也在 outbox 中查找（已标记已读的消息）
    if [[ -z "$original_msg_file" ]] && [[ -d "${OUTBOX_DIR}/${my_instance}" ]]; then
        original_msg_file=$(find "${OUTBOX_DIR}/${my_instance}" -name "${original_msg_id}.json" 2>/dev/null | head -1)
    fi

    [[ -n "$original_msg_file" ]] || die "找不到消息: $original_msg_id"

    # .from 字段存储的是发送者的 instance
    local from_instance
    from_instance=$(jq -r '.from' "$original_msg_file")

    # 解析目标（human 是特殊角色，不在 pane 中）
    local target_pane="" target_instance=""
    if [[ "$from_instance" == "human" ]]; then
        target_instance="human"
    else
        local target_info
        target_info=$(resolve_role_to_pane "$from_instance")
        target_pane=$(echo "$target_info" | cut -d'|' -f1)
        target_instance=$(echo "$target_info" | cut -d'|' -f2)
    fi

    # 创建回复消息
    local reply_id
    reply_id=$(gen_msg_id)

    mkdir -p "${INBOX_DIR}/${target_instance}"

    local reply_file="${INBOX_DIR}/${target_instance}/${reply_id}.json"
    jq -n \
        --arg id "$reply_id" \
        --arg from "$my_instance" \
        --arg to "$target_instance" \
        --arg content "$content" \
        --arg timestamp "$(get_timestamp)" \
        --arg status "pending" \
        --arg reply_to "$original_msg_id" \
        --arg priority "normal" \
        '{
            id: $id,
            from: $from,
            to: $to,
            content: $content,
            timestamp: $timestamp,
            status: $status,
            reply_to: $reply_to,
            priority: $priority
        }' | safe_write "$reply_file" --lock

    # 发射事件
    emit_event "message.replied" "$my_instance" "msg_id=$reply_id" "to=$target_instance" "reply_to=$original_msg_id"

    # 推送通知到目标 pane（human 没有 pane，只写 inbox）
    if [[ -n "$target_pane" ]]; then
        local notification
        notification="[Swarm 回复] 来自 ${my_instance} (回复 ${original_msg_id}):
${content}

回复方式: swarm-msg.sh reply ${reply_id} \"你的回复\""

        push_to_pane "$target_pane" "$notification"
    fi

    info "回复已发送: $my_instance -> $target_instance (${reply_id})"
    echo "$reply_id"
}

# =============================================================================
# 子命令: read
# =============================================================================

cmd_read() {
    local my_instance
    my_instance=$(detect_my_instance)

    local inbox="${INBOX_DIR}/${my_instance}"

    if [[ ! -d "$inbox" ]]; then
        echo "没有新消息。"
        return 0
    fi

    # 按优先级排序：urgent > high > normal > low，同优先级按文件名（时间戳）排序
    # 使用 find + xargs 分批传递，避免大量文件时超过 ARG_MAX
    local msg_files
    msg_files=$(
        find "$inbox" -maxdepth 1 -name '*.json' -type f -print0 2>/dev/null \
        | xargs -0 jq -r '
            ({"urgent":"0","high":"1","normal":"2","low":"3"}[.priority // "normal"] // "2")
            + "|" + input_filename
          ' 2>/dev/null \
        | sort -t'|' -k1,1n -k2,2 | cut -d'|' -f2
    )

    if [[ -z "$msg_files" ]]; then
        echo "没有新消息。"
        return 0
    fi

    # 加载已消费 ID 文件路径
    local consumed_file="$CONSUMED_IDS_DIR/${my_instance}.log"

    local display_count=0
    local -a new_consumed_ids=()
    local output=""

    while IFS= read -r msg_file; do
        [[ -f "$msg_file" ]] || continue
        local msg_id
        msg_id=$(jq -r '.id // ""' "$msg_file" 2>/dev/null)

        # 去重: 已消费的消息静默移到 outbox
        if [[ -n "$msg_id" ]] && _is_consumed "$consumed_file" "$msg_id"; then
            mkdir -p "${OUTBOX_DIR}/${my_instance}"
            mv "$msg_file" "${OUTBOX_DIR}/${my_instance}/" 2>/dev/null || true
            continue
        fi

        display_count=$((display_count + 1))
        [[ -n "$msg_id" ]] && new_consumed_ids+=("$msg_id")

        output+=$(jq -r '
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" +
            "  ID: \(.id)\n  来自: \(.from)\n  时间: \(.timestamp)\n" +
            (if .reply_to and .reply_to != "" and .reply_to != null then "  回复: \(.reply_to)\n" else "" end) +
            (if (.priority // "normal") != "normal" then "  优先级: \(.priority)\n" else "" end) +
            "  内容: \(.content)\n\n  回复: swarm-msg.sh reply \(.id) \"你的回复\""
        ' "$msg_file")
        output+=$'\n'
    done <<< "$msg_files"

    if [[ $display_count -eq 0 ]]; then
        echo "没有新消息。"
        return 0
    fi

    echo "收件箱有 ${display_count} 条未读消息:"
    echo ""
    echo "$output"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 批量标记已消费
    if [[ ${#new_consumed_ids[@]} -gt 0 ]]; then
        _mark_consumed "$my_instance" "${new_consumed_ids[@]}"
    fi
}

# =============================================================================
# 子命令: wait
# =============================================================================

cmd_wait() {
    local from_filter=""
    local timeout=60

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)    from_filter="$2"; shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            *)         die "wait: 未知参数 $1" ;;
        esac
    done

    local my_instance
    my_instance=$(detect_my_instance)

    info "等待新消息... (超时: ${timeout}s${from_filter:+, 来自: $from_filter})"

    local start_time
    start_time=$(date +%s)

    # 确保 events.jsonl 存在
    touch "$EVENTS_LOG"

    # 使用 tail -f 事件驱动，零 CPU 轮询
    exec 3< <(tail -f "$EVENTS_LOG" 2>/dev/null)
    trap "exec 3<&-" RETURN

    while true; do
        local remaining=$(( timeout - ($(date +%s) - start_time) ))
        if [[ $remaining -le 0 ]]; then
            info "等待超时 (${timeout}s)"
            return 1
        fi

        local line=""
        if IFS= read -t "$remaining" -r line <&3; then
            # 过滤 message.sent/replied/broadcast 事件
            local event_type
            event_type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null) || continue
            case "$event_type" in
                message.sent|message.replied|message.broadcast) ;;
                *) continue ;;
            esac

            # 检查目标是否为当前实例
            local event_to
            event_to=$(echo "$line" | jq -r '.data.to // ""' 2>/dev/null)
            if [[ "$event_type" != "message.broadcast" && "$event_to" != "$my_instance" ]]; then
                continue
            fi

            # 应用来源过滤
            local msg_from msg_id
            msg_from=$(echo "$line" | jq -r '.role // ""' 2>/dev/null)
            msg_id=$(echo "$line" | jq -r '.data.msg_id // ""' 2>/dev/null)
            if [[ -n "$from_filter" && "$msg_from" != "$from_filter" ]]; then
                continue
            fi

            info "收到新消息: 来自 $msg_from ($msg_id)"
            cmd_read
            return 0
        fi
    done
}

# =============================================================================
# 子命令: list-roles
# =============================================================================

cmd_list_roles() {
    [[ -f "$STATE_FILE" ]] || die "state.json 不存在，蜂群未启动？"

    echo "在线实例:"
    echo ""

    jq -r '.panes[] | "  \(.instance // .role)\(if .instance != .role then " (角色: \(.role))" else "" end)\(if .alias and .alias != "" then " (\(.alias))" else "" end) -> pane \(.pane) [\(.cli)]\(if .branch and .branch != "" then " branch:\(.branch)" else "" end)"' "$STATE_FILE"
}

# =============================================================================
# 子命令: broadcast
# =============================================================================

cmd_broadcast() {
    local content="$1"

    local my_instance
    my_instance=$(detect_my_instance)

    [[ -f "$STATE_FILE" ]] || die "state.json 不存在，蜂群未启动？"

    local msg_id
    msg_id=$(gen_msg_id)

    # 获取所有实例（排除自己）
    local instances
    instances=$(jq -r --arg me "$my_instance" '.panes[] | select(.instance != $me) | "\(.instance)|\(.pane)"' "$STATE_FILE")

    if [[ -z "$instances" ]]; then
        info "没有其他在线实例可以广播。"
        return 0
    fi

    local count=0
    while IFS='|' read -r inst pane; do
        # 为每个实例创建消息副本
        local individual_id="${msg_id}-${inst}"
        mkdir -p "${INBOX_DIR}/${inst}"

        jq -n \
            --arg id "$individual_id" \
            --arg from "$my_instance" \
            --arg to "$inst" \
            --arg content "$content" \
            --arg timestamp "$(get_timestamp)" \
            --arg status "pending" \
            --arg priority "normal" \
            '{
                id: $id,
                from: $from,
                to: $to,
                content: $content,
                timestamp: $timestamp,
                status: $status,
                reply_to: null,
                priority: $priority
            }' | safe_write "${INBOX_DIR}/${inst}/${individual_id}.json" --lock

        # 推送通知
        local notification
        notification="[Swarm 广播] 来自 ${my_instance}:
${content}

回复方式: swarm-msg.sh reply ${individual_id} \"你的回复\""

        push_to_pane "$pane" "$notification" 2>/dev/null || {
            info "警告: 推送通知到 ${inst} (pane ${pane}) 失败，跳过"
        }

        count=$((count + 1))
    done <<< "$instances"

    # 发射广播事件
    emit_event "message.broadcast" "$my_instance" "msg_id=$msg_id" "recipients=$count"

    info "广播已发送给 ${count} 个实例"
}

# =============================================================================
# 子命令: mark-read
# =============================================================================

cmd_mark_read() {
    local target="$1"

    local my_instance
    my_instance=$(detect_my_instance)

    local inbox="${INBOX_DIR}/${my_instance}"
    mkdir -p "${OUTBOX_DIR}/${my_instance}"

    if [[ "$target" == "--all" ]]; then
        # 标记所有消息为已读
        local count=0
        if [[ -d "$inbox" ]]; then
            for msg_file in "$inbox"/*.json; do
                [[ -f "$msg_file" ]] || continue
                mv "$msg_file" "${OUTBOX_DIR}/${my_instance}/"
                count=$((count + 1))
            done
        fi
        info "已标记 ${count} 条消息为已读"
    else
        # 标记指定消息为已读
        local msg_file="${inbox}/${target}.json"
        if [[ -f "$msg_file" ]]; then
            mv "$msg_file" "${OUTBOX_DIR}/${my_instance}/"
            info "消息 $target 已标记为已读"
        else
            die "找不到消息: $target"
        fi
    fi
}

# =============================================================================
# 消息去重辅助函数
# =============================================================================

# 已消费消息 ID 的存储目录
CONSUMED_IDS_DIR="${RUNTIME_DIR}/.consumed_ids"

# 消息去重: 检查 msg_id 是否已消费
# 格式: 每行 "epoch\tmsg_id"
# 参数: $1 - consumed_file, $2 - msg_id
# 返回: 0=已消费, 1=未消费
_is_consumed() {
    local consumed_file="$1" msg_id="$2"
    [[ -f "$consumed_file" ]] || return 1
    # 第二列匹配 msg_id
    awk -F'\t' -v id="$msg_id" '$2 == id { found=1; exit } END { exit !found }' "$consumed_file" 2>/dev/null
}

# 标记消息为已消费
# 格式: "epoch\tmsg_id"
# 参数: $1 - instance 名, $2... - msg_id 列表
_mark_consumed() {
    local instance="$1"; shift
    mkdir -p "$CONSUMED_IDS_DIR"
    local consumed_file="$CONSUMED_IDS_DIR/${instance}.log"
    local now
    now=$(date +%s)
    local id
    for id in "$@"; do
        printf '%s\t%s\n' "$now" "$id" >> "$consumed_file"
    done
}

# 清理已消费记录: 删除超过 TTL 的条目
# 参数: $1 - TTL (秒)
_cleanup_consumed_ids() {
    local ttl="${1:-$CLEANUP_TTL}"
    [[ -d "$CONSUMED_IDS_DIR" ]] || return 0
    local now
    now=$(date +%s)
    local cutoff=$(( now - ttl ))
    shopt -s nullglob
    for f in "$CONSUMED_IDS_DIR"/*.log; do
        [[ -f "$f" ]] || continue
        # 保留 epoch >= cutoff 的行
        awk -F'\t' -v cutoff="$cutoff" '$1 >= cutoff' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    done
    shopt -u nullglob
}

# =============================================================================
# 子命令: cleanup (清理过期消息和已完成任务)
# =============================================================================

cmd_cleanup() {
    local ttl="$CLEANUP_TTL"
    local dry_run=false
    local clean_gate=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ttl)        ttl="$2"; shift 2 ;;
            --dry-run)    dry_run=true; shift ;;
            --gate-logs)  clean_gate=true; shift ;;
            -*) die "cleanup: 未知选项 '$1'" ;;
            *)  die "cleanup: 多余参数 '$1'" ;;
        esac
    done

    local now
    now=$(date +%s)
    local cleaned_msgs=0 cleaned_tasks=0 cleaned_gate=0

    # 清理 outbox/ 中超过 TTL 的已读消息
    shopt -s nullglob
    for role_dir in "$OUTBOX_DIR"/*/; do
        [[ -d "$role_dir" ]] || continue
        for f in "$role_dir"*.json; do
            [[ -f "$f" ]] || continue
            local file_mtime
            file_mtime=$(_file_mtime "$f")
            if [[ $(( now - file_mtime )) -ge $ttl ]]; then
                if [[ "$dry_run" == true ]]; then
                    echo "[dry-run] 删除已发消息: $f"
                else
                    rm -f "$f"
                fi
                ((cleaned_msgs++)) || true
            fi
        done
    done

    # 清理 completed/ 中超过 TTL 的已完成任务
    for f in "$TASKS_DIR/completed/"*.json; do
        [[ -f "$f" ]] || continue
        local file_mtime
        file_mtime=$(_file_mtime "$f")
        if [[ $(( now - file_mtime )) -ge $ttl ]]; then
            if [[ "$dry_run" == true ]]; then
                echo "[dry-run] 删除已完成任务: $f"
            else
                rm -f "$f"
            fi
            ((cleaned_tasks++)) || true
        fi
    done

    # 清理过期质量门日志（--gate-logs 时启用）
    if [[ "$clean_gate" == true ]]; then
        local gate_ttl="$GATE_LOG_TTL"
        local gate_dir="${GATE_LOGS_DIR:-$RUNTIME_DIR/gate-logs}"
        if [[ -d "$gate_dir" ]]; then
            for f in "$gate_dir"/*.log; do
                [[ -f "$f" ]] || continue
                local file_mtime
                file_mtime=$(_file_mtime "$f")
                if [[ $(( now - file_mtime )) -ge $gate_ttl ]]; then
                    if [[ "$dry_run" == true ]]; then
                        echo "[dry-run] 删除质量门日志: $f"
                    else
                        rm -f "$f"
                    fi
                    ((cleaned_gate++)) || true
                fi
            done
        fi
    fi
    shopt -u nullglob

    # 清理过期的消息去重记录
    _cleanup_consumed_ids "$ttl"

    local mode_label=""
    [[ "$dry_run" == true ]] && mode_label=" (dry-run)"
    local gate_label=""
    [[ "$clean_gate" == true ]] && gate_label=", 质量门日志 $cleaned_gate 个"
    info "清理完成${mode_label}: 消息 $cleaned_msgs 条, 任务 $cleaned_tasks 个${gate_label} (TTL=${ttl}s)"
}

# =============================================================================
# 帮助信息
# =============================================================================

show_help() {
    cat <<'EOF'
swarm-msg.sh - CLI-to-CLI 自主消息 & 任务队列工具

用法:
  swarm-msg.sh <子命令> [参数]

消息子命令:
  send <role> "<msg>"          发送消息给指定角色
  reply <msg-id> "<msg>"       回复指定消息
  read                         读取收件箱未读消息
  wait [选项]                  等待新消息（零轮询）
  list-roles                   列出所有在线角色
  broadcast "<msg>"            向所有角色广播
  mark-read <msg-id|--all>     标记消息已读

任务队列子命令:
  create-group "<title>"               创建任务组（返回 group-id）
  publish <type> "<title>" [选项]      发布任务到队列
  list-tasks [选项]                    列出队列中的任务
  claim <task-id>                      认领一个待处理任务
  complete-task <task-id> "<result>"   完成任务并反馈结果
  fail-task <task-id> ["<reason>"]     报告任务失败（自动重试或移入 failed/）
  escalate-task <task-id> ["<reason>"]  上报任务给 supervisor 拆分（释放认领，继续干其他活）
  split-task <parent-id> [选项]        拆分任务为子任务（支持多层嵌套，深度上限: SUBTASK_MAX_DEPTH）
  re-split <parent-id>                 重置拆分（保留已完成子任务，取消未完成的）
  expand-subtask <subtask-id> [选项]  展开子任务为更细粒度的子任务（打平到同层）
  pause-task <task-id> ["<reason>"]    暂停任务（processing → paused）
  resume-task <task-id>                恢复暂停的任务（paused → processing/pending）
  cancel-task <task-id> ["<reason>"]   取消任务（级联取消依赖和子任务）
  group-status [group-id]              查看任务组进度
  group-report <group-id>              任务组汇总报告（含耗时信息）
  story-view <group-id>                查看任务组 Story（渲染为 markdown）
  set-priority <task-id> <level>       修改待处理任务的优先级 (high/normal/low)
  approve-task <task-id> ["<comment>"] 人工审批通过（仅 inspector）
  reject-task <task-id> ["<reason>"]   人工驳回（仅 inspector）
  set-verify '<json>' --role <name>    设置角色级验证命令（质量门按角色执行）
  flow-log <task-id>                   查看任务流转审计记录
  recover-tasks                        恢复卡在 processing 的任务（认领者已离线）
  request-supervisor ["<reason>"]      请求扩展新 supervisor（仅 supervisor/human 可调用）
  set-limit [N]                        查看/设置 CLI 数量上限 (0=不限制)
  cleanup [--ttl <秒>] [--gate-logs] [--dry-run]  清理过期消息/任务/质量门日志

publish 选项:
  --description|-d "<text>"    任务详细描述
  --priority|-p <level>        优先级: low/normal/high (默认: normal)
  --group|-g <group-id>        关联到任务组
  --depends <id1,id2,...>      依赖的任务 ID（逗号分隔，阻塞直到依赖完成）
  --branch|-b <branch>         指定关联分支（覆盖自动检测，支持逗号分隔多分支）
  --verify|-V <json>           任务级验证命令（JSON 对象，如 '{"test":"go test ./..."}'）
  --contract|-C <json>         V2 任务契约（必须包含 phase/phase_assignments[含integrate]/inputs/expected_outputs/acceptance_criteria/impact_scope/execution_mode/resource_keys/handoff_format）
  注意: publish 不再支持 --assign，负责人必须写入 --contract.phase_assignments

split-task 选项（可重复使用 --subtask 定义多个子任务）:
  --subtask|-s "<title>"         子任务标题（每个 --subtask 开启一组新参数）
  --assign|-a <role>             指派给特定角色（跟在 --subtask 后面）
  --depends <a,b,...>            依赖的子任务后缀（如 a,b 自动展开为 parent-a,parent-b）
  --description|-d "<text>"      子任务描述

expand-subtask 选项（参数格式同 split-task）:
  --subtask|-s "<title>"         新子任务标题（可多次指定）
  --assign|-a <role>             指派角色
  --depends <a,b,...>            依赖简写（同 split-task）
  --description|-d "<text>"      任务描述

list-tasks 选项:
  --type|-t <type>             按类型过滤 (如 review, develop)
  --status|-s <status>         按状态过滤 (默认: pending)
  --group|-g <group-id>        按任务组过滤
  --all                        显示所有状态的任务

wait 选项:
  --from <role>                只等待特定角色的消息
  --timeout <秒>               超时时间（默认: 60）

环境变量:
  SWARM_ROLE    当前角色名（自动设置）
  SWARM_ROOT    Swarm 根目录（默认: 脚本所在目录的父目录）
  SESSION_NAME  Tmux session 名（默认: swarm）

示例:
  # 消息
  swarm-msg.sh send backend "请提供用户列表 API"
  swarm-msg.sh reply msg-1707000001-12345 "API 已完成"
  swarm-msg.sh read
  swarm-msg.sh broadcast "API 接口已就绪"

  # 任务队列（独立任务）
  swarm-msg.sh publish review "审核用户注册 API" \
    --contract '{"phase":"verify","phase_assignments":{"research":"reviewer","synthesize":"reviewer","implement":"reviewer","integrate":"integrator","verify":"reviewer"},"inputs":["审核目标"],"expected_outputs":["审查结论"],"acceptance_criteria":["结论可执行"],"impact_scope":"read_only","execution_mode":"parallel","resource_keys":[],"handoff_format":"markdown"}' \
    -d "实现了注册、登录、JWT 鉴权"
  swarm-msg.sh claim task-xxx
  swarm-msg.sh complete-task task-xxx "审核通过"

  # 编排者派发（通过 contract 声明阶段负责人）
  swarm-msg.sh list-roles                        # 查看在线角色
  swarm-msg.sh publish develop "实现注册 API" \
    --contract '{"phase":"implement","phase_assignments":{"research":"backend","synthesize":"backend","implement":"backend","integrate":"integrator","verify":"reviewer"},"inputs":["实现 POST /api/register"],"expected_outputs":["接口实现","验证结果"],"acceptance_criteria":["接口可运行","verify 通过"],"impact_scope":"write","execution_mode":"exclusive","resource_keys":["repo:backend/api/register"],"handoff_format":"markdown"}'

  # 任务组（带依赖的批量任务）
  G=$(swarm-msg.sh create-group "用户注册系统")
  T1=$(swarm-msg.sh publish develop "实现注册 API" -g $G --contract '<contract-json>')
  T2=$(swarm-msg.sh publish develop "设计 users 表" -g $G --depends $T1 --contract '<contract-json>')
  T3=$(swarm-msg.sh publish review "审核全部代码" -g $G --depends $T1,$T2 --contract '<contract-json>')
  swarm-msg.sh group-status $G
  swarm-msg.sh list-tasks --group $G --all

  # 子任务拆分（Worker 在执行中发现任务太大，主动拆分）
  swarm-msg.sh split-task task-xxx \
    --subtask "数据校验" --assign backend \
    --subtask "JWT鉴权" --assign backend --depends a \
    --subtask "集成测试" --assign backend --depends a,b
  # 子任务完成后自动 compose 归一到父任务

  # 重新拆分（取消未完成的子任务，保留已完成的）
  swarm-msg.sh re-split task-xxx

  # Worker 自助展开子任务（将正在执行的子任务拆为更细粒度，打平到同层）
  # 假设父任务已有子任务 a, b, c（其中 c depends b）
  swarm-msg.sh claim task-xxx-b
  swarm-msg.sh expand-subtask task-xxx-b \
    --subtask "密码加密" --assign backend \
    --subtask "JWT签发" --assign backend --depends d
  # task-xxx-b → failed(expanded)
  # 新建 task-xxx-d(密码加密), task-xxx-e(JWT签发, depends d)
  # task-xxx-c 的依赖自动从 [b] 重写为 [d, e]

  # 工蜂发现子任务太复杂，上报给 supervisor 拆分
  swarm-msg.sh escalate-task task-xxx-b "需求涉及 3 个独立模块，建议拆分"
  # 工蜂自动认领下一个任务继续工作
  # supervisor 收到通知后用 expand-subtask 展开

  # 质量门验证命令（由 inspector 按角色配置）
  swarm-msg.sh set-verify '{"build":"cd backend && go build ./..."}' --role backend
  swarm-msg.sh set-verify '{"build":"npm run build","test":"npm test"}' --role frontend
  # 或发任务时逐个指定
  swarm-msg.sh publish develop "实现 API" \
    --contract '{"phase":"implement","phase_assignments":{"research":"backend","synthesize":"backend","implement":"backend","integrate":"integrator","verify":"reviewer"},"inputs":["实现 API"],"expected_outputs":["代码变更","验证结果"],"acceptance_criteria":["build/test 通过"],"impact_scope":"write","execution_mode":"exclusive","resource_keys":["repo:backend/api"],"handoff_format":"markdown"}' \
    --verify '{"build":"go build ./...","test":"go test ./..."}'
  # 查看任务组 Story
  swarm-msg.sh story-view $G

  # CLI 预算管理（主控使用）
  SWARM_ROLE=human swarm-msg.sh set-limit         # 查看当前上限
  SWARM_ROLE=human swarm-msg.sh set-limit 20      # 设置上限为 20
  SWARM_ROLE=human swarm-msg.sh set-limit 0       # 取消上限
EOF
}

# =============================================================================
# 主入口
# =============================================================================

main() {
    # 确保消息和任务目录存在
    mkdir -p "$INBOX_DIR" "$OUTBOX_DIR"
    mkdir -p "$TASKS_DIR"/{pending,processing,completed,failed,blocked,paused,pending_review,groups}

    local subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$subcmd" in
        send)
            [[ $# -ge 2 ]] || die "用法: swarm-msg.sh send <role> \"<message>\""
            cmd_send "$1" "$2" "${3:-normal}"
            ;;
        reply)
            [[ $# -ge 2 ]] || die "用法: swarm-msg.sh reply <msg-id> \"<message>\""
            cmd_reply "$1" "$2"
            ;;
        read)
            cmd_read
            ;;
        wait)
            cmd_wait "$@"
            ;;
        list-roles)
            cmd_list_roles
            ;;
        broadcast)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh broadcast \"<message>\""
            cmd_broadcast "$1"
            ;;
        mark-read)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh mark-read <msg-id|--all>"
            cmd_mark_read "$1"
            ;;
        create-group)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh create-group \"<title>\""
            cmd_create_group "$1"
            ;;
        publish)
            [[ $# -ge 2 ]] || die "用法: swarm-msg.sh publish <type> \"<title>\" [选项]"
            cmd_publish "$@"
            ;;
        list-tasks)
            cmd_list_tasks "$@"
            ;;
        claim)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh claim <task-id>"
            cmd_claim "$1"
            ;;
        complete-task)
            [[ $# -ge 2 ]] || die "用法: swarm-msg.sh complete-task <task-id> \"<result>\""
            cmd_complete_task "$1" "$2"
            ;;
        fail-task)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh fail-task <task-id> [\"<reason>\"]"
            cmd_fail_task "$1" "${2:-未指定原因}"
            ;;
        pause-task)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh pause-task <task-id> [\"<reason>\"]"
            cmd_pause_task "$1" "${2:-手动暂停}"
            ;;
        resume-task)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh resume-task <task-id>"
            cmd_resume_task "$1"
            ;;
        cancel-task)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh cancel-task <task-id> [\"<reason>\"]"
            cmd_cancel_task "$1" "${2:-手动取消}"
            ;;
        escalate-task)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh escalate-task <task-id> [\"<reason>\"]"
            cmd_escalate_task "$1" "${2:-任务过于复杂，需要拆分}"
            ;;
        split-task)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh split-task <parent-task-id> --subtask \"标题\" --assign 角色 [...]"
            cmd_split_task "$@"
            ;;
        re-split)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh re-split <parent-task-id>"
            cmd_re_split "$1"
            ;;
        expand-subtask)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh expand-subtask <subtask-id> --subtask \"标题\" --assign 角色 [...]"
            cmd_expand_subtask "$@"
            ;;
        group-status)
            cmd_group_status "${1:-}"
            ;;
        group-report)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh group-report <group-id>"
            cmd_group_report "$1"
            ;;
        story-view)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh story-view <group-id>"
            _story_render_markdown "$1"
            ;;
        set-prd)
            [[ $# -ge 2 ]] || die "用法: swarm-msg.sh set-prd <group-id> \"<prd-content>\""
            _story_set_prd "$1" "$2" "$(detect_my_instance)"
            echo "PRD 已关联到任务组 $1"
            ;;
        flow-log)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh flow-log <task-id>"
            cmd_flow_log "$1"
            ;;
        recover-tasks)
            cmd_recover_tasks
            ;;
        set-priority)
            [[ $# -ge 2 ]] || die "用法: swarm-msg.sh set-priority <task-id> <high|normal|low>"
            cmd_set_priority "$1" "$2"
            ;;
        approve-task)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh approve-task <task-id> [\"<comment>\"]"
            cmd_approve_task "$1" "${2:-}"
            ;;
        reject-task)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh reject-task <task-id> [\"<reason>\"]"
            cmd_reject_task "$1" "${2:-人工驳回}"
            ;;
        set-verify)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh set-verify '<json>' --role <角色名>"
            cmd_set_verify "$@"
            ;;
        request-supervisor)
            cmd_request_supervisor "${1:-}"
            ;;
        set-limit)
            cmd_set_limit "${1:-}"
            ;;
        cleanup)
            cmd_cleanup "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        "")
            show_help
            exit 1
            ;;
        *)
            die "未知子命令: $subcmd (使用 swarm-msg.sh help 查看帮助)"
            ;;
    esac
}

main "$@"
