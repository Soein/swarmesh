#!/usr/bin/env bash
################################################################################
# discuss-relay.sh — tmux-swarm discuss 模式核心
#
# 负责圆桌讨论：多个 CLI（Codex / Claude / Gemini）在一个 tmux session 里互相
# 交流，用户通过 @点名 触发被点名者接话。不走 supervisor 编排。
#
# 子命令：
#   start   --project <dir> --cli <cmd> [--name <n>] [--hidden]
#   add     --name <n> --cli <cmd>
#   post    --from <who> --content <text>
#   tail    [--last N]
#   list
#   promote --profile <p>
#   stop    [--clean]
################################################################################

set -uo pipefail

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${SCRIPTS_DIR:=$(cd "$SCRIPT_DIR/.." && pwd)}"

# 允许测试跳过 swarm-lib（只验证数据层）
if [[ -z "${DISCUSS_RELAY_SKIP_LIB:-}" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPTS_DIR/swarm-lib.sh"
fi

# ---- 可配置 --------------------------------------------------------------
DISCUSS_SESSION_NAME="${DISCUSS_SESSION_NAME:-swarm-discuss}"
DISCUSS_MAX_TURNS="${SWARM_DISCUSS_MAX_TURNS:-20}"
DISCUSS_CONTEXT_TURNS="${SWARM_DISCUSS_CONTEXT_TURNS:-10}"
DISCUSS_STARTUP_WAIT="${SWARM_DISCUSS_STARTUP_WAIT:-3}"
# -------------------------------------------------------------------------

die()  { echo "[discuss-relay] ERROR: $*" >&2; exit 1; }
info() { echo "[discuss-relay] $*"; }

# 确保 PROJECT_DIR 和 runtime 路径已初始化（由 swarm-lib 定义的默认值）
_ensure_runtime() {
    [[ -n "${PROJECT_DIR:-}" ]] || die "PROJECT_DIR 未设置"
    RUNTIME_DIR="${PROJECT_DIR}/.swarm/runtime"
    STATE_FILE="${RUNTIME_DIR}/state.json"
    DISCUSS_DIR="${RUNTIME_DIR}/discuss"
    DISCUSS_LOG="${DISCUSS_DIR}/session.jsonl"
    mkdir -p "$DISCUSS_DIR"
}

# 以 mktemp 落盘，再 paste-buffer 到目标 pane
_paste_to_pane() {
    local pane_target="$1" content="$2" cli_type="${3:-}"
    local tmpf; tmpf=$(mktemp "${RUNTIME_DIR}/.discuss-paste-XXXXXX")
    printf '%s' "$content" > "$tmpf"
    SESSION_NAME="$DISCUSS_SESSION_NAME" _pane_locked_paste_enter "$pane_target" "$tmpf" "$cli_type"
    rm -f "$tmpf"
}

# 从 CLI 命令中推断类型（codex / claude / gemini / unknown）
_infer_cli_type() {
    local cmd="$1"
    case "${cmd%% *}" in
        codex*)  echo codex ;;
        claude*) echo claude ;;
        gemini*) echo gemini ;;
        *)       echo unknown ;;
    esac
}

# ---- start ---------------------------------------------------------------
cmd_start() {
    local project="" cli="" name="" hidden=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) project="$2"; shift 2 ;;
            --cli)     cli="$2";     shift 2 ;;
            --name)    name="$2";    shift 2 ;;
            --hidden)  hidden=true;  shift   ;;
            *) die "start: 未知参数 $1" ;;
        esac
    done
    [[ -n "$project" ]] || die "--project 必需"
    [[ -n "$cli"     ]] || die "--cli 必需"
    [[ -n "$name"    ]] || name="${cli%% *}"

    export PROJECT_DIR="$(cd "$project" && pwd)"
    _ensure_runtime

    if tmux has-session -t "$DISCUSS_SESSION_NAME" 2>/dev/null; then
        die "discuss session 已存在 ($DISCUSS_SESSION_NAME)，请先 /swarm-stop"
    fi

    info "启动 discuss session: $DISCUSS_SESSION_NAME"
    tmux new-session -d -s "$DISCUSS_SESSION_NAME" -n "roundtable" -c "$PROJECT_DIR"
    local pane_target="0.0"
    tmux send-keys -t "${DISCUSS_SESSION_NAME}:${pane_target}" "$cli" Enter

    sleep "$DISCUSS_STARTUP_WAIT"

    # 初始化 discuss jsonl
    : > "$DISCUSS_LOG"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s\n' "$(jq -nc \
        --arg ts "$ts" \
        --arg name "$name" \
        '{turn: 0, ts: $ts, type: "session_start", participants: [$name]}')" >> "$DISCUSS_LOG"

    # 写 state.json
    local state; state=$(jq -n \
        --arg session "$DISCUSS_SESSION_NAME" \
        --arg project "$PROJECT_DIR" \
        --arg ts "$ts" \
        --argjson participants "$(jq -n --arg n "$name" --arg c "$cli" --arg t "$(_infer_cli_type "$cli")" --arg p "$pane_target" \
            '[{name:$n, cli:$c, cli_type:$t, pane:$p}]')" \
        '{
            schema_version: 1,
            mode: "discuss",
            session: $session,
            project: $project,
            started_at: $ts,
            discuss: {
                max_turns: 20,
                turn_count: 0,
                participants: $participants
            }
        }')
    echo "$state" | jq '.' > "$STATE_FILE"

    info "✅ discuss session 就绪"
    info "   - 参与者: $name ($cli)"
    info "   - pane: ${DISCUSS_SESSION_NAME}:${pane_target}"
    info "   - jsonl: $DISCUSS_LOG"
    info "   - 下一步: /swarm-chat-add 加人, /swarm-chat-msg @$name <内容> 对话"

    _maybe_start_watcher

    if [[ "$hidden" != "true" ]]; then
        info "(使用 --hidden 可跳过 attach 提示)"
    fi
}

