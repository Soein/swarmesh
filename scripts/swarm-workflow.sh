#!/usr/bin/env bash
################################################################################
# swarm-workflow.sh - 多 CLI 工作流引擎
#
# 核心功能: 按工作流定义自动编排多个 AI CLI 协作
#
# 工作流执行逻辑:
#   1. 读取工作流 JSON 配置
#   2. 按阶段 (stage) 顺序执行
#   3. 同一阶段内的任务可以并行执行
#   4. 跨阶段通过 swarm-relay.sh 自动传递结果
#   5. 支持超时、失败处理、断点恢复
#
# 用法:
#   swarm-workflow.sh <workflow.json> <需求描述> [选项]
#   swarm-workflow.sh --status
#   swarm-workflow.sh --resume <workflow_id>
#
# 选项:
#   --timeout <秒>      单个任务超时 (默认: 300)
#   --from-stage <N>    从第 N 阶段开始执行
#   --dry-run           仅显示执行计划，不实际执行
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SWARM_ROOT="${SWARM_ROOT:-$(dirname "$SCRIPT_DIR")}"
readonly SCRIPTS_DIR="${SWARM_ROOT}/scripts"
readonly STATE_FILE="${SWARM_ROOT}/runtime/state.json"
readonly WF_STATE_DIR="${SWARM_ROOT}/runtime/workflows"
readonly RESULTS_DIR="${SWARM_ROOT}/runtime/results"
readonly SESSION_NAME="${SWARM_SESSION:-swarm}"

# 加载共享事件库
source "${SCRIPT_DIR}/swarm-lib.sh"

# 默认配置
TASK_TIMEOUT=300
FROM_STAGE=1
DRY_RUN=false

# ============================================================================
# 工具函数
# ============================================================================

info()    { echo -e "\033[0;34m[workflow]\033[0m $*" >&2; }
success() { echo -e "\033[0;32m[workflow]\033[0m $*" >&2; }
warn()    { echo -e "\033[1;33m[workflow]\033[0m $*" >&2; }
stage()   { echo -e "\n\033[1;35m━━━ $* ━━━\033[0m" >&2; }

# ============================================================================
# 工作流状态管理
# ============================================================================

# 创建工作流运行实例
create_workflow_state() {
    local wf_file="$1"
    local requirement="$2"
    local wf_id="wf-$(date +%s)-$$-${RANDOM}"

    mkdir -p "$WF_STATE_DIR"

    local state_file="${WF_STATE_DIR}/${wf_id}.json"

    cat > "$state_file" <<EOF
{
  "id": "$wf_id",
  "workflow_file": "$wf_file",
  "requirement": $(echo "$requirement" | jq -Rs .),
  "status": "running",
  "started_at": "$(get_timestamp)",
  "current_stage": 0,
  "tasks": {},
  "results": {}
}
EOF

    echo "$wf_id"
}

