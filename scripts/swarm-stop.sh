#!/usr/bin/env bash

################################################################################
# Swarm Stop Script - 蜂群系统停止脚本
#
# 功能说明：
#   - 停止运行中的 tmux 蜂群会话
#   - 保存最终状态和统计信息
#   - 可选择归档日志文件
#   - 清理 watcher 进程和临时资源
#
# 使用方法：
#   swarm-stop.sh [选项]
#
# 选项：
#   --force         强制停止，不保存状态，不确认
#   --keep-logs     保留日志文件，不归档
#   --help          显示此帮助信息
#
# 作者: Swarm System
# 日期: 2026-02-12
# 版本: 1.0.0
################################################################################

set -euo pipefail

################################################################################
# 配置区域
################################################################################

# 基础路径配置（统一由 swarm-lib.sh 管理）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/swarm-lib.sh"
readonly ARCHIVE_DIR="${LOGS_DIR}/archive"

# 时间格式配置（使用 defaults.conf 统一定义的 LOG_TIMESTAMP_FORMAT）
readonly ARCHIVE_DATE_FORMAT="%Y%m%d_%H%M%S"

# 默认选项
FORCE_STOP=false
KEEP_LOGS=false
CLEAN_ALL=false
readonly RESUME_SCHEMA_VERSION=2