# 如果启用自动 watcher，后台拉起 discuss-watcher.sh
_maybe_start_watcher() {
    if [[ "${SWARM_DISCUSS_AUTO_WATCH:-1}" == "0" ]]; then
        info "   - watcher: 禁用（SWARM_DISCUSS_AUTO_WATCH=0）"
        return 0
    fi

    local watcher="$SCRIPTS_DIR/lib/discuss-watcher.sh"
    [[ -x "$watcher" ]] || { info "   - watcher: 脚本缺失，跳过"; return 0; }

    local pid_file="$DISCUSS_DIR/watcher.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        info "   - watcher: 已在跑 (pid $(cat "$pid_file"))"
        return 0
    fi

    PROJECT_DIR="$PROJECT_DIR" nohup "$watcher" start >"$DISCUSS_DIR/watcher.log" 2>&1 &
    sleep 1
    if [[ -f "$pid_file" ]]; then
        info "   - watcher: 已启动 (pid $(cat "$pid_file"), 日志 $DISCUSS_DIR/watcher.log)"
    else
        info "   - watcher: 启动失败，查看 $DISCUSS_DIR/watcher.log"
    fi
}

# ---- add -----------------------------------------------------------------
cmd_add() {
    local name="" cli=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --cli)  cli="$2";  shift 2 ;;
            *) die "add: 未知参数 $1" ;;
        esac
    done
    [[ -n "$name" ]] || die "--name 必需"
    [[ -n "$cli"  ]] || die "--cli 必需"

    _locate_state_from_cwd
    _ensure_runtime

    tmux has-session -t "$DISCUSS_SESSION_NAME" 2>/dev/null \
        || die "discuss session 不存在，先 /swarm-chat <cli>"

    # 检查重名
    jq -e --arg n "$name" '.discuss.participants[] | select(.name==$n)' "$STATE_FILE" >/dev/null 2>&1 \
        && die "参与者 '$name' 已存在"

    # split-window 新 pane
    tmux split-window -t "${DISCUSS_SESSION_NAME}:0" -c "$PROJECT_DIR"
    tmux select-layout -t "${DISCUSS_SESSION_NAME}:0" tiled >/dev/null 2>&1 || true
    # 最新 pane 坐标
    local pane_target
    pane_target=$(tmux list-panes -t "${DISCUSS_SESSION_NAME}:0" -F '#{window_index}.#{pane_index}' | tail -1)

    tmux send-keys -t "${DISCUSS_SESSION_NAME}:${pane_target}" "$cli" Enter
    sleep "$DISCUSS_STARTUP_WAIT"

    local cli_type; cli_type=$(_infer_cli_type "$cli")
    local tmp; tmp=$(mktemp)
    jq --arg n "$name" --arg c "$cli" --arg t "$cli_type" --arg p "$pane_target" \
        '.discuss.participants += [{name:$n, cli:$c, cli_type:$t, pane:$p}]' \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"

    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s\n' "$(jq -nc \
        --arg ts "$ts" --arg n "$name" --arg c "$cli" \
        '{turn: 0, ts: $ts, type: "participant_join", name: $n, cli: $c}')" >> "$DISCUSS_LOG"

    info "✅ 加入 $name ($cli) @ pane $pane_target"

    # 新参与者加入后，确保 watcher 在跑（可能 start 时没启动）
    _maybe_start_watcher
}

