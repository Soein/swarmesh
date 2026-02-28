#!/usr/bin/env bash
################################################################################
# msg-quality-gate.sh - 质量门（Quality Gate）
#
# 设计理念：
#   脚本只负责"执行"验证命令，不负责"决定"用什么命令。
#   验证命令的来源（优先级从高到低）：
#     1. 任务级: publish --verify '{"build":"go build ./..."}' (LLM 发布任务时指定)
#     2. 项目级: .swarm/verify.json (用户或 LLM 创建)
#     3. 运行时: runtime/project-info.json 的 verify_commands (LLM 写入)
#   如果三层都没有指定验证命令 → 跳过质量门
#
# 由 swarm-msg.sh source 加载，不独立运行。
################################################################################

[[ -n "${_MSG_QUALITY_GATE_LOADED:-}" ]] && return 0
_MSG_QUALITY_GATE_LOADED=1

GATE_LOGS_DIR="${GATE_LOGS_DIR:-$RUNTIME_DIR/gate-logs}"

# GATE_TIMEOUT / SKIP_GATE_TYPES 由 config/defaults.conf 统一定义

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
    gate_start=$(get_timestamp)

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
            echo "[$(get_timestamp)] --- [$check_name] $check_cmd ---"
        } >> "$log_file"

        local exit_code=0
        # 在 worktree 目录下执行
        if timeout "$GATE_TIMEOUT" bash -c "cd '$worktree' && $check_cmd" >> "$log_file" 2>&1; then
            echo "[$(get_timestamp)] [PASS] $check_name" >> "$log_file"
            info "[质量门] $check_name: 通过"
        else
            exit_code=$?
            # 区分 "命令不存在"(127) 和 "检查失败"
            if [[ $exit_code -eq 127 ]]; then
                echo "[$(get_timestamp)] [SKIP] $check_name (命令不存在, exit=$exit_code)" >> "$log_file"
                warn "[质量门] $check_name: 命令不存在，跳过（环境可能缺少依赖）"
                skip_count=$((skip_count + 1))
                skip_names+="$check_name "
            else
                echo "[$(get_timestamp)] [FAIL] $check_name (exit=$exit_code)" >> "$log_file"
                info "[质量门] $check_name: 失败 (exit=$exit_code)"
                all_passed=false
            fi
        fi
        echo "" >> "$log_file"
    done < <(echo "$verify_json" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

    {
        echo "========================================"
        echo "结果: $([ "$all_passed" = true ] && echo "全部通过" || echo "有检查失败")"
        echo "结束时间: $(get_timestamp)"
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
