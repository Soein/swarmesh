#!/usr/bin/env bash
################################################################################
# discuss-watcher.sh — discuss 模式的 pane 输出监听守护进程
#
# 轮询所有 discuss 参与者 pane，识别 CLI 回答完成（提示符再现 + 防抖），
# 提取本轮回答文本，自动调用 discuss-relay.sh post --from <name> --content "..."
# 形成 CLI 之间的自动转发链路。
#
# 子命令:
#   start   启动守护（前台；一般由 discuss-relay 通过 nohup 拉起）
#   stop    读 pid 文件并 kill
#   status  检查是否在跑
#
# 环境变量:
#   SWARM_DISCUSS_AUTO_WATCH=0      禁用自动 watcher（降级到半自动手动 post）
#   DISCUSS_WATCH_INTERVAL=3        轮询间隔秒
#   DISCUSS_QUIET_PERIOD=2          提示符命中后等待秒，确认无新增再判答完
#   DISCUSS_CODEX_TRUST_AUTO=1      检测 "Do you trust" 自动回 "1"+Enter
################################################################################

set -uo pipefail

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${SCRIPTS_DIR:=$(cd "$SCRIPT_DIR/.." && pwd)}"

DISCUSS_SESSION_NAME="${DISCUSS_SESSION_NAME:-swarm-discuss}"
DISCUSS_WATCH_INTERVAL="${DISCUSS_WATCH_INTERVAL:-3}"
# 提高默认防抖：8 秒静默才算答完（threshold = 8/3+1 = 3 次连续 quiet hits）
DISCUSS_QUIET_PERIOD="${DISCUSS_QUIET_PERIOD:-8}"
# 冷启动 baseline 等待秒数：watcher 启动后这段时间不推任何 answer
DISCUSS_BASELINE_WAIT="${DISCUSS_BASELINE_WAIT:-10}"
# 最小回答字符数（去装饰后），过短判为噪音
DISCUSS_MIN_ANSWER_CHARS="${DISCUSS_MIN_ANSWER_CHARS:-20}"
DISCUSS_CODEX_TRUST_AUTO="${DISCUSS_CODEX_TRUST_AUTO:-1}"
DISCUSS_CLAUDE_SAFETY_AUTO="${DISCUSS_CLAUDE_SAFETY_AUTO:-1}"
# 最后从过滤后的内容里只取末尾 N 行作为 answer（CLI 答完的最新输出在末尾）
DISCUSS_ANSWER_TAIL="${DISCUSS_ANSWER_TAIL:-8}"

# Claude / Gemini / Codex 提示符
PROMPT_PATTERNS_WATCH="${PROMPT_PATTERNS_WATCH:-❯|›|Type your message|Use /skills|context left|esc to interrupt}"

# 启动屏特征（出现这些就不算答完）
STARTUP_PATTERNS="${STARTUP_PATTERNS:-Quick safety check|Do you trust|trust the contents|Press enter to continue|2\\. No, exit|Enter to confirm|OpenAI Codex \\(v|using-superpowers|SessionStart hook|UserPromptSubmit hook}"

