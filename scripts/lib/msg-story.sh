#!/usr/bin/env bash
################################################################################
# msg-story.sh - Story 文件管理（任务上下文载体）
#
# 设计：数据用 JSON 存储（可靠读写），展示时用 jq 渲染为 markdown。
# 由 swarm-msg.sh source 加载，不独立运行。
################################################################################

[[ -n "${_MSG_STORY_LOADED:-}" ]] && return 0
_MSG_STORY_LOADED=1

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
    now=$(get_timestamp)

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
            prd: null,
            tasks: [],
            verifications: [],
            timeline: [($created_at + " 任务组创建 by " + $from)]
        }' > "$story_file"
}

# 关联 PRD 到 Story
# 参数: $1=group_id, $2=prd_content, $3=from(提交者)
# 使用临时文件传递 PRD 内容，避免长文本超出 ARG_MAX 限制
_story_set_prd() {
    local group_id="$1" prd_content="$2" from="${3:-prd}"
    local now
    now=$(get_timestamp)

    # 将 PRD 构造为 JSON 对象写入临时文件（通过文件传递内容，避免 ARG_MAX）
    local prd_tmp prd_content_tmp
    prd_tmp=$(mktemp "${RUNTIME_DIR:=/tmp}/.prd-XXXXXX")
    prd_content_tmp=$(mktemp "${RUNTIME_DIR:=/tmp}/.prd-content-XXXXXX")
    trap "rm -f '$prd_tmp' '$prd_content_tmp'" RETURN
    printf '%s' "$prd_content" > "$prd_content_tmp"
    jq -n \
        --rawfile content "$prd_content_tmp" \
        --arg from "$from" \
        --arg updated_at "$now" \
        '{content:$content, from:$from, updated_at:$updated_at}' > "$prd_tmp"
    rm -f "$prd_content_tmp"

    _story_update "$group_id" \
        '.prd = $p[0] | .timeline += [$msg]' \
        --slurpfile p "$prd_tmp" \
        --arg msg "$now PRD 关联 by $from"
}

# 向 Story 追加子任务
# 参数: $1=group_id, $2=task_id, $3=title, $4=type, $5=assigned_to, $6=branch
_story_add_task() {
    local group_id="$1" task_id="$2" title="$3" type="${4:-}" assigned_to="${5:-}" branch="${6:-}" phase="${7:-}"
    local now
    now=$(get_timestamp)

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
            --arg phase "$phase" \
            --arg status "pending" \
            '{id:$id, title:$title, type:$type, assigned_to:$assigned_to, branch:$branch, phase:$phase, status:$status, result:null}')" \
        --arg msg "$timeline_msg"
}

# 更新 Story 中的子任务状态
# 参数: $1=task_id, $2=status(processing/completed), $3=info(可选), $4=phase(可选)
_story_update_task() {
    local task_id="$1" new_status="$2" info="${3:-}" phase="${4:-}"

    # 查找任务所属 group_id
    local group_id=""
    local task_file=""
    for d in processing completed pending blocked failed; do
        [[ -f "$TASKS_DIR/$d/$task_id.json" ]] && task_file="$TASKS_DIR/$d/$task_id.json" && break
    done
    [[ -n "$task_file" ]] && group_id=$(jq -r '.group_id // ""' "$task_file" 2>/dev/null)
    [[ -n "$group_id" ]] || return 0

    local now
    now=$(get_timestamp)

    _story_update "$group_id" \
        '(.tasks[] | select(.id == $tid)) |= (.status = $s
          | .phase = (if $p != "" then $p else .phase end)
          | .result = (if $r != "" then $r else .result end))
         | .timeline += [$msg]' \
        --arg tid "$task_id" \
        --arg s "$new_status" \
        --arg r "$info" \
        --arg p "$phase" \
        --arg msg "$now $task_id $new_status${phase:+ [$phase]}"
}

# 向 Story 追加验收记录
# 参数: $1=group_id, $2=task_id, $3=result(通过/失败), $4=checker
_story_add_verification() {
    local group_id="$1" task_id="$2" result="$3" checker="${4:-自动}"
    local now
    now=$(get_timestamp)

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
    now=$(get_timestamp)

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
        (if .prd then
            "## PRD\n\n" +
            "> 提交者: \(.prd.from) | 更新时间: \(.prd.updated_at)\n\n" +
            "\(.prd.content)\n\n"
         else "" end) +
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
