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
# v0.4: marker 锚点模板。v0.5 起 marker 只作 CLI 软提示（帮助 LLM 定位答案），
# 抽取本身完全由 LLM 做，marker 有无都能正确抽取。
VOTE_MARKER_START_TMPL="${VOTE_MARKER_START_TMPL:-<<<VOTE_%s_START>>>}"
VOTE_MARKER_END_TMPL="${VOTE_MARKER_END_TMPL:-<<<VOTE_%s_END>>>}"
# v0.5: LLM-assisted extract。collect 稳定性达标后，每个参与者的 pane 原文
# 喂给一个 headless CLI，要求返回 {status, content, abstain_reason, confidence, stance}
# 结构化 JSON。v0.4 的硬规则（awk marker、启发式黑名单）彻底删除。
VOTE_LLM_EXTRACT_CMD="${VOTE_LLM_EXTRACT_CMD:-}"          # 默认复用 VOTE_LLM_CMD 自动探测
VOTE_LLM_EXTRACT_TIMEOUT="${VOTE_LLM_EXTRACT_TIMEOUT:-30}"
VOTE_LLM_EXTRACT_PARALLEL="${VOTE_LLM_EXTRACT_PARALLEL:-}" # 未设 = 参与者数
VOTE_LLM_EXTRACT_MAX="${VOTE_LLM_EXTRACT_MAX:-10}"         # 硬上限防资源挤爆

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
    local question="" plist="" timeout="$VOTE_DEFAULT_TIMEOUT" min_responses="" rounds="1"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --question)      question="$2";      shift 2 ;;
            --participants)  plist="$2";         shift 2 ;;
            --timeout)       timeout="$2";       shift 2 ;;
            --min-responses) min_responses="$2"; shift 2 ;;
            --rounds)        rounds="$2";        shift 2 ;;
            *) die "ask: 未知参数 $1" ;;
        esac
    done
    [[ -n "$question" ]] || die "--question 必需"

    _ensure_runtime
    tmux has-session -t "$DISCUSS_SESSION_NAME" 2>/dev/null \
        || die "discuss session 不存在，先 /swarm-chat <cli> 或 /swarm-chat-add 准备参与者"

    # v0.5.3: UUID 后缀替代 $RANDOM，消除同秒并发碰撞概率
    local vote_suffix
    vote_suffix=$(uuidgen 2>/dev/null | tr -d - | tr 'A-Z' 'a-z' | cut -c1-12 \
        || openssl rand -hex 6 2>/dev/null \
        || printf '%x%x' "$RANDOM" "$RANDOM")
    local vote_id; vote_id="vote-$(date +%s)-${vote_suffix}"
    local vote_dir="$VOTE_ROOT/$vote_id"
    mkdir -p "$vote_dir"

    # 参与者列表：未指定则取全部
    local names_json
    if [[ -n "$plist" ]]; then
        names_json=$(printf '%s\n' ${plist//,/ } | jq -R . | jq -s .)
    else
        names_json=$(jq '.discuss.participants | map(.name)' "$STATE_FILE")
    fi

    # 元数据（v0.4: min_responses 未传则存 null / v0.5.2: rounds + current_round）
    local mr_json="null"
    [[ -n "$min_responses" ]] && mr_json="$min_responses"
    jq -n \
        --arg question "$question" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson participants "$names_json" \
        --argjson timeout "$timeout" \
        --argjson mr "$mr_json" \
        --argjson rounds "$rounds" \
        '{id: "'"$vote_id"'", question:$question, ts:$ts,
          participants:$participants, timeout:$timeout, min_responses:$mr,
          rounds:$rounds, current_round:1}' \
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

    # v0.5: Phase 1 ——稳定性判定，筛出待 LLM-extract 的参与者。
    #       pane 原文落盘 (.pending-$n.raw)，由 Phase 2 并发消费。
    local pending_count=0
    for n in $names; do
        local pane; pane=$(jq -r --arg n "$n" '.discuss.participants[] | select(.name==$n) | .pane' "$STATE_FILE")
        [[ -z "$pane" ]] && continue
        [[ -f "$vote_dir/expect-$n.flag" ]] || continue

        local raw; raw=$(tmux capture-pane -t "${DISCUSS_SESSION_NAME}:${pane}" -p -S -500 2>/dev/null \
            | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r')
        [[ -n "$raw" ]] || continue

        # v0.3-A: 稳定性判定（保留）——hash 不变 + 命中提示符连续 N 次才认定"答完"
        local hash; hash=$(printf '%s' "$raw" | shasum -a 256 | awk '{print $1}')
        local ws; ws=$(_vote_ws_get "$vote_dir" "$n")
        local last_hash="${ws%%|*}" quiet_hits="${ws##*|}"
        if _vote_hit_prompt "$raw"; then
            if [[ "$hash" == "$last_hash" ]]; then
                quiet_hits=$((quiet_hits + 1))
            else
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
        # 写入待 extract 文件供 Phase 2 并发消费
        printf '%s' "$raw" > "$vote_dir/.pending-$n.raw"
        pending_count=$((pending_count + 1))
    done

    (( pending_count == 0 )) && return 0

    # v0.5: Phase 2 ——并发 LLM extract。
    # 并发度：VOTE_LLM_EXTRACT_PARALLEL 未设 = pending_count；最大不超过 VOTE_LLM_EXTRACT_MAX。
    local parallel="${VOTE_LLM_EXTRACT_PARALLEL:-$pending_count}"
    (( parallel > VOTE_LLM_EXTRACT_MAX )) && parallel=$VOTE_LLM_EXTRACT_MAX
    (( parallel < 1 )) && parallel=1
    info "🧠 Phase 2: LLM extract $pending_count 人，并发度 $parallel"

    # 后台起 N 个 job（受 parallel 上限），每个处理一个 pending-*.raw
    local running=0 n
    for n in $names; do
        [[ -f "$vote_dir/.pending-$n.raw" ]] || continue
        (
            local raw_path="$vote_dir/.pending-$n.raw"
            local out_path="$vote_dir/.extract-$n.json"
            _llm_extract_answer "$question" < "$raw_path" > "$out_path" 2>/dev/null \
                || echo '{"status":"error"}' > "$out_path"
        ) &
        running=$((running + 1))
        if (( running >= parallel )); then
            wait -n 2>/dev/null || wait
            running=$((running - 1))
        fi
    done
    wait

    # Phase 3: 读回 extract 结果，分发到 answer/abstain，或保留 expect
    for n in $names; do
        local out_path="$vote_dir/.extract-$n.json"
        [[ -f "$out_path" ]] || continue
        local status; status=$(jq -r '.status // "error"' "$out_path")
        case "$status" in
            answer)
                jq -r '.content // ""' "$out_path" > "$vote_dir/answer-$n.md"
                # meta: confidence / stance 供 v0.5.1 report 分组 & 综合阶段用
                jq -c '{confidence:(.confidence // 0.5), stance:(.stance // "other")}' \
                    "$out_path" > "$vote_dir/meta-$n.json"
                rm -f "$vote_dir/expect-$n.flag" "$vote_dir/.pending-$n.raw" "$out_path"
                info "✅ @$n 回答已抽取（stance=$(jq -r .stance "$vote_dir/meta-$n.json")）"
                ;;
            abstain)
                jq -r '.abstain_reason // ""' "$out_path" > "$vote_dir/abstain-$n.md"
                rm -f "$vote_dir/expect-$n.flag" "$vote_dir/.pending-$n.raw" "$out_path"
                info "🟡 @$n 弃权"
                ;;
            incomplete|no_answer)
                rm -f "$vote_dir/.pending-$n.raw" "$out_path"
                info "⏳ @$n LLM 判定为 ${status}，下次 collect 再试"
                ;;
            error|*)
                rm -f "$vote_dir/.pending-$n.raw" "$out_path"
                die "LLM extract 返回无效/失败 for @$n (status=${status})"
                ;;
        esac
    done
}

