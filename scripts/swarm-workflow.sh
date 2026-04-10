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
#   5. 支持超时、失败处理、从指定阶段恢复
#
# 用法:
#   swarm-workflow.sh <workflow.json> <需求描述> [选项]
#   swarm-workflow.sh --status
#
# 选项:
#   --timeout <秒>      单个任务超时 (默认: 300)
#   --from-stage <N>    从第 N 阶段开始执行（用于断点恢复）
#   --dry-run           仅显示执行计划，不实际执行
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/swarm-lib.sh"
readonly WF_STATE_DIR="${RUNTIME_DIR}/workflows"
readonly RESULTS_DIR="${RUNTIME_DIR}/results"
# 加载质量门模块（可选，用于 verify 字段）
source "${SCRIPT_DIR}/lib/msg-quality-gate.sh" 2>/dev/null || true

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
# 工作流清理
# ============================================================================

# 清理工作流失败后遗留的 processing/pending 任务
# 参数: $1 - 工作流 ID
_cleanup_workflow_tasks() {
    local wf_id="$1"
    local state_file="${WF_STATE_DIR}/${wf_id}.json"
    [[ -f "$state_file" ]] || return 0

    local cleaned=0
    while IFS=$'\t' read -r tid status; do
        [[ "$status" == "completed" || "$status" == "dry-run" ]] && continue
        local now_ts
        now_ts=$(get_timestamp)
        for d in processing pending; do
            local f="$TASKS_DIR/$d/$tid.json"
            [[ -f "$f" ]] || continue
            mkdir -p "$TASKS_DIR/failed"
            local task_tmp="${f}.tmp"
            if jq --arg at "$now_ts" --arg wf "$wf_id" \
                '.status = "failed" | .fail_reason = "workflow aborted: " + $wf | .failed_at = $at' \
                "$f" > "$task_tmp" 2>/dev/null; then
                mv "$task_tmp" "$TASKS_DIR/failed/$tid.json"
                rm -f "$f"
                ((cleaned++)) || true
            else
                rm -f "$task_tmp"
            fi
        done
    done < <(jq -r '.tasks | to_entries[] | "\(.key)\t\(.value)"' "$state_file" 2>/dev/null)

    # 更新工作流状态
    local state_tmp="${state_file}.tmp"
    jq '.status = "failed"' "$state_file" > "$state_tmp" && mv "$state_tmp" "$state_file"

    [[ $cleaned -gt 0 ]] && warn "已清理 $cleaned 个工作流遗留任务"
}

# ============================================================================
# 工作流状态管理
# ============================================================================

