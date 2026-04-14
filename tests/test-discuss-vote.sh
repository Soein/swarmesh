#!/usr/bin/env bash
# test-discuss-vote.sh — 验证 vote 的 meta 写入、隔离 paste、report 生成

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
VOTE="$SCRIPT_DIR/lib/discuss-vote.sh"

TEST_ROOT=$(mktemp -d -t swarm-vote-XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

export PROJECT_DIR="$TEST_ROOT/project"
mkdir -p "$PROJECT_DIR/.swarm/runtime/discuss"

STATE="$PROJECT_DIR/.swarm/runtime/state.json"
cat > "$STATE" <<'JSON'
{
  "mode": "discuss",
  "session": "swarm-discuss",
  "discuss": {
    "max_turns": 20,
    "turn_count": 0,
    "participants": [
      {"name": "cx", "cli": "codex", "cli_type": "codex", "pane": "0.0"},
      {"name": "cl", "cli": "claude", "cli_type": "claude", "pane": "0.1"}
    ]
  }
}
JSON

export DISCUSS_VOTE_SKIP_LIB=1
# 关掉后台自动 collect：测试不需要，且历史上 $0 指向测试脚本时触发过 fork 炸弹
export VOTE_AUTO_COLLECT=0
# v0.3-A: 稳定性阈值默认 2（需要 2 次连续 quiet+prompt 观测）。
# Test 1-4 保留"单次 collect 即提交"的旧语义：设 1。
# Test 5 明确测试 >1 阈值的新行为。
export VOTE_STABLE_HITS=1
# v0.3-B: 默认禁用 LLM 综合（测试无外部 CLI 调用），Test 6 单独 mock
export VOTE_LLM_DISABLE=1
# shellcheck disable=SC1090
source "$VOTE"
_ensure_runtime

# v0.5: 统一 _llm_extract_answer mock。
# 默认返回 status=answer + MOCK_LLM_CONTENT（默认 "mocked answer"）。
# 每个 test section 按需 export MOCK_LLM_STATUS / MOCK_LLM_CONTENT /
# MOCK_LLM_ABSTAIN_REASON / MOCK_LLM_STANCE 调整，或者重定义本函数。
_llm_extract_answer() {
    local _q="$1"
    local _raw; _raw=$(cat)  # absorb stdin
    jq -n \
        --arg st "${MOCK_LLM_STATUS:-answer}" \
        --arg c  "${MOCK_LLM_CONTENT:-mocked answer}" \
        --arg r  "${MOCK_LLM_ABSTAIN_REASON:-}" \
        --arg sn "${MOCK_LLM_STANCE:-neutral}" \
        '{status:$st,
          content:(if $c=="NULL" then null else $c end),
          abstain_reason:(if $r=="" then null else $r end),
          confidence:0.9,
          stance:$sn}'
}
export -f _llm_extract_answer

# mock _paste_isolated + tmux
MOCK_PASTE="$TEST_ROOT/paste.journal"
: > "$MOCK_PASTE"
_paste_isolated() {
    echo "PASTE|pane=$1|q=$2|cli=$3" >> "$MOCK_PASTE"
}
tmux() {
    case "$1" in
        has-session) return 0 ;;
        capture-pane)
            # 返回一个 mock pane 输出（问题 + 答案）
            cat <<EOF
some preamble
【独立投票 · 请给出你的独立判断，不参考任何其他人】
问题：Redis vs Dynamo?
My answer: Redis for sub-ms latency.
Real reasoning goes here.
❯
EOF
            ;;
        *) return 0 ;;
    esac
}
export -f tmux

PASS=0; FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
section() { printf '\n\033[1;34m━━ %s ━━\033[0m\n' "$1"; }

section "Test 1: ask 生成 meta.json + paste 所有参与者"
cmd_ask --question "Redis vs Dynamo?" >/dev/null

vote_dir=$(ls -d "$VOTE_ROOT"/vote-* | head -1)
[[ -f "$vote_dir/meta.json" ]] && pass "meta.json 已创建" || fail "meta.json 缺失"

q=$(jq -r '.question' "$vote_dir/meta.json")
[[ "$q" == "Redis vs Dynamo?" ]] && pass "question 正确保存" || fail "question: $q"