# 更新任务状态
update_task_state() {
    local wf_id="$1"
    local task_id="$2"
    local status="$3"
    local state_file="${WF_STATE_DIR}/${wf_id}.json"

    local tmp
    tmp=$(mktemp)
    jq --arg tid "$task_id" --arg st "$status" \
        '.tasks[$tid] = $st' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

# 保存任务结果
save_task_result() {
    local wf_id="$1"
    local task_id="$2"
    local result="$3"
    local state_file="${WF_STATE_DIR}/${wf_id}.json"

    local tmp
    tmp=$(mktemp)
    jq --arg tid "$task_id" --arg res "$result" \
        '.results[$tid] = $res' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

# ============================================================================
# 任务执行
# ============================================================================

# 执行单个任务
execute_task() {
    local wf_id="$1"
    local task_json="$2"
    local requirement="$3"

    local task_id role template timeout_val
    task_id=$(echo "$task_json" | jq -r '.id')
    role=$(echo "$task_json" | jq -r '.role')
    template=$(echo "$task_json" | jq -r '.template // ""')
    timeout_val=$(echo "$task_json" | jq -r ".timeout // $TASK_TIMEOUT")

    # 获取依赖任务的结果，替换模板变量
    local depends_on
    depends_on=$(echo "$task_json" | jq -r '.depends_on // [] | .[]' 2>/dev/null)

    local message="$template"

    # 替换 {{task-id}} 模板变量为实际结果
    if [[ -n "$depends_on" ]]; then
        local state_file="${WF_STATE_DIR}/${wf_id}.json"
        for dep_id in $depends_on; do
            local dep_result
            dep_result=$(jq -r --arg tid "$dep_id" '.results[$tid] // "（无结果）"' "$state_file")
            message="${message//\{\{${dep_id}\}\}/$dep_result}"
        done
    fi

    # 替换 {{requirement}} 变量
    message="${message//\{\{requirement\}\}/$requirement}"

    # 如果没有模板，使用默认消息
    if [[ -z "$message" ]] || [[ "$message" == "null" ]]; then
        message="请完成以下任务: $requirement"
    fi

    info "执行任务 [$task_id] → 角色: $role"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] 将发送给 $role: ${message:0:80}..."
        update_task_state "$wf_id" "$task_id" "dry-run"
        return 0
    fi

    # 发送任务
    update_task_state "$wf_id" "$task_id" "processing"
    "$SCRIPTS_DIR/swarm-send.sh" "$role" "$message" > /dev/null 2>&1

    # 等待完成（事件驱动，零轮询）
    info "等待 $role 完成 [$task_id]..."
    if "$SCRIPTS_DIR/swarm-events.sh" --wait task.completed \
            --role "$role" --timeout "$timeout_val" > /dev/null 2>&1; then
        success "任务 [$task_id] 完成"
        update_task_state "$wf_id" "$task_id" "completed"

        # 捕获结果（优先从日志精确提取，无截断）
        local log_file log_offset result
        log_file=$(jq -r --arg q "$role" '
            .panes[] | select(.role == $q) | .log
        ' "$STATE_FILE")

        # 从 task.sent 事件获取偏移量
        log_offset=$(grep "\"task.sent\"" "$EVENTS_LOG" 2>/dev/null \
            | grep "\"role\":\"$role\"" \
            | tail -1 \
            | jq -r '.data.log_offset // "0"')

        if [[ "$log_offset" != "0" ]] && [[ -f "$log_file" ]]; then
            result=$(tail -c "+$((log_offset + 1))" "$log_file" 2>/dev/null \
                | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
                | grep -vE '^\s*$|^❯|^>|^›|Type your message')
        else
            # 回退到 pane 截屏
            local pane_info
            pane_info=$(jq -r --arg q "$role" '
                .panes[] | select(.role == $q) | .pane
            ' "$STATE_FILE")
            result=$(tmux capture-pane -t "${SESSION_NAME}:${pane_info}" -p -S -50 2>/dev/null \
                | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
                | grep -vE '^\s*$|^❯|^>|^›|Type your message' \
                | tail -30)
        fi

        save_task_result "$wf_id" "$task_id" "$result"
        return 0
    else
        warn "任务 [$task_id] 超时！"
        update_task_state "$wf_id" "$task_id" "timeout"
        return 1
    fi
}

# ============================================================================
# 阶段执行
# ============================================================================

execute_stage() {
    local wf_id="$1"
    local stage_json="$2"
    local requirement="$3"

    local stage_num stage_name parallel
    stage_num=$(echo "$stage_json" | jq -r '.stage')
    stage_name=$(echo "$stage_json" | jq -r '.name')
    parallel=$(echo "$stage_json" | jq -r '.parallel // false')

    stage "阶段 $stage_num: $stage_name"

    # 发射阶段开始事件
    emit_event "workflow.stage_started" "" "workflow_id=$wf_id" "stage=$stage_num" "name=$stage_name"

    local tasks_count
    tasks_count=$(echo "$stage_json" | jq '.tasks | length')

    if [[ "$parallel" == "true" ]] && [[ $tasks_count -gt 1 ]]; then
        # 并行执行
        info "并行执行 $tasks_count 个任务..."

        local pids=()
        local task_ids=()

        for ((i=0; i<tasks_count; i++)); do
            local task
            task=$(echo "$stage_json" | jq -c ".tasks[$i]")
            local tid
            tid=$(echo "$task" | jq -r '.id')
            task_ids+=("$tid")

            execute_task "$wf_id" "$task" "$requirement" &
            pids+=($!)
        done

        # 等待所有并行任务完成
        local all_ok=true
        for ((i=0; i<${#pids[@]}; i++)); do
            if ! wait "${pids[$i]}"; then
                warn "并行任务 [${task_ids[$i]}] 失败"
                all_ok=false
            fi
        done

        if [[ "$all_ok" == "false" ]]; then
            warn "阶段 $stage_num 中有任务失败"
            return 1
        fi
    else
        # 串行执行
        for ((i=0; i<tasks_count; i++)); do
            local task
            task=$(echo "$stage_json" | jq -c ".tasks[$i]")

            if ! execute_task "$wf_id" "$task" "$requirement"; then
                warn "串行任务失败，阶段终止"
                return 1
            fi
        done
    fi

    success "阶段 $stage_num 完成"

    # 发射阶段完成事件
    emit_event "workflow.stage_completed" "" "workflow_id=$wf_id" "stage=$stage_num" "name=$stage_name"

    return 0
}

# ============================================================================
# 工作流执行
# ============================================================================

run_workflow() {
    local wf_file="$1"
    local requirement="$2"

    # 读取工作流
    [[ -f "$wf_file" ]] || die "工作流文件不存在: $wf_file"

    local wf_json
    wf_json=$(cat "$wf_file")

    local wf_name
    wf_name=$(echo "$wf_json" | jq -r '.name')
    local stages_count
    stages_count=$(echo "$wf_json" | jq '.stages | length')

    echo ""
    echo -e "\033[1;36m╔══════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;36m║  工作流引擎 - $wf_name\033[0m"
    echo -e "\033[1;36m╠══════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;36m║  需求: ${requirement:0:42}\033[0m"
    echo -e "\033[1;36m║  阶段: $stages_count 个\033[0m"
    echo -e "\033[1;36m║  模式: $([ "$DRY_RUN" == "true" ] && echo "试运行" || echo "实际执行")\033[0m"
    echo -e "\033[1;36m╚══════════════════════════════════════════════════╝\033[0m"
    echo ""

    # 创建工作流状态
    local wf_id
    wf_id=$(create_workflow_state "$wf_file" "$requirement")
    info "工作流 ID: $wf_id"

    # 发射工作流启动事件
    emit_event "workflow.started" "" "workflow_id=$wf_id" "workflow=$wf_name" "stages=$stages_count"

    # 按阶段执行
    local failed=false
    for ((s=0; s<stages_count; s++)); do
        local stage_json
        stage_json=$(echo "$wf_json" | jq -c ".stages[$s]")
        local stage_num
        stage_num=$(echo "$stage_json" | jq -r '.stage')

        # 跳过指定阶段之前的
        if [[ $stage_num -lt $FROM_STAGE ]]; then
            info "跳过阶段 $stage_num（从阶段 $FROM_STAGE 开始）"
            continue
        fi

        if ! execute_stage "$wf_id" "$stage_json" "$requirement"; then
            warn "阶段 $stage_num 失败！工作流中止。"
            failed=true
            break
        fi
    done

    # 最终报告
    echo ""
    if [[ "$failed" == "true" ]]; then
        echo -e "\033[1;33m╔══════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[1;33m║  工作流执行中止（部分完成）\033[0m"
        echo -e "\033[1;33m║  ID: $wf_id\033[0m"
        echo -e "\033[1;33m║  使用 --resume 恢复: swarm-workflow.sh --resume $wf_id\033[0m"
        echo -e "\033[1;33m╚══════════════════════════════════════════════════╝\033[0m"

        # 发射工作流失败事件
        emit_event "workflow.failed" "" "workflow_id=$wf_id" "workflow=$wf_name"
    else
        echo -e "\033[1;32m╔══════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[1;32m║  工作流执行完成！\033[0m"
        echo -e "\033[1;32m║  ID: $wf_id\033[0m"
        echo -e "\033[1;32m║  结果: ${WF_STATE_DIR}/${wf_id}.json\033[0m"
        echo -e "\033[1;32m╚══════════════════════════════════════════════════╝\033[0m"

        # 发射工作流完成事件
        emit_event "workflow.completed" "" "workflow_id=$wf_id" "workflow=$wf_name"
    fi
}

# 显示工作流状态
show_status() {
    [[ -d "$WF_STATE_DIR" ]] || die "没有工作流记录"

    echo ""
    echo "工作流历史:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    for f in "$WF_STATE_DIR"/wf-*.json; do
        [[ -f "$f" ]] || continue
        local id status started req
        id=$(jq -r '.id' "$f")
        status=$(jq -r '.status' "$f")
        started=$(jq -r '.started_at' "$f")
        req=$(jq -r '.requirement' "$f" | head -c 50)
        echo "  [$status] $id  $started  $req"
    done

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ============================================================================
# 参数解析和主入口
# ============================================================================

show_help() {
    cat <<'EOF'
swarm-workflow - 多 CLI 工作流引擎

用法:
  swarm-workflow.sh <workflow.json> <需求描述> [选项]
  swarm-workflow.sh --status
  swarm-workflow.sh --resume <workflow_id>

选项:
  --timeout <秒>      单任务超时 (默认: 300)
  --from-stage <N>    从第 N 阶段开始
  --dry-run           试运行（不实际执行）
  --help              帮助

示例:
  # 执行完整功能开发流程
  swarm-workflow.sh workflows/feature-complete.json "实现用户登录"

  # 试运行
  swarm-workflow.sh workflows/feature-complete.json "实现登录" --dry-run

  # 从第 3 阶段恢复
  swarm-workflow.sh workflows/feature-complete.json "实现登录" --from-stage 3
EOF
}

main() {
    local wf_file="" requirement=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout)    TASK_TIMEOUT="$2"; shift 2 ;;
            --from-stage) FROM_STAGE="$2"; shift 2 ;;
            --dry-run)    DRY_RUN=true; shift ;;
            --status)     show_status; exit 0 ;;
            --help|-h)    show_help; exit 0 ;;
            -*)           die "未知选项: $1" ;;
            *)
                if [[ -z "$wf_file" ]]; then
                    wf_file="$1"
                elif [[ -z "$requirement" ]]; then
                    requirement="$1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "$wf_file" ]] || { show_help; exit 1; }
    [[ -n "$requirement" ]] || die "请提供需求描述"

    tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "蜂群未启动"

    run_workflow "$wf_file" "$requirement"
}

main "$@"
