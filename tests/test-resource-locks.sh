#!/usr/bin/env bash
# test-resource-locks.sh — 验证 exclusive 任务的 resource_keys 互斥
set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export SWARM_ROOT="$ROOT_DIR"

TEST_ROOT=$(mktemp -d -t swarm-reslock-XXXXXX)
export RUNTIME_DIR="$TEST_ROOT/runtime"
export PROJECT_DIR="$TEST_ROOT/project"
mkdir -p "$PROJECT_DIR" "$RUNTIME_DIR"
git -C "$PROJECT_DIR" init -q >/dev/null 2>&1

source "$SCRIPT_DIR/swarm-lib.sh"
source "$SCRIPT_DIR/lib/msg-story.sh"
source "$SCRIPT_DIR/lib/msg-quality-gate.sh"
source "$SCRIPT_DIR/lib/msg-task-queue.sh"

TEST_INSTANCE="backend"
TEST_ROLE="backend"

detect_my_instance() { echo "$TEST_INSTANCE"; }
_unified_notify() { :; }
_resolve_pane_by_id() { echo ""; }
info() { :; }
log_info() { :; }
log_warn() { :; }
_story_update_task() { :; }
_run_quality_gate() { return 0; }

# mock 让 cmd_claim 能读到 my_role
export STATE_FILE="$RUNTIME_DIR/state.json"
cat > "$STATE_FILE" <<JSON
{"session":"test","panes":[
  {"instance":"backend","pane":"0.1","role":"backend","cli":"claude"},
  {"instance":"database","pane":"0.2","role":"database","cli":"claude"}
]}
JSON

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

TASKS_DIR="$RUNTIME_DIR/tasks"
mkdir -p "$TASKS_DIR/pending" "$TASKS_DIR/processing" "$TASKS_DIR/completed" "$TASKS_DIR/failed"

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }

_mk_task() {
    local id="$1" exec_mode="$2" keys="$3" assigned="$4"
    jq -n --arg id "$id" --arg em "$exec_mode" --argjson keys "$keys" --arg a "$assigned" '
    {
      schema_version: 2, id: $id, type: "implement", from: "human",
      title: ("test " + $id), description: "",
      assigned_to: $a, phase: "implement", phase_owner: $a,
      execution_mode: $em, resource_keys: $keys,
      status: "pending", claimed_by: null, claimed_at: null,
      completed_at: null, result: null, priority: "normal",
      group_id: "", depends_on: [],
      blocked: false, blocked_reason: null, resource_blocked_by: null,
      verify: {}, retry_count: 0, max_retries: 3, flow_log: []
    }' > "$TASKS_DIR/pending/$id.json"
}

# ============================================================================
# Test 1: exclusive 互斥
# ============================================================================
_mk_task "task-A" "exclusive" '["src/api/auth.ts"]' "backend"
_mk_task "task-B" "exclusive" '["src/api/auth.ts"]' "database"

TEST_INSTANCE="backend"; TEST_ROLE="backend"
( cmd_claim "task-A" >/dev/null 2>&1 ) || fail "Test 1a: backend claim task-A 应成功"
[[ -f "$TASKS_DIR/processing/task-A.json" ]] || fail "Test 1a: task-A 应在 processing"

holder=$(jq -r '."src/api/auth.ts".task_id' "$RUNTIME_DIR/resource_locks.json")
[[ "$holder" == "task-A" ]] || fail "Test 1b: resource_locks 应记录 task-A (实际: $holder)"
pass "Test 1a/1b: exclusive claim 获取资源锁"

TEST_INSTANCE="database"; TEST_ROLE="database"
if ( cmd_claim "task-B" >/dev/null 2>&1 ); then
    fail "Test 1c: task-B claim 应因资源冲突失败"
fi
[[ -f "$TASKS_DIR/pending/task-B.json" ]] || fail "Test 1d: task-B 应回退 pending"
blocked_by=$(jq -r '.resource_blocked_by' "$TASKS_DIR/pending/task-B.json")
[[ "$blocked_by" == "task-A" ]] || fail "Test 1e: blocker 应为 task-A (实际: $blocked_by)"
pass "Test 1c/1d/1e: 冲突 claim 被拒绝 + 回退 + 标记 blocker"

