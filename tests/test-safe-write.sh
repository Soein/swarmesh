#!/usr/bin/env bash
# test-safe-write.sh — 验证 safe_write 原子性与并发安全
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
SWARM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/swarm-lib.sh"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }

# ---- Test 1: 基本 tmp+mv 原子替换 ----
target="$TMPDIR_TEST/basic.json"
echo '{"a":1}' | safe_write "$target"
[[ "$(cat "$target")" == '{"a":1}' ]] || fail "Test 1: basic write"
[[ ! -f "${target}.tmp."* ]] || fail "Test 1: tmp residue"
pass "Test 1: 基本原子写入"

# ---- Test 2: 覆盖写 ----
echo '{"a":2}' | safe_write "$target"
[[ "$(cat "$target")" == '{"a":2}' ]] || fail "Test 2: overwrite"
pass "Test 2: 覆盖写"

# ---- Test 3: 带锁写入 ----
target2="$TMPDIR_TEST/locked.json"
echo '{"b":1}' | safe_write "$target2" --lock
[[ "$(cat "$target2")" == '{"b":1}' ]] || fail "Test 3: lock write"
[[ -f "${target2}.lock" ]] || fail "Test 3: lock file should exist"
pass "Test 3: 带锁写入正确"

# ---- Test 4: 并发写 20 个不同文件到同一目录（不应损坏任何一个）----
concurrent_dir="$TMPDIR_TEST/concurrent"
mkdir -p "$concurrent_dir"
for i in $(seq 1 20); do
    (
        # shellcheck disable=SC1091
        source "$SCRIPT_DIR/swarm-lib.sh"
        jq -n --argjson i "$i" '{msg_id:$i, payload:"x"}' | \
            safe_write "$concurrent_dir/msg-$i.json" --lock
    ) &
done
wait

count=$(find "$concurrent_dir" -name 'msg-*.json' | wc -l | tr -d ' ')
[[ "$count" == "20" ]] || fail "Test 4: expect 20 files, got $count"

# 每个文件都应是合法 JSON
for f in "$concurrent_dir"/msg-*.json; do
    jq -e '.msg_id' "$f" >/dev/null || fail "Test 4: corrupted json in $f"
done
pass "Test 4: 20 并发写独立文件全部完整"

# ---- Test 5: 并发写同一文件（带锁，最终内容必须是某次完整写入，不能半写）----
same_target="$TMPDIR_TEST/same.json"
echo '{}' > "$same_target"
for i in $(seq 1 30); do
    (
        # shellcheck disable=SC1091
        source "$SCRIPT_DIR/swarm-lib.sh"
        jq -n --argjson i "$i" '{winner:$i, data:"abcdefghij"}' | \
            safe_write "$same_target" --lock
    ) &
done
wait

# 最终必须是合法 JSON（不能半写/损坏）
jq -e '.winner' "$same_target" >/dev/null || fail "Test 5: final state corrupted"
pass "Test 5: 30 并发写同文件最终合法"

# ---- Test 6: 写入失败不应留下半写目标 ----
# 构造一个场景：目标目录不可写
readonly_dir="$TMPDIR_TEST/ro"
mkdir -p "$readonly_dir"
chmod 555 "$readonly_dir"
if echo 'x' | safe_write "$readonly_dir/fail.json" 2>/dev/null; then
    chmod 755 "$readonly_dir"
    # mkdir -p 对已存在目录是幂等的，所以 cat > tmp 应当失败
    [[ ! -f "$readonly_dir/fail.json" ]] || fail "Test 6: should not create target on failure"
fi
chmod 755 "$readonly_dir"
pass "Test 6: 失败时无半写残留"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 所有 safe_write 测试通过"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
