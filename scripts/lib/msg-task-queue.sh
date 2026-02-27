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
                --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
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
