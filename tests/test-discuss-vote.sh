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

section "Test 2: collect 提取回答"
vote_id=$(basename "$vote_dir")
cmd_collect --id "$vote_id" >/dev/null

[[ -f "$vote_dir/answer-cx.md" ]] && pass "cx 回答已存" || fail "answer-cx.md 缺"
[[ -f "$vote_dir/answer-cl.md" ]] && pass "cl 回答已存" || fail "answer-cl.md 缺"
grep -q 'Redis for sub-ms' "$vote_dir/answer-cx.md" && pass "回答内容正确" \
    || fail "回答内容: $(cat "$vote_dir/answer-cx.md")"

section "Test 3: report 输出结构化 markdown"
out=$(cmd_report --id "$vote_id")
grep -q '^# 投票结果：' <<<"$out" && pass "markdown 标题" || fail "缺标题"
grep -q '^## cx' <<<"$out" && pass "cx 节" || fail "缺 cx 节"
grep -q '^## cl' <<<"$out" && pass "cl 节" || fail "缺 cl 节"
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