log()  { printf '[discuss-watcher %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# -----------------------------------------------------------------------------
# 运行时路径（由 PROJECT_DIR 推算；discuss-relay 传入或从 cwd 查）
# -----------------------------------------------------------------------------
_locate_runtime() {
    if [[ -z "${PROJECT_DIR:-}" ]]; then
        # 从 cwd 向上找
        local dir="$(pwd)"
        while [[ "$dir" != "/" ]]; do
            if [[ -f "$dir/.swarm/runtime/state.json" ]]; then
                PROJECT_DIR="$dir"; break
            fi
            dir="$(dirname "$dir")"
        done
    fi
    [[ -n "${PROJECT_DIR:-}" ]] || die "PROJECT_DIR 无法定位"
    RUNTIME_DIR="$PROJECT_DIR/.swarm/runtime"
    STATE_FILE="$RUNTIME_DIR/state.json"
    DISCUSS_DIR="$RUNTIME_DIR/discuss"
    DISCUSS_LOG="$DISCUSS_DIR/session.jsonl"
    WATCH_STATE="$DISCUSS_DIR/watch-state.json"
    BASELINE_DIR="$DISCUSS_DIR/baselines"
    PID_FILE="$DISCUSS_DIR/watcher.pid"
    HEARTBEAT="$DISCUSS_DIR/watcher.heartbeat"
    HANDLED_FLAGS="$DISCUSS_DIR/handled-flags"
    mkdir -p "$DISCUSS_DIR" "$BASELINE_DIR" "$HANDLED_FLAGS"
}

# baseline：watcher 启动后第一次见到该 pane 时抓快照；后续 answer 必须不在 baseline 里
_get_baseline() {
    local pane="$1"
    local f="$BASELINE_DIR/${pane//./_}.txt"
    [[ -f "$f" ]] && cat "$f" || true
}

_save_baseline() {
    local pane="$1" content="$2"
    printf '%s' "$content" > "$BASELINE_DIR/${pane//./_}.txt"
}

# 标记某次启动屏处理已完成（防止重复触发 trust/safety handler）
_handled_flag_set() {
    local pane="$1" flag="$2"
    touch "$HANDLED_FLAGS/${pane//./_}_${flag}"
}

_handled_flag_check() {
    local pane="$1" flag="$2"
    [[ -f "$HANDLED_FLAGS/${pane//./_}_${flag}" ]]
}

# ANSI 清洗 + 回车规范化
_strip_ansi() {
    sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g; s/\x1b\\].*\x07//g' | tr -d '\r'
}

# 从 pane 抓一段文本并清洗
_capture_pane_clean() {
    local pane="$1" last_n="${2:-200}"
    tmux capture-pane -t "${DISCUSS_SESSION_NAME}:${pane}" -p -S "-${last_n}" 2>/dev/null \
        | _strip_ansi
}

# 判断 pane 底部是否命中提示符
_hit_prompt() {
    local text="$1"
    local tail; tail=$(printf '%s\n' "$text" | sed '/^[[:space:]]*$/d' | tail -6)
    grep -qE "$PROMPT_PATTERNS_WATCH" <<<"$tail"
}

# Codex trust prompt 自动接受（处理过一次就记 flag，防止重复触发）
_handle_codex_trust() {
    local pane="$1"
    _handled_flag_check "$pane" "codex_trust" && return 1
    local text; text=$(_capture_pane_clean "$pane" 50)
    if grep -q "Do you trust the contents of this directory" <<<"$text"; then
        log "检测到 Codex trust prompt @ ${pane}，自动选 '1' Enter"
        tmux send-keys -t "${DISCUSS_SESSION_NAME}:${pane}" "1" Enter
        _handled_flag_set "$pane" "codex_trust"
        sleep 1
        return 0
    fi
    return 1
}

# Claude "Quick safety check" 启动屏自动接受（按 Enter 继续）
_handle_claude_safety() {
    local pane="$1"
    _handled_flag_check "$pane" "claude_safety" && return 1
    local text; text=$(_capture_pane_clean "$pane" 50)
    if grep -qE "Quick safety check|Is this a project you" <<<"$text"; then
        log "检测到 Claude safety check @ ${pane}，自动按 Enter"
        tmux send-keys -t "${DISCUSS_SESSION_NAME}:${pane}" Enter
        _handled_flag_set "$pane" "claude_safety"
        sleep 1
        return 0
    fi
    return 1
}

# 读取 watch-state 中某 pane 上次的 hash / last_text_hash
_get_pane_last_hash() {
    local pane="$1"
    [[ -f "$WATCH_STATE" ]] || { echo ""; return; }
    jq -r --arg p "$pane" '.panes[$p].last_hash // ""' "$WATCH_STATE" 2>/dev/null
}