# v0.3-B: 跨平台 timeout ----------------------------------------------
_vote_exec_timeout() {
    local tout="$1"; shift
    if command -v gtimeout >/dev/null 2>&1; then gtimeout "$tout" "$@"
    elif command -v timeout  >/dev/null 2>&1; then timeout  "$tout" "$@"
    else perl -e 'alarm shift @ARGV; exec @ARGV' "$tout" "$@"; fi
}

# v0.5: 选 LLM extract CLI（探测顺序同综合阶段）----------------------
_pick_llm_cmd() {
    local prefer="$1"
    if [[ -n "$prefer" ]]; then echo "$prefer"; return 0; fi
    if   command -v claude >/dev/null 2>&1; then echo "claude -p"
    elif command -v codex  >/dev/null 2>&1; then echo "codex exec"
    elif command -v gemini >/dev/null 2>&1; then echo "gemini -p"
    else return 1
    fi
}

# v0.5: LLM 抽取+分类单个参与者的 pane 输出 -------------------------
# 入参:
#   $1 question
#   stdin: pane_raw (已去 ANSI)
# 出参:
#   stdout: 单行 JSON {status, content, abstain_reason, confidence, stance}
#   status ∈ {answer, abstain, incomplete, no_answer}
# 失败:
#   return 1（LLM 不可用/超时/返回非 JSON）
_llm_extract_answer() {
    local question="$1"
    local llm_cmd; llm_cmd=$(_pick_llm_cmd "$VOTE_LLM_EXTRACT_CMD") || return 1

    local pane_raw; pane_raw=$(cat)  # absorb stdin
    local prompt
    prompt=$(cat <<PROMPT
你是一个投票裁判助手。以下是一个参与者的终端 pane 输出（去 ANSI 后约 200 行）。
他们被问的问题是：
$question

请判定 pane 里是否包含对这个问题的**完整**回答，并返回严格的单行 JSON：
{
  "status": "answer" | "abstain" | "incomplete" | "no_answer",
  "content": "<纯净答案正文>" 或 null,
  "abstain_reason": "<理由>" 或 null,
  "confidence": 0.0-1.0,
  "stance": "pro" | "con" | "neutral" | "other"
}

规则：
- status=answer：给出了对问题的实质回答（无论语言、篇幅）
- status=abstain：明确表示信息不足 / 无法判断 / 拒绝回答（中英文均算，如"弃权"/"I abstain"/"I don't know"）
- status=incomplete：还在打字或句子截断，没答完
- status=no_answer：pane 里完全看不到和问题相关的回答
content 里**只**保留答案正文——剥离 CLI 装饰、提示符、工具调用日志、上下文头、paste header。
stance：相对问题的立场（pro=支持/认同，con=反对/否定，neutral=中立/权衡，other=不适用）。
confidence：你对自己分类的信心（低表示你也看不懂他们想说什么）。

只输出 JSON，不要额外文字、不要 markdown 代码块。

--- PANE 开始 ---
$pane_raw
--- PANE 结束 ---
PROMPT
)
    local out
    # shellcheck disable=SC2086
    out=$(printf '%s' "$prompt" | _vote_exec_timeout "$VOTE_LLM_EXTRACT_TIMEOUT" $llm_cmd 2>/dev/null) || return 1
    [[ -n "$out" ]] || return 1
    # 健壮性：剥可能的 ```json 包裹、前后空白
    out=$(printf '%s' "$out" | sed -E 's/^```(json)?//; s/```$//' | tr -d '\r' | awk 'NF' | head -c 8192)
    # 校验是合法 JSON 且 status 字段存在
    echo "$out" | jq -e '.status' >/dev/null 2>&1 || return 1
    printf '%s' "$out"
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
    # v0.5.1: 在每个回答节里附 stance 标注，告诉 LLM 立场分布
    local n
    for n in "${names[@]}"; do
        [[ -f "$vote_dir/answer-$n.md" ]] || continue
        local n_stance="other"
        [[ -f "$vote_dir/meta-$n.md.json" ]] && n_stance=$(jq -r '.stance // "other"' "$vote_dir/meta-$n.md.json" 2>/dev/null || echo other)
        [[ -f "$vote_dir/meta-$n.json" ]] && n_stance=$(jq -r '.stance // "other"' "$vote_dir/meta-$n.json" 2>/dev/null || echo other)
        prompt+=$'\n### '"$n"" [stance=$n_stance]"$'\n'
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
    # v0.5.1: 按 stance 分组展示（pro/con/neutral/other）
    # 每个参与者读其 meta-<n>.json 拿 stance，没 meta 默认 other
    _stance_label() {
        case "$1" in
            pro)     echo "## 支持（pro）" ;;
            con)     echo "## 反对（con）" ;;
            neutral) echo "## 中立（neutral）" ;;
            *)       echo "## 其他（other）" ;;
        esac
    }
    local stance_key
    for stance_key in pro con neutral other; do
        local group_any=0
        local stance_block=""
        for n in $names; do
            [[ -f "$vote_dir/abstain-$n.md" ]] && continue  # 弃权者不归组
            local n_stance="other"
            [[ -f "$vote_dir/meta-$n.json" ]] && n_stance=$(jq -r '.stance // "other"' "$vote_dir/meta-$n.json" 2>/dev/null || echo other)
            # 归一：未知 stance → other
            case "$n_stance" in
                pro|con|neutral) ;;
                *) n_stance=other ;;
            esac
            [[ "$n_stance" == "$stance_key" ]] || continue
            group_any=1
            stance_block+=$'\n### '"$n"$'\n'
            if [[ -f "$vote_dir/answer-$n.md" ]]; then
                stance_block+=$(cat "$vote_dir/answer-$n.md")$'\n'
            elif [[ -f "$vote_dir/expect-$n.flag" ]]; then
                stance_block+=$'_（尚未收到回答，可再次执行 collect）_\n'
            fi
        done
        if (( group_any )); then
            _stance_label "$stance_key"
            echo
            printf '%s\n' "$stance_block"
        fi
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