# ---- post ----------------------------------------------------------------
cmd_post() {
    local from="" content=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)    from="$2";    shift 2 ;;
            --content) content="$2"; shift 2 ;;
            *) die "post: 未知参数 $1" ;;
        esac
    done
    [[ -n "$from"    ]] || die "--from 必需"
    [[ -n "$content" ]] || die "--content 必需"

    _locate_state_from_cwd
    _ensure_runtime

    local turn; turn=$(jq -r '.discuss.turn_count // 0' "$STATE_FILE")
    turn=$((turn + 1))
    local max; max=$(jq -r '.discuss.max_turns // 20' "$STATE_FILE")
    if (( turn > max )); then
        die "达到最大轮次 $max，暂停等待。提高上限: SWARM_DISCUSS_MAX_TURNS 或 /swarm-promote"
    fi

    # 提取 @mentions（去重，保留顺序）
    local mentions; mentions=$(grep -oE '@[A-Za-z0-9_-]+' <<<"$content" | sed 's/^@//' | awk '!seen[$0]++')

    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local mentions_json
    if [[ -n "$mentions" ]]; then
        mentions_json=$(printf '%s\n' $mentions | jq -R . | jq -s .)
    else
        mentions_json='[]'
    fi

    printf '%s\n' "$(jq -nc \
        --argjson turn "$turn" \
        --arg ts "$ts" \
        --arg from "$from" \
        --argjson mentions "$mentions_json" \
        --arg content "$content" \
        '{turn:$turn, ts:$ts, type:"message", from:$from, mentions:$mentions, content:$content}')" >> "$DISCUSS_LOG"

    local tmp; tmp=$(mktemp)
    jq --argjson t "$turn" '.discuss.turn_count = $t' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"

    if [[ -z "$mentions" ]]; then
        info "📝 turn $turn 已记录（无 @点名，未触发接话）"
        return 0
    fi

    # 对每个被点名者推送上下文
    local participant_name pane cli_type
    for m in $mentions; do
        # 防回环：@ 自己不触发
        if [[ "$m" == "$from" ]]; then
            info "⏭  @$m 是发送者自身，跳过（防回环）"
            continue
        fi
        participant_name=$(jq -r --arg n "$m" '.discuss.participants[] | select(.name==$n) | .name' "$STATE_FILE")
        if [[ -z "$participant_name" ]]; then
            info "⚠️  @$m 不在参与者列表，跳过"
            continue
        fi
        pane=$(jq -r --arg n "$m" '.discuss.participants[] | select(.name==$n) | .pane' "$STATE_FILE")
        cli_type=$(jq -r --arg n "$m" '.discuss.participants[] | select(.name==$n) | .cli_type' "$STATE_FILE")
        local ctx; ctx=$(_build_context_for "$m" "$content" "$from")
        _paste_to_pane "$pane" "$ctx" "$cli_type"
        info "➡️  turn $turn → @$m (pane $pane)"
    done
}

# 组装喂给某参与者的上下文（最近 N 轮 + 当前消息）
_build_context_for() {
    local target="$1" current_content="$2" from="$3"
    local header
    header=$(printf '【圆桌讨论 · 被 @ %s】\n主持：你和其他 AI 正在同一会话里讨论。以下是最近对话历史（每行 "turn/from: content"），最后一段是 @你 的消息，请正面回应、可继续 @ 其他人。' "${target}")
    local history
    history=$(tail -n "$((DISCUSS_CONTEXT_TURNS * 2))" "$DISCUSS_LOG" \
        | jq -r 'select(.type=="message") | "[turn \(.turn)] \(.from): \(.content)"' \
        | tail -n "$DISCUSS_CONTEXT_TURNS")
    printf '%b\n---历史---\n%s\n---当前---\n%s: %s\n' "$header" "$history" "$from" "$current_content"
}

# ---- tail ----------------------------------------------------------------
cmd_tail() {
    local n=50
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --last) n="$2"; shift 2 ;;
            *) die "tail: 未知参数 $1" ;;
        esac
    done
    _locate_state_from_cwd
    _ensure_runtime
    [[ -f "$DISCUSS_LOG" ]] || { echo "(尚无对话)"; return 0; }
    tail -n "$n" "$DISCUSS_LOG" | jq -r '
        if .type=="session_start" then "━━ 会话启动 @ \(.ts) 参与者: \(.participants|join(","))"
        elif .type=="participant_join" then "➕ \(.name) 加入 (\(.cli))"
        elif .type=="message" then "[turn \(.turn) · \(.from) → \(.mentions|join(",")|if .=="" then "(无点名)" else . end)] \(.content)"
        else "(unknown) \(.)" end'
}

# ---- list ----------------------------------------------------------------
cmd_list() {
    _locate_state_from_cwd
    _ensure_runtime
    jq -r '.discuss.participants[]? | "- \(.name) [\(.cli_type)] pane=\(.pane) cli=\(.cli)"' "$STATE_FILE"
}