plen=$(jq -r '.participants | length' "$vote_dir/meta.json")
[[ "$plen" == "2" ]] && pass "participants 2 个" || fail "participants: $plen"

paste_count=$(wc -l < "$MOCK_PASTE" | tr -d ' ')
[[ "$paste_count" == "2" ]] && pass "paste 了 2 次（每人一次）" || fail "paste 次数: $paste_count"

grep -q 'pane=0.0' "$MOCK_PASTE" && grep -q 'pane=0.1' "$MOCK_PASTE" \
    && pass "两个 pane 都收到" || fail "漏 pane"

section "Test 2: collect 提取回答（v0.5 走 LLM mock）"
vote_id=$(basename "$vote_dir")
MOCK_LLM_CONTENT="Redis for sub-ms latency" cmd_collect --id "$vote_id" >/dev/null

[[ -f "$vote_dir/answer-cx.md" ]] && pass "cx 回答已存" || fail "answer-cx.md 缺"
[[ -f "$vote_dir/answer-cl.md" ]] && pass "cl 回答已存" || fail "answer-cl.md 缺"
grep -q 'Redis for sub-ms' "$vote_dir/answer-cx.md" && pass "LLM content 写入 answer" \
    || fail "回答内容: $(cat "$vote_dir/answer-cx.md")"
[[ -f "$vote_dir/meta-cx.json" ]] && pass "meta-cx.json 已存 (confidence/stance)" \
    || fail "meta-cx.json 缺"
jq -e '.confidence >= 0' "$vote_dir/meta-cx.json" >/dev/null \
    && pass "confidence 字段存在" || fail "confidence 字段缺"

section "Test 3: report 输出结构化 markdown"
out=$(cmd_report --id "$vote_id")
grep -q '^# 投票结果：' <<<"$out" && pass "markdown 标题" || fail "缺标题"
# v0.5.1: 参与者从 "^## <name>" 变成 stance 分组下的 "^### <name>"
grep -qE '^### cx' <<<"$out" && pass "cx 节（stance 子节）" || fail "缺 cx 节"
grep -qE '^### cl' <<<"$out" && pass "cl 节（stance 子节）" || fail "缺 cl 节"
grep -q '关键词统计' <<<"$out" && pass "关键词统计段" || fail "缺关键词段"

section "Test 4: 指定 --participants 仅问子集"
: > "$MOCK_PASTE"
cmd_ask --question "Q2" --participants cx >/dev/null
paste_count=$(wc -l < "$MOCK_PASTE" | tr -d ' ')
[[ "$paste_count" == "1" ]] && pass "子集过滤：只 paste 1 次" || fail "paste: $paste_count"

section "Test 5: v0.3-A watcher 式稳定性判定"
# 用与 mock 一致的问题，保证 answer 一定能抽到；唯一变量是稳定性阈值。
# 阈值 2：首次 collect 只应累计 quiet_hits，不应写 answer
VOTE_STABLE_HITS=2 cmd_ask --question "Redis vs Dynamo?" --participants cx >/dev/null
v5_dir=$(ls -dt "$VOTE_ROOT"/vote-* | head -1)
v5_id=$(basename "$v5_dir")
VOTE_STABLE_HITS=2 cmd_collect --id "$v5_id" >/dev/null
[[ ! -f "$v5_dir/answer-cx.md" ]] && pass "首次 collect 未立即提交（仅累计 1/2）" \
    || fail "answer-cx.md 过早写入"
[[ -f "$v5_dir/expect-cx.flag" ]] && pass "expect flag 保留" || fail "expect flag 被误删"

# 第二次 collect：hash 不变 + 命中提示符 → quiet_hits=2 达阈值 → 写 answer
VOTE_STABLE_HITS=2 cmd_collect --id "$v5_id" >/dev/null
[[ -f "$v5_dir/answer-cx.md" ]] && pass "二次 collect 达阈值后提交" \
    || fail "answer-cx.md 未在达阈值后写入"
[[ ! -f "$v5_dir/expect-cx.flag" ]] && pass "expect flag 已清理" || fail "expect flag 未清"

# watch-state.json 应存在，记录 quiet_hits
ws="$v5_dir/.watch-state.json"
[[ -f "$ws" ]] && pass ".watch-state.json 已落盘" || fail "watch-state 缺"