# v0.5.2: 多轮辩论 —— 归档当前轮 + paste 下轮指令 + 重置 expect ----
cmd_next_round() {
    local vote_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id) vote_id="$2"; shift 2 ;;
            *) die "next-round: 未知参数 $1" ;;
        esac
    done
    [[ -n "$vote_id" ]] || die "--id 必需"

    _ensure_runtime
    local vote_dir="$VOTE_ROOT/$vote_id"
    [[ -d "$vote_dir" ]] || die "vote 目录不存在: $vote_dir"

    local rounds cur
    rounds=$(jq -r '.rounds // 1' "$vote_dir/meta.json")
    cur=$(jq -r '.current_round // 1' "$vote_dir/meta.json")

    (( cur >= rounds )) && die "已是最后轮 (current=${cur}/max=${rounds})"

    local question; question=$(jq -r '.question' "$vote_dir/meta.json")
    local names; names=$(jq -r '.participants[]' "$vote_dir/meta.json")

    # 归档当前轮到 round<cur>/
    local arc="$vote_dir/round${cur}"
    mkdir -p "$arc"
    local n
    for n in $names; do
        for f in "answer-$n.md" "abstain-$n.md" "meta-$n.json"; do
            [[ -f "$vote_dir/$f" ]] && mv "$vote_dir/$f" "$arc/$f"
        done
        # watch-state 也重置（下轮重新判稳定性）
        rm -f "$vote_dir/.watch-state.json"
    done
    # 把上一轮的 report 也归档（若存在）
    [[ -f "$vote_dir/report-r${cur}.md" ]] && mv "$vote_dir/report-r${cur}.md" "$arc/report.md"

    # 构造下轮 paste 内容：附上一轮立场
    local ctx_block
    ctx_block=$(cat <<CTX

【第 $((cur + 1)) / ${rounds} 轮 · 辩论】
上一轮各参与者的立场如下（请参考后给出你的**最终**立场，可维持或修正）：
CTX
)
    for n in $names; do
        local n_answer="" n_stance="other"
        if [[ -f "$arc/answer-$n.md" ]]; then
            n_answer=$(cat "$arc/answer-$n.md")
            [[ -f "$arc/meta-$n.json" ]] && n_stance=$(jq -r '.stance // "other"' "$arc/meta-$n.json")
            ctx_block+=$'\n\n'"- @${n} [stance=${n_stance}]: ${n_answer}"
        elif [[ -f "$arc/abstain-$n.md" ]]; then
            ctx_block+=$'\n\n'"- @${n} [弃权]: $(cat "$arc/abstain-$n.md")"
        fi
    done

    # paste 给每个参与者（复用 _paste_isolated，不广播）
    local pane cli_type
    for n in $names; do
        pane=$(jq -r --arg n "$n" '.discuss.participants[] | select(.name==$n) | .pane' "$STATE_FILE")
        cli_type=$(jq -r --arg n "$n" '.discuss.participants[] | select(.name==$n) | .cli_type' "$STATE_FILE")
        [[ -z "$pane" ]] && continue
        _paste_isolated "$pane" "${question}${ctx_block}" "$cli_type" "$vote_id"
        info "   ➡ R$((cur + 1)) paste 到 @$n"
        printf '%s' "$n" > "$vote_dir/expect-$n.flag"
    done

    # 推进 current_round
    local tmp; tmp=$(mktemp "$vote_dir/.meta.XXXXXX")
    jq --argjson c "$((cur + 1))" '.current_round = $c' "$vote_dir/meta.json" > "$tmp" && mv "$tmp" "$vote_dir/meta.json"
    info "🔁 已进入第 $((cur + 1)) / ${rounds} 轮"
}

