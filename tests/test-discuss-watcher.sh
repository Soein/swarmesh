#!/usr/bin/env bash
# test-discuss-watcher.sh — 验证 watcher 的 ANSI 清洗、提示符防抖、@mention 提取、Codex trust 处理、防回环
#
# 策略：source watcher 脚本得到函数；mock tmux / shasum / discuss-relay post 调用。

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
WATCHER="$SCRIPT_DIR/lib/discuss-watcher.sh"
RELAY="$SCRIPT_DIR/lib/discuss-relay.sh"

TEST_ROOT=$(mktemp -d -t swarm-watcher-XXXXXX)
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

# Source watcher 函数定义（BASH_SOURCE != $0 时会 return，不 dispatch）
# shellcheck disable=SC1090
source "$WATCHER"
_locate_runtime  # 设定 DISCUSS_DIR / WATCH_STATE / ...

# -----------------------------------------------------------------------------
# Mocks
# -----------------------------------------------------------------------------
MOCK_CAPTURE=""
MOCK_POST_JOURNAL="$TEST_ROOT/post.journal"
: > "$MOCK_POST_JOURNAL"

# 覆盖 _capture_pane_clean 直接返回预置内容
_capture_pane_clean() { printf '%s' "$MOCK_CAPTURE"; }

# 覆盖 discuss-relay.sh post 调用（我们不想真起 discuss-relay）
_mock_post() {
    # discuss-watcher 里 "$SCRIPT_DIR/discuss-relay.sh" post --from X --content Y
    # 我们在 watcher 的 source 之后把 SCRIPT_DIR 指向一个 fake 目录
    echo "POST|$*" >> "$MOCK_POST_JOURNAL"
}

# 替换脚本内 "$SCRIPT_DIR/discuss-relay.sh" 调用（通过伪造一个脚本）
FAKE_RELAY="$TEST_ROOT/fake-relay.sh"
cat > "$FAKE_RELAY" <<FAKE
#!/usr/bin/env bash
shift  # 去掉子命令 "post"
echo "POST|\$*" >> "$MOCK_POST_JOURNAL"
FAKE
chmod +x "$FAKE_RELAY"

# 覆盖 SCRIPT_DIR 让 _tick_pane 走 fake relay
SCRIPT_DIR="$TEST_ROOT"
ln -s "$FAKE_RELAY" "$TEST_ROOT/discuss-relay.sh"

# Mock tmux send-keys（Codex trust 测试用）
MOCK_TMUX_JOURNAL="$TEST_ROOT/tmux.journal"
: > "$MOCK_TMUX_JOURNAL"
tmux() {
    case "$1" in
        send-keys) echo "SENDKEYS|$*" >> "$MOCK_TMUX_JOURNAL" ;;
        has-session) return 0 ;;
        *) return 0 ;;
    esac
}
export -f tmux

PASS=0; FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
section() { printf '\n\033[1;34m━━ %s ━━\033[0m\n' "$1"; }

# -----------------------------------------------------------------------------
section "Test 1: ANSI 清洗 + CR 归一化"
# -----------------------------------------------------------------------------
raw=$'\x1b[31mred\x1b[0m\r\nhello'
cleaned=$(printf '%s' "$raw" | _strip_ansi)
[[ "$cleaned" == $'red\nhello' ]] && pass "ANSI + CR 清洗正确" \
    || fail "期望 'red<LF>hello'，实际: $(printf '%q' "$cleaned")"

# -----------------------------------------------------------------------------
section "Test 2: 提示符检测"
# -----------------------------------------------------------------------------
text_with_prompt=$'ok\n❯ '
if _hit_prompt "$text_with_prompt"; then pass "命中 ❯"; else fail "应命中 ❯"; fi

text_no_prompt=$'still working\n'
if _hit_prompt "$text_no_prompt"; then fail "不应命中"; else pass "无提示符正确拒绝"; fi

# -----------------------------------------------------------------------------
section "Test 3: Codex trust prompt 自动处理"
# -----------------------------------------------------------------------------
: > "$MOCK_TMUX_JOURNAL"
MOCK_CAPTURE='Do you trust the contents of this directory?
› 1. Yes, continue
  2. No, quit'
if _handle_codex_trust "0.0"; then
    pass "trust 返回 0（已处理）"
else
    fail "trust 应返回 0"
fi
grep -q 'SENDKEYS.*1' "$MOCK_TMUX_JOURNAL" && pass "send-keys 1 Enter" \
    || fail "未发送 1: $(cat "$MOCK_TMUX_JOURNAL")"

: > "$MOCK_TMUX_JOURNAL"
MOCK_CAPTURE='some normal output'
if _handle_codex_trust "0.0"; then
    fail "非 trust 不应返回 0"
else
    pass "非 trust 正确返回 1"
fi

# -----------------------------------------------------------------------------
section "Test 4: 答完检测 + 防抖"
# -----------------------------------------------------------------------------
# 提高防抖阈值，测试行为更清晰
DISCUSS_QUIET_PERIOD=6      # threshold = 6/3 + 1 = 3
DISCUSS_WATCH_INTERVAL=3
rm -f "$WATCH_STATE"
MOCK_CAPTURE=$'some claude answer\n❯ '

# 第一次 tick：没有 last_hash → 保存 hash + quiet_hits=0，不触发
_tick_pane "cl" "0.1" "claude"
[[ ! -s "$MOCK_POST_JOURNAL" ]] && pass "首次 tick 不触发 post" \
    || fail "首次不应 post"

# 第二次 tick：hash 相同 + 命中 prompt → quiet_hits=1
_tick_pane "cl" "0.1" "claude"
qh=$(jq -r '.panes["0.1"].quiet_hits' "$WATCH_STATE")
[[ "$qh" == "1" ]] && pass "quiet_hits=1 防抖计数" || fail "quiet_hits=$qh"

# 第三次 tick：quiet_hits=2，仍未达到阈值 3
_tick_pane "cl" "0.1" "claude"
[[ ! -s "$MOCK_POST_JOURNAL" ]] && pass "第三次未达阈值不触发" \
    || fail "不应 post: $(cat "$MOCK_POST_JOURNAL")"

# 第四次 tick：quiet_hits=3 达到阈值 → 触发 post
_tick_pane "cl" "0.1" "claude"
grep -q 'POST.*--from cl' "$MOCK_POST_JOURNAL" && pass "第四次达阈值触发 post" \
    || fail "应触发 post: $(cat "$MOCK_POST_JOURNAL")"

# -----------------------------------------------------------------------------
section "Test 5: _extract_answer 清洗装饰行"
# -----------------------------------------------------------------------------
input=$'previous text\nthe actual answer here\n❯ \n────────────\n[Opus 4.6]\n上下文 ██'
answer=$(_extract_answer "0.1" "$input" "previous text")
echo "$answer" | grep -q 'actual answer here' && pass "保留真实回答" || fail "真实回答丢失: $answer"
! echo "$answer" | grep -q '❯' && pass "过滤提示符行" || fail "提示符未过滤"
! echo "$answer" | grep -q '\[Opus' && pass "过滤 Claude badge" || fail "Claude badge 未过滤"

# -----------------------------------------------------------------------------
printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
if [[ $FAIL -eq 0 ]]; then
    printf '\033[32m✅ discuss-watcher: %d/%d tests passed\033[0m\n' "$PASS" "$((PASS+FAIL))"
    exit 0
else
    printf '\033[31m❌ discuss-watcher: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