section "Test 9: v0.5 abstain 语义（LLM status=abstain）"
cmd_ask --question "abstain-q?" --participants cx >/dev/null
v9_dir=$(ls -dt "$VOTE_ROOT"/vote-* | head -1)
v9_id=$(basename "$v9_dir")
MOCK_LLM_STATUS=abstain MOCK_LLM_ABSTAIN_REASON="信息不足难以判断" MOCK_LLM_CONTENT="NULL" \
    cmd_collect --id "$v9_id" >/dev/null

[[ -f "$v9_dir/abstain-cx.md" ]] && pass "abstain 文件已落盘" || fail "abstain-cx.md 缺"
[[ ! -f "$v9_dir/answer-cx.md" ]] && pass "不生成 answer 文件" || fail "误写了 answer"
grep -q '信息不足难以判断' "$v9_dir/abstain-cx.md" && pass "弃权理由已存" \
    || fail "理由: $(cat "$v9_dir/abstain-cx.md" 2>/dev/null)"
[[ ! -f "$v9_dir/expect-cx.flag" ]] && pass "expect flag 已清理" || fail "expect flag 残留"

section "Test 7b: v0.5 LLM status=incomplete 保留 expect"
cmd_ask --question "incomplete-q?" --participants cx >/dev/null
v7b_dir=$(ls -dt "$VOTE_ROOT"/vote-* | head -1)
v7b_id=$(basename "$v7b_dir")
MOCK_LLM_STATUS=incomplete MOCK_LLM_CONTENT="NULL" cmd_collect --id "$v7b_id" >/dev/null
[[ ! -f "$v7b_dir/answer-cx.md" ]] && pass "incomplete 不写 answer" || fail "误写 answer"
[[ ! -f "$v7b_dir/abstain-cx.md" ]] && pass "incomplete 不写 abstain" || fail "误写 abstain"
[[ -f "$v7b_dir/expect-cx.flag" ]] && pass "expect flag 保留供下次 collect" || fail "expect flag 误清"

# report 应含弃权段
VOTE_LLM_DISABLE=1 out9=$(cmd_report --id "$v9_id")
grep -q '^## 弃权' <<<"$out9" && pass "report 含 ## 弃权 段" || fail "缺弃权段"
grep -q '信息不足难以判断' <<<"$out9" && pass "report 列出理由" || fail "理由未显示"

section "Test 10: v0.4 quorum / min-responses"
# 场景 A：2 人投票 + --min-responses 2，只有 cx 答，未达法定
cmd_ask --question "quorum-q?" --participants cx,cl --min-responses 2 >/dev/null
v10_dir=$(ls -dt "$VOTE_ROOT"/vote-* | head -1)
v10_id=$(basename "$v10_dir")
# meta.json 应记 min_responses=2
mr=$(jq -r '.min_responses' "$v10_dir/meta.json")
[[ "$mr" == "2" ]] && pass "meta.json 记录 min_responses=2" || fail "min_responses: $mr"

v10_start=$(printf "$VOTE_MARKER_START_TMPL" "$v10_id")
v10_end=$(printf "$VOTE_MARKER_END_TMPL" "$v10_id")
# 只给 cx (pane 0.0) 返回答案；cl (pane 0.1) 仅返回提示符（不含 marker/问题，抽不到）
tmux() {
    case "$1" in
        has-session) return 0 ;;
        capture-pane)
            # 遍历参数找 -t sess:pane
            local target=""
            while [[ $# -gt 0 ]]; do
                [[ "$1" == "-t" ]] && target="$2"
                shift
            done
            if [[ "$target" == *":0.0" ]]; then
                cat <<EOF
${v10_start}
cx answer
${v10_end}
❯
EOF
            else
                echo "❯"
            fi
            ;;
        *) return 0 ;;
    esac
}
export -f tmux
# LLM 按 pane 原文分派：cx 有 "cx answer" 字样 → status=answer；cl 只有 ❯ → incomplete
_llm_extract_answer() {
    local _q="$1"
    local _raw; _raw=$(cat)
    if [[ "$_raw" == *"cx answer"* ]]; then
        jq -n '{status:"answer", content:"cx-llm-content", abstain_reason:null, confidence:0.9, stance:"neutral"}'
    else
        jq -n '{status:"incomplete", content:null, abstain_reason:null, confidence:0.3, stance:"other"}'
    fi
}
export -f _llm_extract_answer
cmd_collect --id "$v10_id" >/dev/null
[[ -f "$v10_dir/answer-cx.md" ]] && pass "cx 答案写入" || fail "answer-cx.md 缺"
[[ -f "$v10_dir/expect-cl.flag" ]] && pass "cl 仍 expect 中" || fail "cl expect 提前清"

