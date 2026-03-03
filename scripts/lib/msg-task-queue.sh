#!/usr/bin/env bash
################################################################################
# msg-task-queue.sh - 任务队列内部逻辑 + 任务管理命令
#
# 包含: 自动认领、依赖检查、阻塞解除、组完成检测
#       以及 publish/claim/complete-task/list-tasks 等子命令。
# 由 swarm-msg.sh source 加载，不独立运行。
################################################################################

[[ -n "${_MSG_TASK_QUEUE_LOADED:-}" ]] && return 0
_MSG_TASK_QUEUE_LOADED=1

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
    local now_epoch
    now_epoch=$(date +%s)
    for f in "$TASKS_DIR/pending/"*.json; do
        [[ -f "$f" ]] || continue
        # 单次 jq 提取 assigned_to + retry_after（减少进程开销）
        local meta assigned retry_after
        meta=$(jq -r '[(.assigned_to // ""), (.retry_after // "")] | join("\u0001")' "$f" 2>/dev/null) || continue
        IFS=$'\001' read -r assigned retry_after <<< "$meta"
        # 能接: assigned_to 为空（谁都能接）或匹配本角色
        if [[ -z "$assigned" || "$assigned" == "$my_role" ]]; then
            # retry_after 检查: 还没到重试时间的任务跳过
            if [[ -n "$retry_after" && "$retry_after" != "null" ]]; then
                local retry_epoch
                retry_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$retry_after" +%s 2>/dev/null \
                    || date -d "$retry_after" +%s 2>/dev/null \
                    || echo "0")
                if [[ "$retry_epoch" != "0" && $now_epoch -lt $retry_epoch ]]; then
                    continue  # 还没到重试时间，跳过
                fi
            fi
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
    claimed_at=$(get_timestamp)
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
            # 先更新字段到 tmp，再原子 mv 到 pending（避免中间状态可见）
            local tmp_unblock="$TASKS_DIR/blocked/${tid}.json.tmp"
            if jq '.blocked = false | .status = "pending"' "$blocked_file" > "$tmp_unblock" 2>/dev/null; then
                if mv "$tmp_unblock" "$TASKS_DIR/pending/$tid.json" 2>/dev/null; then
                    rm -f "$blocked_file"
                else
                    rm -f "$tmp_unblock"
                    continue  # 被其他进程抢先处理
                fi
            else
                rm -f "$tmp_unblock"
                continue  # jq 失败
            fi

            emit_event "task.unblocked" "" "task_id=$tid" "unblocked_by=$completed_task_id"
            info "任务已解除阻塞: $tid"

            # 通知：新任务可认领（包含完整描述，尊重 assigned_to）
            local t_meta t_title t_type t_from t_branch t_assign t_desc
            t_meta=$(jq -r '[.title, .type, .from, (.branch // ""), (.assigned_to // "")] | join("\u0001")' \
                "$TASKS_DIR/pending/$tid.json")
            IFS=$'\001' read -r t_title t_type t_from t_branch t_assign <<< "$t_meta"
            t_desc=$(jq -r '.description // ""' "$TASKS_DIR/pending/$tid.json")

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
                --arg timestamp "$(get_timestamp)" \
                --arg status "pending" \
                --arg priority "high" \
                '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority}' \
                > "${INBOX_DIR}/${from_role}/${notify_id}.json"

            # TODO: push_to_pane 涉及 tmux 调用，理想情况应移到 flock 外以缩短锁持有时间
            local from_pane
            from_pane=$(jq -r --arg role "$from_role" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
            [[ -n "$from_pane" ]] && push_to_pane "$from_pane" \
                "[任务组完成] $group_title ($completed/$total 全部完成)" 2>/dev/null || true

            info "任务组全部完成: $group_id ($group_title)"
        fi
    ) 200>"${group_file}.lock"
}

# =============================================================================
# 子任务: 深度计算 + ID 生成 + 级联取消
# =============================================================================

# 计算任务的嵌套深度（沿 parent_task 链向上遍历）
# 参数: $1 - 任务 ID
# 输出: 深度值（0=顶层）
_get_task_depth() {
    local task_id="$1"
    local depth=0
    local current_id="$task_id"
    local max_iter=$(( ${SUBTASK_MAX_DEPTH:-3} + 2 ))

    while [[ $max_iter -gt 0 ]]; do
        ((max_iter--)) || true
        local task_file=""
        for d in processing completed pending blocked failed; do
            [[ -f "$TASKS_DIR/$d/$current_id.json" ]] && task_file="$TASKS_DIR/$d/$current_id.json" && break
        done
        [[ -n "$task_file" ]] || break
        local pid
        pid=$(jq -r '.parent_task // ""' "$task_file" 2>/dev/null)
        [[ -n "$pid" && "$pid" != "null" ]] || break
        ((depth++)) || true
        current_id="$pid"
    done
    echo "$depth"
}

# 批量生成子任务 ID（根据深度交替使用字母/数字后缀）
# 参数: $1=父任务ID, $2=目标深度, $3=需要数量, $4+=已存在的ID
# 输出: 空格分隔的 ID 列表
_generate_subtask_ids() {
    local parent_id="$1" target_depth="$2" count="$3"
    shift 3
    local -a existing_ids=("$@")
    local -a result=()

    # 奇数层用字母，偶数层用数字
    local use_alpha=$(( target_depth % 2 ))
    local alphabet="abcdefghijklmnopqrstuvwxyz"
    local idx=0

    for (( n=0; n<count; )); do
        local suffix sub_id
        if [[ $use_alpha -eq 1 ]]; then
            [[ $idx -ge 26 ]] && echo "" && return 1
            suffix="${alphabet:$idx:1}"
        else
            [[ $idx -ge 999 ]] && echo "" && return 1
            suffix="$(( idx + 1 ))"
        fi
        sub_id="${parent_id}-${suffix}"
        ((idx++)) || true

        # 碰撞检查
        local collision=false
        for eid in "${existing_ids[@]}"; do
            [[ "$eid" == "$sub_id" ]] && collision=true && break
        done
        [[ -f "$TASKS_DIR/failed/$sub_id.json" ]] && collision=true
        [[ "$collision" == true ]] && continue

        result+=("$sub_id")
        existing_ids+=("$sub_id")
        ((n++)) || true
    done
    echo "${result[*]}"
}