_get_pane_last_text() {
    local pane="$1"
    [[ -f "$WATCH_STATE" ]] || { echo ""; return; }
    jq -r --arg p "$pane" '.panes[$p].last_text // ""' "$WATCH_STATE" 2>/dev/null
}

_save_pane_state() {
    local pane="$1" hash="$2" text="$3" quiet_hits="${4:-0}" posted_hash="${5:-}"
    local tmp; tmp=$(mktemp "${DISCUSS_DIR}/.ws.XXXXXX")
    if [[ -z "$posted_hash" ]]; then
        posted_hash=$(_get_pane_posted_hash "$pane")
    fi
    if [[ -f "$WATCH_STATE" ]]; then
        jq --arg p "$pane" --arg h "$hash" --arg t "$text" --argjson q "$quiet_hits" --arg ph "$posted_hash" \
            '.panes[$p] = {last_hash:$h, last_text:$t, quiet_hits:$q, posted_hash:$ph}' \
            "$WATCH_STATE" > "$tmp"
    else
        jq -n --arg p "$pane" --arg h "$hash" --arg t "$text" --argjson q "$quiet_hits" --arg ph "$posted_hash" \
            '{panes: {($p): {last_hash:$h, last_text:$t, quiet_hits:$q, posted_hash:$ph}}}' > "$tmp"
    fi
    mv "$tmp" "$WATCH_STATE"
}

_get_pane_posted_hash() {
    local pane="$1"
    [[ -f "$WATCH_STATE" ]] || { echo ""; return; }
    jq -r --arg p "$pane" '.panes[$p].posted_hash // ""' "$WATCH_STATE" 2>/dev/null
}

_get_quiet_hits() {
    local pane="$1"
    [[ -f "$WATCH_STATE" ]] || { echo 0; return; }
    jq -r --arg p "$pane" '.panes[$p].quiet_hits // 0' "$WATCH_STATE" 2>/dev/null
}

# -----------------------------------------------------------------------------
# 回答抽取：取上次 "answer end marker" 之后的新文本，去掉提示符行
# -----------------------------------------------------------------------------
_extract_answer() {
    local pane="$1" current_text="$2" last_text="$3"

    # 主策略：用 baseline 逐行剔除（baseline 是 watcher 启动时抓的快照，
    # 任何 baseline 已有行都不可能是 answer）
    local new_part="$current_text"
    local baseline; baseline=$(_get_baseline "$pane")
    if [[ -n "$baseline" ]]; then
        local bl_tmp; bl_tmp=$(mktemp)
        # 只用 baseline 里"非空、非装饰"的行做剔除模式，避免 grep -vFf 把空行也吃了
        printf '%s' "$baseline" | awk 'NF && length($0) > 2' > "$bl_tmp"
        if [[ -s "$bl_tmp" ]]; then
            new_part=$(printf '%s' "$new_part" | grep -vFxf "$bl_tmp" || true)
        fi
        rm -f "$bl_tmp"
    fi

    # 关键：Codex 等 CLI 渲染时给行加 2 空格缩进，必须先 trim 再过滤
    # 过滤：提示符 / CLI 装饰 / 启动屏 / 空行 / paste header 残留 / 工具调用日志
    printf '%s\n' "$new_part" \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -vE "$PROMPT_PATTERNS_WATCH" \
        | grep -vE "^$|^─+$|^╭|^│|^╰" \
        | grep -vE "gpt-.*·|Opus.*context|上下文 |用量 |本周 |/private/tmp|⏱️|\\[Opus|\\[Sonnet|Working.*esc to interrupt" \
        | grep -vE "$STARTUP_PATTERNS" \
        | grep -vE "^---历史---|^---当前---|^主持：|^\\[turn [0-9]|^Tip:|^hook context:|^Quick safety|^Press enter|^Enter to confirm|^content\")" \
        | grep -vE "^•[[:space:]]*Ran |^•[[:space:]]*Explored|^└|^│[[:space:]]*sed|^│[[:space:]]*find|^│[[:space:]]*\\[|^… \\+[0-9]+ lines" \
        | grep -vE "Added \\.omx|workspace conventions|AGENTS\\.md|using-superpowers|SessionStart hook|UserPromptSubmit hook|\\.omx/state|\\.omx 当前" \
        | grep -vE "^user: @|^@cx |^@cl |^@gem " \
        | awk 'NF' \
        | tail -"${DISCUSS_ANSWER_TAIL:-8}"
}

