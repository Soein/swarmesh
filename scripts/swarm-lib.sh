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

# 保存环境显式设置的值（区分"用户设了"vs"脚本默认"）
_RUNTIME_DIR_FROM_ENV="${RUNTIME_DIR:-}"

# 从脚本位置推导框架根目录（scripts/ 的父目录）
if [[ -z "${SWARM_ROOT:-}" ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        SWARM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    else
        SWARM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    fi
fi

# 从 CWD 向上查找 .swarm/runtime/state.json，定位项目根目录
_detect_project_from_cwd() {
    local dir="$(pwd)"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/.swarm/runtime/state.json" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# 根据 PROJECT_DIR 重算所有运行时路径（swarm-start.sh 解析 --project 后调用）
_reinit_runtime_paths() {
    [[ -n "${PROJECT_DIR:-}" ]] || return 0
    RUNTIME_DIR="$PROJECT_DIR/.swarm/runtime"
    MESSAGES_DIR="$RUNTIME_DIR/messages"
    INBOX_DIR="$MESSAGES_DIR/inbox"
    OUTBOX_DIR="$MESSAGES_DIR/outbox"
    LOGS_DIR="$RUNTIME_DIR/logs"
    TASKS_DIR="$RUNTIME_DIR/tasks"
    STATE_FILE="$RUNTIME_DIR/state.json"
    EVENTS_LOG="$RUNTIME_DIR/events.jsonl"
    SESSION_NAME="${SWARM_SESSION:-swarm-$(basename "$PROJECT_DIR")}"
}

# 路径优先级：环境变量 > 项目检测 > 框架回退
if [[ -n "$_RUNTIME_DIR_FROM_ENV" ]]; then
    RUNTIME_DIR="$_RUNTIME_DIR_FROM_ENV"
elif [[ -n "${PROJECT_DIR:-}" ]]; then
    RUNTIME_DIR="$PROJECT_DIR/.swarm/runtime"
elif _auto_project=$(_detect_project_from_cwd 2>/dev/null); then
    PROJECT_DIR="$_auto_project"
    RUNTIME_DIR="$PROJECT_DIR/.swarm/runtime"
else
    RUNTIME_DIR="$SWARM_ROOT/runtime"
fi

# SESSION_NAME：有项目时带项目名
if [[ -n "${PROJECT_DIR:-}" ]]; then
    SESSION_NAME="${SWARM_SESSION:-swarm-$(basename "$PROJECT_DIR")}"
else
    SESSION_NAME="${SWARM_SESSION:-swarm}"
fi

# 后续依赖路径（基于正确的 RUNTIME_DIR）
SCRIPTS_DIR="${SCRIPTS_DIR:-$SWARM_ROOT/scripts}"
CONFIG_DIR="${CONFIG_DIR:-$SWARM_ROOT/config}"
MESSAGES_DIR="${MESSAGES_DIR:-$RUNTIME_DIR/messages}"
INBOX_DIR="${INBOX_DIR:-$MESSAGES_DIR/inbox}"
OUTBOX_DIR="${OUTBOX_DIR:-$MESSAGES_DIR/outbox}"
LOGS_DIR="${LOGS_DIR:-$RUNTIME_DIR/logs}"
TASKS_DIR="${TASKS_DIR:-$RUNTIME_DIR/tasks}"
STATE_FILE="${STATE_FILE:-$RUNTIME_DIR/state.json}"
EVENTS_LOG="${EVENTS_LOG:-$RUNTIME_DIR/events.jsonl}"

# =============================================================================
# 加载配置（优先级：框架默认 < 项目覆盖 < 环境变量）
# =============================================================================

# 框架默认值立即加载（:= 模式只填充未设置的变量，安全）
_load_defaults() {
    local defaults="$CONFIG_DIR/defaults.conf"
    [[ -f "$defaults" ]] && source "$defaults"
}

# 在首次 source 时保存来自环境的原始值（用于 load_project_config 恢复）
_swarm_save_env_config() {
    local defaults="$CONFIG_DIR/defaults.conf"
    [[ -f "$defaults" ]] || return 0
    _SWARM_ENV_SNAPSHOT=()
    local var
    while IFS= read -r var; do
        [[ -n "${!var+set}" ]] && _SWARM_ENV_SNAPSHOT+=("${var}=${!var}")
    done < <(grep -oE '\$\{[A-Z_]+:=' "$defaults" | sed 's/\${//;s/:=//')
}
declare -a _SWARM_ENV_SNAPSHOT=()
_swarm_save_env_config
_load_defaults

# 加载项目级覆盖（需在 PROJECT_DIR 设置后由调用脚本显式调用）
# 正确实现三层优先级: 环境变量 > 项目覆盖(:=) > 框架默认(:=)
#
# 原理: 先 unset 所有配置变量 → 恢复环境原始值 → source 项目配置 → source 默认值
# 由于两层都用 :=（只在未设置时赋值），先加载的优先
load_project_config() {
    local project_conf="${PROJECT_DIR:+$PROJECT_DIR/.swarm/swarm.conf}"
    [[ -n "$project_conf" && -f "$project_conf" ]] || return 0

    local defaults="$CONFIG_DIR/defaults.conf"
    [[ -f "$defaults" ]] || return 0

    # 1. 提取所有配置变量名并 unset
    local var
    while IFS= read -r var; do
        unset "$var"
    done < <(grep -oE '\$\{[A-Z_]+:=' "$defaults" | sed 's/\${//;s/:=//')

    # 2. 恢复环境原始值（最高优先级）
    local entry
    for entry in "${_SWARM_ENV_SNAPSHOT[@]}"; do
        local key="${entry%%=*}"
        local val="${entry#*=}"
        printf -v "$key" '%s' "$val"
    done

    # 3. 加载项目覆盖 → 框架默认（:= 先到先得）
    source "$project_conf"
    _load_defaults
}

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

log_info()    { echo -e "${_C_CYAN}[$(get_timestamp)] [INFO]${_C_RESET} $*" >&2; }
log_warn()    { echo -e "${_C_YELLOW}[$(get_timestamp)] [WARN]${_C_RESET} $*" >&2; }
log_error()   { echo -e "${_C_RED}[$(get_timestamp)] [ERROR]${_C_RESET} $*" >&2; }
log_success() { echo -e "${_C_GREEN}[$(get_timestamp)] [SUCCESS]${_C_RESET} $*" >&2; }
die()         { log_error "$*"; exit 1; }

get_timestamp() {
    date "+$LOG_TIMESTAMP_FORMAT"
}

# 获取文件修改时间（macOS/Linux 兼容）
_file_mtime() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo "0"
}

# 获取文件大小（macOS/Linux 兼容）
_file_size() {
    stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo "0"
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

# 生成实例名（首实例 instance==role，后续 role-2, role-3, ...）
generate_instance_name() {
    local role="$1" state_file="$2"
    local existing_count
    existing_count=$(jq -r --arg role "$role" '[.panes[] | select(.role == $role)] | length' "$state_file" 2>/dev/null)
    if [[ "$existing_count" -eq 0 ]]; then
        echo "$role"
    else
        local max_num
        max_num=$(jq -r --arg role "$role" '
            [.panes[] | select(.role == $role) | .instance |
             if test("-[0-9]+$") then (split("-") | last | tonumber) else 1 end
            ] | max // 1
        ' "$state_file" 2>/dev/null)
        echo "${role}-$((max_num + 1))"
    fi
}

# 通用 pane 查找: 先精确匹配 instance，再回退 role
# 输出: pane target（单行）
_resolve_pane_by_id() {
    local id="$1"
    local state_file="${STATE_FILE:-$RUNTIME_DIR/state.json}"
    jq -r --arg q "$id" '
        (.panes[] | select(.instance == $q) | .pane) //
        (.panes[] | select(.role == $q) | .pane) //
        empty
    ' "$state_file" 2>/dev/null | head -1
}

# 按角色查找全部实例
# 输出: 每行 pane|instance|cli
resolve_role_to_all_panes() {
    local role="$1"
    local state_file="${STATE_FILE:-$RUNTIME_DIR/state.json}"
    jq -r --arg q "$role" '
        .panes[] | select(.role == $q) | "\(.pane)|\(.instance)|\(.cli // "unknown")"
    ' "$state_file" 2>/dev/null
}

# 解析角色名/别名/实例名到 pane 映射
# 输出: pane_target|instance_name
resolve_role_to_pane() {
    local query="$1"
    local state_file="${STATE_FILE:-$RUNTIME_DIR/state.json}"
    [[ -f "$state_file" ]] || die "state.json 不存在，蜂群未启动？"

    local result
    # 优先精确匹配 instance
    result=$(jq -r --arg q "$query" '
        .panes[] | select(.instance == $q) | "\(.pane)|\(.instance)"
    ' "$state_file" 2>/dev/null | head -1)

    # 回退到 role/alias 匹配
    if [[ -z "$result" ]]; then
        result=$(jq -r --arg q "$query" '
            .panes[] |
            select(.role == $q or (.alias // "" | split(",") | map(gsub("^\\s+|\\s+$"; "")) | index($q) != null)) |
            "\(.pane)|\(.instance)"
        ' "$state_file" 2>/dev/null | head -1)
    fi

    [[ -n "$result" ]] || die "找不到角色/实例: $query (使用 swarm-msg.sh list-roles 查看在线角色)"
    echo "$result"
}

# 解析角色名/别名/实例名到完整映射（供 relay/detect 使用）
# 输出: pane_target|instance_name|cli_command|log_file
resolve_role_full() {
    local query="$1"
    local state_file="${STATE_FILE:-$RUNTIME_DIR/state.json}"
    [[ -f "$state_file" ]] || die "state.json 不存在，蜂群未启动？"

    local result
    # 优先精确匹配 instance
    result=$(jq -r --arg q "$query" '
        .panes[] | select(.instance == $q) | "\(.pane)|\(.instance)|\(.cli // "unknown")|\(.log)"
    ' "$state_file" 2>/dev/null | head -1)

    if [[ -z "$result" ]]; then
        result=$(jq -r --arg q "$query" '
            .panes[] |
            select(.role == $q or (.alias // "" | split(",") | map(gsub("^\\s+|\\s+$"; "")) | index($q) != null)) |
            "\(.pane)|\(.instance)|\(.cli // "unknown")|\(.log)"
        ' "$state_file" 2>/dev/null | head -1)
    fi

    [[ -n "$result" ]] || die "找不到角色/实例: $query"
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

# =============================================================================
# 恢复摘要生成（swarm-stop.sh 和 swarm-start.sh 共用）
# =============================================================================

# 生成单个实例的工作摘要
# 参数:
#   $1 - 实例名 (如 frontend, backend-2)
#   $2 - 分支名 (如 swarm/frontend)
#   $3 - 项目目录
#   $4 - 输出文件路径
generate_instance_resume_summary() {
    local instance="$1" branch="$2" project_dir="$3" output_file="$4"

    mkdir -p "$(dirname "$output_file")"

    {
        echo "# 恢复摘要: $instance"
        echo "生成时间: $(get_timestamp)"
        echo "分支: $branch"
        echo ""

        # Git 提交历史（该分支相对于 main/HEAD 的新提交）
        echo "## 最近提交"
        local main_branch
        main_branch=$(git -C "$project_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
            | sed 's|refs/remotes/origin/||')
        if [[ -z "$main_branch" ]]; then
            for candidate in main master; do
                if git -C "$project_dir" show-ref --verify --quiet "refs/heads/$candidate" 2>/dev/null; then
                    main_branch="$candidate"; break
                fi
            done
            main_branch="${main_branch:-main}"
        fi
        if git -C "$project_dir" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
            local commits
            commits=$(git -C "$project_dir" log "$branch" --not "$main_branch" \
                --oneline --no-decorate -n "${RESUME_SUMMARY_MAX_COMMITS:-20}" 2>/dev/null)
            if [[ -n "$commits" ]]; then
                echo '```'
                echo "$commits"
                echo '```'
            else
                echo "（无新提交）"
            fi
        else
            echo "（分支 $branch 不存在）"
        fi
        echo ""

        # 已完成的任务
        echo "## 已完成任务"
        local completed_count=0
        if [[ -d "$TASKS_DIR/completed" ]]; then
            local task_file
            for task_file in "$TASKS_DIR/completed/"*.json; do
                [[ -f "$task_file" ]] || continue
                local claimed_by
                claimed_by=$(jq -r '.claimed_by // ""' "$task_file" 2>/dev/null)
                if [[ "$claimed_by" == "$instance" ]]; then
                    ((completed_count++)) || true
                    [[ $completed_count -le ${RESUME_SUMMARY_MAX_TASKS:-10} ]] || continue
                    local title result
                    title=$(jq -r '.title // .id // "unknown"' "$task_file" 2>/dev/null)
                    result=$(jq -r '.result // "" | if length > 100 then .[:100] + "..." else . end' "$task_file" 2>/dev/null)
                    echo "- [完成] $title"
                    [[ -n "$result" ]] && echo "  结果: $result"
                fi
            done
        fi
        [[ $completed_count -eq 0 ]] && echo "（无）"
        echo ""

        # 未完成的任务（processing + pending 中 claimed_by 匹配）
        echo "## 未完成任务"
        local pending_count=0
        for status_dir in "$TASKS_DIR/processing" "$TASKS_DIR/pending"; do
            [[ -d "$status_dir" ]] || continue
            local task_file
            for task_file in "$status_dir/"*.json; do
                [[ -f "$task_file" ]] || continue
                local claimed_by
                claimed_by=$(jq -r '.claimed_by // ""' "$task_file" 2>/dev/null)
                if [[ "$claimed_by" == "$instance" ]]; then
                    ((pending_count++)) || true
                    [[ $pending_count -le ${RESUME_SUMMARY_MAX_TASKS:-10} ]] || continue
                    local title task_id task_status
                    title=$(jq -r '.title // .id // "unknown"' "$task_file" 2>/dev/null)
                    task_id=$(basename "$task_file" .json)
                    task_status=$(jq -r '.status // "unknown"' "$task_file" 2>/dev/null)
                    echo "- [$task_status] $title (ID: $task_id)"
                fi
            done
        done
        [[ $pending_count -eq 0 ]] && echo "（无）"
        echo ""

        # 最后 CLI 输出（stop 时捕获的 pane 内容）
        echo "## 最后 CLI 输出"
        local pane_output_file="${RESUME_SUMMARY_DIR:-$RUNTIME_DIR/resume}/${instance}.pane-output"
        if [[ -f "$pane_output_file" && -s "$pane_output_file" ]]; then
            echo '```'
            cat "$pane_output_file"
            echo '```'
        else
            echo "（无）"
        fi
        echo ""

        # 最近消息记录（inbox + outbox）
        echo "## 最近消息"
        local msg_count=0
        local max_msgs="${RESUME_SUMMARY_MAX_MESSAGES:-10}"
        local all_msgs=()
        for dir in "$MESSAGES_DIR/inbox/$instance" "$MESSAGES_DIR/outbox/$instance"; do
            [[ -d "$dir" ]] || continue
            for msg_file in "$dir/"*.json; do
                [[ -f "$msg_file" ]] || continue
                all_msgs+=("$msg_file")
            done
        done
        if [[ ${#all_msgs[@]} -gt 0 ]]; then
            local sorted_msgs
            sorted_msgs=$(for mf in "${all_msgs[@]}"; do
                echo "$(_file_mtime "$mf") $mf"
            done | sort -rn | head -"$max_msgs" | awk '{print $2}')
            while IFS= read -r mf; do
                [[ -n "$mf" ]] || continue
                local from to content ts
                from=$(jq -r '.from // ""' "$mf" 2>/dev/null)
                to=$(jq -r '.to // ""' "$mf" 2>/dev/null)
                content=$(jq -r '.content // "" | if length > 200 then .[:200] + "..." else . end' "$mf" 2>/dev/null)
                ts=$(jq -r '.timestamp // ""' "$mf" 2>/dev/null)
                echo "- [$ts] $from → $to: $content"
                ((msg_count++)) || true
            done <<< "$sorted_msgs"
        fi
        [[ $msg_count -eq 0 ]] && echo "（无）"
        echo ""

        # 最后提交变更
        echo "## 最后提交变更"
        if git -C "$project_dir" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
            local last_stat
            last_stat=$(git -C "$project_dir" log "$branch" -1 --stat --oneline 2>/dev/null)
            if [[ -n "$last_stat" ]]; then
                echo '```'
                echo "$last_stat"
                echo '```'
            else
                echo "（无提交）"
            fi
        else
            echo "（分支不存在）"
        fi

    } > "$output_file"
}

# 为所有实例生成恢复摘要
# 参数:
#   $1 - state.json 路径
save_all_resume_summaries() {
    local state_file="${1:-$STATE_FILE}"
    [[ -f "$state_file" ]] || return 0

    local project_dir
    project_dir=$(jq -r '.project // ""' "$state_file" 2>/dev/null)
    [[ -n "$project_dir" && -d "$project_dir" ]] || return 0

    mkdir -p "${RESUME_SUMMARY_DIR:-$RUNTIME_DIR/resume}"

    while IFS='|' read -r inst branch; do
        [[ -n "$inst" ]] || continue
        # 兜底：state.json 无 branch 字段（旧版本）
        [[ -n "$branch" && "$branch" != "null" ]] || branch="swarm/$inst"
        generate_instance_resume_summary \
            "$inst" "$branch" "$project_dir" \
            "${RESUME_SUMMARY_DIR:-$RUNTIME_DIR/resume}/${inst}.md"
    done < <(jq -r '.panes[] | "\(.instance // .role)|\(.branch // "")"' "$state_file" 2>/dev/null)
}

# 构建恢复初始化消息（在标准 init 消息基础上附加恢复上下文）
# 参数:
#   $1 - 配置文件路径
#   $2 - 角色分支名
#   $3 - 团队成员信息
#   $4 - 恢复摘要文件路径（可选，不存在则降级为标准消息）
build_resume_init_message() {
    local config_file="$1"
    local role_branch="$2"
    local team_info="$3"
    local resume_file="${4:-}"

    # 获取基础 init 消息
    local base_msg
    base_msg=$(build_init_message "$config_file" "$role_branch" "$team_info")

    # 如果没有恢复摘要文件，降级为标准 init 消息
    if [[ -z "$resume_file" || ! -f "$resume_file" ]]; then
        echo "$base_msg"
        return 0
    fi

    # 附加恢复上下文
    local resume_content
    resume_content=$(cat "$resume_file")

    cat <<RESUME_EOF
$base_msg

## 恢复上下文（重要）
这是一次会话恢复。你之前的工作上下文如下：

$resume_content

### 恢复行动指南
1. 先检查你的分支状态: git status && git log --oneline -5
2. 查看是否有未完成的任务: swarm-msg.sh list-tasks
3. 如果有上次未完成的工作，继续完成
4. 如果所有工作已完成，认领新任务或等待 supervisor 分配
5. 恢复后立即向 supervisor 报告你的状态
RESUME_EOF
}

# =============================================================================
# Pane → CLI 类型解析
# =============================================================================
# 从 state.json 中根据 pane target 查找对应 CLI 类型
# 参数: $1 - pane target (如 0.1)
# 输出: cli 命令字符串 (如 "claude chat", "codex chat", "gemini ...")，未知返回 "unknown"
_resolve_cli_from_pane() {
    local pane_target="$1"
    if [[ -f "$STATE_FILE" ]]; then
        jq -r --arg pane "$pane_target" \
            '[.panes[] | select(.pane == $pane) | .cli // "unknown"] | first // "unknown"' \
            "$STATE_FILE" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# 判断 CLI 类型字符串是否为 Codex CLI
# 参数: $1 - CLI 命令字符串 (如 "codex chat", "claude chat")
# 返回: 0 (是 Codex) / 1 (不是)
_is_codex_cli() {
    [[ "${1:-}" == *codex* ]]
}

# 向 pane 发送 shell 命令并提交（Codex 兼容）
# CLI 启动阶段 state.json 尚未写入，不能用 _resolve_cli_from_pane，
# 必须由调用方传入 CLI 命令字符串直接判断。
# 参数:
#   $1 - pane target (如 0.1)
#   $2 - 要执行的 shell 命令
#   $3 - CLI 命令字符串 (用于判断是否 Codex)
_send_keys_enter() {
    local pane_target="$1"
    local cmd="$2"
    local cli_type="${3:-}"

    if _is_codex_cli "$cli_type"; then
        # Codex CLI: Kitty keyboard protocol 导致 C-m / Enter 被静默忽略，
        # 先发送命令文本，再用 -l 发送原始 CR 字节 (0x0D)
        tmux send-keys -t "${SESSION_NAME}:${pane_target}" "$cmd"
        sleep "${CODEX_PASTE_DELAY:-0.5}"
        tmux send-keys -l -t "${SESSION_NAME}:${pane_target}" $'\r'
    else
        tmux send-keys -t "${SESSION_NAME}:${pane_target}" "$cmd" C-m
    fi
}

# =============================================================================
# Pane 级原子发送: flock 保护 paste-buffer + submit 序列
# 防止并发发送同一 pane 时消息交错（命名 buffer + 互斥锁）
# =============================================================================
# 参数:
#   $1 - pane target (如 0.1)
#   $2 - 要发送的临时文件路径
#   $3 - (可选) CLI 类型，省略时自动从 state.json 推断
#
# Codex CLI (Rust/crossterm) 启用了 Kitty Keyboard Enhancement Protocol，
# tmux 对此支持有限 (tmux/tmux#4196)，导致 `send-keys Enter` 被静默忽略。
# 解决方案: 对 Codex 使用 `send-keys -l` 发送原始 CR 字节 (\r / 0x0D)。
# 参考: openai/codex#12645
_pane_locked_paste_enter() {
    local pane_target="$1"
    local content_file="$2"
    local cli_type="${3:-}"
    local buf_name="pane-$$-$RANDOM"

    # 自动推断 CLI 类型
    if [[ -z "$cli_type" ]]; then
        cli_type=$(_resolve_cli_from_pane "$pane_target")
    fi

    # 锁文件按 pane 目标命名（. 替换为 - 避免路径问题）
    local lock_file="${RUNTIME_DIR}/.pane-send-lock-${pane_target//./-}"

    (
        exec 9>"$lock_file"
        flock -x 9
        # 真 flock: 子 shell 退出时 fd 关闭自动释放锁
        # macOS mkdir polyfill: 加锁时已自动注册 EXIT trap 清理，无需额外处理

        tmux load-buffer -b "$buf_name" "$content_file"
        tmux paste-buffer -b "$buf_name" -t "${SESSION_NAME}:${pane_target}" -d

        if _is_codex_cli "$cli_type"; then
            # Codex CLI: Kitty keyboard protocol 导致 Enter 关键字失效，
            # 必须用 -l 发送原始 CR 字节 (0x0D)
            sleep "${CODEX_PASTE_DELAY:-0.5}"
            tmux send-keys -l -t "${SESSION_NAME}:${pane_target}" $'\r'
        else
            sleep "${PASTE_DELAY:-0.3}"
            tmux send-keys -t "${SESSION_NAME}:${pane_target}" Enter
        fi
    )
}

# 通过 tmux paste-buffer 发送初始化消息到 pane
# 参数: $1 - pane target, $2 - 初始化消息, $3 - (可选) CLI 类型
send_init_to_pane() {
    local pane_target="$1"
    local init_msg="$2"
    local cli_type="${3:-}"

    local init_tmp
    init_tmp=$(mktemp "${RUNTIME_DIR}/.init-XXXXXX")
    printf '%s' "$init_msg" > "$init_tmp"
    _pane_locked_paste_enter "$pane_target" "$init_tmp" "$cli_type"
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
    local exclude="${4:-}"
    local state_file="${STATE_FILE:-$RUNTIME_DIR/state.json}"

    while IFS='|' read -r inst_name inst_pane inst_cli; do
        [[ -z "$inst_name" ]] && continue
        [[ "$inst_name" == "$exclude" ]] && continue

        # 通道 1: 写入收件箱（可靠持久）
        local notify_id
        notify_id="sys-${category}-$(date +%s)-${RANDOM}"
        mkdir -p "${MESSAGES_DIR}/inbox/${inst_name}"
        jq -n \
            --arg id "$notify_id" \
            --arg from "system" \
            --arg to "$inst_name" \
            --arg content "$inbox_content" \
            --arg timestamp "$(get_timestamp)" \
            --arg status "pending" \
            --arg priority "high" \
            '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:$status, reply_to:null, priority:$priority}' \
            > "${MESSAGES_DIR}/inbox/${inst_name}/${notify_id}.json"

        # 通道 2: paste-buffer 尽力即时推送（原子发送）
        local notify_tmp
        notify_tmp=$(mktemp "${RUNTIME_DIR}/.notify-XXXXXX")
        printf '%s' "$pane_content" > "$notify_tmp"
        _pane_locked_paste_enter "$inst_pane" "$notify_tmp" "$inst_cli" 2>/dev/null || true
        rm -f "$notify_tmp"

    done < <(jq -r '.panes[] | "\(.instance)|\(.pane)|\(.cli // "unknown")"' "$state_file" 2>/dev/null)
}

# =============================================================================
# 统一通知系统
# =============================================================================

# 从配置读取投递规则
# 参数: $1 - 通知类别 (如 "task.published")
# 返回: "dual" 或 "inbox_only"
_get_delivery_rule() {
    local category="$1"
    local policy_file="${SWARM_ROOT}/config/notification-policy.json"
    if [[ -f "$policy_file" ]]; then
        local rule
        rule=$(jq -r --arg cat "$category" '.delivery_rules[$cat] // .delivery_rules["default"] // "dual"' "$policy_file" 2>/dev/null)
        case "${rule:-dual}" in
            dual|inbox_only) echo "$rule" ;;
            *) log_warn "[_get_delivery_rule] 未知规则: $rule (类别: $category)，回退到 dual"; echo "dual" ;;
        esac
    else
        echo "dual"
    fi
}

# 统一通知入口：所有脚本内部的通知都通过此函数发送
# 参数:
#   $1 - 目标实例名 (如 "supervisor", "backend", "backend-2")
#   $2 - 通知内容
#   $3 - 通知类别 (如 "task.published", "task.claimed", "gate.failed")
#   $4 - 优先级 (low/normal/high，默认 normal)
_unified_notify() {
    local to="$1" content="$2" category="${3:-default}" priority="${4:-normal}"

    # 守卫：过滤无效目标
    if [[ -z "$to" || "$to" == "null" ]]; then
        log_warn "[_unified_notify] 无效目标: to='$to' category=$category，跳过"
        return 0
    fi

    # 解析目标 pane
    local target_pane
    target_pane=$(_resolve_pane_by_id "$to")

    # 通道 1: 始终写 inbox（持久、可追踪）
    local notify_id="notify-${category//\./-}-$(date +%s)-$$-${RANDOM}"
    local my_instance="${SWARM_INSTANCE:-${SWARM_ROLE:-system}}"
    mkdir -p "${MESSAGES_DIR}/inbox/${to}"
    if ! jq -n \
        --arg id "$notify_id" \
        --arg from "$my_instance" \
        --arg to "$to" \
        --arg content "$content" \
        --arg timestamp "$(get_timestamp)" \
        --arg priority "$priority" \
        --arg category "$category" \
        '{id:$id, from:$from, to:$to, content:$content, timestamp:$timestamp, status:"pending", reply_to:null, priority:$priority, category:$category}' \
        > "${MESSAGES_DIR}/inbox/${to}/${notify_id}.json" 2>/dev/null; then
        log_warn "[_unified_notify] inbox 写入失败: to=$to category=$category"
    fi

    # 通道 2: 根据投递策略决定是否 push 到 pane
    if [[ -n "$target_pane" && "$target_pane" != "null" ]]; then
        local delivery
        delivery=$(_get_delivery_rule "$category")
        if [[ "$delivery" == "dual" ]]; then
            if command -v push_to_pane &>/dev/null; then
                push_to_pane "$target_pane" "$content" 2>/dev/null || true
            else
                log_warn "[_unified_notify] push_to_pane 未定义，跳过 paste-buffer 推送 (to=$to)"
            fi
        fi
    fi
}

# 批量通知：向多个目标发送相同通知
# 参数:
#   $1 - 通知内容
#   $2 - 通知类别
#   $3 - 优先级
#   stdin - 目标列表 (每行一个 instance 名，或 "instance|pane" 格式，pane 字段被忽略)
_unified_notify_multi() {
    local content="$1" category="${2:-default}" priority="${3:-normal}"
    local to _unused
    while IFS='|' read -r to _unused; do
        [[ -z "$to" ]] && continue
        _unified_notify "$to" "$content" "$category" "$priority"
    done
}

# 通知所有 supervisor 实例
# 参数: $1=content, $2=category(默认default), $3=priority(默认normal)
_notify_all_supervisors() {
    local content="$1" category="${2:-default}" priority="${3:-normal}"
    resolve_role_to_all_panes "supervisor" | _unified_notify_multi "$content" "$category" "$priority"
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
    tmp_file=$(mktemp "${RUNTIME_DIR}/.state-update-XXXXXX")

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
        ( sleep "$duration" 2>/dev/null && kill "$cmd_pid" 2>/dev/null ) &
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
# macOS 兼容: flock polyfill
# =============================================================================

if ! command -v flock &>/dev/null; then
    # macOS 不自带 flock（属于 util-linux）。
    # 使用 mkdir 原子操作实现自旋锁，零调用点修改。

    # 通过 fd 的 inode 构造唯一锁目录路径
    _swarm_flock_dir() {
        local fd="$1"
        local inode
        inode=$(stat -f '%d_%i' /dev/fd/"$fd" 2>/dev/null) || return 1
        echo "/tmp/.swarm-flock-${inode}"
    }

    # 检查锁目录持有者是否仍存活（死锁检测）
    _swarm_flock_stale_check() {
        local lock_dir="$1"
        local pid_file="$lock_dir/pid"
        [[ -f "$pid_file" ]] || return 0  # 无 pid 文件视为 stale
        local holder_pid
        holder_pid=$(cat "$pid_file" 2>/dev/null) || return 0
        # kill -0 检查进程是否存活
        kill -0 "$holder_pid" 2>/dev/null && return 1  # 存活，非 stale
        return 0  # 进程已死，stale
    }

    flock() {
        local mode="" fd=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -x|-s|-u) mode="$1"; shift ;;
                *)        fd="$1"; shift ;;
            esac
        done

        [[ -n "$fd" ]] || return 0

        local lock_dir
        lock_dir=$(_swarm_flock_dir "$fd") || {
            # stat 失败（fd 无效等），降级为 no-op（安全兜底）
            return 0
        }

        if [[ "$mode" == "-u" ]]; then
            # 解锁: 移除 pid 文件再 rmdir
            rm -f "$lock_dir/pid" 2>/dev/null
            rmdir "$lock_dir" 2>/dev/null
            return 0
        fi

        # 加锁: mkdir 自旋
        local attempt=0
        while ! mkdir "$lock_dir" 2>/dev/null; do
            ((attempt++))
            # 每 20 次（约 1s）检查死锁
            if (( attempt % 20 == 0 )); then
                if _swarm_flock_stale_check "$lock_dir"; then
                    rm -f "$lock_dir/pid" 2>/dev/null
                    rmdir "$lock_dir" 2>/dev/null
                    continue
                fi
            fi
            # 200 次（约 10s）超时强制清除
            if (( attempt >= 200 )); then
                rm -f "$lock_dir/pid" 2>/dev/null
                rmdir "$lock_dir" 2>/dev/null || { [[ "$lock_dir" == /tmp/.swarm-flock-* ]] && rm -rf "$lock_dir" 2>/dev/null; }
                continue
            fi
            sleep 0.05
        done

        # 写入持锁进程 PID（$BASHPID 为 subshell 实际 PID，$$ 为父进程 PID）
        echo "${BASHPID:-$$}" > "$lock_dir/pid" 2>/dev/null

        # subshell 退出自动释放（链式保留调用者已有的 EXIT trap）
        local _prev_exit_trap
        _prev_exit_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
        trap "rm -f '$lock_dir/pid' 2>/dev/null; rmdir '$lock_dir' 2>/dev/null; ${_prev_exit_trap:-:}" EXIT

        return 0
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
    # 事件日志使用固定 ISO 8601 格式，不受 LOG_TIMESTAMP_FORMAT 影响
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
# 日志轮转
# =============================================================================

# 通用文件轮转（按天命名: .log → .log.2026-02-28_HHmmss）
# copy-truncate 模式: 先复制再清空原文件，无需中断写入方
# 过期清理由看门狗的 LOG_RETENTION_TTL 统一负责
# 参数:
#   $1 - 文件路径
_rotate_file() {
    local file="$1"
    local date_suffix
    date_suffix=$(date "+%Y-%m-%d_%H%M%S")
    local target="${file}.${date_suffix}"

    if [[ -f "$file" ]]; then
        cp "$file" "$target"
        : > "$file"  # truncate，写入方（pipe-pane/flock）无需中断
    fi
}

# 生成带时间戳的 pipe-pane 命令
# macOS/Linux 均自带 perl，用 perl 为每行添加时间戳前缀
# 参数:
#   $1 - 日志文件路径
# 输出: 可传给 tmux pipe-pane -o 的命令字符串
_pipe_pane_cmd() {
    local log_file="$1"
    local ts_fmt="$LOG_TIMESTAMP_FORMAT"
    # 校验格式串：只允许 strftime 安全字符，防止注入 perl 代码
    if [[ "$ts_fmt" =~ [^%A-Za-z0-9\ :/_-] ]]; then
        log_warn "_pipe_pane_cmd: LOG_TIMESTAMP_FORMAT 含非法字符，回退到默认格式"
        ts_fmt="%Y-%m-%d %H:%M:%S"
    fi
    # perl one-liner: 为每行添加 [timestamp] 前缀，flushed 输出
    echo "perl -MPOSIX -ne '\$|=1; print \"[\".strftime(\"${ts_fmt}\",localtime).\"] \".\$_' >> '${log_file}'"
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
        while IFS='|' read -r r_instance r_role r_alias r_branch; do
            team_info+="- $r_instance"
            [[ -n "$r_role" && "$r_role" != "$r_instance" ]] && team_info+=" (角色: $r_role)"
            [[ -n "$r_alias" && "$r_alias" != "" ]] && team_info+=" ($r_alias)"
            [[ -n "$r_branch" && "$r_branch" != "" ]] && team_info+=" [branch: $r_branch]"
            team_info+=$'\n'
        done < <(jq -r '.panes[] | "\(.instance)|\(.role)|\(.alias // "")|\(.branch // "")"' "$state_file" 2>/dev/null)
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

任务组示例（带依赖 + 指派）:
  G=\$(swarm-msg.sh create-group "用户注册系统")
  T1=\$(swarm-msg.sh publish develop "实现 API" -g \$G --assign backend)
  T2=\$(swarm-msg.sh publish develop "设计数据库" -g \$G --assign database)
  T3=\$(swarm-msg.sh publish review "审核代码" -g \$G --assign reviewer --depends \$T1,\$T2)

### 行为准则
1. 当任务涉及其他角色的职责时，主动用 swarm-msg.sh send 联系对方
2. 批量任务用 create-group 创建组，用 --depends 设置依赖顺序
3. 开发完成后，代码会自动 commit 到你的分支，然后用 publish 发布审核任务
4. 审核角色从队列 claim 任务，用 git diff 审核分支代码
5. 任务完成后用 complete-task 反馈，依赖此任务的阻塞任务会自动解锁
6. 任务组全部完成时，发布者会自动收到通知

### 任务完成检测机制（重要）
系统通过两个渠道判断你的任务是否完成：
1. **主渠道**: 你调用 swarm-msg.sh complete-task 主动报告完成
2. **自动检测**: 系统监控你的 CLI 提示符——当 CLI 显示输入提示符且持续无新输出时，系统自动判定任务完成，并触发代码自动 commit + 通知 supervisor

注意事项：
- 避免在代码或输出中打印与 CLI 提示符相似的字符（如 ❯、›、单独的 > 行），以免系统误判任务完成
- 如果 CLI 卡住（长时间无响应也无提示符），执行 swarm-msg.sh fail-task 通知 supervisor
- 每次任务完成后，推荐使用 complete-task 明确报告，而非仅依赖自动检测
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
        # 注: macOS awk 不支持 -v 传入多行字符串（报 newline in string），
        # 改为先写入临时文件，awk 用 getline 从文件读取并插入
        local tmp content_tmp
        tmp=$(mktemp "${RUNTIME_DIR}/.ctx-XXXXXX")
        content_tmp=$(mktemp "${RUNTIME_DIR}/.ctx-inject-XXXXXX")
        printf '%s\n' "$content" > "$content_tmp"
        awk -v start="$SWARM_CONTEXT_START" -v end="$SWARM_CONTEXT_END" -v cfile="$content_tmp" '
            $0 == start { skip=1; while((getline line < cfile) > 0) print line; close(cfile); next }
            $0 == end   { skip=0; next }
            !skip       { print }
        ' "$file" > "$tmp"
        rm -f "$content_tmp"
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
                tmp=$(mktemp "${RUNTIME_DIR:-.}/.ctx-clean-XXXXXX")
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
    local instance="$1" worktree="$2"
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
    git -C "$worktree" commit -m "swarm($instance): 任务完成自动提交 ($file_count 个文件变更)" 2>/dev/null || return 0

    emit_event "git.auto_commit" "$instance" "worktree=$worktree" "files=$file_count"
}

# =============================================================================
# CLI 提示符检测
# =============================================================================

# CLI 提示符模式（Claude: ❯  Gemini: >  Codex: ›）
PROMPT_PATTERNS="${PROMPT_PATTERNS:-❯|›|^[[:space:]]*>[[:space:]]*$|Type your message|context left}"

# 静默阈值（秒）- 多久没输出算完成（由 config/defaults.conf 统一定义）

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
# 任务完成自动通知 supervisor
# =============================================================================

# 当角色完成任务时，自动通知所有 supervisor 实例可分配新任务
# 双通道: inbox（可靠持久）+ paste-buffer（即时推送）
_notify_supervisor_completion() {
    local instance="$1"

    # 所有 supervisor 实例自身不需要通知
    local state_file="${STATE_FILE:-$RUNTIME_DIR/state.json}"
    local my_role
    my_role=$(jq -r --arg inst "$instance" '.panes[] | select(.instance == $inst) | .role // ""' "$state_file" 2>/dev/null | head -1)
    [[ "$my_role" == "supervisor" ]] && return 0

    # 通知所有 supervisor 实例（双通道: inbox + paste-buffer）
    local messages_dir="${RUNTIME_DIR}/messages"
    while IFS='|' read -r sup_pane sup_inst sup_cli; do
        [[ -z "$sup_inst" ]] && continue
        # 通道 1: inbox（可靠持久）
        local notify_id="completion-${instance}-$(date +%s)-${RANDOM}"
        mkdir -p "${messages_dir}/inbox/${sup_inst}"
        jq -n \
            --arg id "$notify_id" --arg from "system" --arg to "$sup_inst" \
            --arg content "[任务完成] 实例 ${instance} 已完成当前任务，可分配新工作。" \
            --arg timestamp "$(get_timestamp)" --arg status "pending" --arg priority "normal" \
            '{id:$id,from:$from,to:$to,content:$content,timestamp:$timestamp,status:$status,reply_to:null,priority:$priority}' \
            > "${messages_dir}/inbox/${sup_inst}/${notify_id}.json"
        # 通道 2: paste-buffer 即时推送
        local notify_tmp
        notify_tmp=$(mktemp "${RUNTIME_DIR}/.watcher-notify-XXXXXX")
        printf '%s' "[系统通知] 实例 ${instance} 已完成任务，可分配新工作。" > "$notify_tmp"
        _pane_locked_paste_enter "$sup_pane" "$notify_tmp" "$sup_cli" 2>/dev/null || true
        rm -f "$notify_tmp"
    done < <(resolve_role_to_all_panes "supervisor")
}

# 通知 inspector 某角色已停滞
_notify_inspector_stall() {
    local instance="$1" elapsed="$2"
    local msg="[STALL] 实例 $instance 已停滞 ${elapsed}s 无输出，请检查"
    _unified_notify "inspector" "$msg" "stall.detected"
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
    local instance="$1" log_file="$2" pane="$3" worktree="${4:-}"

    (
        local state="init"
        local active_since=0

        # 等待日志文件出现
        while [[ ! -f "$log_file" ]]; do sleep 0.5; done

        # tail -f 事件驱动: macOS=kqueue, Linux=inotify，零 CPU 开销
        exec 3< <(tail -f "$log_file" 2>/dev/null)

        while true; do
            if IFS= read -t "$SILENCE_THRESHOLD" -r _line <&3; then
                # 有新输出
                if [[ "$state" == "idle" ]]; then
                    state="active"
                    active_since=$(date +%s)
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
                            auto_commit_worktree "$instance" "$worktree"
                            emit_event "task.completed" "$instance" "pane=$pane" "detected_by=watcher"
                            # 自动通知 supervisor 可分配新任务
                            _notify_supervisor_completion "$instance"
                            state="idle"
                            active_since=0
                        else
                            # stall 检测：active 状态下持续无输出且未完成
                            # active_since == 0 的防御：init → 静默超时的边界情况
                            if [[ "$active_since" -eq 0 ]]; then
                                active_since=$(date +%s)
                            else
                                local now elapsed
                                now=$(date +%s)
                                elapsed=$((now - active_since))
                                if [[ "$elapsed" -ge "${STALL_THRESHOLD:-1800}" ]]; then
                                    emit_event "task.stalled" "$instance" "pane=$pane" "elapsed=${elapsed}s"
                                    _notify_inspector_stall "$instance" "$elapsed"
                                    active_since=$now  # 重置，避免重复通知
                                fi
                            fi
                        fi
                        ;;
                    # idle 状态下忽略静默超时
                esac
            fi
        done
    ) >/dev/null &
    echo $!
}

# ===========================================================================
# 加载扩展模块（放在文件末尾，确保上面所有共享函数已定义）
# ===========================================================================

# CLI 权限适配器（build_cli_command）
if [[ -f "${SCRIPTS_DIR}/lib/cli-permissions.sh" ]]; then
    # shellcheck source=lib/cli-permissions.sh
    source "${SCRIPTS_DIR}/lib/cli-permissions.sh"
fi

# CLI 启动器（launch_cli_in_pane, resolve_role_permissions, infer_category_from_config）
if [[ -f "${SCRIPTS_DIR}/lib/cli-launcher.sh" ]]; then
    # shellcheck source=lib/cli-launcher.sh
    source "${SCRIPTS_DIR}/lib/cli-launcher.sh"
fi