# 创建工作流运行实例
create_workflow_state() {
    local wf_file="$1"
    local requirement="$2"
    local wf_id="wf-$(date +%s)-$$-${RANDOM}"
    local workflow_hash=""
    workflow_hash=$(_sha256_file "$wf_file" 2>/dev/null || echo "")

    mkdir -p "$WF_STATE_DIR"

    local state_file="${WF_STATE_DIR}/${wf_id}.json"

    cat > "$state_file" <<EOF
{
  "schema_version": 2,
  "id": "$wf_id",
  "workflow_file": "$wf_file",
  "workflow_hash": "$workflow_hash",
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

render_task_template() {
    local wf_id="$1"
    local task_json="$2"
    local requirement="$3"

    local template
    template=$(echo "$task_json" | jq -r '.description // .template // ""')

    local depends_on
    depends_on=$(echo "$task_json" | jq -r '.depends_on // [] | .[]' 2>/dev/null)
    if [[ -n "$depends_on" ]]; then
        local state_file="${WF_STATE_DIR}/${wf_id}.json"
        local dep_id dep_result
        for dep_id in $depends_on; do
            dep_result=$(jq -r --arg tid "$dep_id" '.results[$tid] // "（无结果）"' "$state_file")
            template="${template//\{\{${dep_id}\}\}/$dep_result}"
        done
    fi

    template="${template//\{\{requirement\}\}/$requirement}"
    echo "$template"
}

wait_for_queue_task() {
    local queue_task_id="$1"
    local timeout_val="$2"
    local waited=0

    while [[ $waited -lt $timeout_val ]]; do
        if [[ -f "$TASKS_DIR/completed/${queue_task_id}.json" ]]; then
            jq -r '.result // .notification.result // ""' \
                "$TASKS_DIR/completed/${queue_task_id}.json" 2>/dev/null
            return 0
        fi
        if [[ -f "$TASKS_DIR/failed/${queue_task_id}.json" ]]; then
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

# ============================================================================
# 任务执行
# ============================================================================

# 执行单个任务
execute_task() {
    local wf_id="$1"
    local task_json="$2"
    local requirement="$3"

    local task_id role timeout_val
    task_id=$(echo "$task_json" | jq -r '.id')
    role=$(echo "$task_json" | jq -r '.role // .assign_role // ""')
    timeout_val=$(echo "$task_json" | jq -r ".timeout // $TASK_TIMEOUT")

    local description
    description=$(render_task_template "$wf_id" "$task_json" "$requirement")
    [[ -n "$description" && "$description" != "null" ]] || description="请完成以下任务: $requirement"

    local verify_spec
    verify_spec=$(echo "$task_json" | jq -c '.verify // null')
    local contract_json
    contract_json=$(echo "$task_json" | jq -ce --arg description "$description" '
        if (.phase_assignments // null) == null then
            error("workflow task 缺少 phase_assignments")
        else
            if (.phase_assignments.integrate // "") == "" then
                error("workflow task 缺少 phase_assignments.integrate")
            else
            {
                phase: (.phase // "research"),
                phase_assignments: .phase_assignments,
                inputs: (.inputs // [$description]),
                expected_outputs: (.expected_outputs // error("workflow task 缺少 expected_outputs")),
                acceptance_criteria: (.acceptance_criteria // error("workflow task 缺少 acceptance_criteria")),
                impact_scope: (.impact_scope // "read_only"),
                execution_mode: (.execution_mode // "parallel"),
                resource_keys: (.resource_keys // []),
                handoff_format: (.handoff_format // "markdown")
            }
            end
        end
    ')

    info "执行任务 [$task_id] → 角色: ${role:-workflow-contract}"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] 将发布任务: ${description:0:80}..."
        update_task_state "$wf_id" "$task_id" "dry-run"
        return 0
    fi

    local title type priority group_id depends_csv branch queue_task_id publish_output
    title=$(echo "$task_json" | jq -r '.title // .id')
    type=$(echo "$task_json" | jq -r '.type // "orchestrate"')
    priority=$(echo "$task_json" | jq -r '.priority // "normal"')
    group_id=$(echo "$task_json" | jq -r '.group_id // ""')
    branch=$(echo "$task_json" | jq -r '.branch // ""')
    depends_csv=$(echo "$task_json" | jq -r '.depends_on // [] | join(",")')

    update_task_state "$wf_id" "$task_id" "processing"
    local -a publish_args=(
        publish "$type" "$title"
        --description "$description"
        --priority "$priority"
        --contract "$contract_json"
    )
    [[ -n "$group_id" ]] && publish_args+=(--group "$group_id")
    [[ -n "$depends_csv" ]] && publish_args+=(--depends "$depends_csv")
    [[ -n "$branch" ]] && publish_args+=(--branch "$branch")
    if [[ "$verify_spec" != "null" ]]; then
        publish_args+=(--verify "$verify_spec")
    fi
    publish_output=$(SWARM_INSTANCE=workflow SWARM_ROLE=workflow \
        "$SCRIPTS_DIR/swarm-msg.sh" "${publish_args[@]}" 2>/dev/null)
    queue_task_id=$(echo "$publish_output" | tail -n 1)
    [[ -n "$queue_task_id" ]] || {
        update_task_state "$wf_id" "$task_id" "failed"
        return 1
    }

    if result=$(wait_for_queue_task "$queue_task_id" "$timeout_val"); then
        save_task_result "$wf_id" "$task_id" "$result"
        update_task_state "$wf_id" "$task_id" "completed"
        return 0
    fi

    update_task_state "$wf_id" "$task_id" "failed"
    return 1
}

# ============================================================================
# 阶段执行
# ============================================================================

execute_stage() {
    local wf_id="$1"
    local stage_json="$2"
    local requirement="$3"

    local stage_num stage_name execution_mode
    stage_num=$(echo "$stage_json" | jq -r '.stage // 0')
    stage_name=$(echo "$stage_json" | jq -r '.name')
    execution_mode=$(echo "$stage_json" | jq -r '.execution_mode // "serial"')

    stage "阶段 $stage_num: $stage_name"

    # 发射阶段开始事件
    emit_event "workflow.stage_started" "" "workflow_id=$wf_id" "stage=$stage_num" "name=$stage_name"

    local tasks_count
    tasks_count=$(echo "$stage_json" | jq '.tasks | length')

    if [[ "$execution_mode" == "parallel" ]] && [[ $tasks_count -gt 1 ]]; then
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

    local schema_version
    schema_version=$(echo "$wf_json" | jq -r '.schema_version // ""')
    [[ "$schema_version" == "2" ]] || die "workflow schema_version 必须为 2"

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

    # 工作流失败时清理关联的 processing 任务（避免孤儿任务等看门狗 TTL）
    if [[ "$failed" == "true" ]]; then
        _cleanup_workflow_tasks "$wf_id"
    fi

    # 最终报告
    echo ""
    if [[ "$failed" == "true" ]]; then
        echo -e "\033[1;33m╔══════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[1;33m║  工作流执行中止（部分完成）\033[0m"
        echo -e "\033[1;33m║  ID: $wf_id\033[0m"
        echo -e "\033[1;33m║  使用 --from-stage 恢复: swarm-workflow.sh <workflow.json> <需求> --from-stage N\033[0m"
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

选项:
  --timeout <秒>      单任务超时 (默认: 300)
  --from-stage <N>    从第 N 阶段开始（用于断点恢复）
  --dry-run           试运行（不实际执行）
  --help              帮助

示例:
  # 执行完整功能开发流程
  swarm-workflow.sh workflows/feature-complete.json "实现用户登录"

  # 试运行
  swarm-workflow.sh workflows/feature-complete.json "实现登录" --dry-run

  # 从第 3 阶段恢复（工作流中止后使用）
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
            --resume)     die "--resume 已移除，请使用 --from-stage N 从指定阶段恢复" ;;
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

    if [[ "$DRY_RUN" != "true" ]]; then
        tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "蜂群未启动"
    fi

    run_workflow "$wf_file" "$requirement"
}

main "$@"
