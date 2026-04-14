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
# v0.3-A: collect 稳定性阈值——需 N 次连续 "hash 不变 + 命中提示符" 才提交回答。
# 默认 2，对应 ~10s 稳定（collect 5s 一次）。测试可设 1 绕过。
VOTE_STABLE_HITS="${VOTE_STABLE_HITS:-2}"
# 提示符模式：与 discuss-watcher.sh 对齐
VOTE_PROMPT_PATTERNS="${VOTE_PROMPT_PATTERNS:-❯|›|Type your message|Use /skills|context left|esc to interrupt}"
# v0.3-B: LLM 综合分析。VOTE_LLM_DISABLE=1 关闭，VOTE_LLM_CMD 覆盖 CLI 选择，
# VOTE_LLM_TIMEOUT 秒数（默认 90）。
VOTE_LLM_DISABLE="${VOTE_LLM_DISABLE:-0}"
VOTE_LLM_CMD="${VOTE_LLM_CMD:-}"
VOTE_LLM_TIMEOUT="${VOTE_LLM_TIMEOUT:-90}"
# v0.4: marker 锚点模板。%s 占位为 vote_id，保证每轮 marker 唯一、
# 不会和历史 pane scrollback 里的残留 marker 撞上。
VOTE_MARKER_START_TMPL="${VOTE_MARKER_START_TMPL:-<<<VOTE_%s_START>>>}"
VOTE_MARKER_END_TMPL="${VOTE_MARKER_END_TMPL:-<<<VOTE_%s_END>>>}"

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
    local pane="$1" question="$2" cli_type="$3" vote_id="${4:-}"
    local start_tag="" end_tag="" marker_block=""
    if [[ -n "$vote_id" ]]; then
        start_tag=$(printf "$VOTE_MARKER_START_TMPL" "$vote_id")
        end_tag=$(printf "$VOTE_MARKER_END_TMPL" "$vote_id")
        marker_block=$(cat <<MARKER

请将你的最终答案完整包在以下两行之间（不要加 markdown 代码块装饰）：
$start_tag
...你的答案正文...
$end_tag

若信息不足或无法判断，在 marker 内仅写一行：ABSTAIN: <简短理由>
MARKER
)
    fi
    local header
    header=$(printf '【独立投票 · 请给出你的独立判断，不参考任何其他人】\n问题：%s%s' "$question" "$marker_block")
    local tmpf; tmpf=$(mktemp "${RUNTIME_DIR}/.vote-paste-XXXXXX")
    printf '%s' "$header" > "$tmpf"
    SESSION_NAME="$DISCUSS_SESSION_NAME" _pane_locked_paste_enter "$pane" "$tmpf" "$cli_type"
    rm -f "$tmpf"
}

cmd_ask() {
    local question="" plist="" timeout="$VOTE_DEFAULT_TIMEOUT" min_responses=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --question)      question="$2";      shift 2 ;;
            --participants)  plist="$2";         shift 2 ;;
            --timeout)       timeout="$2";       shift 2 ;;
            --min-responses) min_responses="$2"; shift 2 ;;
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

    # 元数据（v0.4: min_responses 未传则存 null）
    local mr_json="null"
    [[ -n "$min_responses" ]] && mr_json="$min_responses"
    jq -n \
        --arg question "$question" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson participants "$names_json" \
        --argjson timeout "$timeout" \
        --argjson mr "$mr_json" \
        '{id: "'"$vote_id"'", question:$question, ts:$ts, participants:$participants, timeout:$timeout, min_responses:$mr}' \
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
        _paste_isolated "$pane" "$question" "$cli_type" "$vote_id"
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

# v0.3-A: watcher 式稳定性判定工具 ------------------------------------
# 底部非空行命中提示符模式即视为"CLI 在等输入"
_vote_hit_prompt() {
    local raw="$1"
    local tail; tail=$(printf '%s\n' "$raw" | sed '/^[[:space:]]*$/d' | tail -6)
    grep -qE "$VOTE_PROMPT_PATTERNS" <<<"$tail"
}