# v0.5.3: cmd_list —— 列出所有历史 vote（按 mtime 倒序） ---
cmd_list() {
    _ensure_runtime
    [[ -d "$VOTE_ROOT" ]] || { echo "（暂无投票）"; return 0; }
    # 用 stat 拿 mtime，按时间倒序
    local vote_dir id q cur rounds answered total
    find "$VOTE_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'vote-*' \
        | xargs -I{} stat -f '%m %N' {} 2>/dev/null \
        | sort -rn \
        | while read -r _mtime vote_dir; do
            id=$(basename "$vote_dir")
            [[ -f "$vote_dir/meta.json" ]] || continue
            q=$(jq -r '.question' "$vote_dir/meta.json" 2>/dev/null)
            cur=$(jq -r '.current_round // 1' "$vote_dir/meta.json")
            rounds=$(jq -r '.rounds // 1' "$vote_dir/meta.json")
            total=$(jq -r '.participants | length' "$vote_dir/meta.json")
            answered=$(ls "$vote_dir"/answer-*.md 2>/dev/null | wc -l | tr -d ' ')
            printf '%s  [R%s/%s | %s/%s 答]  %s\n' "$id" "$cur" "$rounds" "$answered" "$total" "${q:0:80}"
        done
}

# v0.5.3: cmd_cancel —— 取消并删除 vote 目录 ---
cmd_cancel() {
    local vote_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id) vote_id="$2"; shift 2 ;;
            *) die "cancel: 未知参数 $1" ;;
        esac
    done
    [[ -n "$vote_id" ]] || die "--id 必需"
    _ensure_runtime
    local vote_dir="$VOTE_ROOT/$vote_id"
    [[ -d "$vote_dir" ]] || die "vote 目录不存在: $vote_dir"
    rm -rf "$vote_dir"
    info "🗑  vote $vote_id 已取消"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        ask)        shift; cmd_ask        "$@" ;;
        next-round) shift; cmd_next_round "$@" ;;
        collect)    shift; cmd_collect    "$@" ;;
        report)     shift; cmd_report     "$@" ;;
        list)       shift; cmd_list       "$@" ;;
        cancel)     shift; cmd_cancel     "$@" ;;
        help|-h|--help|"")
            cat <<EOF