# 级联取消子任务树（递归取消任务及其所有后代子任务）
# 参数: $1=任务ID, $2=取消原因（默认 re-split-cascade）
_cancel_subtask_tree() {
    local task_id="$1" reason="${2:-re-split-cascade}"
    local task_file=""
    for d in pending processing blocked; do
        [[ -f "$TASKS_DIR/$d/$task_id.json" ]] && task_file="$TASKS_DIR/$d/$task_id.json" && break
    done
    [[ -n "$task_file" ]] || return 0

    # 先递归取消子任务
    while IFS= read -r child_id; do
        [[ -z "$child_id" ]] && continue
        _cancel_subtask_tree "$child_id" "$reason"
    done < <(jq -r '.subtasks // [] | .[]' "$task_file" 2>/dev/null)

    # 取消当前任务
    mkdir -p "$TASKS_DIR/failed"
    local ftmp="$task_file.tmp"
    jq --arg reason "$reason" --arg at "$(get_timestamp)" \
        '.status = "failed" | .fail_reason = $reason | .failed_at = $at' \
        "$task_file" > "$ftmp" && mv "$ftmp" "$TASKS_DIR/failed/$task_id.json"
    rm -f "$task_file"

    # 从 group 中移除
    local gid
    gid=$(jq -r '.group_id // ""' "$TASKS_DIR/failed/$task_id.json" 2>/dev/null)
    if [[ -n "$gid" && "$gid" != "null" ]]; then
        local gf="$TASKS_DIR/groups/$gid.json"
        [[ -f "$gf" ]] && {
            local gt="$gf.tmp"
            jq --arg tid "$task_id" '.tasks = [.tasks[] | select(. != $tid)] | .total_count = (.tasks | length)' "$gf" > "$gt" && mv "$gt" "$gf"
        }
    fi
    _story_update_task "$task_id" "failed" "$reason"
}

# =============================================================================
# 子任务: 子任务完成检测 + compose 归一
# =============================================================================

# 子任务完成后，检查父任务的所有子任务是否全部完成
# 参数: $1 - 刚完成的子任务 ID
_check_subtask_completion() {
    local child_id="$1"

    local child_file="$TASKS_DIR/completed/$child_id.json"
    [[ -f "$child_file" ]] || return 0

    # 读取 parent_task（兼容旧 JSON）
    local parent_id
    parent_id=$(jq -r '.parent_task // ""' "$child_file" 2>/dev/null)
    [[ -n "$parent_id" && "$parent_id" != "null" ]] || return 0

    # 父任务必须在 processing/ 且 split_status="split"
    local parent_file="$TASKS_DIR/processing/$parent_id.json"
    [[ -f "$parent_file" ]] || return 0

    local split_status
    split_status=$(jq -r '.split_status // ""' "$parent_file" 2>/dev/null)
    [[ "$split_status" == "split" ]] || return 0

    # 遍历父任务的 subtasks[]，检查是否全在 completed/
    local all_done=true
    local completed_count=0 total_count=0
    while IFS= read -r sub_id; do
        [[ -z "$sub_id" ]] && continue
        ((total_count++)) || true
        if [[ -f "$TASKS_DIR/completed/$sub_id.json" ]]; then
            ((completed_count++)) || true
        else
            all_done=false
        fi
    done < <(jq -r '.subtasks // [] | .[]' "$parent_file" 2>/dev/null)

    if [[ "$all_done" == true && $total_count -gt 0 ]]; then
        _compose_parent "$parent_id"
    else
        emit_event "subtask.progress" "" "parent_id=$parent_id" "completed=$completed_count" "total=$total_count"
    fi
}

