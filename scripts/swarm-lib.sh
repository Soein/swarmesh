#!/usr/bin/env bash
################################################################################
# swarm-lib.sh - 共享事件库
#
# 提供 emit_event() 函数和公共路径变量，供所有 swarm 脚本 source 使用。
#
# 用法（在其他脚本中）:
#   source "$(cd "$(dirname "$0")" && pwd)/swarm-lib.sh"
#   emit_event "task.sent" "backend" "task_id=task-123" "content=实现登录API"
################################################################################

# 防止重复 source
[[ -n "${_SWARM_LIB_LOADED:-}" ]] && return 0
_SWARM_LIB_LOADED=1

# =============================================================================
# 公共路径变量（不覆盖已有值）
# =============================================================================

# 从脚本位置推导项目根目录（scripts/ 的父目录）
if [[ -z "${SWARM_ROOT:-}" ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        SWARM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    else
        SWARM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    fi
fi
RUNTIME_DIR="${RUNTIME_DIR:-$SWARM_ROOT/runtime}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$SWARM_ROOT/scripts}"
CONFIG_DIR="${CONFIG_DIR:-$SWARM_ROOT/config}"
MESSAGES_DIR="${MESSAGES_DIR:-$RUNTIME_DIR/messages}"
LOGS_DIR="${LOGS_DIR:-$RUNTIME_DIR/logs}"
TASKS_DIR="${TASKS_DIR:-$RUNTIME_DIR/tasks}"
STATE_FILE="${STATE_FILE:-$RUNTIME_DIR/state.json}"
EVENTS_LOG="${EVENTS_LOG:-$RUNTIME_DIR/events.jsonl}"
SESSION_NAME="${SWARM_SESSION:-swarm}"

# =============================================================================
# 公共工具函数（所有脚本共用，消除重复定义）
# =============================================================================

# 颜色（支持非终端环境自动禁用）
if [[ -t 2 ]]; then
    _C_RESET='\033[0m'; _C_RED='\033[0;31m'; _C_GREEN='\033[0;32m'
    _C_YELLOW='\033[0;33m'; _C_CYAN='\033[0;36m'
else
    _C_RESET=''; _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_CYAN=''
fi

log_info()    { echo -e "${_C_CYAN}[INFO]${_C_RESET} $*" >&2; }
log_warn()    { echo -e "${_C_YELLOW}[WARN]${_C_RESET} $*" >&2; }
log_error()   { echo -e "${_C_RED}[ERROR]${_C_RESET} $*" >&2; }
log_success() { echo -e "${_C_GREEN}[SUCCESS]${_C_RESET} $*" >&2; }
die()         { log_error "$*"; exit 1; }

get_timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

# 检查命令是否存在
check_command() {
    command -v "$1" &>/dev/null || die "需要安装 $1"
}

# 检查多个依赖
check_dependencies() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "缺少必要的命令: ${missing[*]}（请通过系统包管理器安装）"
    fi
}

# 生成唯一 ID（防碰撞: 秒+纳秒+PID+RANDOM）
gen_unique_id() {
    local prefix="${1:-id}"
    echo "${prefix}-$(date +%s%N 2>/dev/null || date +%s)-$$-${RANDOM}"
}

# 解析角色名/别名到 pane 映射
# 输出: pane_target|role_name
resolve_role_to_pane() {
    local role="$1"
    local state_file="${STATE_FILE:-$RUNTIME_DIR/state.json}"
    [[ -f "$state_file" ]] || die "state.json 不存在，蜂群未启动？"

    local result
    result=$(jq -r --arg q "$role" '
        .panes[] |
        select(.role == $q or (.alias // "" | split(",") | map(gsub("^\\s+|\\s+$"; "")) | index($q) != null)) |
        "\(.pane)|\(.role)"
    ' "$state_file" 2>/dev/null | head -1)

    [[ -n "$result" ]] || die "找不到角色: $role (使用 swarm-msg.sh list-roles 查看在线角色)"
    echo "$result"
}

# 解析角色名/别名到完整映射（供 relay/detect 使用）
# 输出: pane_target|role_name|cli_command|log_file
resolve_role_full() {
    local role="$1"
    local state_file="${STATE_FILE:-$RUNTIME_DIR/state.json}"
    [[ -f "$state_file" ]] || die "state.json 不存在，蜂群未启动？"

    local result
    result=$(jq -r --arg q "$role" '
        .panes[] |
        select(.role == $q or (.alias // "" | split(",") | map(gsub("^\\s+|\\s+$"; "")) | index($q) != null)) |
        "\(.pane)|\(.role)|\(.cli)|\(.log)"
    ' "$state_file" 2>/dev/null | head -1)

    [[ -n "$result" ]] || die "找不到角色: $role"
    echo "$result"
}

# =============================================================================
# 初始化消息构建（swarm-start.sh 和 swarm-join.sh 共用）
# =============================================================================

# 构建角色初始化消息
# 参数:
#   $1 - 配置文件路径
#   $2 - 角色分支名
#   $3 - 团队成员信息（已格式化的文本）
build_init_message() {
    local config_file="$1"
    local role_branch="$2"
    local team_info="$3"

    # 构建项目信息段（如果扫描结果存在）
    local project_info_section=""
    local project_info_file="$RUNTIME_DIR/project-info.json"
    if [[ -f "$project_info_file" ]]; then
        local key_files_list
        key_files_list=$(jq -r '.key_files[]?.path' "$project_info_file" 2>/dev/null | head -20)
        if [[ -n "$key_files_list" ]]; then
            project_info_section="
## 项目信息
项目已扫描，关键配置文件:
$key_files_list
详细内容请读取: $project_info_file"
        fi
    fi

    cat <<INIT_EOF
请读取你的角色配置文件: $config_file 并确认你已理解角色定义。
${project_info_section}

## 并行开发
你在独立的 git worktree 中工作，分支: $role_branch
你的代码修改不会与其他角色冲突。完成后由人类决定合并。

## 当前团队成员
${team_info}
注意: 只与上述团队成员沟通。如果任务需要的角色不在团队中,你需要自行承担该部分职责。
你可以随时执行 swarm-msg.sh list-roles 查看最新在线角色。

## Swarm 协作工具
消息（点对点）:
- 发送消息: swarm-msg.sh send <角色名> "消息内容"
- 回复消息: swarm-msg.sh reply <消息ID> "回复内容"
- 查看收件箱: swarm-msg.sh read
- 等待消息: swarm-msg.sh wait --timeout 60
- 查看在线角色: swarm-msg.sh list-roles
- 广播消息: swarm-msg.sh broadcast "消息内容"

任务队列（中心队列，任何角色可认领）:
- 发布任务: swarm-msg.sh publish <类型> "标题" --description "详情"
- 查看待认领: swarm-msg.sh list-tasks
- 认领任务: swarm-msg.sh claim <任务ID>
- 完成任务: swarm-msg.sh complete-task <任务ID> "结果"

开发完成后你的代码会自动 commit 到分支。如需审核,执行:
  swarm-msg.sh publish review "审核标题" --description "变更说明"

当你判断任务涉及其他角色的职责时,主动用 swarm-msg.sh send 联系他们。收到消息后请及时处理并回复。
INIT_EOF
}

# 通过 tmux paste-buffer 发送初始化消息到 pane
send_init_to_pane() {
    local pane_target="$1"
    local init_msg="$2"

    local init_tmp
    init_tmp=$(mktemp "${RUNTIME_DIR}/.init-XXXXXX.txt")
    printf '%s' "$init_msg" > "$init_tmp"
    tmux load-buffer "$init_tmp"
    tmux paste-buffer -t "${SESSION_NAME}:${pane_target}"
    sleep 0.3
    tmux send-keys -t "${SESSION_NAME}:${pane_target}" Enter
    rm -f "$init_tmp"
    sleep 1
}

# =============================================================================
# 双通道通知（inbox + paste-buffer，swarm-join.sh 和 swarm-leave.sh 共用）
# =============================================================================

# 向所有在线角色发送系统通知
# 参数:
#   $1 - 通知类别 (join/leave/system)
#   $2 - inbox 完整消息内容
#   $3 - paste-buffer 简短通知
#   $4 - 排除的角色名（可选）
notify_all_roles() {
    local category="$1"
    local inbox_content="$2"
    local pane_content="$3"
    local exclude_role="${4:-}"
    local state_file="${STATE_FILE:-$RUNTIME_DIR/state.json}"

    while IFS='|' read -r role_name role_pane; do
        [[ -z "$role_name" ]] && continue
        [[ "$role_name" == "$exclude_role" ]] && continue

        # 通道 1: 写入收件箱（可靠持久）
        local notify_id
        notify_id="sys-${category}-$(date +%s)-${RANDOM}"
        mkdir -p "${MESSAGES_DIR}/inbox/${role_name}"
        jq -n \
            --arg id "$notify_id" \
            --arg from "system" \
            --arg to "$role_name" \
            --arg content "$inbox_content" \
            --arg timestamp "$(get_timestamp)" \
            --arg status "pending" \
            --arg priority "high" \
            '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority}' \
            > "${MESSAGES_DIR}/inbox/${role_name}/${notify_id}.json"

        # 通道 2: paste-buffer 尽力即时推送
        local notify_tmp
        notify_tmp=$(mktemp "${RUNTIME_DIR}/.notify-XXXXXX.txt")
        printf '%s' "$pane_content" > "$notify_tmp"
        tmux load-buffer "$notify_tmp"
        tmux paste-buffer -t "${SESSION_NAME}:${role_pane}" 2>/dev/null || true
        sleep 0.3
        tmux send-keys -t "${SESSION_NAME}:${role_pane}" Enter 2>/dev/null || true
        rm -f "$notify_tmp"

    done < <(jq -r '.panes[] | "\(.role)|\(.pane)"' "$state_file" 2>/dev/null)
}

# =============================================================================
# state.json 原子更新（flock 文件锁）
# =============================================================================

# 原子更新 state.json（使用 flock 避免并发写入竞态）
# 用法: state_json_update '.panes += [$new_pane]' --argjson new_pane "$JSON"
# 所有对 state.json 的写入操作都应通过此函数
state_json_update() {
    local state_file="${STATE_FILE:-$RUNTIME_DIR/state.json}"
    local lock_file="${state_file}.lock"
    local tmp_file
    tmp_file=$(mktemp "${RUNTIME_DIR}/.state-update-XXXXXX.json")

    (
        flock -x 200
        jq "$@" "$state_file" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$state_file"
    ) 200>"$lock_file"

    rm -f "$tmp_file" 2>/dev/null || true
}

# =============================================================================
# macOS 兼容: timeout polyfill
# =============================================================================

if ! command -v timeout &>/dev/null; then
    # polyfill: 超时返回 124（与 GNU coreutils timeout 一致），
    # 正常结束返回命令本身的 exit code
    timeout() {
        local duration="$1"; shift
        ( "$@" ) &
        local cmd_pid=$!
        ( sleep "$duration" 2>/dev/null; kill "$cmd_pid" 2>/dev/null ) &
        local timer_pid=$!
        wait "$cmd_pid" 2>/dev/null
        local exit_code=$?
        # 如果 timer 仍在运行，说明命令自己退出了（未超时）
        if kill "$timer_pid" 2>/dev/null; then
            wait "$timer_pid" 2>/dev/null
            return $exit_code
        fi
        # timer 已结束（kill 返回非 0），说明是超时触发的 kill
        wait "$timer_pid" 2>/dev/null
        return 124
    }
fi

# =============================================================================
# 事件发射函数
# =============================================================================

# emit_event <type> <role> [key=value ...]
#
# 参数:
#   type  - 事件类型 (如 task.sent, task.completed, system.started)
#   role  - 相关角色 (可为空字符串)
#   key=value... - 可选的数据字段
#
# 示例:
#   emit_event "task.sent" "backend" "task_id=task-123" "pane=0.1"
#   emit_event "system.started" "" "profile=minimal"
#   emit_event "workflow.completed" "" "workflow_id=wf-001"
emit_event() {
    local type="$1"
    local role="${2:-}"
    shift 2 2>/dev/null || shift $#

    # 构建 data JSON（从 key=value 参数，单次 jq 调用）
    local jq_args=(--arg ts "$(date '+%Y-%m-%dT%H:%M:%S')" --arg type "$type" --arg role "$role")
    local data_expr="{"
    local first=true
    for kv in "$@"; do
        local k="${kv%%=*}"
        local v="${kv#*=}"
        jq_args+=(--arg "kv_${k}" "$v")
        $first || data_expr+=","
        data_expr+="(\"$k\"):\$kv_${k}"
        first=false
    done
    data_expr+="}"

    # 单次 jq 调用构建完整事件 JSON，flock 保护并发追加
    local event
    event=$(jq -nc "${jq_args[@]}" "{ts:\$ts, type:\$type, role:\$role, data:$data_expr}")
    (flock -x 200; echo "$event" >> "$EVENTS_LOG") 200>"${EVENTS_LOG}.lock"
}

# =============================================================================
# 角色持久上下文生成
# =============================================================================

# 持久上下文标记（用于注入和清理）
SWARM_CONTEXT_START="<!-- SWARM-CONTEXT-START (auto-generated, do not edit) -->"
SWARM_CONTEXT_END="<!-- SWARM-CONTEXT-END -->"

# 生成蜂群共享上下文内容
# 所有角色共享同一份上下文，各角色通过 $SWARM_ROLE 环境变量识别自己
#
# 参数:
#   $1 - state.json 路径
_build_swarm_context() {
    local state_file="$1"

    # 构建团队成员列表
    local team_info=""
    if [[ -f "$state_file" ]]; then
        while IFS='|' read -r r_name r_alias r_branch; do
            team_info+="- $r_name"
            [[ -n "$r_alias" && "$r_alias" != "" ]] && team_info+=" ($r_alias)"
            [[ -n "$r_branch" && "$r_branch" != "" ]] && team_info+=" [branch: $r_branch]"
            team_info+=$'\n'
        done < <(jq -r '.panes[] | "\(.role)|\(.alias // "")|\(.branch // "")"' "$state_file" 2>/dev/null)
    fi

    # 项目信息引用（原始事实由 LLM 自行解读）
    local tech_stack_section=""
    local project_info="$RUNTIME_DIR/project-info.json"
    if [[ -f "$project_info" ]]; then
        local key_files_list
        key_files_list=$(jq -r '[.key_files[]?.path] | join(", ")' "$project_info" 2>/dev/null)
        if [[ -n "$key_files_list" ]]; then
            tech_stack_section="
## 项目信息
项目已扫描，关键配置文件: ${key_files_list}
详情: cat $project_info
请自行分析技术栈，发布任务时用 --verify 指定质量门验证命令。
"
        fi
    fi

    cat <<EOF
$SWARM_CONTEXT_START
# Swarm 蜂群协作上下文 (自动生成，勿手动编辑)

## 你的身份
通过环境变量确认: echo \$SWARM_ROLE
${tech_stack_section}
## 并行开发模式
每个角色在独立的 git worktree 中工作，拥有独立分支。
你的代码修改不会与其他角色冲突。完成后由人类决定合并。

## 当前团队成员
${team_info:-（暂无其他成员）}

注意: 只与上述团队成员沟通。如果需要的角色不在团队中，自行承担该职责。
执行 swarm-msg.sh list-roles 可查看最新在线角色。

## 协作通讯工具

你在一个多角色蜂群中工作。使用以下 shell 命令与其他角色沟通：

### 消息（点对点）
| 命令 | 说明 |
|------|------|
| swarm-msg.sh send <role> "msg" | 发消息给指定角色 |
| swarm-msg.sh reply <id> "msg" | 回复消息 |
| swarm-msg.sh read | 查看收件箱 |
| swarm-msg.sh wait --timeout 60 | 等待新消息 |
| swarm-msg.sh list-roles | 查看在线角色 |
| swarm-msg.sh broadcast "msg" | 广播给所有人 |

### 任务队列（中心队列，任何角色可认领）
| 命令 | 说明 |
|------|------|
| swarm-msg.sh create-group "title" | 创建任务组（返回 group-id） |
| swarm-msg.sh publish <type> "title" [-g group-id] [--depends id1,id2] | 发布任务 |
| swarm-msg.sh list-tasks | 查看待认领任务 |
| swarm-msg.sh claim <task-id> | 认领任务 |
| swarm-msg.sh complete-task <id> "result" | 完成任务并反馈 |
| swarm-msg.sh group-status [group-id] | 查看任务组进度 |

任务组示例（带依赖）:
  G=\$(swarm-msg.sh create-group "用户注册系统")
  T1=\$(swarm-msg.sh publish develop "实现 API" -g \$G)
  T2=\$(swarm-msg.sh publish develop "设计数据库" -g \$G)
  T3=\$(swarm-msg.sh publish review "审核代码" -g \$G --depends \$T1,\$T2)

### 行为准则
1. 当任务涉及其他角色的职责时，主动用 swarm-msg.sh send 联系对方
2. 批量任务用 create-group 创建组，用 --depends 设置依赖顺序
3. 开发完成后，代码会自动 commit 到你的分支，然后用 publish 发布审核任务
4. 审核角色从队列 claim 任务，用 git diff 审核分支代码
5. 任务完成后用 complete-task 反馈，依赖此任务的阻塞任务会自动解锁
6. 任务组全部完成时，发布者会自动收到通知
$SWARM_CONTEXT_END
EOF
}

# 将蜂群上下文注入到项目目录的持久配置文件中
# 根据团队中使用的 CLI 类型，写入对应文件：
#   Claude Code → .claude/CLAUDE.md
#   Codex       → AGENTS.md
#   Gemini      → GEMINI.md
#
# 如果文件已存在，替换标记之间的内容；否则追加到末尾。
#
# 参数:
#   $1 - state.json 路径
inject_swarm_context() {
    local state_file="${1:-$RUNTIME_DIR/state.json}"
    [[ -f "$state_file" ]] || return 0

    local context
    context=$(_build_swarm_context "$state_file")

    # 为每个角色的 worktree 注入上下文（按 CLI 类型选择目标文件）
    while IFS='|' read -r cli worktree; do
        [[ -n "$worktree" && -d "$worktree" ]] || continue
        case "$cli" in
            *claude*) _inject_to_file "$worktree/.claude/CLAUDE.md" "$context" ;;
            *codex*)  _inject_to_file "$worktree/AGENTS.md" "$context" ;;
            *gemini*) _inject_to_file "$worktree/GEMINI.md" "$context" ;;
        esac
    done < <(jq -r '.panes[] | "\(.cli)|\(.worktree // "")"' "$state_file" 2>/dev/null)
}

# 向指定文件注入/更新标记内容
# 参数:
#   $1 - 文件路径
#   $2 - 要注入的内容（含标记）
_inject_to_file() {
    local file="$1"
    local content="$2"

    mkdir -p "$(dirname "$file")"

    if [[ ! -f "$file" ]]; then
        # 文件不存在，直接创建
        printf '%s\n' "$content" > "$file"
    elif grep -q "$SWARM_CONTEXT_START" "$file" 2>/dev/null; then
        # 已有标记，替换标记之间的内容
        local tmp
        tmp=$(mktemp "${RUNTIME_DIR}/.ctx-XXXXXX.md")
        awk -v start="$SWARM_CONTEXT_START" -v end="$SWARM_CONTEXT_END" -v new="$content" '
            $0 == start { skip=1; print new; next }
            $0 == end   { skip=0; next }
            !skip       { print }
        ' "$file" > "$tmp"
        mv "$tmp" "$file"
    else
        # 文件存在但无标记，追加到末尾
        printf '\n%s\n' "$content" >> "$file"
    fi
}

# 从项目目录清理蜂群上下文标记
# 参数:
#   $1 - state.json 路径（或直接传 project_dir）
cleanup_swarm_context() {
    local state_file="${1:-$RUNTIME_DIR/state.json}"
    [[ -f "$state_file" ]] || return 0

    # 清理每个 worktree 中的上下文标记
    while IFS= read -r worktree; do
        [[ -n "$worktree" && -d "$worktree" ]] || continue
        for file in "$worktree/.claude/CLAUDE.md" "$worktree/AGENTS.md" "$worktree/GEMINI.md"; do
            [[ -f "$file" ]] || continue
            if grep -q "$SWARM_CONTEXT_START" "$file" 2>/dev/null; then
                local tmp
                tmp=$(mktemp "${RUNTIME_DIR:-.}/.ctx-clean-XXXXXX.md")
                awk -v start="$SWARM_CONTEXT_START" -v end="$SWARM_CONTEXT_END" '
                    $0 == start { skip=1; next }
                    $0 == end   { skip=0; next }
                    !skip       { print }
                ' "$file" > "$tmp"
                if [[ ! -s "$tmp" ]] || ! grep -q '[^[:space:]]' "$tmp" 2>/dev/null; then
                    rm -f "$file" "$tmp"
                else
                    mv "$tmp" "$file"
                fi
            fi
        done
    done < <(jq -r '.panes[].worktree // empty' "$state_file" 2>/dev/null)
}

# 刷新蜂群上下文（team 变化时调用）
refresh_all_contexts() {
    local state_file="${1:-$RUNTIME_DIR/state.json}"
    inject_swarm_context "$state_file"
}

# =============================================================================
# Worktree 自动提交
# =============================================================================

# 检测 worktree 是否有未提交的变更，如有则自动 commit
# 参数:
#   $1 - 角色名
#   $2 - worktree 路径
auto_commit_worktree() {
    local role="$1" worktree="$2"
    [[ -n "$worktree" && -d "$worktree" ]] || return 0

    # 检查是否有变更（工作区 + 暂存区 + 未跟踪文件）
    local has_changes=false
    if ! git -C "$worktree" diff --quiet HEAD 2>/dev/null; then
        has_changes=true
    elif ! git -C "$worktree" diff --cached --quiet HEAD 2>/dev/null; then
        has_changes=true
    elif [[ -n "$(git -C "$worktree" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        has_changes=true
    fi

    [[ "$has_changes" == true ]] || return 0

    # 生成 commit 消息（包含变更文件摘要）
    local changed_files
    changed_files=$(git -C "$worktree" diff --name-only HEAD 2>/dev/null | head -5)
    local untracked
    untracked=$(git -C "$worktree" ls-files --others --exclude-standard 2>/dev/null | head -5)

    local summary=""
    [[ -n "$changed_files" ]] && summary="$changed_files"
    [[ -n "$untracked" ]] && summary="${summary:+$summary\n}$untracked"
    local file_count
    file_count=$(echo -e "${summary}" | grep -c '[^[:space:]]' 2>/dev/null || echo "0")

    git -C "$worktree" add -A 2>/dev/null || return 0
    git -C "$worktree" commit -m "swarm($role): 任务完成自动提交 ($file_count 个文件变更)" 2>/dev/null || return 0

    emit_event "git.auto_commit" "$role" "worktree=$worktree" "files=$file_count"
}

# =============================================================================
# CLI 提示符检测
# =============================================================================

# CLI 提示符模式（Claude: ❯  Gemini: >  Codex: ›）
PROMPT_PATTERNS="${PROMPT_PATTERNS:-❯|›|^[[:space:]]*>[[:space:]]*$|Type your message|context left}"

# 静默阈值（秒）- 多久没输出算完成
SILENCE_THRESHOLD="${SILENCE_THRESHOLD:-5}"

# 检查 pane 最后几行是否包含 CLI 提示符
# 注意: tmux pane 底部可能有大量空行，需过滤后再检查
# 依赖: 调用脚本需已定义 SESSION_NAME
check_prompt() {
    local pane_target="$1"
    local last_lines
    last_lines=$(tmux capture-pane -t "${SESSION_NAME}:${pane_target}" -p 2>/dev/null \
        | sed '/^[[:space:]]*$/d' \
        | tail -5)

    echo "$last_lines" | grep -qE "$PROMPT_PATTERNS"
}

# =============================================================================
# Pane Watcher 守护进程
# =============================================================================

# 启动 pane 监视守护进程
# 实时检测 CLI 完成状态，通过事件推送（零轮询）
#
# 状态机:
#   init → (静默+提示符) → idle → (新输出) → active → (静默+提示符) → idle
#   init: CLI 启动中，跳过初始输出
#   idle: CLI 在提示符等待输入
#   active: CLI 正在处理，产生输出
#
# 参数:
#   $1 - 角色名
#   $2 - 日志文件路径
#   $3 - pane target (如 0.1)
#   $4 - worktree 路径（可选，有则在任务完成时自动 commit）
#
# 输出: watcher 进程的 PID (stdout)
start_pane_watcher() {
    local role="$1" log_file="$2" pane="$3" worktree="${4:-}"

    (
        local state="init"

        # 等待日志文件出现
        while [[ ! -f "$log_file" ]]; do sleep 0.5; done

        # tail -f 事件驱动: macOS=kqueue, Linux=inotify，零 CPU 开销
        exec 3< <(tail -f "$log_file" 2>/dev/null)

        while true; do
            if IFS= read -t "$SILENCE_THRESHOLD" -r _line <&3; then
                # 有新输出
                if [[ "$state" == "idle" ]]; then
                    state="active"
                fi
                # init 和 active 状态下继续消费输出
            else
                # 静默超过阈值
                case "$state" in
                    init)
                        # CLI 启动完成？检查提示符
                        if check_prompt "$pane"; then
                            state="idle"
                        fi
                        ;;
                    active)
                        # 任务完成？检查提示符
                        if check_prompt "$pane"; then
                            # 自动提交 worktree 中的变更
                            auto_commit_worktree "$role" "$worktree"
                            emit_event "task.completed" "$role" "pane=$pane" "detected_by=watcher"
                            state="idle"
                        fi
                        # 未找到提示符 → CLI 仍在思考（输出暂停），保持 active
                        ;;
                    # idle 状态下忽略静默超时
                esac
            fi
        done
    ) &
    echo $!
}