VOTE_LLM_DISABLE=1 out10=$(cmd_report --id "$v10_id")
grep -qE '⚠️.*未达法定' <<<"$out10" && pass "report 顶部含 quorum 警告" || fail "缺警告"
grep -qE '1.*/.*2' <<<"$out10" && pass "显示 1/2 比例" || fail "缺比例"

# 恢复默认 LLM mock
unset -f _llm_extract_answer
_llm_extract_answer() {
    local _q="$1"; local _raw; _raw=$(cat)
    jq -n \
        --arg st "${MOCK_LLM_STATUS:-answer}" \
        --arg c  "${MOCK_LLM_CONTENT:-mocked answer}" \
        --arg r  "${MOCK_LLM_ABSTAIN_REASON:-}" \
        --arg sn "${MOCK_LLM_STANCE:-neutral}" \
        '{status:$st, content:(if $c=="NULL" then null else $c end),
          abstain_reason:(if $r=="" then null else $r end),
          confidence:0.9, stance:$sn}'
}
export -f _llm_extract_answer

# 场景 B：无 --min-responses 时保持 v0.3 行为（无警告）
cmd_ask --question "q10b?" --participants cx >/dev/null
v10b_dir=$(ls -dt "$VOTE_ROOT"/vote-* | head -1)
v10b_id=$(basename "$v10b_dir")
v10b_start=$(printf "$VOTE_MARKER_START_TMPL" "$v10b_id")
v10b_end=$(printf "$VOTE_MARKER_END_TMPL" "$v10b_id")
tmux() {
    case "$1" in
        has-session) return 0 ;;
        capture-pane) cat <<EOF
${v10b_start}
any answer
${v10b_end}
❯
EOF
            ;;
        *) return 0 ;;
    esac
}
export -f tmux
cmd_collect --id "$v10b_id" >/dev/null
VOTE_LLM_DISABLE=1 out10b=$(cmd_report --id "$v10b_id")
! grep -qE '⚠️.*未达法定' <<<"$out10b" && pass "无 min_responses 不报警" || fail "误报警"

section "Test 11: v0.4 vote → discuss jsonl 回写"
# 准备 discuss session.jsonl
DLOG="$PROJECT_DIR/.swarm/runtime/discuss/session.jsonl"
: > "$DLOG"

cmd_ask --question "jsonl-q?" --participants cx >/dev/null
v11_dir=$(ls -dt "$VOTE_ROOT"/vote-* | head -1)
v11_id=$(basename "$v11_dir")
v11_start=$(printf "$VOTE_MARKER_START_TMPL" "$v11_id")
v11_end=$(printf "$VOTE_MARKER_END_TMPL" "$v11_id")
tmux() {
    case "$1" in
        has-session) return 0 ;;
        capture-pane) cat <<EOF
${v11_start}
answer for jsonl test
${v11_end}
❯
EOF
            ;;
        *) return 0 ;;
    esac
}
export -f tmux
cmd_collect --id "$v11_id" >/dev/null
VOTE_LLM_DISABLE=1 cmd_report --id "$v11_id" >/dev/null

# 验证 jsonl 被追加
lines=$(wc -l <"$DLOG" | tr -d ' ')
[[ "$lines" -ge 1 ]] && pass "jsonl 被追加（$lines 行）" || fail "jsonl 未写入"

last_line=$(tail -1 "$DLOG")
echo "$last_line" | jq -e '.type=="vote_report"' >/dev/null \
    && pass "type=vote_report" || fail "type 错: $(echo "$last_line" | jq -r .type)"
echo "$last_line" | jq -e --arg v "$v11_id" '.vote_id==$v' >/dev/null \
    && pass "vote_id 正确" || fail "vote_id 错"
