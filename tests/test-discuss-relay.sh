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

section "Test 8: DISCUSS_SESSION_NAME 按项目派生（v0.3-D，零子 shell）"
# 保存当前 state；用函数调用 + 手动变量还原，不 fork 任何子进程
_orig_PROJECT_DIR="$PROJECT_DIR"
_orig_DISCUSS_SESSION_NAME="${DISCUSS_SESSION_NAME:-}"
_orig_RUNTIME_DIR="${RUNTIME_DIR:-}"
_orig_STATE_FILE="${STATE_FILE:-}"
_orig_DISCUSS_DIR="${DISCUSS_DIR:-}"
_orig_DISCUSS_LOG="${DISCUSS_LOG:-}"

# 8.1 proj-a 派生
mkdir -p "$TEST_ROOT/proj-a/.swarm/runtime/discuss"
PROJECT_DIR="$TEST_ROOT/proj-a"
DISCUSS_SESSION_NAME=""
_ensure_runtime
name_a="$DISCUSS_SESSION_NAME"
[[ "$name_a" == "swarm-discuss-proj-a" ]] && pass "proj-a 派生为 $name_a" || fail "proj-a 派生错: '$name_a'"

# 8.2 proj-b 派生
mkdir -p "$TEST_ROOT/proj-b/.swarm/runtime/discuss"
PROJECT_DIR="$TEST_ROOT/proj-b"
DISCUSS_SESSION_NAME=""
_ensure_runtime
name_b="$DISCUSS_SESSION_NAME"
[[ "$name_b" == "swarm-discuss-proj-b" ]] && pass "proj-b 派生为 $name_b" || fail "proj-b 派生错: '$name_b'"
[[ "$name_a" != "$name_b" ]] && pass "两项目 session 名不同" || fail "两项目派生相同"

# 8.3 env 覆盖优先
PROJECT_DIR="$TEST_ROOT/proj-a"
DISCUSS_SESSION_NAME="my-custom"
_ensure_runtime
[[ "$DISCUSS_SESSION_NAME" == "my-custom" ]] && pass "env 变量覆盖派生" || fail "env 覆盖失效: '$DISCUSS_SESSION_NAME'"

# 还原
PROJECT_DIR="$_orig_PROJECT_DIR"
DISCUSS_SESSION_NAME="$_orig_DISCUSS_SESSION_NAME"
RUNTIME_DIR="$_orig_RUNTIME_DIR"
STATE_FILE="$_orig_STATE_FILE"
DISCUSS_DIR="$_orig_DISCUSS_DIR"
DISCUSS_LOG="$_orig_DISCUSS_LOG"

section "Test 16: v0.6.2 promote --brief-file 外部 brief"
# 准备：写一个外部 brief 文件
_ext_brief="$TEST_ROOT/external-brief.md"
cat > "$_ext_brief" <<EOF
# 外部 brief 内容

## 决策
直接上 Redis。
EOF
# mock swarm-start.sh 和 swarm-msg.sh（避免真启 tmux session）
mkdir -p "$TEST_ROOT/scripts-mock"
cat > "$TEST_ROOT/scripts-mock/swarm-start.sh" <<'EOF'
#!/usr/bin/env bash
echo "MOCK_START $*" > "$(dirname "$0")/../start-mock.log"
EOF
cat > "$TEST_ROOT/scripts-mock/swarm-msg.sh" <<'EOF'
#!/usr/bin/env bash
echo "MOCK_MSG $*" > "$(dirname "$0")/../msg-mock.log"
EOF
chmod +x "$TEST_ROOT/scripts-mock/"*.sh
_orig_SCRIPTS_DIR="$SCRIPTS_DIR"
SCRIPTS_DIR="$TEST_ROOT/scripts-mock"
# mock tmux 让 kill-session 无报错
tmux() { return 0; }
export -f tmux

( cmd_promote --profile test --brief-file "$_ext_brief" 2>/dev/null ) || true

_actual_brief="$PROJECT_DIR/.swarm/runtime/discuss/brief.md"
[[ -f "$_actual_brief" ]] && pass "brief.md 被写入" || fail "brief.md 缺"
diff "$_ext_brief" "$_actual_brief" >/dev/null \
    && pass "brief.md 内容 == 外部 brief 文件" \
    || fail "内容不同"
SCRIPTS_DIR="$_orig_SCRIPTS_DIR"

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
if [[ $FAIL -eq 0 ]]; then
    printf '\033[32m✅ discuss-relay: %d/%d tests passed\033[0m\n' "$PASS" "$((PASS+FAIL))"
    exit 0
else
    printf '\033[31m❌ discuss-relay: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