# compose 归一：所有子任务完成后，汇总结果到父任务并标记完成
# 参数: $1 - 父任务 ID
_compose_parent() {
    local parent_id="$1"
    local parent_file="$TASKS_DIR/processing/$parent_id.json"
    local lock_file="$TASKS_DIR/processing/${parent_id}.compose.lock"

    (
        flock -x 200

        # 双重检查：防止并发 compose
        [[ -f "$parent_file" ]] || return 0
        local current_status
        current_status=$(jq -r '.split_status // ""' "$parent_file" 2>/dev/null)
        [[ "$current_status" == "split" ]] || return 0

        # 标记 composing 防重入
        local tmp="$parent_file.tmp"
        jq '.split_status = "composing"' "$parent_file" > "$tmp" && mv "$tmp" "$parent_file"

        # 收集所有子任务的 title + result
        local composed_result=""
        while IFS= read -r sub_id; do
            [[ -z "$sub_id" ]] && continue
            local sub_file="$TASKS_DIR/completed/$sub_id.json"
            [[ -f "$sub_file" ]] || continue
            local sub_title sub_result
            sub_title=$(jq -r '.title // ""' "$sub_file" 2>/dev/null)
            sub_result=$(jq -r '.result // ""' "$sub_file" 2>/dev/null)
            composed_result+="[$sub_id] $sub_title: $sub_result"$'\n'
        done < <(jq -r '.subtasks // [] | .[]' "$parent_file" 2>/dev/null)

        # 父任务 processing/ → completed/（先写 tmp 再 mv，确保原子性）
        local completed_at
        completed_at=$(get_timestamp)
        mkdir -p "$TASKS_DIR/completed"
        local compose_tmp="$TASKS_DIR/completed/${parent_id}.json.tmp"
        jq --arg result "$composed_result" --arg at "$completed_at" \
            '.status = "completed" | .result = $result | .completed_at = $at | .split_status = "composed"' \
            "$parent_file" > "$compose_tmp"
        mv "$compose_tmp" "$TASKS_DIR/completed/$parent_id.json"
        rm -f "$parent_file"

        emit_event "task.composed" "" "parent_id=$parent_id"

        # 通知发布者
        local from_role parent_title
        from_role=$(jq -r '.from' "$TASKS_DIR/completed/$parent_id.json")
        parent_title=$(jq -r '.title' "$TASKS_DIR/completed/$parent_id.json")

        local notify_id="sys-task-composed-$(date +%s)-${parent_id}"
        mkdir -p "${INBOX_DIR}/${from_role}"
        jq -n \
            --arg id "$notify_id" \
            --arg from "system" \
            --arg to "$from_role" \
            --arg content "[任务归一] $parent_title (ID: $parent_id) 所有子任务已完成，结果已汇总。\n$composed_result" \
            --arg timestamp "$(get_timestamp)" \
            --arg status "pending" \
            --arg priority "high" \
            '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority}' \
            > "${INBOX_DIR}/${from_role}/${notify_id}.json"

        local from_pane
        from_pane=$(jq -r --arg role "$from_role" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
        [[ -n "$from_pane" ]] && push_to_pane "$from_pane" \
            "[任务归一] $parent_title 的所有子任务已完成，结果已汇总" 2>/dev/null || true

        # 更新 Story
        _story_update_task "$parent_id" "completed" "子任务全部完成，已归一"

        # 链式传播：父任务完成后触发依赖解除 + 组完成检测
        _check_and_unblock "$parent_id"
        _check_group_completion "$parent_id"

        # 递归冒泡：如果此父任务也是子任务，检查祖父任务是否可 compose
        _check_subtask_completion "$parent_id"

    ) 200>"$lock_file"
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
        --arg created_at "$(get_timestamp)" \
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
        --arg created_at "$(get_timestamp)" \
        --arg priority "$priority" \
        --arg group_id "$group_id" \
        --arg assigned_to "$assign_to" \
        --argjson depends_on "$depends_json" \
        --argjson blocked "$is_blocked" \
        --arg status "$target_status" \
        --argjson verify "$verify_json" \
        --argjson max_retries "${TASK_MAX_RETRIES:-3}" \
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
            verify: $verify,
            retry_count: 0,
            max_retries: $max_retries,
            failed_at: null,
            fail_reason: null,
            retry_history: [],
            parent_task: null,
            subtasks: [],
            split_status: null,
            depth: 0
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
            jq -r '"  [\(.status)] \(.id)\n    类型: \(.type) | 来自: \(.from) | 优先级: \(.priority)\n    标题: \(.title)\(.branch | if . and . != "" then "\n    分支: "+. else "" end)\(.claimed_by | if . and . != "null" then "\n    认领: "+. else "" end)\(.depends_on | if . and length > 0 then "\n    依赖: "+(.|join(", ")) else "" end)\(.group_id | if . and . != "" then "\n    任务组: "+. else "" end)\(if (.retry_count // 0) > 0 then "\n    重试: \(.retry_count // 0)/\(.max_retries // 3)" else "" end)\(.parent_task // null | if . and . != "null" then "\n    父任务: "+. else "" end)\(.subtasks // [] | if length > 0 then "\n    子任务: "+(.|join(", ")) else "" end)\(.split_status // null | if . and . != "null" then "\n    拆分状态: "+. else "" end)\n"' "$f"
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
    claimed_at=$(get_timestamp)
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
    completed_at=$(get_timestamp)

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
        --arg timestamp "$(get_timestamp)" \
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

    # 检查子任务归一（如果本任务是某个父任务的子任务）
    _check_subtask_completion "$task_id"

    # 检查所属任务组是否全部完成
    _check_group_completion "$task_id"

    # 自动拉取下一个任务（工蜂自驱动）
    _auto_claim_next "$my_role"
}

# =============================================================================
# 子命令: fail-task (报告任务失败，自动重试或移入 failed/)
# =============================================================================

cmd_fail_task() {
    local task_id="$1"
    local reason="${2:-未指定原因}"

    local my_role
    my_role=$(detect_my_role)

    local task_file="$TASKS_DIR/processing/$task_id.json"
    [[ -f "$task_file" ]] || die "任务不在处理中: $task_id (只能对 processing 状态的任务报告失败)"

    # 读取重试信息（兼容旧 JSON: // 0 / // 3）
    local retry_count max_retries
    retry_count=$(jq -r '.retry_count // 0' "$task_file")
    max_retries=$(jq -r '.max_retries // 3' "$task_file")

    local now_ts
    now_ts=$(get_timestamp)

    # 构造 retry_history 条目
    local history_entry
    history_entry=$(jq -n \
        --arg failed_at "$now_ts" \
        --arg reason "$reason" \
        --arg failed_by "$my_role" \
        '{failed_at: $failed_at, reason: $reason, failed_by: $failed_by}')

    # 递增 retry_count
    local new_count=$((retry_count + 1))

    if [[ $new_count -le $max_retries ]]; then
        # === 重试: 移回 pending/ ===
        local delay=$(( (1 << new_count) * ${TASK_RETRY_BASE_DELAY:-60} ))

        # 计算 retry_after 时间戳（macOS / Linux 兼容）
        local retry_after
        retry_after=$(date -v+${delay}S '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
            || date -d "+${delay} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
            || echo "")

        mkdir -p "$TASKS_DIR/pending"
        local tmp="$TASKS_DIR/processing/${task_id}.json.tmp"
        if ! jq \
            --argjson new_count "$new_count" \
            --arg reason "$reason" \
            --arg now_ts "$now_ts" \
            --arg retry_after "$retry_after" \
            --argjson entry "$history_entry" \
            '
            .status = "pending"
            | .claimed_by = null
            | .claimed_at = null
            | .retry_count = $new_count
            | .fail_reason = $reason
            | .failed_at = $now_ts
            | .retry_after = $retry_after
            | .retry_history = ((.retry_history // []) + [$entry])
            ' "$task_file" > "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            die "fail-task: jq 更新失败"
        fi

        if ! mv "$tmp" "$TASKS_DIR/pending/$task_id.json" 2>/dev/null; then
            rm -f "$tmp"
            die "fail-task: 移动到 pending 失败"
        fi
        rm -f "$task_file"

        emit_event "task.retry" "$my_role" "task_id=$task_id" "retry_count=$new_count" "max_retries=$max_retries" "delay=${delay}s"

        # 更新 Story
        _story_update_task "$task_id" "pending" "重试 $new_count/$max_retries (原因: $reason)"

        # 通知发布者
        local from_role
        from_role=$(jq -r '.from' "$TASKS_DIR/pending/$task_id.json")
        local from_pane
        from_pane=$(jq -r --arg role "$from_role" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
        [[ -n "$from_pane" ]] && push_to_pane "$from_pane" \
            "[任务重试] $task_id 失败(原因: $reason)，将在 ${delay}s 后重试 ($new_count/$max_retries)" 2>/dev/null || true

        info "任务失败，已安排重试: $task_id ($new_count/$max_retries, 延迟 ${delay}s)"
    else
        # === 重试耗尽: 移入 failed/ ===
        mkdir -p "$TASKS_DIR/failed"
        local tmp="$TASKS_DIR/processing/${task_id}.json.tmp"
        if ! jq \
            --argjson new_count "$new_count" \
            --arg reason "$reason" \
            --arg now_ts "$now_ts" \
            --argjson entry "$history_entry" \
            '
            .status = "failed"
            | .retry_count = $new_count
            | .fail_reason = $reason
            | .failed_at = $now_ts
            | .retry_history = ((.retry_history // []) + [$entry])
            ' "$task_file" > "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            die "fail-task: jq 更新失败"
        fi

        if ! mv "$tmp" "$TASKS_DIR/failed/$task_id.json" 2>/dev/null; then
            rm -f "$tmp"
            die "fail-task: 移动到 failed 失败"
        fi
        rm -f "$task_file"

        emit_event "task.exhausted" "$my_role" "task_id=$task_id" "retry_count=$new_count" "max_retries=$max_retries"

        # 更新 Story
        _story_update_task "$task_id" "failed" "重试耗尽 ($new_count/$max_retries, 最终原因: $reason)"

        # 通知 inspector + 发布者
        local from_role
        from_role=$(jq -r '.from' "$TASKS_DIR/failed/$task_id.json")
        local task_title
        task_title=$(jq -r '.title' "$TASKS_DIR/failed/$task_id.json")

        # 通知 inspector
        local notify_id="sys-task-exhausted-$(date +%s)-${task_id}"
        mkdir -p "${INBOX_DIR}/inspector"
        jq -n \
            --arg id "$notify_id" \
            --arg from "system" \
            --arg to "inspector" \
            --arg content "[任务失败] 任务 $task_id ($task_title) 重试耗尽 ($new_count/$max_retries)。最终原因: $reason。请人工介入。" \
            --arg timestamp "$now_ts" \
            --arg status "pending" \
            --arg priority "high" \
            '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority}' \
            > "${INBOX_DIR}/inspector/${notify_id}.json"

        # 通知发布者
        local from_pane
        from_pane=$(jq -r --arg role "$from_role" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
        [[ -n "$from_pane" ]] && push_to_pane "$from_pane" \
            "[任务失败] $task_id ($task_title) 重试耗尽 ($new_count/$max_retries)，已移入 failed/，请人工介入" 2>/dev/null || true

        info "任务重试耗尽，已移入 failed/: $task_id ($new_count/$max_retries)"
    fi
}

# =============================================================================
# 子命令: escalate-task (上报任务给 supervisor 拆分，工蜂释放认领)
# =============================================================================

cmd_escalate_task() {
    local task_id="$1"
    local reason="${2:-任务过于复杂，需要拆分}"

    local my_role
    my_role=$(detect_my_role)

    local task_file="$TASKS_DIR/processing/$task_id.json"
    [[ -f "$task_file" ]] || die "escalate-task: 任务不在 processing 状态: $task_id"

    # 验证是当前角色认领的任务
    local claimed_by
    claimed_by=$(jq -r '.claimed_by // ""' "$task_file")
    [[ "$claimed_by" == "$my_role" ]] || die "escalate-task: 任务 $task_id 不是由你 ($my_role) 认领的 (认领者: $claimed_by)"

    local now_ts
    now_ts=$(get_timestamp)

    # 更新任务: 释放认领 + 标记 escalated
    local tmp="$task_file.tmp"
    if ! jq --arg reason "$reason" \
       --arg by "$my_role" \
       --arg at "$now_ts" \
       '
       .claimed_by = null
       | .claimed_at = null
       | .escalated = {
           status: "pending",
           reason: $reason,
           escalated_by: $by,
           escalated_at: $at
         }
       ' "$task_file" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        die "escalate-task: 更新任务文件失败: $task_id"
    fi
    mv "$tmp" "$task_file"

    emit_event "task.escalated" "$my_role" "task_id=$task_id" "reason=$reason"

    # Story 更新
    _story_update_task "$task_id" "escalated" "上报拆分: $reason"

    # 通知 supervisor
    local supervisor_pane
    supervisor_pane=$(jq -r '.panes[] | select(.role == "supervisor") | .pane' "$STATE_FILE" 2>/dev/null | head -1)
    if [[ -n "$supervisor_pane" ]]; then
        push_to_pane "$supervisor_pane" \
            "[任务上报] $my_role 上报任务 $task_id 需要拆分。原因: $reason
请使用 split-task 拆分此任务: swarm-msg.sh split-task $task_id --subtask \"子任务1\" --assign 角色 [...]
（如需同层替换而非嵌套拆分，可用 expand-subtask）"
    fi

    # 也写入 supervisor inbox（确保不遗漏）
    local msg_id="escalate-${task_id}-$(date +%s)"
    mkdir -p "${INBOX_DIR}/supervisor"
    jq -n \
        --arg id "$msg_id" \
        --arg from "$my_role" \
        --arg to "supervisor" \
        --arg content "[任务上报] 任务 $task_id 需要拆分。原因: $reason。请使用 split-task 拆分此任务（如需同层替换可用 expand-subtask）。" \
        --arg timestamp "$now_ts" \
        --arg status "pending" \
        --arg priority "high" \
        '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority}' \
        > "${INBOX_DIR}/supervisor/${msg_id}.json"

    info "任务已上报: $task_id → supervisor"

    # 自动认领下一个任务
    _auto_claim_next "$my_role"
}

# =============================================================================
# 子命令: split-task (拆分任务为子任务)
# =============================================================================

# 用法: cmd_split_task <parent_id> --subtask "标题1" --assign role1 [--description "描述"]
#        --subtask "标题2" --assign role2 --depends a [--description "描述"]
cmd_split_task() {
    local parent_id="$1"
    shift

    # 验证父任务
    local parent_file="$TASKS_DIR/processing/$parent_id.json"
    [[ -f "$parent_file" ]] || die "split-task: 父任务不在 processing 状态: $parent_id"

    # 检查父任务是否正在拆分状态（基于 split_status 而非 subtasks 长度，
    # 因为 re-split 后 subtasks 可能保留已完成的子任务但 split_status 已重置为 null）
    local current_split
    current_split=$(jq -r '.split_status // ""' "$parent_file" 2>/dev/null)
    [[ -z "$current_split" || "$current_split" == "null" ]] || \
        die "split-task: 父任务已处于拆分状态: $parent_id (当前: $current_split, 如需重新拆分请先 re-split)"

    # 深度检查
    local current_depth
    current_depth=$(_get_task_depth "$parent_id")
    local max_depth=${SUBTASK_MAX_DEPTH:-3}
    local next_depth=$((current_depth + 1))
    [[ $next_depth -le $max_depth ]] || \
        die "split-task: 嵌套深度超限 ($next_depth > $max_depth): $parent_id (当前深度: $current_depth)"

    # 解析 --subtask/--assign/--depends/--description 参数组
    local -a subtask_titles=()
    local -a subtask_assigns=()
    local -a subtask_depends=()
    local -a subtask_descs=()
    local current_idx=-1

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --subtask|-s)
                ((current_idx++)) || true
                subtask_titles[$current_idx]="$2"
                subtask_assigns[$current_idx]=""
                subtask_depends[$current_idx]=""
                subtask_descs[$current_idx]=""
                shift 2
                ;;
            --assign|-a)
                [[ $current_idx -ge 0 ]] || die "split-task: --assign 必须在 --subtask 之后"
                subtask_assigns[$current_idx]="$2"
                shift 2
                ;;
            --depends)
                [[ $current_idx -ge 0 ]] || die "split-task: --depends 必须在 --subtask 之后"
                subtask_depends[$current_idx]="$2"
                shift 2
                ;;
            --description|-d)
                [[ $current_idx -ge 0 ]] || die "split-task: --description 必须在 --subtask 之后"
                subtask_descs[$current_idx]="$2"
                shift 2
                ;;
            *)
                die "split-task: 未知参数 '$1'"
                ;;
        esac
    done

    local subtask_count=${#subtask_titles[@]}
    [[ $subtask_count -gt 0 ]] || die "split-task: 至少需要一个 --subtask"
    local max_count=${SUBTASK_MAX_COUNT:-10}
    # 字母层上限26，数字层上限99
    if (( next_depth % 2 == 1 )); then
        [[ $max_count -le 26 ]] || max_count=26
    else
        [[ $max_count -le 99 ]] || max_count=99
    fi
    [[ $subtask_count -le $max_count ]] || \
        die "split-task: 子任务数量 $subtask_count 超过上限 $max_count"

    # 校验子任务标题不为空
    for i in $(seq 0 $((subtask_count - 1))); do
        [[ -n "${subtask_titles[$i]}" ]] || die "split-task: 第 $((i+1)) 个子任务标题不能为空"
    done

    # 读取父任务属性（继承给子任务）
    local p_meta p_type p_from p_priority p_group_id p_branch p_verify
    p_meta=$(jq -r '[.type, .from, .priority, (.group_id // ""), (.branch // ""), (.verify // "null")] | join("\u0001")' "$parent_file" 2>/dev/null)
    IFS=$'\001' read -r p_type p_from p_priority p_group_id p_branch p_verify <<< "$p_meta"

    local subtask_ids=()
    local created_files=()

    # 收集已存在的子任务 ID（re-split 后可能保留了已完成的）
    local -a existing_ids=()
    while IFS= read -r eid; do
        [[ -n "$eid" ]] && existing_ids+=("$eid")
    done < <(jq -r '.subtasks // [] | .[]' "$parent_file" 2>/dev/null)

    local ids_str
    ids_str=$(_generate_subtask_ids "$parent_id" "$next_depth" "$subtask_count" "${existing_ids[@]}")
    [[ -n "$ids_str" ]] || die "split-task: 无法生成子任务 ID（后缀耗尽）"
    read -ra subtask_ids <<< "$ids_str"

    for i in $(seq 0 $((subtask_count - 1))); do
        local sub_id="${subtask_ids[$i]}"

        local sub_title="${subtask_titles[$i]}"
        local sub_assign="${subtask_assigns[$i]}"
        local sub_desc="${subtask_descs[$i]}"
        local sub_raw_depends="${subtask_depends[$i]}"

        # 展开依赖简写: "a,b" → "${parent_id}-a,${parent_id}-b"
        local depends_json="[]"
        if [[ -n "$sub_raw_depends" ]]; then
            local expanded=""
            IFS=',' read -ra dep_parts <<< "$sub_raw_depends"
            for dep in "${dep_parts[@]}"; do
                dep=$(echo "$dep" | xargs)  # trim
                # 如果已经是完整 ID（含 task- 前缀）则直接使用
                if [[ "$dep" == task-* ]]; then
                    expanded+="${expanded:+,}$dep"
                else
                    expanded+="${expanded:+,}${parent_id}-${dep}"
                fi
            done
            depends_json=$(echo "$expanded" | tr ',' '\n' | jq -R '.' | jq -s '.')
        fi

        # 判断是否阻塞
        local is_blocked=false
        local target_status="pending"
        if ! _deps_all_met "$depends_json"; then
            is_blocked=true
            target_status="blocked"
        fi

        local target_dir="$target_status"
        mkdir -p "$TASKS_DIR/$target_dir"

        # 解析 verify
        local verify_json="null"
        [[ "$p_verify" != "null" && -n "$p_verify" ]] && verify_json="$p_verify"

        jq -n \
            --arg id "$sub_id" \
            --arg type "$p_type" \
            --arg from "$p_from" \
            --arg title "$sub_title" \
            --arg description "$sub_desc" \
            --arg branch "$p_branch" \
            --arg created_at "$(get_timestamp)" \
            --arg priority "$p_priority" \
            --arg group_id "$p_group_id" \
            --arg assigned_to "$sub_assign" \
            --argjson depends_on "$depends_json" \
            --argjson blocked "$is_blocked" \
            --arg status "$target_status" \
            --argjson verify "$verify_json" \
            --argjson max_retries "${TASK_MAX_RETRIES:-3}" \
            --arg parent_task "$parent_id" \
            --argjson depth "$next_depth" \
            '{
                id: $id,
                type: $type,
                from: $from,
                title: $title,
                description: $description,
                assigned_to: $assigned_to,
                branch: $branch,
                commit: "",
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
                verify: $verify,
                retry_count: 0,
                max_retries: $max_retries,
                failed_at: null,
                fail_reason: null,
                retry_history: [],
                parent_task: $parent_task,
                subtasks: [],
                split_status: null,
                depth: $depth
            }' > "$TASKS_DIR/$target_dir/$sub_id.json"

        created_files+=("$sub_id")

        # 如果属于 group，追加到 group 的任务列表
        if [[ -n "$p_group_id" ]]; then
            local group_file="$TASKS_DIR/groups/$p_group_id.json"
            if [[ -f "$group_file" ]]; then
                local gtmp="${group_file}.tmp"
                jq --arg tid "$sub_id" \
                    '.tasks += [$tid] | .total_count = (.tasks | length)' \
                    "$group_file" > "$gtmp" && mv "$gtmp" "$group_file"
            fi
            _story_add_task "$p_group_id" "$sub_id" "$sub_title" "$p_type" "$sub_assign" "$p_branch"
        fi
    done

    # 更新父任务: subtasks = 保留的旧子任务 + 新子任务, split_status="split"
    local all_subtask_ids=("${existing_ids[@]}" "${subtask_ids[@]}")
    local subtasks_json
    subtasks_json=$(printf '%s\n' "${all_subtask_ids[@]}" | jq -R '.' | jq -s '.')
    local ptmp="$parent_file.tmp"
    jq --argjson subtasks "$subtasks_json" \
        '.subtasks = $subtasks | .split_status = "split"' \
        "$parent_file" > "$ptmp" && mv "$ptmp" "$parent_file"

    # 发射事件
    emit_event "task.split" "" "parent_id=$parent_id" "subtask_count=$subtask_count" \
        "subtask_ids=$(IFS=,; echo "${subtask_ids[*]}")"

    # 推送通知
    local from_pane
    from_pane=$(jq -r --arg role "$p_from" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
    [[ -n "$from_pane" ]] && push_to_pane "$from_pane" \
        "[任务拆分] $parent_id 已拆分为 $subtask_count 个子任务: $(IFS=,; echo "${subtask_ids[*]}")" 2>/dev/null || true

    # 通知被指派的角色
    for i in $(seq 0 $((subtask_count - 1))); do
        local sub_assign="${subtask_assigns[$i]}"
        local sub_id="${subtask_ids[$i]}"
        local sub_title="${subtask_titles[$i]}"
        if [[ -n "$sub_assign" ]]; then
            local target_pane
            target_pane=$(jq -r --arg role "$sub_assign" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
            [[ -n "$target_pane" ]] && push_to_pane "$target_pane" \
                "[子任务] $sub_id: $sub_title (父任务: $parent_id) 已指派给你" 2>/dev/null || true
        fi
    done

    info "任务已拆分: $parent_id → $(IFS=,; echo "${subtask_ids[*]}")"
    echo "子任务 ID: $(IFS=,; echo "${subtask_ids[*]}")"
}

# =============================================================================
# 子命令: re-split (重置拆分，保留已完成的子任务)
# =============================================================================

cmd_re_split() {
    local parent_id="$1"

    # 验证父任务
    local parent_file="$TASKS_DIR/processing/$parent_id.json"
    [[ -f "$parent_file" ]] || die "re-split: 父任务不在 processing 状态: $parent_id"

    local split_status
    split_status=$(jq -r '.split_status // ""' "$parent_file" 2>/dev/null)
    [[ "$split_status" == "split" ]] || die "re-split: 父任务未处于拆分状态: $parent_id (当前: ${split_status:-null})"

    local kept_ids=()
    local cancelled_ids=()

    while IFS= read -r sub_id; do
        [[ -z "$sub_id" ]] && continue

        if [[ -f "$TASKS_DIR/completed/$sub_id.json" ]]; then
            # 已完成 → 保留
            kept_ids+=("$sub_id")
        elif [[ -f "$TASKS_DIR/failed/$sub_id.json" ]]; then
            # 已失败（由看门狗或 fail-task 移入）→ 计入取消列表
            cancelled_ids+=("$sub_id")
        else
            # 使用级联取消（递归取消子任务及其所有后代）
            _cancel_subtask_tree "$sub_id" "re-split"
            cancelled_ids+=("$sub_id")
        fi
    done < <(jq -r '.subtasks // [] | .[]' "$parent_file" 2>/dev/null)

    # 重置父任务
    local kept_json
    if [[ ${#kept_ids[@]} -gt 0 ]]; then
        kept_json=$(printf '%s\n' "${kept_ids[@]}" | jq -R '.' | jq -s '.')
    else
        kept_json="[]"
    fi
    local ptmp="$parent_file.tmp"
    jq --argjson kept "$kept_json" \
        '.subtasks = $kept | .split_status = null' \
        "$parent_file" > "$ptmp" && mv "$ptmp" "$parent_file"

    emit_event "task.re_split" "" "parent_id=$parent_id" \
        "kept=${#kept_ids[@]}" "cancelled=${#cancelled_ids[@]}"

    info "re-split 完成: $parent_id (保留 ${#kept_ids[@]} 个已完成, 取消 ${#cancelled_ids[@]} 个未完成)"
    [[ ${#kept_ids[@]} -gt 0 ]] && echo "保留: $(IFS=,; echo "${kept_ids[*]}")"
    [[ ${#cancelled_ids[@]} -gt 0 ]] && echo "取消: $(IFS=,; echo "${cancelled_ids[*]}")"
}

# =============================================================================
# 子命令: expand-subtask (展开子任务为更细粒度的子任务，打平到同层)
# =============================================================================

cmd_expand_subtask() {
    local old_subtask_id="$1"
    shift

    # -------------------------------------------------------------------------
    # 1. 验证旧子任务
    # -------------------------------------------------------------------------
    local old_file="$TASKS_DIR/processing/$old_subtask_id.json"
    [[ -f "$old_file" ]] || die "expand-subtask: 子任务不在 processing 状态: $old_subtask_id"

    # 必须是子任务（有 parent_task）
    local parent_id
    parent_id=$(jq -r '.parent_task // ""' "$old_file" 2>/dev/null)
    [[ -n "$parent_id" && "$parent_id" != "null" ]] || \
        die "expand-subtask: $old_subtask_id 不是子任务（没有 parent_task）"

    # 父任务必须在 processing/ 且 split_status="split"
    local parent_file="$TASKS_DIR/processing/$parent_id.json"
    [[ -f "$parent_file" ]] || die "expand-subtask: 父任务不在 processing 状态: $parent_id"

    local split_status
    split_status=$(jq -r '.split_status // ""' "$parent_file" 2>/dev/null)
    [[ "$split_status" == "split" ]] || \
        die "expand-subtask: 父任务未处于拆分状态: $parent_id (当前: ${split_status:-null})"

    # -------------------------------------------------------------------------
    # 2. 解析参数（同 cmd_split_task）
    # -------------------------------------------------------------------------
    local -a subtask_titles=()
    local -a subtask_assigns=()
    local -a subtask_depends=()
    local -a subtask_descs=()
    local current_idx=-1

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --subtask|-s)
                ((current_idx++)) || true
                subtask_titles[$current_idx]="$2"
                subtask_assigns[$current_idx]=""
                subtask_depends[$current_idx]=""
                subtask_descs[$current_idx]=""
                shift 2
                ;;
            --assign|-a)
                [[ $current_idx -ge 0 ]] || die "expand-subtask: --assign 必须在 --subtask 之后"
                subtask_assigns[$current_idx]="$2"
                shift 2
                ;;
            --depends)
                [[ $current_idx -ge 0 ]] || die "expand-subtask: --depends 必须在 --subtask 之后"
                subtask_depends[$current_idx]="$2"
                shift 2
                ;;
            --description|-d)
                [[ $current_idx -ge 0 ]] || die "expand-subtask: --description 必须在 --subtask 之后"
                subtask_descs[$current_idx]="$2"
                shift 2
                ;;
            *)
                die "expand-subtask: 未知参数 '$1'"
                ;;
        esac
    done

    local subtask_count=${#subtask_titles[@]}
    [[ $subtask_count -gt 0 ]] || die "expand-subtask: 至少需要一个 --subtask"

    # 校验子任务标题不为空
    for i in $(seq 0 $((subtask_count - 1))); do
        [[ -n "${subtask_titles[$i]}" ]] || die "expand-subtask: 第 $((i+1)) 个子任务标题不能为空"
    done

    # -------------------------------------------------------------------------
    # 3. 数量上限检查：展开后总数 ≤ SUBTASK_MAX_COUNT
    # -------------------------------------------------------------------------
    # 计算被展开子任务的深度（同层替换，新子任务深度相同）
    local current_depth
    current_depth=$(_get_task_depth "$old_subtask_id")

    local max_count=${SUBTASK_MAX_COUNT:-10}
    # 字母层上限26，数字层上限99
    if (( current_depth % 2 == 1 )); then
        [[ $max_count -le 26 ]] || max_count=26
    else
        [[ $max_count -le 99 ]] || max_count=99
    fi

    # 当前父任务的子任务数（去掉被展开的旧子任务）
    local existing_count=0
    while IFS= read -r sid; do
        [[ -z "$sid" ]] && continue
        [[ "$sid" == "$old_subtask_id" ]] && continue
        ((existing_count++)) || true
    done < <(jq -r '.subtasks // [] | .[]' "$parent_file" 2>/dev/null)

    local total_after=$((existing_count + subtask_count))
    [[ $total_after -le $max_count ]] || \
        die "expand-subtask: 展开后子任务总数 $total_after 超过上限 $max_count (现有 $existing_count + 新增 $subtask_count)"

    # -------------------------------------------------------------------------
    # 4. 读取父任务属性（继承给子任务）
    # -------------------------------------------------------------------------
    local p_meta p_type p_from p_priority p_group_id p_branch p_verify
    p_meta=$(jq -r '[.type, .from, .priority, (.group_id // ""), (.branch // ""), (.verify // "null")] | join("\u0001")' "$parent_file" 2>/dev/null)
    IFS=$'\001' read -r p_type p_from p_priority p_group_id p_branch p_verify <<< "$p_meta"

    # -------------------------------------------------------------------------
    # 5. 取消旧子任务: processing/ → failed/ (fail_reason="expanded")
    # -------------------------------------------------------------------------
    mkdir -p "$TASKS_DIR/failed"
    local ftmp="$old_file.tmp"
    if jq --arg reason "expanded" --arg at "$(get_timestamp)" \
        '.status = "failed" | .fail_reason = $reason | .failed_at = $at' \
        "$old_file" > "$ftmp" 2>/dev/null \
        && mv "$ftmp" "$TASKS_DIR/failed/$old_subtask_id.json"; then
        rm -f "$old_file"
    else
        rm -f "$ftmp"
        die "expand-subtask: 移动旧子任务到 failed/ 失败: $old_subtask_id"
    fi

    # 从 group 中移除旧子任务
    if [[ -n "$p_group_id" ]]; then
        local group_file="$TASKS_DIR/groups/$p_group_id.json"
        if [[ -f "$group_file" ]]; then
            local gtmp="${group_file}.tmp"
            jq --arg tid "$old_subtask_id" \
                '.tasks = [.tasks[] | select(. != $tid)] | .total_count = (.tasks | length)' \
                "$group_file" > "$gtmp" && mv "$gtmp" "$group_file"
        fi
    fi

    # Story 更新：旧子任务标记失败
    _story_update_task "$old_subtask_id" "failed" "展开为更细粒度子任务"

    # -------------------------------------------------------------------------
    # 6. 创建新子任务（复用 cmd_split_task 模式）
    # -------------------------------------------------------------------------
    local subtask_ids=()

    # 收集已存在的子任务 ID（用于后缀碰撞避让）
    local -a existing_ids=()
    while IFS= read -r eid; do
        [[ -n "$eid" ]] && existing_ids+=("$eid")
    done < <(jq -r '.subtasks // [] | .[]' "$parent_file" 2>/dev/null)
    # 也要包含旧子任务 ID（虽已移走，但 failed/ 中仍存在，后缀应避让）
    existing_ids+=("$old_subtask_id")

    # 同层替换，新子任务和被替换的子任务深度相同
    local ids_str
    ids_str=$(_generate_subtask_ids "$parent_id" "$current_depth" "$subtask_count" "${existing_ids[@]}")
    [[ -n "$ids_str" ]] || die "expand-subtask: 无法生成子任务 ID（后缀耗尽）"
    read -ra subtask_ids <<< "$ids_str"

    for i in $(seq 0 $((subtask_count - 1))); do
        local sub_id="${subtask_ids[$i]}"
        local sub_title="${subtask_titles[$i]}"
        local sub_assign="${subtask_assigns[$i]}"
        local sub_desc="${subtask_descs[$i]}"
        local sub_raw_depends="${subtask_depends[$i]}"

        # 展开依赖简写: "d,e" → "${parent_id}-d,${parent_id}-e"
        local depends_json="[]"
        if [[ -n "$sub_raw_depends" ]]; then
            local expanded=""
            IFS=',' read -ra dep_parts <<< "$sub_raw_depends"
            for dep in "${dep_parts[@]}"; do
                dep=$(echo "$dep" | xargs)  # trim
                if [[ "$dep" == task-* ]]; then
                    expanded+="${expanded:+,}$dep"
                else
                    expanded+="${expanded:+,}${parent_id}-${dep}"
                fi
            done
            depends_json=$(echo "$expanded" | tr ',' '\n' | jq -R '.' | jq -s '.')
        fi

        # 判断是否阻塞
        local is_blocked=false
        local target_status="pending"
        if ! _deps_all_met "$depends_json"; then
            is_blocked=true
            target_status="blocked"
        fi

        local target_dir="$target_status"
        mkdir -p "$TASKS_DIR/$target_dir"

        # 解析 verify
        local verify_json="null"
        [[ "$p_verify" != "null" && -n "$p_verify" ]] && verify_json="$p_verify"

        jq -n \
            --arg id "$sub_id" \
            --arg type "$p_type" \
            --arg from "$p_from" \
            --arg title "$sub_title" \
            --arg description "$sub_desc" \
            --arg branch "$p_branch" \
            --arg created_at "$(get_timestamp)" \
            --arg priority "$p_priority" \
            --arg group_id "$p_group_id" \
            --arg assigned_to "$sub_assign" \
            --argjson depends_on "$depends_json" \
            --argjson blocked "$is_blocked" \
            --arg status "$target_status" \
            --argjson verify "$verify_json" \
            --argjson max_retries "${TASK_MAX_RETRIES:-3}" \
            --arg parent_task "$parent_id" \
            --argjson depth "$current_depth" \
            '{
                id: $id,
                type: $type,
                from: $from,
                title: $title,
                description: $description,
                assigned_to: $assigned_to,
                branch: $branch,
                commit: "",
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
                verify: $verify,
                retry_count: 0,
                max_retries: $max_retries,
                failed_at: null,
                fail_reason: null,
                retry_history: [],
                parent_task: $parent_task,
                subtasks: [],
                split_status: null,
                depth: $depth
            }' > "$TASKS_DIR/$target_dir/$sub_id.json"

        # 如果属于 group，追加到 group 的任务列表
        if [[ -n "$p_group_id" ]]; then
            local group_file="$TASKS_DIR/groups/$p_group_id.json"
            if [[ -f "$group_file" ]]; then
                local gtmp="${group_file}.tmp"
                jq --arg tid "$sub_id" \
                    '.tasks += [$tid] | .total_count = (.tasks | length)' \
                    "$group_file" > "$gtmp" && mv "$gtmp" "$group_file"
            fi
            _story_add_task "$p_group_id" "$sub_id" "$sub_title" "$p_type" "$sub_assign" "$p_branch"
        fi
    done

    # -------------------------------------------------------------------------
    # 7. 依赖重写：兄弟子任务中依赖旧子任务的，替换为所有新子任务 ID
    # -------------------------------------------------------------------------
    local new_ids_json
    new_ids_json=$(printf '%s\n' "${subtask_ids[@]}" | jq -R '.' | jq -s '.')

    # 遍历父任务的 subtasks（排除旧子任务和刚创建的新子任务）
    while IFS= read -r sibling_id; do
        [[ -z "$sibling_id" ]] && continue
        [[ "$sibling_id" == "$old_subtask_id" ]] && continue
        # 跳过刚创建的新子任务
        local is_new=false
        for nid in "${subtask_ids[@]}"; do
            [[ "$sibling_id" == "$nid" ]] && is_new=true && break
        done
        [[ "$is_new" == true ]] && continue

        local sibling_file=""
        for d in pending processing blocked; do
            [[ -f "$TASKS_DIR/$d/$sibling_id.json" ]] && sibling_file="$TASKS_DIR/$d/$sibling_id.json" && break
        done
        [[ -n "$sibling_file" ]] || continue

        # 检查是否依赖旧子任务
        local has_dep
        has_dep=$(jq --arg old "$old_subtask_id" \
            'if .depends_on then (.depends_on | index($old)) else null end' \
            "$sibling_file" 2>/dev/null)
        [[ "$has_dep" != "null" && -n "$has_dep" ]] || continue

        # 替换：移除旧 ID，追加所有新 ID
        local stmp="$sibling_file.tmp"
        if jq --arg old_id "$old_subtask_id" --argjson new_ids "$new_ids_json" \
            '.depends_on = ([.depends_on[] | select(. != $old_id)] + $new_ids | unique)' \
            "$sibling_file" > "$stmp" 2>/dev/null && mv "$stmp" "$sibling_file"; then

            # 重新检查是否应解除阻塞（如果在 blocked/ 中）
            if [[ "$sibling_file" == *"/blocked/"* ]]; then
                local sibling_deps
                sibling_deps=$(jq -c '.depends_on // []' "$sibling_file" 2>/dev/null)
                if _deps_all_met "$sibling_deps"; then
                    local utmp="$sibling_file.tmp"
                    if jq '.blocked = false | .status = "pending"' "$sibling_file" > "$utmp" 2>/dev/null \
                        && mv "$utmp" "$TASKS_DIR/pending/$sibling_id.json" 2>/dev/null; then
                        rm -f "$sibling_file"
                        emit_event "task.unblocked" "" "task_id=$sibling_id"
                    else
                        rm -f "$utmp"
                    fi
                fi
            fi
        else
            rm -f "$stmp"
        fi
    done < <(jq -r '.subtasks // [] | .[]' "$parent_file" 2>/dev/null)

    # -------------------------------------------------------------------------
    # 8. 更新父任务的 subtasks[]：移除旧 ID + 追加新 ID
    # -------------------------------------------------------------------------
    local updated_subtasks=()
    while IFS= read -r sid; do
        [[ "$sid" == "$old_subtask_id" ]] && continue
        [[ -n "$sid" ]] && updated_subtasks+=("$sid")
    done < <(jq -r '.subtasks // [] | .[]' "$parent_file" 2>/dev/null)
    updated_subtasks+=("${subtask_ids[@]}")

    local subtasks_json
    subtasks_json=$(printf '%s\n' "${updated_subtasks[@]}" | jq -R '.' | jq -s '.')
    local ptmp="$parent_file.tmp"
    jq --argjson subtasks "$subtasks_json" '.subtasks = $subtasks' \
        "$parent_file" > "$ptmp" && mv "$ptmp" "$parent_file"

    # -------------------------------------------------------------------------
    # 9. 事件 + 通知
    # -------------------------------------------------------------------------
    emit_event "task.expanded" "" "parent_id=$parent_id" \
        "old_subtask=$old_subtask_id" \
        "new_subtasks=$(IFS=,; echo "${subtask_ids[*]}")"

    # 通知父任务发布者
    local from_pane
    from_pane=$(jq -r --arg role "$p_from" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
    [[ -n "$from_pane" ]] && push_to_pane "$from_pane" \
        "[子任务展开] $parent_id 的子任务 $old_subtask_id 已展开为: $(IFS=,; echo "${subtask_ids[*]}")" 2>/dev/null || true

    # 通知 Worker（旧子任务的认领者，如果不是发布者本人）
    local worker_role
    worker_role=$(jq -r '.claimed_by // ""' "$TASKS_DIR/failed/$old_subtask_id.json" 2>/dev/null)
    if [[ -n "$worker_role" && "$worker_role" != "null" && "$worker_role" != "$p_from" ]]; then
        local worker_pane
        worker_pane=$(jq -r --arg role "$worker_role" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
        [[ -n "$worker_pane" ]] && push_to_pane "$worker_pane" \
            "[子任务展开] $old_subtask_id → ${subtask_ids[*]} (父任务: $parent_id)" 2>/dev/null || true
    fi

    # 通知被指派的角色
    for i in $(seq 0 $((subtask_count - 1))); do
        local sub_assign="${subtask_assigns[$i]}"
        local sub_id="${subtask_ids[$i]}"
        local sub_title="${subtask_titles[$i]}"
        if [[ -n "$sub_assign" ]]; then
            local target_pane
            target_pane=$(jq -r --arg role "$sub_assign" '.panes[] | select(.role == $role) | .pane' "$STATE_FILE" 2>/dev/null || echo "")
            [[ -n "$target_pane" ]] && push_to_pane "$target_pane" \
                "[子任务] $sub_id: $sub_title (父任务: $parent_id, 展开自: $old_subtask_id) 已指派给你" 2>/dev/null || true
        fi
    done

    info "子任务已展开: $old_subtask_id → $(IFS=,; echo "${subtask_ids[*]}") (父任务: $parent_id)"
    echo "新子任务 ID: $(IFS=,; echo "${subtask_ids[*]}")"
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

        # 跳过已上报的任务（escalated 状态由 supervisor 处理，不是孤儿）
        local escalated_status
        escalated_status=$(jq -r '.escalated.status // ""' "$f" 2>/dev/null)
        if [[ -n "$escalated_status" && "$escalated_status" != "null" ]]; then
            continue
        fi

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
