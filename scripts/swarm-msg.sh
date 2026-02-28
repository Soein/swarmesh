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

            # 检查目标是否为当前角色
            local event_to
            event_to=$(echo "$line" | jq -r '.data.to // ""' 2>/dev/null)
            if [[ "$event_type" != "message.broadcast" && "$event_to" != "$my_role" ]]; then
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
        file_mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "0")
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
  group-status [group-id]              查看任务组进度
  story-view <group-id>                查看任务组 Story（渲染为 markdown）
  set-verify '<json>' --role <name>    设置角色级验证命令（质量门按角色执行）
  recover-tasks                        恢复卡在 processing 的任务（认领者已离线）
  set-limit [N]                        查看/设置 CLI 数量上限 (0=不限制)
  cleanup [--ttl <秒>] [--gate-logs] [--dry-run]  清理过期消息/任务/质量门日志

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