echo "$last_line" | jq -e '.answered | length == 1' >/dev/null \
    && pass "answered 数组含 1 人" || fail "answered: $(echo "$last_line" | jq -c .answered)"
echo "$last_line" | jq -e '.quorum_met == true' >/dev/null \
    && pass "quorum_met=true（无 min_responses）" || fail "quorum_met 错"

# 无 DISCUSS_LOG 时不应回写
rm -f "$DLOG"
# 再起一个 vote，验证不写 jsonl（因为 DLOG 不存在）
cmd_ask --question "no-jsonl-q?" --participants cx >/dev/null
v11b_dir=$(ls -dt "$VOTE_ROOT"/vote-* | head -1)
v11b_id=$(basename "$v11b_dir")
v11b_start=$(printf "$VOTE_MARKER_START_TMPL" "$v11b_id")
v11b_end=$(printf "$VOTE_MARKER_END_TMPL" "$v11b_id")
tmux() {
    case "$1" in
        has-session) return 0 ;;
        capture-pane) cat <<EOF
${v11b_start}
x
${v11b_end}
❯
EOF
            ;;
        *) return 0 ;;
    esac
}
export -f tmux
cmd_collect --id "$v11b_id" >/dev/null
VOTE_LLM_DISABLE=1 cmd_report --id "$v11b_id" >/dev/null
[[ ! -f "$DLOG" ]] && pass "无 discuss 上下文时不回写 jsonl" || fail "误写 jsonl"

section "Test 12: v0.5.1 stance 分组展示"
cmd_ask --question "stance-q?" --participants cx,cl >/dev/null
v12_dir=$(ls -dt "$VOTE_ROOT"/vote-* | head -1)
v12_id=$(basename "$v12_dir")

# tmux 按 pane 返回不同原文，LLM mock 按原文分派
tmux() {
    case "$1" in
        has-session) return 0 ;;
        capture-pane)
            local target=""
            while [[ $# -gt 0 ]]; do
                [[ "$1" == "-t" ]] && target="$2"
                shift
            done
            if [[ "$target" == *":0.0" ]]; then
                printf 'CX_RAW_MARKER pane 0.0 content\n❯\n'
            else
                printf 'CL_RAW_MARKER pane 0.1 content\n❯\n'
            fi
            ;;
        *) return 0 ;;
    esac
}
export -f tmux
_llm_extract_answer() {
    local _q="$1"; local _raw; _raw=$(cat)
    if [[ "$_raw" == *"CX_RAW_MARKER"* ]]; then
        jq -n '{status:"answer", content:"cx 支持方案 A", abstain_reason:null, confidence:0.9, stance:"pro"}'
    else
        jq -n '{status:"answer", content:"cl 反对方案 A", abstain_reason:null, confidence:0.8, stance:"con"}'
    fi
}
export -f _llm_extract_answer
cmd_collect --id "$v12_id" >/dev/null

out12=$(VOTE_LLM_DISABLE=1 cmd_report --id "$v12_id")
grep -q '## 支持（pro）' <<<"$out12" && pass "pro 分组段" || fail "缺 pro 段: $(head -c 400 <<<"$out12")"
grep -q '## 反对（con）' <<<"$out12" && pass "con 分组段" || fail "缺 con 段"
! grep -q '## 中立（neutral）' <<<"$out12" && pass "无 neutral 时省略" || fail "误显示 neutral"

# 恢复默认 mock
unset -f _llm_extract_answer
_llm_extract_answer() {
    local _q="$1"; local _raw; _raw=$(cat)
    jq -n \
        --arg st "${MOCK_LLM_STATUS:-answer}" \
        --arg c  "${MOCK_LLM_CONTENT:-mocked answer}" \
        --arg r  "${MOCK_LLM_ABSTAIN_REASON:-}" \
        --arg sn "${MOCK_LLM_STANCE:-neutral}" \
        '{status:$st, content:(if $c=="NULL" then null else $c end),
          abstain_reason:(if $r=="" then null else $r end),
          confidence:0.9, stance:$sn}'
}
export -f _llm_extract_answer