discuss-vote.sh — 隔离投票（v0.5）

子命令:
  ask        --question <text> [--participants a,b,c] [--timeout N]
             [--min-responses N] [--rounds N]
  collect    --id <vote-id>          # LLM-assisted 抽取
  report     --id <vote-id>
  next-round --id <vote-id>          # 多轮辩论下一轮
  list                                # 列出所有历史 vote
  cancel     --id <vote-id>          # 删除 vote 目录

环境变量（全部）:
  VOTE_AUTO_COLLECT        默认 1，0 关闭后台 collect
  VOTE_STABLE_HITS         默认 2，稳定性判定所需连续 quiet+prompt 次数
  VOTE_DEFAULT_TIMEOUT     默认 120，后台 collect 最长等待
  VOTE_LLM_DISABLE         默认 0，综合分析是否关闭
  VOTE_LLM_CMD             综合阶段的 headless CLI（默认自动探测）
  VOTE_LLM_TIMEOUT         默认 90，综合调用超时
  VOTE_LLM_EXTRACT_CMD     extract 阶段 CLI（默认复用 VOTE_LLM_CMD）
  VOTE_LLM_EXTRACT_TIMEOUT 默认 30
  VOTE_LLM_EXTRACT_PARALLEL 默认 = pending 人数
  VOTE_LLM_EXTRACT_MAX     默认 10，并发硬上限
EOF
            ;;
        *) die "未知子命令: $1" ;;
    esac
fi
