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
SWARM_ROOT="${SWARM_ROOT:-$(dirname "$SCRIPT_DIR")}"
RUNTIME_DIR="${RUNTIME_DIR:-$SWARM_ROOT/runtime}"
MESSAGES_DIR="${MESSAGES_DIR:-$RUNTIME_DIR/messages}"
INBOX_DIR="${INBOX_DIR:-$MESSAGES_DIR/inbox}"
OUTBOX_DIR="${OUTBOX_DIR:-$MESSAGES_DIR/outbox}"
TASKS_DIR="${TASKS_DIR:-$RUNTIME_DIR/tasks}"
STATE_FILE="${STATE_FILE:-$RUNTIME_DIR/state.json}"
SESSION_NAME="${SWARM_SESSION:-swarm}"

# 加载共享事件库
source "${SCRIPT_DIR}/swarm-lib.sh"

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

# =============================================================================
# 消息推送（tmux paste-buffer）
# =============================================================================

# 将消息通知推送到目标 pane
# 使用命名 buffer 避免并发广播时全局 buffer 竞态
push_to_pane() {
    local pane_target="$1"
    local notification="$2"

    local buf_name="msg-$$-$RANDOM"
    local tmp_file
    tmp_file=$(mktemp "${RUNTIME_DIR}/.msg-push-XXXXXX.txt")
    trap "rm -f '$tmp_file'" RETURN
    printf '%s' "$notification" > "$tmp_file"

    tmux load-buffer -b "$buf_name" "$tmp_file"
    tmux paste-buffer -b "$buf_name" -t "${SESSION_NAME}:${pane_target}" -d
    sleep 0.3
    tmux send-keys -t "${SESSION_NAME}:${pane_target}" Enter
}

# =============================================================================
# 子命令: send
# =============================================================================

cmd_send() {
    local to_role="$1"
    local content="$2"
    local priority="${3:-normal}"

    local my_role
    my_role=$(detect_my_role)

    # 解析目标角色（human 是特殊角色，不在 pane 中）
    local target_pane="" target_role_name=""
    if [[ "$to_role" == "human" ]]; then
        target_role_name="human"
    else
        local target_info
        target_info=$(resolve_role_to_pane "$to_role")
        target_pane=$(echo "$target_info" | cut -d'|' -f1)
        target_role_name=$(echo "$target_info" | cut -d'|' -f2)
    fi

    # 创建消息
    local msg_id
    msg_id=$(gen_msg_id)

    mkdir -p "${INBOX_DIR}/${target_role_name}"

    local msg_file="${INBOX_DIR}/${target_role_name}/${msg_id}.json"
    jq -n \
        --arg id "$msg_id" \
        --arg from "$my_role" \
        --arg to "$target_role_name" \
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
        }' > "$msg_file"

    # 发射事件
    emit_event "message.sent" "$my_role" "msg_id=$msg_id" "to=$target_role_name" "priority=$priority"

    # 推送通知到目标 pane（human 没有 pane，只写 inbox）
    if [[ -n "$target_pane" ]]; then
        local notification
        notification="[Swarm 消息] 来自 ${my_role}:
${content}

回复方式: swarm-msg.sh reply ${msg_id} \"你的回复\""

        push_to_pane "$target_pane" "$notification"
    fi

    info "消息已发送: $my_role -> $target_role_name (${msg_id})"
    echo "$msg_id"
}

# =============================================================================
# 子命令: reply
# =============================================================================

cmd_reply() {
    local original_msg_id="$1"
    local content="$2"

    local my_role
    my_role=$(detect_my_role)

    # 查找原始消息（在自己的收件箱中）
    local original_msg_file=""
    if [[ -d "${INBOX_DIR}/${my_role}" ]]; then
        original_msg_file=$(find "${INBOX_DIR}/${my_role}" -name "${original_msg_id}.json" 2>/dev/null | head -1)
    fi
    # 也在 outbox 中查找（已标记已读的消息）
    if [[ -z "$original_msg_file" ]] && [[ -d "${OUTBOX_DIR}/${my_role}" ]]; then
        original_msg_file=$(find "${OUTBOX_DIR}/${my_role}" -name "${original_msg_id}.json" 2>/dev/null | head -1)
    fi

    [[ -n "$original_msg_file" ]] || die "找不到消息: $original_msg_id"

    local from_role
    from_role=$(jq -r '.from' "$original_msg_file")

    # 解析目标角色（human 是特殊角色，不在 pane 中）
    local target_pane="" target_role_name=""
    if [[ "$from_role" == "human" ]]; then
        target_role_name="human"
    else
        local target_info
        target_info=$(resolve_role_to_pane "$from_role")
        target_pane=$(echo "$target_info" | cut -d'|' -f1)
        target_role_name=$(echo "$target_info" | cut -d'|' -f2)
    fi

    # 创建回复消息
    local reply_id
    reply_id=$(gen_msg_id)

    mkdir -p "${INBOX_DIR}/${target_role_name}"

    local reply_file="${INBOX_DIR}/${target_role_name}/${reply_id}.json"
    jq -n \
        --arg id "$reply_id" \
        --arg from "$my_role" \
        --arg to "$target_role_name" \
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
        }' > "$reply_file"

    # 发射事件
    emit_event "message.replied" "$my_role" "msg_id=$reply_id" "to=$target_role_name" "reply_to=$original_msg_id"

    # 推送通知到目标 pane（human 没有 pane，只写 inbox）
    if [[ -n "$target_pane" ]]; then
        local notification
        notification="[Swarm 回复] 来自 ${my_role} (回复 ${original_msg_id}):
${content}

回复方式: swarm-msg.sh reply ${reply_id} \"你的回复\""

        push_to_pane "$target_pane" "$notification"
    fi

    info "回复已发送: $my_role -> $target_role_name (${reply_id})"
    echo "$reply_id"
}

# =============================================================================
# 子命令: read
# =============================================================================