# 显示帮助信息
show_help() {
    cat << EOF
Swarm Stop Script - 蜂群系统停止脚本

使用方法:
    ${0##*/} [选项]

选项:
    --force         强制停止，不保存状态，不确认
    --keep-logs     保留日志文件，不归档
    --clean         停止后清理所有运行时数据（messages/tasks/state/events）
    --help          显示此帮助信息

示例:
    # 正常停止（会确认）
    ${0##*/}

    # 强制停止
    ${0##*/} --force

    # 停止但保留日志
    ${0##*/} --keep-logs

    # 停止并清理所有数据（下次全新开始）
    ${0##*/} --force --clean

环境变量:
    SWARM_ROOT      蜂群系统主目录（默认: 脚本所在目录的父目录）
    SWARM_SESSION   Tmux 会话名称（默认: swarm）

EOF
}

################################################################################
# 核心功能函数
################################################################################

# 检查 tmux session 是否存在
check_session_exists() {
    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log_warn "Tmux 会话 '$SESSION_NAME' 不存在或已停止"
        return 1
    fi
    return 0
}

# 获取运行时长（秒）
get_runtime_duration() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "0"
        return
    fi

    local start_time
    start_time=$(jq -r '.started_at // empty' "$STATE_FILE" 2>/dev/null || echo "")

    if [[ -z "$start_time" ]]; then
        echo "0"
        return
    fi

    local start_epoch end_epoch
    # macOS: date -j -f, Linux: date -d
    start_epoch=$(date -j -f "$LOG_TIMESTAMP_FORMAT" "$start_time" +%s 2>/dev/null \
        || date -d "$start_time" +%s 2>/dev/null \
        || echo "0")
    end_epoch=$(date +%s)

    echo $((end_epoch - start_epoch))
}

# 格式化时长为人类可读格式
format_duration() {
    local total_seconds=$1
    local days=$((total_seconds / 86400))
    local hours=$(((total_seconds % 86400) / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))

    local result=""
    [[ $days -gt 0 ]] && result="${days}天 "
    [[ $hours -gt 0 ]] && result="${result}${hours}小时 "
    [[ $minutes -gt 0 ]] && result="${result}${minutes}分钟 "
    result="${result}${seconds}秒"

    echo "$result"
}

build_resume_snapshot() {
    local state_file="${1:-$STATE_FILE}"
    [[ -f "$state_file" ]] || return 1

    local profile_name profile_file profile_hash
    profile_name=$(jq -r '.profile // ""' "$state_file" 2>/dev/null)
    profile_file="${CONFIG_DIR}/profiles/${profile_name}.json"
    profile_hash=""
    [[ -f "$profile_file" ]] && profile_hash=$(_sha256_file "$profile_file")

    local role_prompt_hashes='{}'
    while IFS= read -r config_rel; do
        [[ -z "$config_rel" || "$config_rel" == "null" ]] && continue
        local role_file role_hash
        role_file="${CONFIG_DIR}/roles/${config_rel}"
        role_hash=""
        [[ -f "$role_file" ]] && role_hash=$(_sha256_file "$role_file")
        role_prompt_hashes=$(jq -c --arg key "$config_rel" --arg value "$role_hash" \
            '. + {($key): $value}' <<<"$role_prompt_hashes")
    done < <(jq -r '.panes[].config // empty' "$state_file" 2>/dev/null | sort -u)

    local permission_hashes='{}'
    while IFS= read -r pane_json; do
        [[ -z "$pane_json" ]] && continue
        local instance perms_json perm_hash
        instance=$(jq -r '.instance' <<<"$pane_json")
        perms_json=$(jq -c '.permissions // {}' <<<"$pane_json")
        perm_hash=$(_sha256_string "$perms_json")
        permission_hashes=$(jq -c --arg key "$instance" --arg value "$perm_hash" \
            '. + {($key): $value}' <<<"$permission_hashes")
    done < <(jq -c '.panes[]' "$state_file" 2>/dev/null)

    jq -nc \
        --argjson schema_version "$RESUME_SCHEMA_VERSION" \
        --arg profile_hash "$profile_hash" \
        --arg workflow_hash "" \
        --argjson role_prompt_hashes "$role_prompt_hashes" \
        --argjson permission_snapshot_hashes "$permission_hashes" \
        '{
            schema_version: $schema_version,
            profile_hash: $profile_hash,
            workflow_hash: $workflow_hash,
            role_prompt_hashes: $role_prompt_hashes,
            permission_snapshot_hashes: $permission_snapshot_hashes
        }'
}

# 统计任务数量
count_tasks() {
    local status=$1

    if [[ ! -d "$TASKS_DIR/$status" ]]; then
        echo "0"
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

# 统计日志文件
count_log_files() {
    if [[ ! -d "$LOGS_DIR" ]]; then
        echo "0"
        return
    fi

    find "$LOGS_DIR" -type f -name "*.log" 2>/dev/null | wc -l | tr -d ' '
}

# 获取活动角色数量
get_active_roles_count() {
    if ! check_session_exists; then
        echo "0"
        return
    fi

    # 从 state.json 读取角色数量
    if [[ -f "$STATE_FILE" ]]; then
        jq -r '.panes | length' "$STATE_FILE" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# 显示会话摘要
show_session_summary() {
    log_info "========================================"
    log_info "蜂群会话摘要"
    log_info "========================================"

    local duration_seconds
    duration_seconds=$(get_runtime_duration)
    local duration_formatted
    duration_formatted=$(format_duration "$duration_seconds")

    local completed_tasks pending_tasks
    completed_tasks=$(count_tasks "completed")
    pending_tasks=$(count_tasks "pending")

    local log_files_count
    log_files_count=$(count_log_files)

    local active_roles
    active_roles=$(get_active_roles_count)

    echo "会话名称:      $SESSION_NAME"
    echo "运行时长:      $duration_formatted"
    echo "活动角色:      $active_roles 个"
    echo "已完成任务:    $completed_tasks 个"
    echo "未完成任务:    $pending_tasks 个"
    echo "日志文件:      $log_files_count 个"

    log_info "========================================"
}

# 用户确认
confirm_stop() {
    if [[ "$FORCE_STOP" == "true" ]]; then
        return 0
    fi

    local active_roles completed_tasks pending_tasks
    active_roles=$(get_active_roles_count)
    completed_tasks=$(count_tasks "completed")
    pending_tasks=$(count_tasks "pending")

    echo ""
    echo "确认停止蜂群？这将终止所有 $active_roles 个角色。"
    echo "已完成任务：$completed_tasks 个"
    echo "未完成任务：$pending_tasks 个"
    echo ""
    read -rp "是否继续？[y/N] " response

    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            log_info "用户取消停止操作"
            return 1
            ;;
    esac
}

# 保存最终状态
save_final_state() {
    if [[ "$FORCE_STOP" == "true" ]]; then
        log_info "强制停止模式，跳过保存状态"
        return 0
    fi

    log_info "保存最终状态..."

    local stop_time
    stop_time=$(date +"$LOG_TIMESTAMP_FORMAT")

    local duration_seconds
    duration_seconds=$(get_runtime_duration)

    local completed_tasks pending_tasks
    completed_tasks=$(count_tasks "completed")
    pending_tasks=$(count_tasks "pending")

    local state_json
    state_json=$(cat <<EOF
{
  "session_name": "$SESSION_NAME",
  "stop_time": "$stop_time",
  "duration_seconds": $duration_seconds,
  "tasks": {
    "completed": $completed_tasks,
    "pending": $pending_tasks
  },
  "status": "stopped"
}
EOF
)

    # 收集 processing 中的孤儿任务 ID 列表（用于 resume 恢复）
    local processing_tasks="[]"
    if [[ -d "$TASKS_DIR/processing" ]]; then
        processing_tasks=$(find "$TASKS_DIR/processing" -name "*.json" -type f -exec basename {} .json \; \
            | jq -R -s 'split("\n") | map(select(length > 0))')
    fi

    local resume_snapshot='{}'
    if [[ -f "$STATE_FILE" ]]; then
        resume_snapshot=$(build_resume_snapshot "$STATE_FILE" 2>/dev/null || echo '{}')
    fi

    # 合并停止信息到已有状态（保留 panes、project 等启动信息）
    # 走 safe_write --lock，与 state_json_update 的锁语义保持一致，避免和 watchdog/join/leave 写 state 并发竞态
    if [[ -f "$STATE_FILE" ]]; then
        if ! jq \
            --arg stop_time "$stop_time" \
            --argjson duration "${duration_seconds:-0}" \
            --argjson completed "${completed_tasks:-0}" \
            --argjson pending "${pending_tasks:-0}" \
            --argjson orphan_tasks "$processing_tasks" \
            --argjson schema_version "$RESUME_SCHEMA_VERSION" \
            --argjson snapshot "$resume_snapshot" \
            '. + {
                schema_version: $schema_version,
                stop_time: $stop_time,
                duration_seconds: $duration,
                tasks: { completed: $completed, pending: $pending },
                status: "stopped",
                resume: {
                    orphan_tasks: $orphan_tasks,
                    resumable: true,
                    snapshot: $snapshot
                }
            }' "$STATE_FILE" | safe_write "$STATE_FILE" --lock; then
            log_warn "状态合并失败，保留原始状态文件"
        fi
    else
        echo "$state_json" | safe_write "$STATE_FILE"
    fi

    log_success "状态已保存到: $STATE_FILE"
}

# 归档日志文件
archive_logs() {
    if [[ "$KEEP_LOGS" == "true" ]]; then
        log_info "保留日志文件，跳过归档"
        return 0
    fi

    if [[ ! -d "$LOGS_DIR" ]] || [[ -z "$(ls -A "$LOGS_DIR"/*.log 2>/dev/null)" ]]; then
        log_info "没有日志文件需要归档"
        return 0
    fi

    log_info "归档日志文件..."

    # 创建归档目录
    mkdir -p "$ARCHIVE_DIR"

    local archive_name
    archive_name="swarm_logs_$(date +"$ARCHIVE_DATE_FORMAT").tar.gz"
    local archive_path="${ARCHIVE_DIR}/${archive_name}"

    # 打包日志文件
    if tar -czf "$archive_path" -C "$LOGS_DIR" \
        $(find "$LOGS_DIR" -maxdepth 1 -type f -name "*.log" -exec basename {} \;) 2>/dev/null; then

        # 删除原始日志文件
        find "$LOGS_DIR" -maxdepth 1 -type f -name "*.log" -delete

        log_success "日志已归档到: $archive_path"
    else
        log_warn "日志归档失败，保留原始文件"
    fi
}

# 清理任务看门狗进程
cleanup_watchdog() {
    if [[ -f "$STATE_FILE" ]]; then
        local watchdog_pid
        watchdog_pid=$(jq -r '.watchdog_pid // empty' "$STATE_FILE" 2>/dev/null || true)
        if [[ -n "$watchdog_pid" ]]; then
            log_info "停止任务看门狗进程 (PID: $watchdog_pid)..."
            if kill -0 "$watchdog_pid" 2>/dev/null; then
                kill "$watchdog_pid" 2>/dev/null || true
                log_success "看门狗进程已停止"
            else
                log_info "看门狗进程已不存在，跳过"
            fi
        fi
    fi
}

# 清理 pane watcher 守护进程
cleanup_watchers() {
    if [[ -f "$STATE_FILE" ]]; then
        local watcher_pids
        watcher_pids=$(jq -r '.panes[].watcher_pid // empty' "$STATE_FILE" 2>/dev/null || true)
        if [[ -n "$watcher_pids" ]]; then
            log_info "停止 pane watcher 进程..."
            local count=0
            while IFS= read -r pid; do
                [[ -z "$pid" ]] && continue
                if kill -0 "$pid" 2>/dev/null; then
                    kill "$pid" 2>/dev/null || true
                    ((count++)) || true
                fi
            done <<< "$watcher_pids"
            log_success "$count 个 watcher 进程已停止"
        fi
    fi
}

# 移除所有 git worktree 并列出分支供人类审查
cleanup_worktrees() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 0
    fi

    local project_dir worktree_dir
    project_dir=$(jq -r '.project // ""' "$STATE_FILE" 2>/dev/null)
    worktree_dir=$(jq -r '.worktree_dir // ""' "$STATE_FILE" 2>/dev/null)

    [[ -n "$project_dir" && -d "$project_dir" ]] || return 0

    # 列出蜂群创建的分支
    local branches=()
    while IFS= read -r branch; do
        [[ -n "$branch" ]] && branches+=("$branch")
    done < <(jq -r '.panes[].branch // empty' "$STATE_FILE" 2>/dev/null)

    if [[ ${#branches[@]} -gt 0 ]]; then
        log_info "移除 git worktrees..."
        for wt in "$worktree_dir"/*/; do
            [[ -d "$wt" ]] && git -C "$project_dir" worktree remove --force "$wt" 2>/dev/null || true
        done
        rm -rf "$worktree_dir"
        log_success "Worktrees 已清理"

        echo ""
        echo "以下 swarm 分支已保留，供人类审查和合并:"
        for br in "${branches[@]}"; do
            # 检查分支是否有未合并的提交
            local ahead=0
            ahead=$(git -C "$project_dir" rev-list --count "HEAD..$br" 2>/dev/null || echo "0")
            if [[ "$ahead" -gt 0 ]]; then
                echo "  * $br ($ahead 个新提交)"
            else
                echo "  - $br (无新提交)"
            fi
        done
        echo ""
        echo "合并命令:"
        echo "  git merge <分支名>           # 合并某个分支"
        echo "  git branch -d <分支名>       # 删除已合并的分支"
        echo "  git branch -D <分支名>       # 强制删除分支"
        echo ""
    fi
}

# 清理运行时数据（messages、tasks、state、events）
cleanup_runtime_data() {
    log_info "清理运行时数据..."

    local cleaned=0

    # 清理消息目录
    if [[ -d "$RUNTIME_DIR/messages" ]]; then
        rm -rf "$RUNTIME_DIR/messages"
        log_info "  已清理: messages/"
        ((cleaned++)) || true
    fi

    # 清理任务目录内容
    if [[ -d "$TASKS_DIR" ]]; then
        rm -f "$TASKS_DIR"/pending/*.json "$TASKS_DIR"/processing/*.json \
              "$TASKS_DIR"/completed/*.json "$TASKS_DIR"/failed/*.json 2>/dev/null || true
        log_info "  已清理: tasks/"
        ((cleaned++)) || true
    fi

    # 清理 state.json
    if [[ -f "$STATE_FILE" ]]; then
        rm -f "$STATE_FILE"
        log_info "  已清理: state.json"
        ((cleaned++)) || true
    fi

    # 清理 events.jsonl
    if [[ -f "$EVENTS_LOG" ]]; then
        rm -f "$EVENTS_LOG"
        log_info "  已清理: events.jsonl"
        ((cleaned++)) || true
    fi

    # 清理临时文件
    rm -f "$RUNTIME_DIR"/.*.txt "$RUNTIME_DIR"/.*.json 2>/dev/null || true

    log_success "运行时数据已清理 ($cleaned 项)"
}

# 关闭 tmux session
kill_session() {
    if ! check_session_exists; then
        log_info "会话不存在，跳过关闭"
        return 0
    fi

    log_info "关闭 tmux 会话: $SESSION_NAME"

    if tmux kill-session -t "$SESSION_NAME" 2>/dev/null; then
        log_success "Tmux 会话已关闭"
    else
        log_warn "关闭 tmux 会话失败"
        return 1
    fi
}

################################################################################
# 主函数
################################################################################

main() {
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE_STOP=true
                shift
                ;;
            --keep-logs)
                KEEP_LOGS=true
                shift
                ;;
            --clean)
                CLEAN_ALL=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                die "未知选项: $1。使用 --help 查看帮助信息。"
                ;;
        esac
    done

    # 检查依赖
    check_dependencies tmux jq date

    # 检查会话是否存在
    if ! check_session_exists; then
        log_warn "没有运行中的蜂群会话需要停止"
        # 即使 session 不在，--clean 仍然可以清理残留数据
        if [[ "$CLEAN_ALL" == "true" ]]; then
            cleanup_runtime_data
        fi
        exit 0
    fi

    # 显示会话摘要
    show_session_summary

    # 确认停止
    if ! confirm_stop; then
        log_info "停止操作已取消"
        exit 0
    fi

    echo ""
    log_info "开始停止蜂群系统..."
    echo ""

    # 停止任务看门狗进程（在 save_final_state 之前，确保 state.json 完整可读）
    cleanup_watchdog

    # 清理 watcher 进程（在 kill session 之前，避免 watcher 访问已销毁的 pane）
    cleanup_watchers

    # 为所有实例执行最终 auto_commit 并生成恢复摘要（非强制停止时）
    if [[ "$FORCE_STOP" != "true" && -f "$STATE_FILE" ]]; then
        # 步骤 A.0: 捕获所有 pane 最后输出（必须在 kill session 前，pane 还活着时）
        log_info "捕获 CLI 最后输出..."
        mkdir -p "${RESUME_SUMMARY_DIR:-$RUNTIME_DIR/resume}"
        while IFS='|' read -r inst pane; do
            [[ -n "$inst" && -n "$pane" ]] || continue
            local output_file="${RESUME_SUMMARY_DIR:-$RUNTIME_DIR/resume}/${inst}.pane-output"
            tmux capture-pane -t "$SESSION_NAME:$pane" -p -S -200 2>/dev/null \
                | sed '/^[[:space:]]*$/d' \
                | tail -"${RESUME_PANE_LINES:-50}" \
                > "$output_file" || true
        done < <(jq -r '.panes[] | "\(.instance)|\(.pane)"' "$STATE_FILE" 2>/dev/null)
        log_success "CLI 输出已捕获"

        # 步骤 A: 为所有实例执行最终 auto_commit（确保停止前的代码不丢失）
        log_info "为所有实例执行最终代码提交..."
        local commit_count=0
        while IFS='|' read -r inst wt; do
            [[ -n "$inst" && -n "$wt" && -d "$wt" ]] || continue
            if auto_commit_worktree "$inst" "$wt"; then
                ((commit_count++)) || true
            fi
        done < <(jq -r '.panes[] | "\(.instance)|\(.worktree // "")"' "$STATE_FILE" 2>/dev/null)
        [[ $commit_count -gt 0 ]] && log_success "$commit_count 个实例的代码已提交"

        # 步骤 B: 为所有实例生成恢复摘要
        log_info "生成恢复摘要..."
        save_all_resume_summaries "$STATE_FILE"
        log_success "恢复摘要已生成到 ${RESUME_SUMMARY_DIR:-$RUNTIME_DIR/resume}/"
    fi

    # 保存最终状态
    save_final_state

    # 归档日志
    archive_logs

    # 清理项目目录中注入的蜂群上下文
    cleanup_swarm_context "$STATE_FILE"

    # 移除所有 git worktree 并列出分支供人类审查
    cleanup_worktrees

    # 发射停止事件（在 kill session 之前，确保事件写入）
    emit_event "system.stopped" "" "session=$SESSION_NAME"

    # 关闭 tmux session
    kill_session

    # 清理运行时数据（可选）
    if [[ "$CLEAN_ALL" == "true" ]]; then
        cleanup_runtime_data
    fi

    echo ""
    log_success "蜂群系统已成功停止"
    echo ""
}

# 执行主函数
main "$@"