section "Test 13: v0.5.2 多轮辩论——next-round 归档 + 重置"
cmd_ask --question "debate-q?" --participants cx,cl --rounds 2 >/dev/null
v13_dir=$(ls -dt "$VOTE_ROOT"/vote-* | head -1)
v13_id=$(basename "$v13_dir")
# meta.json 应记 rounds=2, current_round=1
jq -e '.rounds == 2' "$v13_dir/meta.json" >/dev/null \
    && pass "meta.json rounds=2" || fail "rounds 字段: $(jq -r .rounds "$v13_dir/meta.json")"
jq -e '.current_round == 1' "$v13_dir/meta.json" >/dev/null \
    && pass "meta.json current_round=1" || fail "current_round"

# 跑完第 1 轮（默认 LLM mock 都 answer）
cmd_collect --id "$v13_id" >/dev/null
[[ -f "$v13_dir/answer-cx.md" ]] && [[ -f "$v13_dir/answer-cl.md" ]] \
    && pass "Round 1 两人已答" || fail "R1 答案缺"

# next-round：归档 r1，重置 r2
cmd_next_round --id "$v13_id" >/dev/null

[[ -d "$v13_dir/round1" ]] && pass "round1/ 目录已创建" || fail "归档目录缺"
[[ -f "$v13_dir/round1/answer-cx.md" ]] && pass "cx R1 答案归档" || fail
[[ -f "$v13_dir/round1/answer-cl.md" ]] && pass "cl R1 答案归档" || fail
[[ ! -f "$v13_dir/answer-cx.md" ]] && pass "顶层 answer-cx.md 被清" || fail "R1 未清理"
[[ -f "$v13_dir/expect-cx.flag" ]] && [[ -f "$v13_dir/expect-cl.flag" ]] \
    && pass "R2 expect flags 已重置" || fail "expect 未重置"
jq -e '.current_round == 2' "$v13_dir/meta.json" >/dev/null \
    && pass "current_round 推进到 2" || fail "current_round"

# paste 到了 cx/cl（mock 记录）
paste_after=$(wc -l <"$MOCK_PASTE" | tr -d ' ')
[[ "$paste_after" -ge "$((paste_count + 2))" ]] && pass "R2 paste 2 次" || fail "paste 次数 $paste_after"

# 超过 max rounds 时 next-round 应拒绝（die → 非 0 退出）
# 必须用 subshell 包装，否则 die 会终结 test 脚本自身
# 注意 pipefail 下 pipe 左侧 die 返回 1 会污染整条 pipe 的退出码，
# 所以先捕获 stderr 文本再 grep
_r13_out=$( { cmd_next_round --id "$v13_id" 2>&1 || true; } )
grep -qi '已是最后轮\|max.*rounds' <<<"$_r13_out" \
    && pass "超最大轮数拒绝" || fail "未拒绝超轮（输出: $_r13_out）"

section "Test 6: v0.3-B LLM 综合分析（mocked）"
# 用前面 Test 1/2 已收到答案的 vote_dir（vote_id 取第一次 ask 的）
# 直接 mock _llm_analyze_answers，不动 tmux
_llm_analyze_answers() {
    printf '## 共识点\n- MOCKED-CONSENSUS\n\n## 分歧点\n- MOCKED-DIVERGENCE\n'
}
VOTE_LLM_DISABLE=0 out6=$(cmd_report --id "$vote_id")
grep -q '## 综合分析' <<<"$out6" && pass "report 含综合分析段" || fail "缺综合分析段"
grep -q 'MOCKED-CONSENSUS' <<<"$out6" && pass "LLM 输出被插入" || fail "mock 输出未出现"
grep -q '关键词统计' <<<"$out6" && fail "LLM 成功时不应再出关键词段" || pass "LLM 成功时关键词段被抑制"
# LLM 失败时应回退到关键词段
_llm_analyze_answers() { return 1; }
VOTE_LLM_DISABLE=0 out6b=$(cmd_report --id "$vote_id")
grep -q '关键词统计' <<<"$out6b" && pass "LLM 失败时回退关键词" || fail "失败回退缺"
unset -f _llm_analyze_answers

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
if [[ $FAIL -eq 0 ]]; then
    printf '\033[32m✅ discuss-vote: %d/%d tests passed\033[0m\n' "$PASS" "$((PASS+FAIL))"
    exit 0
else
    printf '\033[31m❌ discuss-vote: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