cmd_read() {
    local my_role
    my_role=$(detect_my_role)

    local inbox="${INBOX_DIR}/${my_role}"

    if [[ ! -d "$inbox" ]]; then
        echo "没有新消息。"
        return 0
    fi

    local msg_files
    msg_files=$(find "$inbox" -name "*.json" -type f 2>/dev/null | sort)

    if [[ -z "$msg_files" ]]; then
        echo "没有新消息。"
        return 0
    fi

    local count
    count=$(echo "$msg_files" | wc -l | tr -d ' ')
    echo "收件箱有 ${count} 条未读消息:"
    echo ""

    while IFS= read -r msg_file; do
        [[ -f "$msg_file" ]] || continue
        jq -r '
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" +
            "  ID: \(.id)\n  来自: \(.from)\n  时间: \(.timestamp)\n" +
            (if .reply_to and .reply_to != "" and .reply_to != null then "  回复: \(.reply_to)\n" else "" end) +
            (if (.priority // "normal") != "normal" then "  优先级: \(.priority)\n" else "" end) +
            "  内容: \(.content)\n\n  回复: swarm-msg.sh reply \(.id) \"你的回复\""
        ' "$msg_file"
    done <<< "$msg_files"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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

    local my_role
    my_role=$(detect_my_role)

    info "等待新消息... (超时: ${timeout}s${from_filter:+, 来自: $from_filter})"

    # 使用 tail -f events.jsonl 零轮询等待 message.sent/message.replied/message.broadcast 事件
    local start_time
    start_time=$(date +%s)

    # 记录 events.jsonl 当前行数作为起始位置
    local start_lines=0
    [[ -f "$EVENTS_LOG" ]] && start_lines=$(wc -l < "$EVENTS_LOG" | tr -d ' ')

    while true; do
        local now
        now=$(date +%s)
        local elapsed=$(( now - start_time ))
        if [[ $elapsed -ge $timeout ]]; then
            info "等待超时 (${timeout}s)"
            return 1
        fi

        local remaining=$(( timeout - elapsed ))

        # tail -f + timeout: 读取新行
        local new_event=""
        new_event=$(tail -n +$(( start_lines + 1 )) "$EVENTS_LOG" 2>/dev/null \
            | grep -E '"message\.(sent|replied|broadcast)"' \
            | jq -r --arg to "$my_role" 'select(.data.to == $to or .type == "message.broadcast")' \
            | head -1) || true

        if [[ -n "$new_event" ]]; then
            local msg_from msg_id
            msg_from=$(echo "$new_event" | jq -r '.role // ""')
            msg_id=$(echo "$new_event" | jq -r '.data.msg_id // ""')

            # 应用来源过滤
            if [[ -n "$from_filter" && "$msg_from" != "$from_filter" ]]; then
                start_lines=$(wc -l < "$EVENTS_LOG" | tr -d ' ')
                sleep 0.5
                continue
            fi

            info "收到新消息: 来自 $msg_from ($msg_id)"
            # 输出消息内容
            cmd_read
            return 0
        fi

        # 更新起始行数并短暂等待
        [[ -f "$EVENTS_LOG" ]] && start_lines=$(wc -l < "$EVENTS_LOG" | tr -d ' ')
        sleep 1
    done
}

# =============================================================================
# 子命令: list-roles
# =============================================================================

cmd_list_roles() {
    [[ -f "$STATE_FILE" ]] || die "state.json 不存在，蜂群未启动？"

    echo "在线角色:"
    echo ""

    jq -r '.panes[] | "  \(.role)\(if .alias and .alias != "" then " (\(.alias))" else "" end) -> pane \(.pane) [\(.cli)]\(if .branch and .branch != "" then " branch:\(.branch)" else "" end)"' "$STATE_FILE"
}

# =============================================================================
# 子命令: broadcast
# =============================================================================

cmd_broadcast() {
    local content="$1"

    local my_role
    my_role=$(detect_my_role)

    [[ -f "$STATE_FILE" ]] || die "state.json 不存在，蜂群未启动？"

    local msg_id
    msg_id=$(gen_msg_id)

    # 获取所有角色（排除自己）
    local roles
    roles=$(jq -r --arg me "$my_role" '.panes[] | select(.role != $me) | "\(.role)|\(.pane)"' "$STATE_FILE")

    if [[ -z "$roles" ]]; then
        info "没有其他在线角色可以广播。"
        return 0
    fi

    local count=0
    while IFS='|' read -r role pane; do
        # 为每个角色创建消息副本
        local individual_id="${msg_id}-${role}"
        mkdir -p "${INBOX_DIR}/${role}"

        jq -n \
            --arg id "$individual_id" \
            --arg from "$my_role" \
            --arg to "$role" \
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
            }' > "${INBOX_DIR}/${role}/${individual_id}.json"

        # 推送通知
        local notification
        notification="[Swarm 广播] 来自 ${my_role}:
${content}

回复方式: swarm-msg.sh reply ${individual_id} \"你的回复\""

        push_to_pane "$pane" "$notification" 2>/dev/null || {
            info "警告: 推送通知到 ${role} (pane ${pane}) 失败，跳过"
        }

        count=$((count + 1))
    done <<< "$roles"

    # 发射广播事件
    emit_event "message.broadcast" "$my_role" "msg_id=$msg_id" "recipients=$count"

    info "广播已发送给 ${count} 个角色"
}

# =============================================================================
# 子命令: mark-read
# =============================================================================

cmd_mark_read() {
    local target="$1"

    local my_role
    my_role=$(detect_my_role)

    local inbox="${INBOX_DIR}/${my_role}"
    mkdir -p "${OUTBOX_DIR}/${my_role}"

    if [[ "$target" == "--all" ]]; then
        # 标记所有消息为已读
        local count=0
        if [[ -d "$inbox" ]]; then
            for msg_file in "$inbox"/*.json; do
                [[ -f "$msg_file" ]] || continue
                mv "$msg_file" "${OUTBOX_DIR}/${my_role}/"
                count=$((count + 1))
            done
        fi
        info "已标记 ${count} 条消息为已读"
    else
        # 标记指定消息为已读
        local msg_file="${inbox}/${target}.json"
        if [[ -f "$msg_file" ]]; then
            mv "$msg_file" "${OUTBOX_DIR}/${my_role}/"
            info "消息 $target 已标记为已读"
        else
            die "找不到消息: $target"
        fi
    fi
}

# =============================================================================
# 任务队列内部工具函数
# =============================================================================

# 自动认领下一个任务（工蜂完成任务后自动拉取）
# 扫描 pending/，找本角色能接的任务，按优先级认领
# 参数: $1 - 当前角色名
_auto_claim_next() {
    local my_role="$1"

    shopt -s nullglob
    local candidates=()
    for f in "$TASKS_DIR/pending/"*.json; do
        [[ -f "$f" ]] || continue
        local assigned
        assigned=$(jq -r '.assigned_to // ""' "$f")
        # 能接: assigned_to 为空（谁都能接）或匹配本角色
        if [[ -z "$assigned" || "$assigned" == "$my_role" ]]; then
            candidates+=("$f")
        fi
    done
    shopt -u nullglob

    [[ ${#candidates[@]} -eq 0 ]] && return 0

    # 按优先级选: high > normal > low
    local next_file=""
    for pri in high normal low; do
        for f in "${candidates[@]}"; do
            [[ -f "$f" ]] || continue
            local p
            p=$(jq -r '.priority // "normal"' "$f" 2>/dev/null) || continue
            if [[ "$p" == "$pri" ]]; then
                next_file="$f"
                break 2
            fi
        done
    done
    [[ -z "$next_file" ]] && next_file="${candidates[0]}"

    local next_id
    next_id=$(jq -r '.id' "$next_file")

    # 原子认领: pending → processing（mv 只有一个进程能成功）
    local claimed_at
    claimed_at=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$TASKS_DIR/processing"
    if ! mv "$next_file" "$TASKS_DIR/processing/$next_id.json" 2>/dev/null; then
        # 被其他实例抢走了，静默返回
        return 0
    fi
    # 更新字段
    local tmp_file="$TASKS_DIR/processing/$next_id.json.tmp"
    jq --arg role "$my_role" --arg at "$claimed_at" \
        '.status = "processing" | .claimed_by = $role | .claimed_at = $at' \
        "$TASKS_DIR/processing/$next_id.json" > "$tmp_file"
    mv "$tmp_file" "$TASKS_DIR/processing/$next_id.json"

    emit_event "task.auto_claimed" "$my_role" "task_id=$next_id"

    # 通知发布者
    local from_role from_pane
    from_role=$(jq -r '.from' "$TASKS_DIR/processing/$next_id.json")
    from_pane=$(jq -r --arg role "$from_role" \
        '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
    [[ -n "$from_pane" ]] && push_to_pane "$from_pane" \
        "[自动认领] $my_role 已认领任务: $next_id" 2>/dev/null || true

    # 输出任务详情，CLI 看到后直接开始工作
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "[自动认领] 队列中有新任务，已为你认领，请立即开始工作"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "任务详情:"
    jq '.' "$TASKS_DIR/processing/$next_id.json"
    echo ""
    echo "完成后执行: swarm-msg.sh complete-task $next_id --result \"完成说明\""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# 检查依赖列表是否全部满足（全在 completed/ 中）
# 参数: $1 - JSON 数组字符串 '["task-001","task-002"]'
# 返回: 0=全部满足, 1=有未满足
_deps_all_met() {
    local depends_json="$1"
    [[ "$depends_json" == "[]" || -z "$depends_json" ]] && return 0

    while IFS= read -r dep_id; do
        [[ -z "$dep_id" ]] && continue
        [[ -f "$TASKS_DIR/completed/$dep_id.json" ]] || return 1
    done < <(echo "$depends_json" | jq -r '.[]' 2>/dev/null)
    return 0
}

# 任务完成后，扫描 blocked/ 中的任务，解除满足条件的阻塞
# 参数: $1 - 刚完成的任务 ID
_check_and_unblock() {
    local completed_task_id="$1"

    shopt -s nullglob
    for blocked_file in "$TASKS_DIR/blocked/"*.json; do
        [[ -f "$blocked_file" ]] || continue

        # 该任务是否依赖刚完成的任务
        local has_dep
        has_dep=$(jq --arg dep "$completed_task_id" \
            'if .depends_on then (.depends_on | index($dep)) else null end' \
            "$blocked_file" 2>/dev/null)
        [[ "$has_dep" != "null" && -n "$has_dep" ]] || continue

        # 所有依赖是否全部满足
        local deps
        deps=$(jq -c '.depends_on // []' "$blocked_file")
        if _deps_all_met "$deps"; then
            local tid
            tid=$(jq -r '.id' "$blocked_file")
            mkdir -p "$TASKS_DIR/pending"
            if mv "$blocked_file" "$TASKS_DIR/pending/$tid.json" 2>/dev/null; then
                local tmp_unblock="$TASKS_DIR/pending/${tid}.json.tmp"
                jq '.blocked = false | .status = "pending"' \
                    "$TASKS_DIR/pending/$tid.json" > "$tmp_unblock" \
                    && mv "$tmp_unblock" "$TASKS_DIR/pending/$tid.json"
            else
                continue  # 被其他进程抢先处理
            fi

            emit_event "task.unblocked" "" "task_id=$tid" "unblocked_by=$completed_task_id"
            info "任务已解除阻塞: $tid"

            # 通知：新任务可认领（包含完整描述，尊重 assigned_to）
            local t_title t_desc t_type t_from t_branch t_assign
            t_title=$(jq -r '.title' "$TASKS_DIR/pending/$tid.json")
            t_desc=$(jq -r '.description // ""' "$TASKS_DIR/pending/$tid.json")
            t_type=$(jq -r '.type' "$TASKS_DIR/pending/$tid.json")
            t_from=$(jq -r '.from' "$TASKS_DIR/pending/$tid.json")
            t_branch=$(jq -r '.branch // ""' "$TASKS_DIR/pending/$tid.json")
            t_assign=$(jq -r '.assigned_to // ""' "$TASKS_DIR/pending/$tid.json")

            local notify_msg="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            notify_msg+=$'\n'"[任务解锁] $t_type: $t_title"
            notify_msg+=$'\n'"发布者: $t_from | 任务ID: $tid"
            [[ -n "$t_assign" && "$t_assign" != "null" ]] && notify_msg+=$'\n'"指派给: $t_assign"
            [[ -n "$t_branch" && "$t_branch" != "null" ]] && notify_msg+=$'\n'"分支: $t_branch"
            if [[ -n "$t_desc" && "$t_desc" != "null" ]]; then
                notify_msg+=$'\n'$'\n'"📋 任务描述:"
                notify_msg+=$'\n'"$t_desc"
            fi
            notify_msg+=$'\n'$'\n'"👉 认领: swarm-msg.sh claim $tid"
            notify_msg+=$'\n'"👉 完成后: swarm-msg.sh complete-task $tid --result \"完成说明\""
            notify_msg+=$'\n'"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

            if [[ -n "$t_assign" && "$t_assign" != "null" ]]; then
                # 定向推送给被指派角色
                while IFS= read -r tp; do
                    push_to_pane "$tp" "$notify_msg" 2>/dev/null || true
                done < <(jq -r --arg role "$t_assign" \
                    '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null)
            else
                # 广播给所有角色
                while IFS='|' read -r r p; do
                    push_to_pane "$p" "$notify_msg" 2>/dev/null || true
                done < <(jq -r '.panes[] | "\(.role)|\(.pane)"' "$STATE_FILE" 2>/dev/null)
            fi
        fi
    done
    shopt -u nullglob
}

# 任务完成后，检查其所属 group 是否全部完成
# 参数: $1 - 刚完成的任务 ID
_check_group_completion() {
    local task_id="$1"

    local group_id
    group_id=$(jq -r '.group_id // ""' "$TASKS_DIR/completed/$task_id.json" 2>/dev/null)
    [[ -n "$group_id" ]] || return 0

    local group_file="$TASKS_DIR/groups/$group_id.json"
    [[ -f "$group_file" ]] || return 0

    (
        flock -x 200

        # 统计组内任务完成情况
        local completed=0 total=0
        while IFS= read -r tid; do
            [[ -z "$tid" ]] && continue
            ((total++)) || true
            [[ -f "$TASKS_DIR/completed/$tid.json" ]] && ((completed++)) || true
        done < <(jq -r '.tasks[]' "$group_file" 2>/dev/null)

        # 更新 group 进度
        local tmp="${group_file}.tmp"
        jq --argjson c "$completed" --argjson t "$total" \
            '.completed_count = $c | .total_count = $t' \
            "$group_file" > "$tmp" && mv "$tmp" "$group_file"

        # 全部完成？
        if [[ $completed -eq $total && $total -gt 0 ]]; then
            jq '.status = "completed"' "$group_file" > "$tmp" && mv "$tmp" "$group_file"

            local group_title from_role
            group_title=$(jq -r '.title' "$group_file")
            from_role=$(jq -r '.from' "$group_file")

            emit_event "group.completed" "$from_role" "group_id=$group_id" "title=$group_title"

            # 标记 Story 为已完成
            _story_mark_completed "$group_id"

            # 双通道通知主控
            local notify_id="sys-group-done-$(date +%s)-${group_id}"
            mkdir -p "${INBOX_DIR}/${from_role}"
            jq -n \
                --arg id "$notify_id" \
                --arg from "system" \
                --arg to "$from_role" \
                --arg content "[任务组完成] $group_title (ID: $group_id)\n全部 $total 个任务已完成。执行 swarm-msg.sh group-status $group_id 查看详情。" \
                --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
                --arg status "pending" \
                --arg priority "high" \
                '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority}' \
                > "${INBOX_DIR}/${from_role}/${notify_id}.json"

            local from_pane
            from_pane=$(jq -r --arg role "$from_role" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
            [[ -n "$from_pane" ]] && push_to_pane "$from_pane" \
                "[任务组完成] $group_title ($completed/$total 全部完成)" 2>/dev/null || true

            info "任务组全部完成: $group_id ($group_title)"
        fi
    ) 200>"${group_file}.lock"
}

# =============================================================================
# Story 文件管理（任务上下文载体）
#
# 设计：数据用 JSON 存储（可靠读写），展示时用 jq 渲染为 markdown。
# =============================================================================

STORIES_DIR="${STORIES_DIR:-$RUNTIME_DIR/stories}"

# 原子更新 story JSON（flock 保护并发写入）
# 用法: _story_update <group_id> '<jq_filter>' [--argjson k v ...]
_story_update() {
    local group_id="$1"; shift
    local story_file="$STORIES_DIR/$group_id.json"
    [[ -f "$story_file" ]] || return 0

    local lock_file="${story_file}.lock"
    local tmp_file="${story_file}.tmp"

    (
        flock -x 200
        jq "$@" "$story_file" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$story_file"
    ) 200>"$lock_file"
    rm -f "$tmp_file" 2>/dev/null || true
}

# 创建 Story
# 参数: $1=group_id, $2=title, $3=from(创建者)
_create_story() {
    local group_id="$1" title="$2" from="$3"
    local story_file="$STORIES_DIR/$group_id.json"
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    mkdir -p "$STORIES_DIR"

    jq -n \
        --arg id "$group_id" \
        --arg title "$title" \
        --arg from "$from" \
        --arg created_at "$now" \
        '{
            id: $id,
            title: $title,
            from: $from,
            created_at: $created_at,
            status: "active",
            tasks: [],
            verifications: [],
            timeline: [($created_at + " 任务组创建 by " + $from)]
        }' > "$story_file"
}

# 向 Story 追加子任务
# 参数: $1=group_id, $2=task_id, $3=title, $4=type, $5=assigned_to, $6=branch
_story_add_task() {
    local group_id="$1" task_id="$2" title="$3" type="${4:-}" assigned_to="${5:-}" branch="${6:-}"
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    local timeline_msg="$now $task_id 发布"
    [[ -n "$assigned_to" ]] && timeline_msg+=" → $assigned_to"

    _story_update "$group_id" \
        '.tasks += [$t] | .timeline += [$msg]' \
        --argjson t "$(jq -n \
            --arg id "$task_id" \
            --arg title "$title" \
            --arg type "$type" \
            --arg assigned_to "$assigned_to" \
            --arg branch "$branch" \
            --arg status "pending" \
            '{id:$id, title:$title, type:$type, assigned_to:$assigned_to, branch:$branch, status:$status, result:null}')" \
        --arg msg "$timeline_msg"
}

# 更新 Story 中的子任务状态
# 参数: $1=task_id, $2=status(processing/completed), $3=info(可选)
_story_update_task() {
    local task_id="$1" new_status="$2" info="${3:-}"

    # 查找任务所属 group_id
    local group_id=""
    local task_file=""
    for d in processing completed pending blocked failed; do
        [[ -f "$TASKS_DIR/$d/$task_id.json" ]] && task_file="$TASKS_DIR/$d/$task_id.json" && break
    done
    [[ -n "$task_file" ]] && group_id=$(jq -r '.group_id // ""' "$task_file" 2>/dev/null)
    [[ -n "$group_id" ]] || return 0

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    _story_update "$group_id" \
        '(.tasks[] | select(.id == $tid)) |= (.status = $s | .result = (if $r != "" then $r else .result end))
         | .timeline += [$msg]' \
        --arg tid "$task_id" \
        --arg s "$new_status" \
        --arg r "$info" \
        --arg msg "$now $task_id $new_status"
}

# 向 Story 追加验收记录
# 参数: $1=group_id, $2=task_id, $3=result(通过/失败), $4=checker
_story_add_verification() {
    local group_id="$1" task_id="$2" result="$3" checker="${4:-自动}"
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    _story_update "$group_id" \
        '.verifications += [$v]' \
        --argjson v "$(jq -n \
            --arg time "$now" \
            --arg task "$task_id" \
            --arg result "$result" \
            --arg checker "$checker" \
            '{time:$time, task:$task, result:$result, checker:$checker}')"
}

# 标记 Story 为已完成
# 参数: $1=group_id
_story_mark_completed() {
    local group_id="$1"
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    _story_update "$group_id" \
        '.status = "completed" | .timeline += [$msg]' \
        --arg msg "$now 任务组全部完成"
}

# 渲染 Story JSON 为 markdown（只读展示用）
_story_render_markdown() {
    local group_id="$1"
    local story_file="$STORIES_DIR/$group_id.json"
    [[ -f "$story_file" ]] || { echo "Story 不存在: $group_id"; return 1; }

    jq -r '
        "# \(.title)\n" +
        "> 任务组 ID: \(.id)\n" +
        "> 创建者: \(.from)\n" +
        "> 创建时间: \(.created_at)\n" +
        "> 状态: \(.status)\n\n" +
        "## 子任务\n\n" +
        (if (.tasks | length) == 0 then "（暂无子任务）\n"
         else (.tasks | map(
            "### - [\(if .status == "completed" then "x" else " " end)] \(.title) (\(.id))\n" +
            (if .type != "" then "- **类型**: \(.type)\n" else "" end) +
            (if .assigned_to != "" then "- **角色**: \(.assigned_to)\n" else "" end) +
            "- **状态**: \(.status)\n" +
            (if .branch != "" then "- **分支**: \(.branch)\n" else "" end) +
            (if .result then "- **结果**: \(.result)\n" else "" end)
         ) | join("\n"))
         end) + "\n" +
        "## 验收记录\n\n" +
        "| 时间 | 任务 | 结果 | 检查者 |\n" +
        "|------|------|------|--------|\n" +
        (.verifications | map("| \(.time) | \(.task) | \(.result) | \(.checker) |") | join("\n")) +
        "\n\n## 进度时间线\n\n" +
        (.timeline | map("- \(.)") | join("\n"))
    ' "$story_file"
}

# =============================================================================
# 质量门（Quality Gate）
#
# 设计理念：
#   脚本只负责"执行"验证命令，不负责"决定"用什么命令。
#   验证命令的来源（优先级从高到低）：
#     1. 任务级: publish --verify '{"build":"go build ./..."}' (LLM 发布任务时指定)
#     2. 项目级: .swarm/verify.json (用户或 LLM 创建)
#     3. 运行时: runtime/project-info.json 的 verify_commands (LLM 写入)
#   如果三层都没有指定验证命令 → 跳过质量门
# =============================================================================

GATE_LOGS_DIR="${GATE_LOGS_DIR:-$RUNTIME_DIR/gate-logs}"

# 不需要质量门检查的任务类型（可通过环境变量覆盖）
SKIP_GATE_TYPES="${SKIP_GATE_TYPES:-review design architecture audit document plan}"

# 解析验证命令（三层合并，无硬编码默认值）
# 参数: $1=task_id, $2=role
_resolve_verify_commands() {
    local task_id="$1"
    local role="${2:-}"
    local result="{}"

    # 层 1（最低优先级）: runtime/project-info.json 的 verify_commands（按角色查找）
    local project_info="$RUNTIME_DIR/project-info.json"
    if [[ -f "$project_info" && -n "$role" ]]; then
        local runtime_cmds
        runtime_cmds=$(jq --arg role "$role" '.verify_commands[$role] // {}' "$project_info" 2>/dev/null)
        [[ "$runtime_cmds" != "{}" && -n "$runtime_cmds" ]] && result="$runtime_cmds"
    fi

    # 层 2: 项目级 .swarm/verify.json（覆盖层 1 的同名命令）
    local project_dir
    project_dir=$(jq -r '.project // ""' "$STATE_FILE" 2>/dev/null)
    if [[ -n "$project_dir" ]]; then
        local user_verify="$project_dir/.swarm/verify.json"
        if [[ -f "$user_verify" ]]; then
            local user_cmds
            user_cmds=$(jq '. // {}' "$user_verify" 2>/dev/null)
            result=$(jq -n --argjson a "$result" --argjson b "$user_cmds" '$a * $b')
        fi
    fi

    # 层 3（最高优先级）: 任务 JSON 的 verify 字段
    local task_file=""
    for d in processing completed pending; do
        [[ -f "$TASKS_DIR/$d/$task_id.json" ]] && task_file="$TASKS_DIR/$d/$task_id.json" && break
    done
    if [[ -n "$task_file" ]]; then
        local task_verify
        task_verify=$(jq -r '.verify // ""' "$task_file" 2>/dev/null)
        if [[ -n "$task_verify" && "$task_verify" != "null" && "$task_verify" != "" ]]; then
            if echo "$task_verify" | jq -e 'type == "object"' &>/dev/null; then
                result=$(jq -n --argjson a "$result" --argjson b "$task_verify" '$a * $b')
            fi
        fi
    fi

    echo "$result"
}

# 执行质量门
# 参数: $1=task_id, $2=role
# 返回: 0=通过, 1=失败（已回退任务）
_run_quality_gate() {
    local task_id="$1" role="$2"

    # 检查任务类型是否需要跳过
    local task_type=""
    for d in processing completed pending; do
        if [[ -f "$TASKS_DIR/$d/$task_id.json" ]]; then
            task_type=$(jq -r '.type // ""' "$TASKS_DIR/$d/$task_id.json" 2>/dev/null)
            break
        fi
    done
    for skip_type in $SKIP_GATE_TYPES; do
        if [[ "$task_type" == "$skip_type" ]]; then
            return 0
        fi
    done

    # 获取工蜂的 worktree 路径
    local worktree=""
    worktree=$(jq -r --arg role "$role" '.panes[] | select(.role == $role) | .worktree // ""' "$STATE_FILE" 2>/dev/null)
    if [[ -z "$worktree" || ! -d "$worktree" ]]; then
        info "[质量门] 无法获取 $role 的 worktree，跳过检查"
        return 0
    fi

    # 解析验证命令（不依赖 worktree 内容，全部由 LLM 或配置文件决定）
    local verify_json
    verify_json=$(_resolve_verify_commands "$task_id" "$role")

    # 检查是否有验证命令
    local cmd_count
    cmd_count=$(echo "$verify_json" | jq 'length' 2>/dev/null)
    if [[ "$cmd_count" -eq 0 || -z "$cmd_count" ]]; then
        info "[质量门] 无验证命令，跳过"
        return 0
    fi

    mkdir -p "$GATE_LOGS_DIR"
    local log_file="$GATE_LOGS_DIR/$task_id.log"
    local all_passed=true
    local skip_count=0
    local skip_names=""
    local gate_start
    gate_start=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "========================================"
        echo "质量门检查: $task_id"
        echo "角色: $role"
        echo "Worktree: $worktree"
        echo "开始时间: $gate_start"
        echo "========================================"
        echo ""
    } > "$log_file"

    # 逐项执行验证命令
    while IFS=$'\t' read -r check_name check_cmd; do
        [[ -z "$check_name" || -z "$check_cmd" ]] && continue

        {
            echo "--- [$check_name] $check_cmd ---"
        } >> "$log_file"

        local exit_code=0
        # 在 worktree 目录下执行，超时 120 秒
        if timeout 120 bash -c "cd '$worktree' && $check_cmd" >> "$log_file" 2>&1; then
            echo "[PASS] $check_name" >> "$log_file"
            info "[质量门] $check_name: 通过"
        else
            exit_code=$?
            # 区分 "命令不存在"(127) 和 "检查失败"
            if [[ $exit_code -eq 127 ]]; then
                echo "[SKIP] $check_name (命令不存在, exit=$exit_code)" >> "$log_file"
                warn "[质量门] $check_name: 命令不存在，跳过（环境可能缺少依赖）"
                skip_count=$((skip_count + 1))
                skip_names+="$check_name "
            else
                echo "[FAIL] $check_name (exit=$exit_code)" >> "$log_file"
                info "[质量门] $check_name: 失败 (exit=$exit_code)"
                all_passed=false
            fi
        fi
        echo "" >> "$log_file"
    done < <(echo "$verify_json" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

    {
        echo "========================================"
        echo "结果: $([ "$all_passed" = true ] && echo "全部通过" || echo "有检查失败")"
        echo "结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================"
    } >> "$log_file"

    # 查找任务所属 group（用于 story 验收记录）
    local group_id=""
    local group_task_file=""
    for d in processing completed pending blocked failed; do
        [[ -f "$TASKS_DIR/$d/$task_id.json" ]] && group_task_file="$TASKS_DIR/$d/$task_id.json" && break
    done
    [[ -n "$group_task_file" ]] && group_id=$(jq -r '.group_id // ""' "$group_task_file" 2>/dev/null)

    # 有命令被跳过（exit 127），通知 inspector 环境可能缺依赖
    if [[ $skip_count -gt 0 ]]; then
        warn "[质量门] $skip_count 个检查因命令不存在被跳过: $skip_names"
        echo "WARNING: $skip_count 个检查被跳过 (命令不存在): $skip_names" >> "$log_file"
        # 写入 inspector 收件箱
        local warn_id="sys-gate-$(date +%s)-${RANDOM}"
        mkdir -p "${INBOX_DIR}/inspector"
        jq -n \
            --arg id "$warn_id" \
            --arg content "质量门警告: 任务 $task_id 有 $skip_count 个检查因命令不存在被跳过（${skip_names}）。请检查 worktree 环境是否缺少依赖，或调整 set-verify 配置。" \
            --arg timestamp "$(get_timestamp)" \
            '{id:$id, from:"system", to:"inspector", content:$content, timestamp:$timestamp, status:"pending", reply_to:"", priority:"high"}' \
            > "${INBOX_DIR}/inspector/${warn_id}.json" 2>/dev/null || true
    fi

    if [[ "$all_passed" == true ]]; then
        emit_event "gate.passed" "$role" "task_id=$task_id"
        [[ -n "$group_id" ]] && _story_add_verification "$group_id" "$task_id" "Gate 通过$([ $skip_count -gt 0 ] && echo " ($skip_count 项跳过)")" "自动"
        return 0
    else
        emit_event "gate.failed" "$role" "task_id=$task_id"
        [[ -n "$group_id" ]] && _story_add_verification "$group_id" "$task_id" "Gate 失败" "自动"

        # 任务保持在 processing（无需回退，本来就没移走）
        # 推送失败日志给工蜂
        local role_pane
        role_pane=$(jq -r --arg role "$role" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
        if [[ -n "$role_pane" ]]; then
            local fail_msg="[质量门失败] 任务 $task_id 未通过自动检查，仍在 processing 状态。"
            fail_msg+=$'\n'"查看详情: cat $log_file"
            fail_msg+=$'\n'"修复后重新执行: swarm-msg.sh complete-task $task_id \"修复说明\""
            push_to_pane "$role_pane" "$fail_msg" 2>/dev/null || true
        fi

        info "[质量门] 任务 $task_id 未通过检查，保持 processing"
        return 1
    fi
}

# =============================================================================
# 子命令: create-group (创建任务组)
# =============================================================================

cmd_create_group() {
    local title="$1"

    local my_role
    my_role=$(detect_my_role)

    local group_id="group-$(date +%s)-$$-$((RANDOM % 10000))"

    mkdir -p "$TASKS_DIR/groups"
    jq -n \
        --arg id "$group_id" \
        --arg title "$title" \
        --arg from "$my_role" \
        --arg created_at "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{
            id: $id,
            title: $title,
            from: $from,
            created_at: $created_at,
            status: "active",
            tasks: [],
            completed_count: 0,
            total_count: 0
        }' > "$TASKS_DIR/groups/$group_id.json"

    emit_event "group.created" "$my_role" "group_id=$group_id" "title=$title"

    # 创建 Story 文件
    _create_story "$group_id" "$title" "$my_role"

    info "任务组已创建: $group_id ($title)"
    echo "$group_id"
}

# =============================================================================
# 子命令: publish (发布任务到中心队列)
# =============================================================================

cmd_publish() {
    local type="$1"
    local title="$2"
    shift 2

    local description="" priority="normal" group_id="" depends_on="" assign_to="" explicit_branch="" verify=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --description|-d) description="$2"; shift 2 ;;
            --priority|-p)    priority="$2"; shift 2 ;;
            --group|-g)       group_id="$2"; shift 2 ;;
            --depends)        depends_on="$2"; shift 2 ;;
            --assign|-a)      assign_to="$2"; shift 2 ;;
            --branch|-b)      explicit_branch="$2"; shift 2 ;;
            --verify|-V)      verify="$2"; shift 2 ;;
            -*) die "publish: 未知选项 '$1' (使用 swarm-msg.sh help 查看帮助)" ;;
            *)  die "publish: 多余参数 '$1'" ;;
        esac
    done

    local my_role
    my_role=$(detect_my_role)

    # 分支: 优先使用显式指定的 --branch，否则自动取发布者的分支
    local branch="" commit_hash="" project_dir=""
    if [[ -n "$explicit_branch" ]]; then
        branch="$explicit_branch"
    else
        branch=$(jq -r --arg role "$my_role" '.panes[] | select(.role == $role) | .branch // ""' "$STATE_FILE" 2>/dev/null)
    fi
    project_dir=$(jq -r '.project // ""' "$STATE_FILE" 2>/dev/null)
    if [[ -n "$branch" && -n "$project_dir" ]]; then
        commit_hash=$(git -C "$project_dir" rev-parse --short "$branch" 2>/dev/null || echo "")
    fi

    # 解析依赖列表: "task-001,task-002" → JSON 数组
    local depends_json="[]"
    if [[ -n "$depends_on" ]]; then
        depends_json=$(echo "$depends_on" | tr ',' '\n' | jq -R '.' | jq -s '.')
    fi

    # 判断是否被阻塞
    local is_blocked=false
    if ! _deps_all_met "$depends_json"; then
        is_blocked=true
    fi

    # 生成任务 ID
    local task_id="task-$(date +%s)-$$-$((RANDOM % 10000))"

    # 目标目录: blocked 或 pending
    local target_dir="pending"
    local target_status="pending"
    [[ "$is_blocked" == true ]] && target_dir="blocked" && target_status="blocked"

    # 解析 verify 参数为 JSON（必须是 JSON 对象，如 '{"test":"go test ./..."}'）
    local verify_json="null"
    if [[ -n "$verify" ]]; then
        if echo "$verify" | jq -e 'type == "object"' &>/dev/null; then
            verify_json="$verify"
        else
            die "publish: --verify 参数必须是 JSON 对象，如 '{\"test\":\"go test ./...\"}'"
        fi
    fi

    mkdir -p "$TASKS_DIR/$target_dir"
    jq -n \
        --arg id "$task_id" \
        --arg type "$type" \
        --arg from "$my_role" \
        --arg title "$title" \
        --arg description "$description" \
        --arg branch "$branch" \
        --arg commit "$commit_hash" \
        --arg created_at "$(date '+%Y-%m-%d %H:%M:%S')" \
        --arg priority "$priority" \
        --arg group_id "$group_id" \
        --arg assigned_to "$assign_to" \
        --argjson depends_on "$depends_json" \
        --argjson blocked "$is_blocked" \
        --arg status "$target_status" \
        --argjson verify "$verify_json" \
        '{
            id: $id,
            type: $type,
            from: $from,
            title: $title,
            description: $description,
            assigned_to: $assigned_to,
            branch: $branch,
            commit: $commit,
            created_at: $created_at,
            status: $status,
            claimed_by: null,
            claimed_at: null,
            completed_at: null,
            result: null,
            priority: $priority,
            group_id: $group_id,
            depends_on: $depends_on,
            blocked: $blocked,
            verify: $verify
        }' > "$TASKS_DIR/$target_dir/$task_id.json"

    # 如果属于某个 group，追加到 group 的任务列表
    if [[ -n "$group_id" ]]; then
        local group_file="$TASKS_DIR/groups/$group_id.json"
        if [[ -f "$group_file" ]]; then
            local tmp="${group_file}.tmp"
            jq --arg tid "$task_id" \
                '.tasks += [$tid] | .total_count = (.tasks | length)' \
                "$group_file" > "$tmp" && mv "$tmp" "$group_file"
        fi

        # 向 Story 追加子任务
        _story_add_task "$group_id" "$task_id" "$title" "$type" "$assign_to" "$branch"
    fi

    # 发射事件
    emit_event "task.published" "$my_role" "task_id=$task_id" "type=$type" "title=$title" \
        "assigned_to=${assign_to:-all}" "group=${group_id:-none}" "blocked=$is_blocked"

    # 如果不是阻塞的，推送通知（包含完整任务描述）
    if [[ "$is_blocked" == false ]]; then
        local notify_msg="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        notify_msg+=$'\n'"[新任务] $type: $title"
        notify_msg+=$'\n'"发布者: $my_role | 任务ID: $task_id"
        [[ -n "$assign_to" ]] && notify_msg+=$'\n'"指派给: $assign_to"
        [[ -n "$branch" ]] && notify_msg+=$'\n'"分支: $branch"
        [[ -n "$group_id" ]] && notify_msg+=$'\n'"任务组: $group_id"
        if [[ -n "$description" ]]; then
            notify_msg+=$'\n'$'\n'"📋 任务描述:"
            notify_msg+=$'\n'"$description"
        fi
        notify_msg+=$'\n'$'\n'"👉 认领: swarm-msg.sh claim $task_id"
        notify_msg+=$'\n'"👉 完成后: swarm-msg.sh complete-task $task_id --result \"完成说明\""
        notify_msg+=$'\n'"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if [[ -n "$assign_to" ]]; then
            # 定向推送：只发给被指派角色的所有 pane（同角色可能有多个 CLI）
            while IFS= read -r target_pane; do
                push_to_pane "$target_pane" "$notify_msg" 2>/dev/null || true
            done < <(jq -r --arg role "$assign_to" \
                '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null)
        else
            # 无指派：广播给所有角色（排除发布者自己）
            while IFS='|' read -r other_role other_pane; do
                [[ "$other_role" == "$my_role" ]] && continue
                push_to_pane "$other_pane" "$notify_msg" 2>/dev/null || true
            done < <(jq -r '.panes[] | "\(.role)|\(.pane)"' "$STATE_FILE" 2>/dev/null)
        fi
    fi

    local assign_info=""
    [[ -n "$assign_to" ]] && assign_info=" → $assign_to"
    if [[ "$is_blocked" == true ]]; then
        info "任务已发布(阻塞中): $task_id ($type: $title)$assign_info [等待依赖: $depends_on]"
    else
        info "任务已发布: $task_id ($type: $title)$assign_info"
    fi
    echo "$task_id"
}

# =============================================================================
# 子命令: list-tasks (列出队列中的任务)
# =============================================================================

cmd_list_tasks() {
    local filter_type="" filter_status="pending" filter_group=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type|-t)   filter_type="$2"; shift 2 ;;
            --status|-s) filter_status="$2"; shift 2 ;;
            --group|-g)  filter_group="$2"; shift 2 ;;
            --all)       filter_status="all"; shift ;;
            -*) die "list-tasks: 未知选项 '$1' (使用 swarm-msg.sh help 查看帮助)" ;;
            *)  die "list-tasks: 多余参数 '$1'" ;;
        esac
    done

    local dirs=()
    if [[ "$filter_status" == "all" ]]; then
        dirs=("pending" "blocked" "processing" "completed" "failed")
    else
        dirs=("$filter_status")
    fi

    echo "任务队列${filter_type:+ (类型: $filter_type)}${filter_group:+ (组: $filter_group)}:"
    echo ""

    local found=false
    for status_dir in "${dirs[@]}"; do
        local dir="$TASKS_DIR/$status_dir"
        [[ -d "$dir" ]] || continue

        shopt -s nullglob
        for f in "$dir"/*.json; do
            [[ -f "$f" ]] || continue

            # 类型过滤
            if [[ -n "$filter_type" ]]; then
                local t
                t=$(jq -r '.type' "$f" 2>/dev/null)
                [[ "$t" == "$filter_type" ]] || continue
            fi

            # 组过滤
            if [[ -n "$filter_group" ]]; then
                local g
                g=$(jq -r '.group_id // ""' "$f" 2>/dev/null)
                [[ "$g" == "$filter_group" ]] || continue
            fi

            found=true
            jq -r '"  [\(.status)] \(.id)\n    类型: \(.type) | 来自: \(.from) | 优先级: \(.priority)\n    标题: \(.title)\(.branch | if . and . != "" then "\n    分支: "+. else "" end)\(.claimed_by | if . and . != "null" then "\n    认领: "+. else "" end)\(.depends_on | if . and length > 0 then "\n    依赖: "+(.|join(", ")) else "" end)\(.group_id | if . and . != "" then "\n    任务组: "+. else "" end)\n"' "$f"
        done
        shopt -u nullglob
    done

    if [[ "$found" == false ]]; then
        echo "  (无任务)"
    fi
}

# =============================================================================
# 子命令: claim (认领任务)
# =============================================================================

cmd_claim() {
    local task_id="$1"

    local my_role
    my_role=$(detect_my_role)

    local task_file="$TASKS_DIR/pending/$task_id.json"
    mkdir -p "$TASKS_DIR/processing"

    # 原子抢占：mv 只有一个进程能成功
    if ! mv "$task_file" "$TASKS_DIR/processing/$task_id.json" 2>/dev/null; then
        die "任务不存在或已被认领: $task_id (使用 swarm-msg.sh list-tasks 查看待认领任务)"
    fi

    # 检查指派限制（抢占后检查，不符合则回退）
    local assigned_to
    assigned_to=$(jq -r '.assigned_to // ""' "$TASKS_DIR/processing/$task_id.json")
    if [[ -n "$assigned_to" && "$assigned_to" != "$my_role" ]]; then
        # 回退：移回 pending
        if ! mv "$TASKS_DIR/processing/$task_id.json" "$task_file" 2>/dev/null; then
            info "[WARNING] 任务 $task_id 回退 pending 失败，可能需要手动恢复或使用 recover-tasks"
        fi
        die "此任务已指派给 $assigned_to，你($my_role)无法认领"
    fi

    # 更新字段
    local claimed_at
    claimed_at=$(date '+%Y-%m-%d %H:%M:%S')
    local tmp_file="$TASKS_DIR/processing/$task_id.json.tmp"
    jq --arg role "$my_role" --arg at "$claimed_at" \
        '.status = "processing" | .claimed_by = $role | .claimed_at = $at' \
        "$TASKS_DIR/processing/$task_id.json" > "$tmp_file"
    mv "$tmp_file" "$TASKS_DIR/processing/$task_id.json"

    emit_event "task.claimed" "$my_role" "task_id=$task_id"

    # 更新 Story 中的任务状态
    _story_update_task "$task_id" "processing"

    # 通知发布者
    local from_role from_pane
    from_role=$(jq -r '.from' "$TASKS_DIR/processing/$task_id.json")
    from_pane=$(jq -r --arg role "$from_role" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")

    if [[ -n "$from_pane" ]]; then
        local notify="[任务认领] $my_role 已认领你发布的任务: $task_id"
        push_to_pane "$from_pane" "$notify" 2>/dev/null || true
    fi

    info "已认领任务: $task_id"
    echo ""
    echo "任务详情:"
    jq '.' "$TASKS_DIR/processing/$task_id.json"

    # 提示审核命令
    local branch
    branch=$(jq -r '.branch // ""' "$TASKS_DIR/processing/$task_id.json")
    if [[ -n "$branch" ]]; then
        echo ""
        echo "审核命令:"
        # 支持逗号分隔的多分支（如 "swarm/backend,swarm/frontend"）
        IFS=',' read -ra branches <<< "$branch"
        for b in "${branches[@]}"; do
            b=$(echo "$b" | xargs)  # 去除首尾空格
            echo "  git log main..$b --oneline    # 查看 $b 提交"
            echo "  git diff main..$b             # 查看 $b 变更"
        done
    fi
}

# =============================================================================
# 子命令: complete-task (完成任务)
# =============================================================================

cmd_complete_task() {
    local task_id="$1"
    local result="$2"

    local my_role
    my_role=$(detect_my_role)

    local task_file="$TASKS_DIR/processing/$task_id.json"
    [[ -f "$task_file" ]] || die "任务不在处理中: $task_id"

    # === 质量门（在 processing 阶段执行，通过后才移到 completed） ===
    if ! _run_quality_gate "$task_id" "$my_role"; then
        # Gate 失败，任务保持 processing，通知工蜂修复
        return 0
    fi

    # Gate 通过（或无需检查），正式完成: processing → completed
    local completed_at
    completed_at=$(date '+%Y-%m-%d %H:%M:%S')

    mkdir -p "$TASKS_DIR/completed"
    jq --arg result "$result" --arg at "$completed_at" \
        '.status = "completed" | .result = $result | .completed_at = $at' \
        "$task_file" > "$TASKS_DIR/completed/$task_id.json"
    rm -f "$task_file"

    emit_event "task.completed_by_queue" "$my_role" "task_id=$task_id"

    # 通知发布者（Gate 已通过，此通知可信）
    local from_role
    from_role=$(jq -r '.from' "$TASKS_DIR/completed/$task_id.json")
    local task_title
    task_title=$(jq -r '.title' "$TASKS_DIR/completed/$task_id.json")

    local notify_id="sys-task-done-$(date +%s)-${task_id}"
    mkdir -p "${INBOX_DIR}/${from_role}"
    jq -n \
        --arg id "$notify_id" \
        --arg from "$my_role" \
        --arg to "$from_role" \
        --arg content "[任务完成] $task_title (ID: $task_id)\n结果: $result" \
        --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
        --arg status "pending" \
        --arg priority "high" \
        '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority}' \
        > "${INBOX_DIR}/${from_role}/${notify_id}.json"

    local from_pane
    from_pane=$(jq -r --arg role "$from_role" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
    [[ -n "$from_pane" ]] && push_to_pane "$from_pane" \
        "[任务完成] $my_role 完成了任务 $task_id: $result" 2>/dev/null || true

    info "任务已完成: $task_id"

    # 更新 Story 中的任务状态
    _story_update_task "$task_id" "completed" "$result"

    # 自动解除依赖此任务的阻塞任务
    _check_and_unblock "$task_id"

    # 检查所属任务组是否全部完成
    _check_group_completion "$task_id"

    # 自动拉取下一个任务（工蜂自驱动）
    _auto_claim_next "$my_role"
}

# =============================================================================
# 子命令: group-status (查看任务组状态)
# =============================================================================

cmd_group_status() {
    local group_id="${1:-}"

    if [[ -z "$group_id" ]]; then
        # 列出所有任务组
        echo "任务组列表:"
        echo ""

        local found=false
        shopt -s nullglob
        for gf in "$TASKS_DIR/groups/"*.json; do
            [[ -f "$gf" ]] || continue
            found=true
            jq -r '"  [\(.status)] \(.id)\n    标题: \(.title) | 发布者: \(.from)\n    进度: \(.completed_count)/\(.total_count) 个任务\n"' "$gf"
        done
        shopt -u nullglob

        [[ "$found" == true ]] || echo "  (无任务组)"
        return
    fi

    # 显示单个任务组详情
    local group_file="$TASKS_DIR/groups/$group_id.json"
    [[ -f "$group_file" ]] || die "任务组不存在: $group_id"

    local group_title group_from group_status completed total
    group_title=$(jq -r '.title' "$group_file")
    group_from=$(jq -r '.from' "$group_file")
    group_status=$(jq -r '.status' "$group_file")
    completed=$(jq -r '.completed_count' "$group_file")
    total=$(jq -r '.total_count' "$group_file")

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "任务组: $group_id"
    echo "标题:   $group_title"
    echo "发布者: $group_from"
    echo "状态:   $group_status"
    echo "进度:   $completed/$total"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # 遍历组内每个任务，显示状态
    while IFS= read -r tid; do
        [[ -z "$tid" ]] && continue

        # 在各目录中查找任务
        local task_file="" task_status="unknown"
        for d in completed processing pending blocked failed; do
            if [[ -f "$TASKS_DIR/$d/$tid.json" ]]; then
                task_file="$TASKS_DIR/$d/$tid.json"
                task_status="$d"
                break
            fi
        done

        if [[ -z "$task_file" ]]; then
            echo "  ? $tid (未找到)"
            continue
        fi

        local icon
        case "$task_status" in
            completed)  icon="OK" ;;
            processing) icon=">>" ;;
            pending)    icon=".." ;;
            blocked)    icon="!!" ;;
            failed)     icon="XX" ;;
            *)          icon="??" ;;
        esac

        local t_type t_title t_claimed t_result t_depends
        t_type=$(jq -r '.type' "$task_file")
        t_title=$(jq -r '.title' "$task_file")
        t_claimed=$(jq -r '.claimed_by // ""' "$task_file")
        t_result=$(jq -r '.result // ""' "$task_file")
        t_depends=$(jq -r '(.depends_on // []) | if length > 0 then join(", ") else "" end' "$task_file")

        echo "  [$icon] $tid ($task_status)"
        echo "       $t_type: $t_title"
        [[ -n "$t_claimed" ]] && echo "       认领: $t_claimed"
        [[ -n "$t_depends" ]] && echo "       依赖: $t_depends"
        [[ -n "$t_result" ]] && echo "       结果: $t_result"
        echo ""
    done < <(jq -r '.tasks[]' "$group_file" 2>/dev/null)
}

# =============================================================================
# 子命令: recover-tasks (恢复卡住的任务)
# =============================================================================

cmd_recover_tasks() {
    local recovered=0
    local session_name="${SESSION_NAME:-swarm}"

    shopt -s nullglob
    for f in "$TASKS_DIR/processing/"*.json; do
        [[ -f "$f" ]] || continue

        local tid claimed_by
        tid=$(jq -r '.id' "$f")
        claimed_by=$(jq -r '.claimed_by // ""' "$f")

        # 检查认领者的 pane 是否还活着
        local pane_target=""
        pane_target=$(jq -r --arg role "$claimed_by" \
            '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")

        local pane_alive=true
        if [[ -z "$pane_target" || "$pane_target" == "null" ]]; then
            pane_alive=false
        elif ! tmux display-message -t "${session_name}:${pane_target}" -p '#{pane_id}' &>/dev/null; then
            pane_alive=false
        fi

        if [[ "$pane_alive" == false ]]; then
            # 恢复: processing → pending（原子移动优先，防并发重复恢复）
            mkdir -p "$TASKS_DIR/pending"
            if ! mv "$f" "$TASKS_DIR/pending/$tid.json" 2>/dev/null; then
                continue  # 被其他 recover-tasks 进程抢先处理了
            fi
            local tmp_file="$TASKS_DIR/pending/$tid.json.tmp"
            jq '.status = "pending" | .claimed_by = null | .claimed_at = null' \
                "$TASKS_DIR/pending/$tid.json" > "$tmp_file"
            mv "$tmp_file" "$TASKS_DIR/pending/$tid.json"
            recovered=$((recovered + 1))
            emit_event "task.recovered" "" "task_id=$tid" "original_claimer=$claimed_by"
            info "已恢复任务: $tid (原认领者 $claimed_by 已离线)"
        fi
    done
    shopt -u nullglob

    if [[ $recovered -eq 0 ]]; then
        info "没有需要恢复的任务"
    else
        info "共恢复 $recovered 个任务到待认领队列"
    fi
}

# =============================================================================
# 子命令: set-verify (设置项目级验证命令)
# =============================================================================

cmd_set_verify() {
    local verify_json=""
    local target_role=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role|-r) target_role="$2"; shift 2 ;;
            -*) die "set-verify: 未知选项 '$1'" ;;
            *)
                [[ -z "$verify_json" ]] && verify_json="$1" && shift || die "set-verify: 多余参数 '$1'"
                ;;
        esac
    done

    [[ -n "$verify_json" ]] || die "set-verify: 缺少 JSON 参数"
    [[ -n "$target_role" ]] || die "set-verify: 必须指定 --role <角色名>"

    # 验证输入是合法的 JSON 对象
    if ! echo "$verify_json" | jq -e 'type == "object"' &>/dev/null; then
        die "set-verify: 参数必须是 JSON 对象，如 '{\"build\":\"go build ./...\"}'"
    fi

    local project_info="$RUNTIME_DIR/project-info.json"

    if [[ -f "$project_info" ]]; then
        local tmp="${project_info}.tmp"
        jq --arg role "$target_role" --argjson cmds "$verify_json" '
            .verify_commands[$role] = ((.verify_commands[$role] // {}) * $cmds)
        ' "$project_info" > "$tmp" && mv "$tmp" "$project_info"
    else
        mkdir -p "$RUNTIME_DIR"
        jq -n --arg role "$target_role" --argjson cmds "$verify_json" \
            '{scanned_at: "", project_dir: "", file_tree: [], key_files: [], user_verify: {}, verify_commands: {($role): $cmds}, context_summary: ""}' \
            > "$project_info"
    fi

    echo "验证命令已更新 (角色: $target_role):"
    jq '.verify_commands' "$project_info"

    emit_event "config.verify_updated" "${SWARM_ROLE:-human}" "role=$target_role commands=$(echo "$verify_json" | jq -c '.')"
}

# =============================================================================
# 子命令: set-limit
# =============================================================================

cmd_set_limit() {
    local new_limit="${1:-}"

    if [[ -z "$new_limit" ]]; then
        # 无参数: 显示当前限制
        local current_max current_count
        current_max=$(jq -r '.max_cli // 0' "$STATE_FILE" 2>/dev/null)
        current_count=$(jq '.panes | length' "$STATE_FILE" 2>/dev/null)
        echo "当前 CLI 数量: $current_count"
        echo "当前上限:       $current_max (0=不限制)"
        return 0
    fi

    # 校验参数
    [[ "$new_limit" =~ ^[0-9]+$ ]] || die "上限必须是非负整数，当前输入: $new_limit"

    # 原子更新 state.json（flock 加锁）
    state_json_update '.max_cli = $limit' --argjson limit "$new_limit"

    local current_count
    current_count=$(jq '.panes | length' "$STATE_FILE" 2>/dev/null)
    echo "CLI 上限已更新: $new_limit (当前 CLI 数量: $current_count)"

    # 通知蜂群内所有角色（通过事件）
    emit_event "config.max_cli_changed" "human" "new_limit=$new_limit" "current_count=$current_count"

    # 通知 supervisor（如果存在）
    local sup_pane
    sup_pane=$(jq -r '.panes[] | select(.role == "supervisor") | .pane' "$STATE_FILE" 2>/dev/null || true)
    if [[ -n "$sup_pane" && "$sup_pane" != "null" ]]; then
        local notify_msg="[系统通知] CLI 上限已更新为 $new_limit（当前 $current_count 个）。如需扩容可继续使用 swarm-join.sh。"
        push_to_pane "$sup_pane" "$notify_msg" 2>/dev/null || true
    fi
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
  group-status [group-id]              查看任务组进度
  story-view <group-id>                查看任务组 Story（渲染为 markdown）
  set-verify '<json>' --role <name>    设置角色级验证命令（质量门按角色执行）
  recover-tasks                        恢复卡在 processing 的任务（认领者已离线）
  set-limit [N]                        查看/设置 CLI 数量上限 (0=不限制)

publish 选项:
  --assign|-a <role>           指派给特定角色（只有该角色能认领，通知也只推给该角色）
  --description|-d "<text>"    任务详细描述
  --priority|-p <level>        优先级: low/normal/high (默认: normal)
  --group|-g <group-id>        关联到任务组
  --depends <id1,id2,...>      依赖的任务 ID（逗号分隔，阻塞直到依赖完成）
  --branch|-b <branch>         指定关联分支（覆盖自动检测，支持逗号分隔多分支）
  --verify|-V <json>           任务级验证命令（JSON 对象，如 '{"test":"go test ./..."}'）

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
  swarm-msg.sh publish review "审核用户注册 API" -d "实现了注册、登录、JWT 鉴权"
  swarm-msg.sh claim task-xxx
  swarm-msg.sh complete-task task-xxx "审核通过"

  # 编排者定向派发（先查角色再分配）
  swarm-msg.sh list-roles                        # 查看在线角色
  swarm-msg.sh publish develop "实现注册 API" --assign backend \
    -d "实现 POST /api/register, 参数: email, password, name"
  swarm-msg.sh publish develop "设计 users 表" --assign database \
    -d "字段: id, email, password_hash, name, created_at"
  swarm-msg.sh publish develop "实现注册页面" --assign frontend \
    -d "表单: 邮箱、密码、姓名, 调用 POST /api/register"

  # 任务组（带依赖 + 指派的批量任务）
  G=$(swarm-msg.sh create-group "用户注册系统")
  T1=$(swarm-msg.sh publish develop "实现注册 API" -g $G --assign backend)
  T2=$(swarm-msg.sh publish develop "设计 users 表" -g $G --assign database)
  T3=$(swarm-msg.sh publish develop "实现注册页面" -g $G --assign frontend --depends $T2)
  T4=$(swarm-msg.sh publish review "审核全部代码" -g $G --assign reviewer --depends $T1,$T2,$T3)
  swarm-msg.sh group-status $G
  swarm-msg.sh list-tasks --group $G --all

  # 质量门验证命令（由 inspector 按角色配置）
  swarm-msg.sh set-verify '{"build":"cd backend && go build ./..."}' --role backend
  swarm-msg.sh set-verify '{"build":"npm run build","test":"npm test"}' --role frontend
  # 或发任务时逐个指定
  swarm-msg.sh publish develop "实现 API" --verify '{"build":"go build ./...","test":"go test ./..."}'
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
    mkdir -p "$TASKS_DIR"/{pending,processing,completed,failed,blocked,groups}

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
        group-status)
            cmd_group_status "${1:-}"
            ;;
        story-view)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh story-view <group-id>"
            _story_render_markdown "$1"
            ;;
        recover-tasks)
            cmd_recover_tasks
            ;;
        set-verify)
            [[ $# -ge 1 ]] || die "用法: swarm-msg.sh set-verify '<json>' --role <角色名>"
            cmd_set_verify "$@"
            ;;
        set-limit)
            cmd_set_limit "${1:-}"
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