# ============================================================================
# Test 2: 释放后可重新获取
# ============================================================================
_release_resources "task-A"
remaining=$(jq -r '."src/api/auth.ts" // "absent"' "$RUNTIME_DIR/resource_locks.json")
[[ "$remaining" == "absent" ]] || fail "Test 2a: 释放后锁应消失 (实际: $remaining)"

TEST_INSTANCE="database"; TEST_ROLE="database"
( cmd_claim "task-B" >/dev/null 2>&1 ) || fail "Test 2b: 释放后 task-B 应可认领"
new_holder=$(jq -r '."src/api/auth.ts".task_id' "$RUNTIME_DIR/resource_locks.json")
[[ "$new_holder" == "task-B" ]] || fail "Test 2c: 新锁应指向 task-B (实际: $new_holder)"
pass "Test 2: 释放后其他任务可认领"

# ============================================================================
# Test 3: parallel 任务不占锁（回归保护）
# ============================================================================
_release_resources "task-B"
rm -f "$TASKS_DIR/processing"/*.json

_mk_task "task-P1" "parallel" '["src/shared/util.ts"]' "backend"
_mk_task "task-P2" "parallel" '["src/shared/util.ts"]' "database"
TEST_INSTANCE="backend"; TEST_ROLE="backend"
( cmd_claim "task-P1" >/dev/null 2>&1 ) || fail "Test 3a: parallel P1 应可认领"
p_holder=$(jq -r '."src/shared/util.ts" // "absent"' "$RUNTIME_DIR/resource_locks.json")
[[ "$p_holder" == "absent" ]] || fail "Test 3b: parallel 不应占锁 (实际: $p_holder)"
TEST_INSTANCE="database"; TEST_ROLE="database"
( cmd_claim "task-P2" >/dev/null 2>&1 ) || fail "Test 3c: parallel P2 应可认领"
pass "Test 3: parallel 任务不占锁"

# ============================================================================
# Test 4: 空 resource_keys 不占锁
# ============================================================================
_mk_task "task-E" "exclusive" '[]' "backend"
TEST_INSTANCE="backend"; TEST_ROLE="backend"
( cmd_claim "task-E" >/dev/null 2>&1 ) || fail "Test 4: 空 resource_keys 的 exclusive 应可认领"
pass "Test 4: 空 resource_keys 不占锁"

# ============================================================================
# Test 5: 多 resource_keys — 部分重叠也冲突
# ============================================================================
rm -rf "$TASKS_DIR"/processing/*.json
echo '{}' > "$RUNTIME_DIR/resource_locks.json"

_mk_task "task-M1" "exclusive" '["file1.ts","file2.ts"]' "backend"
_mk_task "task-M2" "exclusive" '["file2.ts","file3.ts"]' "database"

TEST_INSTANCE="backend"; TEST_ROLE="backend"
( cmd_claim "task-M1" >/dev/null 2>&1 ) || fail "Test 5a: M1 应可认领"
TEST_INSTANCE="database"; TEST_ROLE="database"
if ( cmd_claim "task-M2" >/dev/null 2>&1 ); then
    fail "Test 5b: M2 应因 file2.ts 冲突失败"
fi
blocked_by=$(jq -r '.resource_blocked_by' "$TASKS_DIR/pending/task-M2.json")
[[ "$blocked_by" == "task-M1" ]] || fail "Test 5c: M2 blocker 应为 M1 (实际: $blocked_by)"
pass "Test 5: 部分重叠 resource_keys 正确拒绝"

# ============================================================================
# Test 5.5: 释放资源时级联解阻塞等待者
# ============================================================================
rm -rf "$TASKS_DIR"/processing/*.json "$TASKS_DIR"/pending/*.json
echo '{}' > "$RUNTIME_DIR/resource_locks.json"

_mk_task "task-H" "exclusive" '["lock-res"]' "backend"
_mk_task "task-W1" "exclusive" '["lock-res"]' "backend"
_mk_task "task-W2" "exclusive" '["lock-res","other"]' "database"

TEST_INSTANCE="backend"; TEST_ROLE="backend"
( cmd_claim "task-H" >/dev/null 2>&1 ) || fail "Test 5.5a: H 应可认领"
# 让 W1 / W2 被阻塞
( cmd_claim "task-W1" >/dev/null 2>&1 ) && fail "Test 5.5b: W1 应被阻塞"
TEST_INSTANCE="database"; TEST_ROLE="database"
( cmd_claim "task-W2" >/dev/null 2>&1 ) && fail "Test 5.5c: W2 应被阻塞"

# 验证两者都已标记 resource_blocked_by
[[ "$(jq -r '.resource_blocked_by' "$TASKS_DIR/pending/task-W1.json")" == "task-H" ]] \
    || fail "Test 5.5d: W1 应被 H 阻塞"
[[ "$(jq -r '.resource_blocked_by' "$TASKS_DIR/pending/task-W2.json")" == "task-H" ]] \
    || fail "Test 5.5e: W2 应被 H 阻塞"

# 释放 H 的资源，W1/W2 应自动解阻塞
_release_resources "task-H"

[[ "$(jq -r '.resource_blocked_by // "null"' "$TASKS_DIR/pending/task-W1.json")" == "null" ]] \
    || fail "Test 5.5f: W1 释放后应清 resource_blocked_by"
[[ "$(jq -r '.blocked_reason // "null"' "$TASKS_DIR/pending/task-W1.json")" == "null" ]] \
    || fail "Test 5.5g: W1 释放后应清 blocked_reason"
[[ "$(jq -r '.resource_blocked_by // "null"' "$TASKS_DIR/pending/task-W2.json")" == "null" ]] \
    || fail "Test 5.5h: W2 释放后应清 resource_blocked_by"

# flow_log 应有 unblocked 记录
[[ "$(jq -r '.flow_log[-1].action' "$TASKS_DIR/pending/task-W1.json")" == "unblocked" ]] \
    || fail "Test 5.5i: W1 flow_log 应有 unblocked 记录"

# events.jsonl 应有 resource.released 和 resource.unblocked
grep -q 'resource.released' "$RUNTIME_DIR/events.jsonl" || fail "Test 5.5j: 应发 resource.released 事件"
grep -q 'resource.unblocked' "$RUNTIME_DIR/events.jsonl" || fail "Test 5.5k: 应发 resource.unblocked 事件"

# 解阻塞后 W1 应可被重新认领
TEST_INSTANCE="backend"; TEST_ROLE="backend"
( cmd_claim "task-W1" >/dev/null 2>&1 ) || fail "Test 5.5l: 解阻塞后 W1 应可认领"
pass "Test 5.5: 级联解阻塞正确释放 + 清字段 + 通知"

# ============================================================================
# Test 6: _try_acquire_resources 对同 task_id 幂等
# ============================================================================
echo '{}' > "$RUNTIME_DIR/resource_locks.json"
_try_acquire_resources "task-X" "exclusive" '["foo.ts"]' "backend" >/dev/null \
    || fail "Test 6a: 首次 acquire 应成功"
_try_acquire_resources "task-X" "exclusive" '["foo.ts"]' "backend" >/dev/null \
    || fail "Test 6b: 同 task_id 重复 acquire 应幂等"
pass "Test 6: 同 task_id 重复 acquire 幂等"

# ============================================================================
# Test 7: fail-task retry 必须释放资源（Codex review 发现的回归）
# ============================================================================
# 直接模拟 fail-task retry 后的状态：任务在 pending/，锁应已释放。
# 这里用 _release_resources 模拟 fail-task 里新加的调用。
rm -rf "$TASKS_DIR"/processing/*.json "$TASKS_DIR"/pending/*.json
echo '{}' > "$RUNTIME_DIR/resource_locks.json"

_mk_task "task-RT1" "exclusive" '["retry-res"]' "backend"
TEST_INSTANCE="backend"; TEST_ROLE="backend"
( cmd_claim "task-RT1" >/dev/null 2>&1 ) || fail "Test 7a: RT1 claim"
# 手动模拟 fail-task retry：mv 回 pending + _release_resources
mv "$TASKS_DIR/processing/task-RT1.json" "$TASKS_DIR/pending/task-RT1.json"
_release_resources "task-RT1"
# 现在另一个 agent 应能 claim 同资源
_mk_task "task-RT2" "exclusive" '["retry-res"]' "database"
TEST_INSTANCE="database"; TEST_ROLE="database"
( cmd_claim "task-RT2" >/dev/null 2>&1 ) || fail "Test 7b: 释放后 RT2 应可认领同资源"
pass "Test 7: fail-task retry 释放资源后他人可认领"

# ============================================================================
# Test 8: 静默失败保护 — 锁表损坏时 acquire 必须 fail-closed
# ============================================================================
rm -rf "$TASKS_DIR"/processing/*.json "$TASKS_DIR"/pending/*.json
echo "not-valid-json{" > "$RUNTIME_DIR/resource_locks.json"

_mk_task "task-FC1" "exclusive" '["fc-res"]' "backend"
TEST_INSTANCE="backend"; TEST_ROLE="backend"
if ( cmd_claim "task-FC1" >/dev/null 2>&1 ); then
    fail "Test 8: 锁表损坏时 claim 必须拒绝（fail-closed），不应假成功"
fi
# 任务应退回 pending
[[ -f "$TASKS_DIR/pending/task-FC1.json" ]] || fail "Test 8: 拒绝后任务应回 pending"
pass "Test 8: 锁表损坏时 acquire fail-closed"

# 恢复锁表
echo '{}' > "$RUNTIME_DIR/resource_locks.json"

# ============================================================================
# Test 9: _release_resources 静默失败保护
# ============================================================================
echo '{}' > "$RUNTIME_DIR/resource_locks.json"
_try_acquire_resources "task-R1" "exclusive" '["r1"]' "backend" >/dev/null
# 损坏锁表
echo "broken{" > "$RUNTIME_DIR/resource_locks.json"
# _release_resources 应返回非零
if _release_resources "task-R1" 2>/dev/null; then
    fail "Test 9: 锁表损坏时 release 应返回失败"
fi
pass "Test 9: _release_resources fail-closed"

# ============================================================================
# Test 10: _release_resources_tolerant 成功路径与 _release_resources 一致
# ============================================================================
rm -rf "$TASKS_DIR"/processing/*.json "$TASKS_DIR"/pending/*.json "$TASKS_DIR"/completed/*.json 2>/dev/null
mkdir -p "$TASKS_DIR/completed"
echo '{}' > "$RUNTIME_DIR/resource_locks.json"

_mk_task "task-TOL" "exclusive" '["tol-res"]' "backend"
TEST_INSTANCE="backend"; TEST_ROLE="backend"
( cmd_claim "task-TOL" >/dev/null 2>&1 ) || fail "Test 10a: TOL claim"
# 模拟 complete：移到 completed 后 tolerant 释放
mv "$TASKS_DIR/processing/task-TOL.json" "$TASKS_DIR/completed/task-TOL.json"
_release_resources_tolerant "task-TOL" || fail "Test 10b: tolerant release 应成功"
[[ "$(jq -r '."tol-res" // "absent"' "$RUNTIME_DIR/resource_locks.json")" == "absent" ]] \
    || fail "Test 10c: 释放后锁应消失"
# 成功路径不应打 stale 标记
[[ "$(jq -r '.resource_lock_stale // "null"' "$TASKS_DIR/completed/task-TOL.json")" == "null" ]] \
    || fail "Test 10d: 成功释放不应打 stale 标记"
pass "Test 10: _release_resources_tolerant 成功路径正确"

# ============================================================================
# Test 11: _release_resources_tolerant 锁表损坏时给终态文件打 stale 标记
# ============================================================================
rm -rf "$TASKS_DIR"/completed/*.json 2>/dev/null
echo '{}' > "$RUNTIME_DIR/resource_locks.json"
_try_acquire_resources "task-STALE" "exclusive" '["stale-res"]' "backend" >/dev/null

# 构造终态文件
cat > "$TASKS_DIR/completed/task-STALE.json" <<JSON
{"id":"task-STALE","status":"completed","result":"ok"}
JSON

# 损坏锁表
echo "broken{" > "$RUNTIME_DIR/resource_locks.json"

# 调用 tolerant：应返回 1 并在文件上打 stale
if _release_resources_tolerant "task-STALE" 2>/dev/null; then
    fail "Test 11a: 锁表损坏时 tolerant 应返回失败"
fi
[[ "$(jq -r '.resource_lock_stale // false' "$TASKS_DIR/completed/task-STALE.json")" == "true" ]] \
    || fail "Test 11b: 终态文件应打 resource_lock_stale=true 标记"
pass "Test 11: tolerant 失败时给终态文件打 stale 标记"

# 恢复锁表
echo '{}' > "$RUNTIME_DIR/resource_locks.json"

# ============================================================================
# Test 12: cmd_claim 区分真冲突 (rc=1) vs 锁表错误 (rc=2)
# ============================================================================
rm -rf "$TASKS_DIR"/processing/*.json "$TASKS_DIR"/pending/*.json
echo '{}' > "$RUNTIME_DIR/resource_locks.json"

# 场景 A: 锁表损坏 → claim 应发 lock_system_error 事件，不写空 blocker
echo "bad{json" > "$RUNTIME_DIR/resource_locks.json"
rm -f "$RUNTIME_DIR/events.jsonl"
_mk_task "task-SE" "exclusive" '["se-res"]' "backend"
TEST_INSTANCE="backend"; TEST_ROLE="backend"
if ( cmd_claim "task-SE" >/dev/null 2>&1 ); then
    fail "Test 12a: 锁表损坏时 claim 应失败"
fi
# 事件应是 lock_system_error 而不是 resource.conflict
grep -q 'resource.lock_system_error' "$RUNTIME_DIR/events.jsonl" \
    || fail "Test 12b: 应发 resource.lock_system_error 事件"
grep -q 'resource.conflict' "$RUNTIME_DIR/events.jsonl" \
    && fail "Test 12c: 不应发 resource.conflict 事件"
# resource_blocked_by 不应被写（因为没有真实 blocker）
[[ -f "$TASKS_DIR/pending/task-SE.json" ]] || fail "Test 12d: 任务应回 pending"
blocked_by=$(jq -r '.resource_blocked_by // "null"' "$TASKS_DIR/pending/task-SE.json")
[[ "$blocked_by" == "null" ]] || fail "Test 12e: 系统错误时 resource_blocked_by 不应被写入 (实际: $blocked_by)"
pass "Test 12: claim 区分 lock_system_error 与 resource.conflict"

# 恢复
echo '{}' > "$RUNTIME_DIR/resource_locks.json"

# ============================================================================
# Test 13: cmd_claim 真冲突走 resource.conflict 路径（回归保护）
# ============================================================================
rm -rf "$TASKS_DIR"/processing/*.json "$TASKS_DIR"/pending/*.json
echo '{}' > "$RUNTIME_DIR/resource_locks.json"
rm -f "$RUNTIME_DIR/events.jsonl"

_mk_task "task-CH1" "exclusive" '["ch-res"]' "backend"
_mk_task "task-CH2" "exclusive" '["ch-res"]' "database"
TEST_INSTANCE="backend"; TEST_ROLE="backend"
( cmd_claim "task-CH1" >/dev/null 2>&1 ) || fail "Test 13a: CH1 应可认领"
TEST_INSTANCE="database"; TEST_ROLE="database"
( cmd_claim "task-CH2" >/dev/null 2>&1 ) && fail "Test 13b: CH2 应被 CH1 阻塞"
grep -q 'resource.conflict' "$RUNTIME_DIR/events.jsonl" || fail "Test 13c: 应发 resource.conflict 事件"
grep -q 'resource.lock_system_error' "$RUNTIME_DIR/events.jsonl" && fail "Test 13d: 不应发 lock_system_error"
blocker=$(jq -r '.resource_blocked_by' "$TASKS_DIR/pending/task-CH2.json")
[[ "$blocker" == "task-CH1" ]] || fail "Test 13e: 真冲突时 blocker 应为 CH1"
pass "Test 13: claim 真冲突正确走 resource.conflict"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 所有 resource-locks 测试通过"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
