#!/usr/bin/env bash
################################################################################
# discuss-vote.sh — 隔离投票（对标 pal consensus）
#
# 同时给 N 个参与者 paste 同一个问题，**严格隔离**（不走 discuss jsonl 广播，
# 每人只看到自己被问的问题），watcher 把各自回答收集到独立文件，最后汇总成
# 结构化 markdown。
#
# 子命令:
#   ask      --question <text> [--participants a,b,c] [--timeout 120]
#            可选 --participants: 不传则用 state.json 当前 discuss.participants
#   collect  --id <vote-id>    手动触发一次收集（一般由 watcher 自动）
#   report   --id <vote-id>    生成汇总 markdown 到 stdout
################################################################################

set -uo pipefail

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${SCRIPTS_DIR:=$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck disable=SC1091
[[ -z "${DISCUSS_VOTE_SKIP_LIB:-}" ]] && source "$SCRIPTS_DIR/swarm-lib.sh"

DISCUSS_SESSION_NAME="${DISCUSS_SESSION_NAME:-swarm-discuss}"
VOTE_DEFAULT_TIMEOUT="${VOTE_DEFAULT_TIMEOUT:-120}"

die()  { echo "[vote] ERROR: $*" >&2; exit 1; }
info() { echo "[vote] $*"; }

_ensure_runtime() {
    if [[ -z "${PROJECT_DIR:-}" ]]; then
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
    VOTE_ROOT="$RUNTIME_DIR/discuss/votes"
    mkdir -p "$VOTE_ROOT"
}

_paste_isolated() {
    local pane="$1" question="$2" cli_type="$3"
    local header
    header=$(printf '【独立投票 · 请给出你的独立判断，不参考任何其他人】\n问题：%s' "$question")
    local tmpf; tmpf=$(mktemp "${RUNTIME_DIR}/.vote-paste-XXXXXX")
    printf '%s' "$header" > "$tmpf"
    SESSION_NAME="$DISCUSS_SESSION_NAME" _pane_locked_paste_enter "$pane" "$tmpf" "$cli_type"
    rm -f "$tmpf"
}

cmd_ask() {
    local question="" plist="" timeout="$VOTE_DEFAULT_TIMEOUT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --question)     question="$2";   shift 2 ;;
            --participants) plist="$2";      shift 2 ;;
            --timeout)      timeout="$2";    shift 2 ;;
            *) die "ask: 未知参数 $1" ;;
        esac
    done
    [[ -n "$question" ]] || die "--question 必需"

    _ensure_runtime
    tmux has-session -t "$DISCUSS_SESSION_NAME" 2>/dev/null \
        || die "discuss session 不存在，先 /swarm-chat <cli> 或 /swarm-chat-add 准备参与者"

    local vote_id; vote_id="vote-$(date +%s)-$RANDOM"
    local vote_dir="$VOTE_ROOT/$vote_id"
    mkdir -p "$vote_dir"

    # 参与者列表：未指定则取全部
    local names_json
    if [[ -n "$plist" ]]; then
        names_json=$(printf '%s\n' ${plist//,/ } | jq -R . | jq -s .)
    else
        names_json=$(jq '.discuss.participants | map(.name)' "$STATE_FILE")
    fi

    # 元数据
    jq -n \
        --arg question "$question" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson participants "$names_json" \
        --argjson timeout "$timeout" \
        '{id: "'"$vote_id"'", question:$question, ts:$ts, participants:$participants, timeout:$timeout}' \
        > "$vote_dir/meta.json"

    info "🗳  发起投票 $vote_id"
    info "   问题: $question"
    info "   参与者: $(jq -r 'join(",")' <<<"$names_json")"

    # 同时 paste 给每个参与者，注意严格隔离——不走 discuss-relay post，不广播
    local names; names=$(jq -r '.[]' <<<"$names_json")
    for n in $names; do
        local pane cli_type
        pane=$(jq -r --arg n "$n" '.discuss.participants[] | select(.name==$n) | .pane' "$STATE_FILE")
        cli_type=$(jq -r --arg n "$n" '.discuss.participants[] | select(.name==$n) | .cli_type' "$STATE_FILE")
        [[ -z "$pane" ]] && { info "   ⚠ $n 不在 participants，跳过"; continue; }
        _paste_isolated "$pane" "$question" "$cli_type"
        info "   ➡ 已 paste 到 @$n (pane $pane)"
        # 登记预期回答
        printf '%s' "$n" > "$vote_dir/expect-$n.flag"
    done

    info "   投票目录: $vote_dir"

    # v0.2.2: 后台自动 collect + report；VOTE_AUTO_COLLECT=0 关闭
    # 用 BASH_SOURCE[0] 锁定本脚本；用 $0 会在被 source 时指向调用方，
    # 如果调用方是测试脚本，就会触发"自己拉起自己"的递归 fork 炸弹
    if [[ "${VOTE_AUTO_COLLECT:-1}" == "1" ]]; then
        local self="${BASH_SOURCE[0]}"
        (
            local elapsed=0
            while (( elapsed < timeout )); do
                sleep 5
                elapsed=$((elapsed + 5))
                "$self" collect --id "$vote_id" >/dev/null 2>&1
                if ! ls "$vote_dir"/expect-*.flag >/dev/null 2>&1; then
                    "$self" report --id "$vote_id" > "$vote_dir/report.md"
                    break
                fi
            done
            [[ -f "$vote_dir/report.md" ]] || "$self" report --id "$vote_id" > "$vote_dir/report.md"
        ) >/dev/null 2>&1 &
        disown 2>/dev/null || true
        info "   ⏳ 后台自动收集中（每 5s 轮询，最长 ${timeout}s），完成后 report.md 自动生成"
    else
        info "   等待参与者回答后，执行:"
        info "     discuss-vote.sh collect --id $vote_id"
        info "     discuss-vote.sh report  --id $vote_id"
    fi

    # 把 vote_id 输出到 stdout 末行，便于脚本捕获
    echo "$vote_id"
}

# 收集：从 watcher 写的 vote-capture 文件 / 手动 stash 读取回答
# v0.2：采用半自动——用户执行 collect 时从 pane capture 当前内容，
# 尝试提取"问题 paste 之后到提示符之前"的增量作为回答
cmd_collect() {
    local vote_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id) vote_id="$2"; shift 2 ;;
            *) die "collect: 未知参数 $1" ;;
        esac
    done
    [[ -n "$vote_id" ]] || die "--id 必需"

    _ensure_runtime
    local vote_dir="$VOTE_ROOT/$vote_id"
    [[ -d "$vote_dir" ]] || die "vote 目录不存在: $vote_dir"

    local question; question=$(jq -r '.question' "$vote_dir/meta.json")
    local names; names=$(jq -r '.participants[]' "$vote_dir/meta.json")

    for n in $names; do
        local pane; pane=$(jq -r --arg n "$n" '.discuss.participants[] | select(.name==$n) | .pane' "$STATE_FILE")
        [[ -z "$pane" ]] && continue
        # 抓整个 pane（后 500 行）
        local raw; raw=$(tmux capture-pane -t "${DISCUSS_SESSION_NAME}:${pane}" -p -S -500 2>/dev/null \
            | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r')
        # 截取问题之后的部分
        local answer
        answer=$(awk -v q="$question" '
            BEGIN{found=0}
            { if (!found && index($0, q)) { found=1; next }
              if (found) print }
        ' <<<"$raw" | grep -vE '❯|›|^─+$|^╭|^│|^╰|gpt-.*·|\[Opus|\[Sonnet|上下文 |用量 |本周 |⏱️|/private/tmp|Working.*esc to interrupt|^[[:space:]]*$' \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
            | awk 'NF')
        if [[ -n "$answer" ]]; then
            printf '%s' "$answer" > "$vote_dir/answer-$n.md"
            rm -f "$vote_dir/expect-$n.flag"
            info "✅ 收到 @$n 的回答 ($(wc -l <<<"$answer" | tr -d ' ') 行)"
        else
            info "⏳ @$n 尚未回答（或无法提取）"
        fi
    done
}

cmd_report() {
    local vote_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id) vote_id="$2"; shift 2 ;;
            *) die "report: 未知参数 $1" ;;
        esac
    done
    [[ -n "$vote_id" ]] || die "--id 必需"

    _ensure_runtime
    local vote_dir="$VOTE_ROOT/$vote_id"
    [[ -d "$vote_dir" ]] || die "vote 目录不存在: $vote_dir"

    local question; question=$(jq -r '.question' "$vote_dir/meta.json")
    local names; names=$(jq -r '.participants[]' "$vote_dir/meta.json")

    echo "# 投票结果：$question"
    echo
    echo "_投票 ID: $vote_id · 生成于 $(date -u +%Y-%m-%dT%H:%M:%SZ)_"
    echo
    for n in $names; do
        echo "## $n"
        if [[ -f "$vote_dir/answer-$n.md" ]]; then
            cat "$vote_dir/answer-$n.md"
        elif [[ -f "$vote_dir/expect-$n.flag" ]]; then
            echo "_（尚未收到回答，可再次执行 collect）_"
        fi
        echo
    done

    # 简版共识/分歧分析（纯关键词提取，不保证准确；v0.3 交 LLM）
    local all_answers
    all_answers=$(for n in $names; do [[ -f "$vote_dir/answer-$n.md" ]] && cat "$vote_dir/answer-$n.md"; done)
    if [[ -n "$all_answers" ]]; then
        echo "## 简易关键词统计（所有回答合并）"
        echo
        echo '```'
        printf '%s' "$all_answers" | tr -c '[:alpha:]' '\n' | awk 'length > 3' | sort | uniq -c | sort -rn | head -15
        echo '```'
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        ask)     shift; cmd_ask     "$@" ;;
        collect) shift; cmd_collect "$@" ;;
        report)  shift; cmd_report  "$@" ;;
        help|-h|--help|"")
            cat <<EOF
discuss-vote.sh — 隔离投票

子命令:
  ask     --question <text> [--participants a,b,c] [--timeout 120]
  collect --id <vote-id>
  report  --id <vote-id>

环境变量:
  VOTE_DEFAULT_TIMEOUT=120
EOF
            ;;
        *) die "未知子命令: $1" ;;
    esac
fi