# ---- promote -------------------------------------------------------------
cmd_promote() {
    local profile="minimal"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile) profile="$2"; shift 2 ;;
            *) die "promote: 未知参数 $1" ;;
        esac
    done
    _locate_state_from_cwd
    _ensure_runtime

    local brief="${RUNTIME_DIR}/discuss/brief.md"
    {
        echo "# Discuss → Execute 转接 brief"
        echo
        echo "_discuss 会话 $(jq -r '.session' "$STATE_FILE") 的摘要（最近 ${DISCUSS_CONTEXT_TURNS} 轮）_"
        echo
        tail -n "$((DISCUSS_CONTEXT_TURNS * 4))" "$DISCUSS_LOG" \
            | jq -r 'select(.type=="message") | "## turn \(.turn) · \(.from)\n\(.content)\n"'
    } > "$brief"

    info "📄 brief 已生成: $brief"
    info "停止 discuss 并拉起 execute 模式 (profile=$profile)"

    tmux kill-session -t "$DISCUSS_SESSION_NAME" 2>/dev/null || true

    "${SCRIPTS_DIR}/swarm-start.sh" \
        --mode execute \
        --project "$PROJECT_DIR" \
        --profile "$profile" \
        --hidden

    sleep 2
    info "把 brief 作为首个任务派发给 supervisor"
    SWARM_ROLE=human "${SCRIPTS_DIR}/swarm-msg.sh" send supervisor "基于以下圆桌讨论摘要开始工作：\n\n$(cat "$brief")"
}

# ---- stop ----------------------------------------------------------------
cmd_stop() {
    local clean=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clean) clean=true; shift ;;
            *) die "stop: 未知参数 $1" ;;
        esac
    done
    _locate_state_from_cwd 2>/dev/null || true

    # 先停 watcher
    local pid_file="${RUNTIME_DIR:-}/discuss/watcher.pid"
    if [[ -n "${RUNTIME_DIR:-}" && -f "$pid_file" ]]; then
        local wpid; wpid=$(cat "$pid_file" 2>/dev/null)
        if [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then
            kill "$wpid" 2>/dev/null && info "已停 watcher (pid=$wpid)"
        fi
        rm -f "$pid_file" "${RUNTIME_DIR}/discuss/watcher.heartbeat"
    fi

    tmux kill-session -t "$DISCUSS_SESSION_NAME" 2>/dev/null && info "已停止 $DISCUSS_SESSION_NAME"
    if [[ "$clean" == "true" && -n "${RUNTIME_DIR:-}" ]]; then
        rm -rf "${RUNTIME_DIR:?}/discuss"
        info "已清理 discuss 运行时数据"
    fi
    # 防 tmux ls 等残留命令让脚本返回非零
    return 0
}

# ---- helpers -------------------------------------------------------------
# 从当前工作目录或 state.json 推断 PROJECT_DIR
_locate_state_from_cwd() {
    if [[ -z "${PROJECT_DIR:-}" ]]; then
        if [[ -f "$PWD/.swarm/runtime/state.json" ]]; then
            PROJECT_DIR="$PWD"
        else
            die "无法定位 discuss session（当前目录未找到 .swarm/runtime/state.json，请在项目目录执行或显式 --project）"
        fi
    fi
    export PROJECT_DIR
}

# ---- dispatch ------------------------------------------------------------
# 只有被直接执行时才 dispatch；被 source 时保留函数供测试用
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0 2>/dev/null || true
fi

case "${1:-}" in
    start)   shift; cmd_start   "$@" ;;
    add)     shift; cmd_add     "$@" ;;
    post)    shift; cmd_post    "$@" ;;
    tail)    shift; cmd_tail    "$@" ;;
    list)    shift; cmd_list    "$@" ;;
    promote) shift; cmd_promote "$@" ;;
    stop)    shift; cmd_stop    "$@" ;;
    ""|help|-h|--help)
        cat <<EOF
discuss-relay.sh — tmux-swarm discuss 模式

子命令:
  start   --project <dir> --cli <cmd> [--name <n>] [--hidden]
  add     --name <n> --cli <cmd>
  post    --from <who> --content <text>
  tail    [--last N]
  list
  promote [--profile <p>]
  stop    [--clean]

环境变量:
  SWARM_DISCUSS_MAX_TURNS       最大轮次（默认 20）
  SWARM_DISCUSS_CONTEXT_TURNS   喂给 CLI 的上下文轮数（默认 10）
  SWARM_DISCUSS_STARTUP_WAIT    CLI 启动等待秒数（默认 3）
EOF
        ;;
    *) die "未知子命令: $1 (用 --help 查看)" ;;
esac