# watch-state：记录每个参与者的 last_hash / quiet_hits
_vote_ws_get() {
    local vote_dir="$1" name="$2"
    local ws="$vote_dir/.watch-state.json"
    [[ -f "$ws" ]] || { echo "|0"; return; }
    jq -r --arg n "$name" '.[$n] // {} | "\(.hash // "")|\(.quiet_hits // 0)"' "$ws" 2>/dev/null
}

_vote_ws_set() {
    local vote_dir="$1" name="$2" hash="$3" quiet_hits="$4"
    local ws="$vote_dir/.watch-state.json"
    [[ -f "$ws" ]] || echo '{}' > "$ws"
    local tmp; tmp=$(mktemp "$vote_dir/.ws.XXXXXX")
    jq --arg n "$name" --arg h "$hash" --argjson q "$quiet_hits" \
        '.[$n] = {hash:$h, quiet_hits:$q}' "$ws" > "$tmp" && mv "$tmp" "$ws"
}

# 收集：v0.3-A watcher 式稳定性判定——连续 VOTE_STABLE_HITS 次
# "hash 不变 + 命中提示符" 才提交回答，规避答案打字中被截断
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
        # 已收到的跳过
        [[ -f "$vote_dir/expect-$n.flag" ]] || continue

        # 抓整个 pane（后 500 行）
        local raw; raw=$(tmux capture-pane -t "${DISCUSS_SESSION_NAME}:${pane}" -p -S -500 2>/dev/null \
            | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r')
        [[ -n "$raw" ]] || continue

        # v0.3-A: 稳定性判定——hash 不变 + 命中提示符连续 N 次才认定"答完"
        local hash; hash=$(printf '%s' "$raw" | shasum -a 256 | awk '{print $1}')
        local ws; ws=$(_vote_ws_get "$vote_dir" "$n")
        local last_hash="${ws%%|*}" quiet_hits="${ws##*|}"
        if _vote_hit_prompt "$raw"; then
            if [[ "$hash" == "$last_hash" ]]; then
                quiet_hits=$((quiet_hits + 1))
            else
                # 首次观测或内容变动后首次 prompt hit：重置为 1
                quiet_hits=1
            fi
        else
            quiet_hits=0
        fi
        _vote_ws_set "$vote_dir" "$n" "$hash" "$quiet_hits"
        if (( quiet_hits < VOTE_STABLE_HITS )); then
            info "⏳ @$n 尚未稳定 ($quiet_hits/$VOTE_STABLE_HITS)"
            continue
        fi

        # v0.4: 优先 marker 抽取；marker 缺失时回退到启发式
        local start_tag end_tag
        start_tag=$(printf "$VOTE_MARKER_START_TMPL" "$vote_id")
        end_tag=$(printf "$VOTE_MARKER_END_TMPL" "$vote_id")
        local answer=""
        if grep -qF "$start_tag" <<<"$raw" && grep -qF "$end_tag" <<<"$raw"; then
            answer=$(awk -v s="$start_tag" -v e="$end_tag" '
                index($0, s) { found=1; next }
                index($0, e) { found=0 }
                found
            ' <<<"$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF')
        fi
        if [[ -z "$answer" ]]; then
            [[ -n "$start_tag" ]] && info "⚠ @$n 未用 marker，回退启发式抽取"
            # 启发式：截取问题之后的部分（v0.3 原逻辑保留做 fallback）
            answer=$(awk -v q="$question" '
                BEGIN{found=0}
                { if (!found && index($0, q)) { found=1; next }
                  if (found) print }
            ' <<<"$raw" | grep -vE '❯|›|^─+$|^╭|^│|^╰|gpt-.*·|\[Opus|\[Sonnet|上下文 |用量 |本周 |⏱️|/private/tmp|Working.*esc to interrupt|^[[:space:]]*$' \
                | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                | awk 'NF')
        fi
        if [[ -n "$answer" ]]; then
            # v0.4: 弃权识别——marker 内仅写 "ABSTAIN: <理由>" 单行
            if [[ "$answer" =~ ^[[:space:]]*ABSTAIN:[[:space:]]*(.*) ]]; then
                local reason="${BASH_REMATCH[1]}"
                printf '%s' "$reason" > "$vote_dir/abstain-$n.md"
                rm -f "$vote_dir/expect-$n.flag"
                info "🟡 @$n 弃权（${reason:0:60}...）"
            else
                printf '%s' "$answer" > "$vote_dir/answer-$n.md"
                rm -f "$vote_dir/expect-$n.flag"
                info "✅ 收到 @$n 的回答 ($(wc -l <<<"$answer" | tr -d ' ') 行)"
            fi
        else
            info "⏳ @$n 尚未回答（或无法提取）"
        fi
    done
}

# v0.3-B: 跨平台 timeout ----------------------------------------------
_vote_exec_timeout() {
    local tout="$1"; shift
    if command -v gtimeout >/dev/null 2>&1; then gtimeout "$tout" "$@"
    elif command -v timeout  >/dev/null 2>&1; then timeout  "$tout" "$@"
    else perl -e 'alarm shift @ARGV; exec @ARGV' "$tout" "$@"; fi
}

# v0.3-B: 喂 LLM 做共识/分歧综合 --------------------------------------
# 入参: question vote_dir name1 name2 ...
# 成功：stdout 输出 markdown 片段（已含 ## 共识点 等小节）
# 失败：return 1（无 CLI、超时、空输出）
_llm_analyze_answers() {
    local question="$1" vote_dir="$2"; shift 2
    local names=("$@")
    [[ "$VOTE_LLM_DISABLE" == "1" ]] && return 1

    local llm_cmd="$VOTE_LLM_CMD"
    if [[ -z "$llm_cmd" ]]; then
        if   command -v claude >/dev/null 2>&1; then llm_cmd="claude -p"
        elif command -v codex  >/dev/null 2>&1; then llm_cmd="codex exec"
        elif command -v gemini >/dev/null 2>&1; then llm_cmd="gemini -p"
        else return 1
        fi
    fi

    local prompt quorum_note=""
    [[ "${VOTE_QUORUM_WARN:-0}" == "1" ]] && quorum_note=$'\n\n⚠️ 注意：本次投票未达法定回答人数，以下回答不代表完整立场。'
    prompt=$(cat <<PROMPT
以下是 ${#names[@]} 位独立参与者针对同一问题的回答。${quorum_note}
请做结构化综合，严格按如下 markdown 段落输出（不要别的小节、不要寒暄、不要复述问题）：

## 共识点
（所有回答中可明确归纳的共同结论，列表形式）

## 分歧点
（存在明显矛盾或取舍分歧之处，逐点列出各方立场）

## 各方立场摘要
（每个参与者 1–2 句提纯）

## 建议决策
（基于以上综合，给出一个明确、可执行的结论或建议）

---
问题：$question

---
回答：
PROMPT
)
    local n
    for n in "${names[@]}"; do
        [[ -f "$vote_dir/answer-$n.md" ]] || continue
        prompt+=$'\n### '"$n"$'\n'
        prompt+=$(cat "$vote_dir/answer-$n.md")
        prompt+=$'\n'
    done
    # v0.4: 弃权清单附在 prompt 末尾，明确告知 LLM 不要把弃权者当共识
    local has_abstain=0
    for n in "${names[@]}"; do
        if [[ -f "$vote_dir/abstain-$n.md" ]]; then
            if (( ! has_abstain )); then
                prompt+=$'\n\n---\n弃权者（不参与共识计算，仅供参考）：\n'
                has_abstain=1
            fi
            prompt+="- ${n}: $(cat "$vote_dir/abstain-$n.md")"$'\n'
        fi
    done

    local out
    # shellcheck disable=SC2086
    out=$(printf '%s' "$prompt" | _vote_exec_timeout "$VOTE_LLM_TIMEOUT" $llm_cmd 2>/dev/null) || return 1
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
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

    # v0.4: quorum 判断——answered 只数实质回答（弃权不算）
    local min_responses; min_responses=$(jq -r '.min_responses // empty' "$vote_dir/meta.json")
    local answered; answered=$(ls "$vote_dir"/answer-*.md 2>/dev/null | wc -l | tr -d ' ')
    local quorum_warn=0
    if [[ -n "$min_responses" && "$min_responses" != "null" ]]; then
        if (( answered < min_responses )); then
            echo "> ⚠️ **投票未达法定数**（实质回答 ${answered} / ${min_responses}），结果仅供参考。"
            echo
            quorum_warn=1
        fi
    fi
    for n in $names; do
        # 弃权者不在主列表里，单列 ## 弃权 段
        [[ -f "$vote_dir/abstain-$n.md" ]] && continue
        echo "## $n"
        if [[ -f "$vote_dir/answer-$n.md" ]]; then
            cat "$vote_dir/answer-$n.md"
        elif [[ -f "$vote_dir/expect-$n.flag" ]]; then
            echo "_（尚未收到回答，可再次执行 collect）_"
        fi
        echo
    done

    # v0.4: 弃权段
    local any_abstain=0
    for n in $names; do [[ -f "$vote_dir/abstain-$n.md" ]] && any_abstain=1; done
    if (( any_abstain )); then
        echo "## 弃权"
        echo
        for n in $names; do
            if [[ -f "$vote_dir/abstain-$n.md" ]]; then
                echo "- **$n**: $(cat "$vote_dir/abstain-$n.md")"
            fi
        done
        echo
    fi

    # v0.3-B: 优先 LLM 综合；失败回退到关键词段
    local all_answers
    all_answers=$(for n in $names; do [[ -f "$vote_dir/answer-$n.md" ]] && cat "$vote_dir/answer-$n.md"; done)
    if [[ -n "$all_answers" ]]; then
        local name_arr=()
        for n in $names; do name_arr+=("$n"); done
        local llm_out
        # v0.4: quorum 未达时通过 env 传递给 LLM，prompt 里会加注记
        if VOTE_QUORUM_WARN="$quorum_warn" llm_out=$(_llm_analyze_answers "$question" "$vote_dir" "${name_arr[@]}"); then
            echo "## 综合分析（LLM）"
            echo
            echo "$llm_out"
            echo
        else
            echo "## 简易关键词统计（所有回答合并·LLM 不可用）"
            echo
            echo '```'
            printf '%s' "$all_answers" | tr -c '[:alpha:]' '\n' | awk 'length > 3' | sort | uniq -c | sort -rn | head -15
            echo '```'
        fi
    fi

    # v0.4: 若当前在 discuss session 内（存在 session.jsonl），追加 vote_report 事件。
    # 只落盘、不 paste、不 broadcast，避免触发 watcher 回环。
    # cmd_promote 用 select(.type=="message") 过滤，vote_report 自动被忽略。
    local dlog="$RUNTIME_DIR/discuss/session.jsonl"
    if [[ -f "$dlog" ]]; then
        local answered_arr abstained_arr
        answered_arr=$(for n in $names; do
            [[ -f "$vote_dir/answer-$n.md"  ]] && echo "$n"
        done | jq -R . | jq -sc .)
        abstained_arr=$(for n in $names; do
            [[ -f "$vote_dir/abstain-$n.md" ]] && echo "$n"
        done | jq -R . | jq -sc .)
        jq -nc \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg vid "$vote_id" \
            --arg q "$question" \
            --argjson p "$(jq '.participants' "$vote_dir/meta.json")" \
            --argjson a "$answered_arr" \
            --argjson ab "$abstained_arr" \
            --argjson qw "$quorum_warn" \
            '{turn:0, ts:$ts, type:"vote_report", vote_id:$vid, question:$q,
              participants:$p, answered:$a, abstained:$ab,
              quorum_met: ($qw == 0)}' \
            >> "$dlog"
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