# -----------------------------------------------------------------------------
# 主检查：对单个 pane 执行一次 tick
# -----------------------------------------------------------------------------
_tick_pane() {
    local name="$1" pane="$2" cli_type="$3"

    # 1. CLI 启动屏自动处理（trust / safety check）
    if [[ "$cli_type" == "codex" && "$DISCUSS_CODEX_TRUST_AUTO" == "1" ]]; then
        _handle_codex_trust "$pane" && return 0
    fi
    if [[ "$cli_type" == "claude" && "$DISCUSS_CLAUDE_SAFETY_AUTO" == "1" ]]; then
        _handle_claude_safety "$pane" && return 0
    fi

    local text; text=$(_capture_pane_clean "$pane" 300)
    [[ -n "$text" ]] || return 0

    # 2. 冷启动 baseline：第一次见到该 pane → 抓快照，本轮不推任何 answer
    if [[ ! -f "$BASELINE_DIR/${pane//./_}.txt" ]]; then
        _save_baseline "$pane" "$text"
        log "📸 baseline 已抓 @ $pane (${#text} chars)，将在 ${DISCUSS_BASELINE_WAIT}s 后开始监听 answer"
        local hash; hash=$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
        _save_pane_state "$pane" "$hash" "$text" 0
        return 0
    fi

    # 3. 启动屏特征仍在底部 → 跳过本轮（CLI 还在初始化）
    # 只检查最后 12 行，避免 scrollback 里的历史启动屏永久阻断
    if printf '%s\n' "$text" | tail -12 | grep -qE "$STARTUP_PATTERNS"; then
        return 0
    fi

    local hash; hash=$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
    local last_hash; last_hash=$(_get_pane_last_hash "$pane")
    local last_text; last_text=$(_get_pane_last_text "$pane")
    local quiet_hits; quiet_hits=$(_get_quiet_hits "$pane")

    # 内容未变 且 命中提示符 → 防抖累加
    if [[ "$hash" == "$last_hash" ]]; then
        if _hit_prompt "$text"; then
            quiet_hits=$((quiet_hits + 1))
            _save_pane_state "$pane" "$hash" "$last_text" "$quiet_hits"
            local threshold=$((DISCUSS_QUIET_PERIOD / DISCUSS_WATCH_INTERVAL + 1))
            if (( quiet_hits >= threshold )); then
                # 4. 重复触发去重：本次 hash 已经 post 过就跳过
                local posted_hash; posted_hash=$(_get_pane_posted_hash "$pane")
                if [[ "$hash" == "$posted_hash" ]]; then
                    _save_pane_state "$pane" "$hash" "$text" "$quiet_hits" "$posted_hash"
                    return 0
                fi
                local answer; answer=$(_extract_answer "$pane" "$text" "$last_text")
                # 5. 最小回答长度阈值
                if [[ -n "$answer" && ${#answer} -ge ${DISCUSS_MIN_ANSWER_CHARS} ]]; then
                    log "✅ ${name} 答完，推 jsonl (${#answer} chars)"
                    "$SCRIPT_DIR/discuss-relay.sh" post --from "$name" --content "$answer" 2>&1 \
                        | sed "s/^/  /" >&2 || log "post 失败"
                    # 关键：把当前 pane 内容写为新 baseline，下轮只看新增
                    _save_baseline "$pane" "$text"
                    _save_pane_state "$pane" "$hash" "$text" 0 "$hash"
                else
                    [[ -n "$answer" ]] && log "⏭ ${name} 答案太短 (${#answer} < $DISCUSS_MIN_ANSWER_CHARS)，跳过"
                    _save_pane_state "$pane" "$hash" "$text" 0 "$hash"
                fi
            fi
        fi
        return 0
    fi

    # 内容变化，重置 quiet_hits
    _save_pane_state "$pane" "$hash" "$last_text" 0
}

# -----------------------------------------------------------------------------
# start / stop / status
# -----------------------------------------------------------------------------
cmd_start() {
    _locate_runtime

    if [[ "${SWARM_DISCUSS_AUTO_WATCH:-1}" == "0" ]]; then
        log "SWARM_DISCUSS_AUTO_WATCH=0，watcher 不启动"
        exit 0
    fi

    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        die "watcher 已在跑 (pid $(cat "$PID_FILE"))"
    fi

    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE" "$HEARTBEAT"; log "退出"; exit 0' INT TERM EXIT

    log "启动；轮询间隔 ${DISCUSS_WATCH_INTERVAL}s，quiet ${DISCUSS_QUIET_PERIOD}s"

    while true; do
        date +%s > "$HEARTBEAT"

        # session 没了就退
        if ! tmux has-session -t "$DISCUSS_SESSION_NAME" 2>/dev/null; then
            log "discuss session 已消失，退出"
            break
        fi

        # 检查 max_turns
        local turn_count max_turns
        turn_count=$(jq -r '.discuss.turn_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)
        max_turns=$(jq -r '.discuss.max_turns // 20' "$STATE_FILE" 2>/dev/null || echo 20)
        if (( turn_count >= max_turns )); then
            log "达到 max_turns ($max_turns)，暂停"
            break
        fi

        # 遍历参与者
        while IFS=$'\t' read -r p_name p_pane p_cli_type; do
            [[ -n "$p_name" ]] || continue
            _tick_pane "$p_name" "$p_pane" "$p_cli_type"
        done < <(jq -r '.discuss.participants[]? | [.name, .pane, .cli_type] | @tsv' "$STATE_FILE" 2>/dev/null)

        sleep "$DISCUSS_WATCH_INTERVAL"
    done
}

cmd_stop() {
    _locate_runtime
    if [[ -f "$PID_FILE" ]]; then
        local pid; pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" && log "已 kill watcher pid=$pid"
        else
            log "pid $pid 已不存在"
        fi
        rm -f "$PID_FILE" "$HEARTBEAT"
    else
        log "watcher 未运行"
    fi
}

cmd_status() {
    _locate_runtime
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        local pid; pid=$(cat "$PID_FILE")
        local hb_age=0
        if [[ -f "$HEARTBEAT" ]]; then
            hb_age=$(( $(date +%s) - $(cat "$HEARTBEAT") ))
        fi
        echo "running pid=$pid heartbeat=${hb_age}s ago"
        exit 0
    else
        echo "stopped"
        exit 1
    fi
}

# 被直接执行才 dispatch
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        start)  shift; cmd_start  "$@" ;;
        stop)   shift; cmd_stop   "$@" ;;
        status) shift; cmd_status "$@" ;;
        help|-h|--help|"")
            cat <<EOF
discuss-watcher.sh — discuss 模式 pane 输出监听

子命令:
  start   启动守护
  stop    停止守护
  status  状态

环境变量:
  SWARM_DISCUSS_AUTO_WATCH=0      禁用自动启动
  DISCUSS_WATCH_INTERVAL=3        轮询间隔
  DISCUSS_QUIET_PERIOD=2          提示符防抖
  DISCUSS_CODEX_TRUST_AUTO=1      Codex trust prompt 自动处理
EOF
            ;;
        *) die "未知子命令: $1" ;;
    esac
fi
