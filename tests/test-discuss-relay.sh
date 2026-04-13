#!/usr/bin/env bash
# test-discuss-relay.sh — 验证 discuss-relay 的 @点名、jsonl 写入、上下文截断
#
# 策略：mock 掉 tmux 和 _paste_to_pane，只验证数据层逻辑。

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
RELAY="$SCRIPT_DIR/lib/discuss-relay.sh"

TEST_ROOT=$(mktemp -d -t swarm-discuss-XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

export PROJECT_DIR="$TEST_ROOT/project"
mkdir -p "$PROJECT_DIR/.swarm/runtime/discuss"

STATE="$PROJECT_DIR/.swarm/runtime/state.json"
DLOG="$PROJECT_DIR/.swarm/runtime/discuss/session.jsonl"

cat > "$STATE" <<'JSON'
{
  "schema_version": 1,
  "mode": "discuss",
  "session": "swarm-discuss",
  "project": "/tmp/fake",
  "discuss": {
    "max_turns": 20,
    "turn_count": 0,
    "participants": [
      {"name": "codex",  "cli": "codex chat", "cli_type": "codex",  "pane": "0.0"},
      {"name": "claude", "cli": "claude",     "cli_type": "claude", "pane": "0.1"}
    ]
  }
}
JSON
: > "$DLOG"

MOCK_JOURNAL="$TEST_ROOT/paste.journal"
: > "$MOCK_JOURNAL"

# 跳过 swarm-lib 加载（我们不需要 tmux）
export DISCUSS_RELAY_SKIP_LIB=1
export SESSION_NAME="swarm-discuss"

# shellcheck disable=SC1090
source "$RELAY"

# override paste
_paste_to_pane() {
    local pane="$1" content="$2" cli_type="${3:-}"
    # 用单行摘要记录（内容里有换行会影响 wc -l，所以只记 header 信息）
    local oneline; oneline=$(printf '%s' "$content" | tr '\n' ' ' | cut -c1-120)
    printf 'PASTE|pane=%s|type=%s|content=%s\n' "$pane" "$cli_type" "$oneline" >> "$MOCK_JOURNAL"
}

PASS=0; FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
section() { printf '\n\033[1;34m━━ %s ━━\033[0m\n' "$1"; }

section "Test 1: post 无 @ 不触发 paste，但落盘"
cmd_post --from user --content "大家看看这个问题" >/dev/null
lines=$(wc -l < "$DLOG" | tr -d ' ')
[[ "$lines" == "1" ]] && pass "jsonl 写入 1 行" || fail "期望 1 行，实际 $lines"
[[ ! -s "$MOCK_JOURNAL" ]] && pass "无 @ 未触发 paste" || fail "不应 paste"
turn=$(jq -r '.discuss.turn_count' "$STATE")
[[ "$turn" == "1" ]] && pass "turn_count=1" || fail "turn_count=$turn"

section "Test 2: @codex 触发 codex pane paste"
: > "$MOCK_JOURNAL"
cmd_post --from user --content "@codex 你怎么看方案 A？" >/dev/null
grep -q 'pane=0.0' "$MOCK_JOURNAL" && pass "paste 到 codex pane 0.0" || fail "未命中 0.0"
grep -q 'type=codex' "$MOCK_JOURNAL" && pass "cli_type=codex" || fail "cli_type 错误"

section "Test 3: 多 @ 同时触发"
: > "$MOCK_JOURNAL"
cmd_post --from user --content "@codex @claude 一起讨论下" >/dev/null
paste_count=$(wc -l < "$MOCK_JOURNAL" | tr -d ' ')
[[ "$paste_count" == "2" ]] && pass "双 @ 触发 2 次 paste" || fail "期望 2 次，实际 $paste_count"
grep -q 'pane=0.0' "$MOCK_JOURNAL" && grep -q 'pane=0.1' "$MOCK_JOURNAL" \
    && pass "两个 pane 都收到" || fail "漏 pane"

section "Test 4: @ 未知参与者跳过"
: > "$MOCK_JOURNAL"
cmd_post --from user --content "@ghost 你听得见吗" >/dev/null
[[ ! -s "$MOCK_JOURNAL" ]] && pass "@ 不存在的不 paste" || fail "不应 paste"

section "Test 5: 上下文包含历史"
: > "$MOCK_JOURNAL"
cmd_post --from user --content "@codex 基于之前讨论，给出结论" >/dev/null
grep -q 'turn' "$MOCK_JOURNAL" && pass "上下文含 'turn' 标记" || fail "上下文未注入历史"

section "Test 6: 达到最大轮次阻断"
jq '.discuss.max_turns = 2 | .discuss.turn_count = 2' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
# die 里有 exit 1；在子 shell 里执行以免杀掉测试进程
if ( cmd_post --from user --content "@codex 再来" 2>/dev/null ); then
    fail "应当被最大轮次阻断"
else
    pass "最大轮次阻断生效"
fi

section "Test 7: list 列出参与者"
listed=$(cmd_list 2>/dev/null | wc -l | tr -d ' ')
[[ "$listed" == "2" ]] && pass "list 输出 2 行" || fail "list 输出 $listed 行"

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
if [[ $FAIL -eq 0 ]]; then
    printf '\033[32m✅ discuss-relay: %d/%d tests passed\033[0m\n' "$PASS" "$((PASS+FAIL))"
    exit 0
else
    printf '\033[31m❌ discuss-relay: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
