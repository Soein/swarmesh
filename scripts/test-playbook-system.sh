#!/usr/bin/env bash
################################################################################
# test-playbook-system.sh - capability/playbook 系统回归测试
#
# 覆盖:
#   1. capabilities 配置存在且可校验
#   2. 内置 playbook 存在且可校验
#   3. 正式 playbook 禁止出现 resolved_role / dispatch_mode
#   4. resolve-capability 支持 preferred / fallback / auto_join / unresolved
#   5. suggest-playbook 会生成 candidate 文件
#   6. approve-playbook 只写入 candidate_playbook 本体
#   7. approve-playbook 会拒绝未知 capability
#
# 用法:
#   bash scripts/test-playbook-system.sh
################################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SWARM_INSIGHTS="$ROOT_DIR/scripts/swarm-insights.sh"

TEST_ROOT=$(mktemp -d -t swarm-playbook-XXXXXX)
export PROJECT_DIR="$TEST_ROOT/project"
export RUNTIME_DIR="$TEST_ROOT/runtime"
export SWARM_ROOT="$ROOT_DIR"
STATE_FILE="$RUNTIME_DIR/state.json"

PASS_COUNT=0
FAIL_COUNT=0
FAIL_MESSAGES=()

cleanup_test_root() {
    [[ "${BASH_SUBSHELL:-0}" -eq 0 ]] || return 0
    rm -rf "$TEST_ROOT"
}

trap cleanup_test_root EXIT

section() {
    printf '\n\033[1;34m═══ %s ═══\033[0m\n' "$1"
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  \033[31m✗\033[0m %s\n' "$label"
        printf '      expected: %s\n' "$expected"
        printf '      actual:   %s\n' "$actual"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_MESSAGES+=("$label")
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  \033[31m✗\033[0m %s\n' "$label"
        printf '      needle:   %s\n' "$needle"
        printf '      haystack: %s\n' "$haystack"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_MESSAGES+=("$label")
    fi
}

assert_file_exists() {
    local label="$1" file="$2"
    if [[ -f "$file" ]]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  \033[31m✗\033[0m %s\n' "$label"
        printf '      missing: %s\n' "$file"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_MESSAGES+=("$label")
    fi
}

assert_nonzero() {
    local label="$1" actual="$2"
    if [[ "$actual" -ne 0 ]]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  \033[31m✗\033[0m %s\n' "$label"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_MESSAGES+=("$label")
    fi
}

setup_runtime() {
    rm -rf "$RUNTIME_DIR" "$PROJECT_DIR"
    mkdir -p \
        "$PROJECT_DIR/.swarm" \
        "$RUNTIME_DIR/tasks/groups" \
        "$RUNTIME_DIR/tasks/completed" \
        "$RUNTIME_DIR/tasks/pending" \
        "$RUNTIME_DIR/tasks/processing" \
        "$RUNTIME_DIR/tasks/failed" \
        "$RUNTIME_DIR/tasks/blocked" \
        "$RUNTIME_DIR/tasks/paused" \
        "$RUNTIME_DIR/tasks/pending_review" \
        "$RUNTIME_DIR/stories" \
        "$RUNTIME_DIR/playbook-candidates"

    jq -n '{
        session: "test-session",
        project: "tmp-project",
        panes: []
    }' > "$STATE_FILE"
}

write_state_with_panes() {
    local panes_json="$1"
    jq -n --argjson panes "$panes_json" '{
        session: "test-session",
        project: "tmp-project",
        panes: $panes
    }' > "$STATE_FILE"
}

run_insights() {
    env \
        SWARM_ROOT="$ROOT_DIR" \
        PROJECT_DIR="$PROJECT_DIR" \
        RUNTIME_DIR="$RUNTIME_DIR" \
        STATE_FILE="$STATE_FILE" \
        bash "$SWARM_INSIGHTS" "$@"
}

section "Test 1: capabilities 配置"
capabilities_file="$ROOT_DIR/config/orchestration/capabilities.json"
assert_file_exists "capabilities.json 存在" "$capabilities_file"
set +e
cap_output=$(run_insights validate-capabilities "$capabilities_file" 2>&1)
cap_rc=$?
set -e
assert_eq "validate-capabilities 成功" "0" "$cap_rc"

section "Test 2: 内置 playbook"
for playbook in single-module-change parallel-feature bugfix-chain refactor-delivery analysis-audit; do
    playbook_file="$ROOT_DIR/config/orchestration/playbooks/${playbook}.json"
    assert_file_exists "$playbook playbook 存在" "$playbook_file"
    set +e
    playbook_output=$(run_insights validate-playbook "$playbook_file" 2>&1)
    playbook_rc=$?
    set -e
    assert_eq "$playbook validate-playbook 成功" "0" "$playbook_rc"
done

section "Test 3: 正式 playbook 禁止 resolved_role / dispatch_mode"
invalid_playbook="$TEST_ROOT/invalid-playbook.json"
cat > "$invalid_playbook" <<'EOF'
{
  "id": "invalid-playbook",
  "name": "非法 playbook",
  "strategy_hint": "parallel-by-module",
  "plan_template": [
    {
      "id": "backend-api",
      "title": "实现后端接口",
      "required_capability": "backend_dev",
      "resolved_role": "backend",
      "dispatch_mode": "existing_role"
    }
  ]
}
EOF
set +e
invalid_output=$(run_insights validate-playbook "$invalid_playbook" 2>&1)
invalid_rc=$?
set -e
assert_nonzero "非法 playbook 校验失败" "$invalid_rc"
assert_contains "非法 playbook 提示 resolved_role" "$invalid_output" "resolved_role"

section "Test 4: resolve-capability"
setup_runtime
write_state_with_panes '[
  {"instance":"backend","role":"backend","pane":"0.0","cli":"claude chat","log":""},
  {"instance":"reviewer","role":"reviewer","pane":"0.1","cli":"codex chat","log":""},
  {"instance":"integrator","role":"integrator","pane":"0.2","cli":"codex chat","log":""}
]'
preferred_json=$(run_insights resolve-capability backend_dev)
assert_eq "preferred 命中 dispatch_mode" "existing_role" "$(jq -r '.dispatch_mode' <<<"$preferred_json")"
assert_eq "preferred 命中 resolved_role" "backend" "$(jq -r '.resolved_role' <<<"$preferred_json")"

fallback_json=$(run_insights resolve-capability security_audit)
assert_eq "fallback 命中 dispatch_mode" "fallback_role" "$(jq -r '.dispatch_mode' <<<"$fallback_json")"
assert_eq "fallback 命中 resolved_role" "reviewer" "$(jq -r '.resolved_role' <<<"$fallback_json")"

setup_runtime
write_state_with_panes '[]'
auto_join_json=$(run_insights resolve-capability backend_dev)
assert_eq "auto_join dispatch_mode" "new_role" "$(jq -r '.dispatch_mode' <<<"$auto_join_json")"
assert_eq "auto_join role" "backend" "$(jq -r '.resolved_role' <<<"$auto_join_json")"
assert_contains "auto_join 含 join command" "$auto_join_json" "swarm-join.sh"

unresolved_json=$(run_insights resolve-capability integration)
assert_eq "unresolved dispatch_mode" "unresolved" "$(jq -r '.dispatch_mode' <<<"$unresolved_json")"
assert_eq "unresolved role 为空" "" "$(jq -r '.resolved_role // ""' <<<"$unresolved_json")"

section "Test 5: suggest-playbook 生成 candidate"
setup_runtime
write_state_with_panes '[
  {"instance":"backend","role":"backend","pane":"0.0","cli":"claude chat","log":""},
  {"instance":"frontend","role":"frontend","pane":"0.1","cli":"gemini --approval-mode yolo","log":""},
  {"instance":"integrator","role":"integrator","pane":"0.2","cli":"codex chat","log":""}
]'

group_id="group-auth"
jq -n --arg id "$group_id" '{
    id: $id,
    title: "认证功能",
    from: "human",
    created_at: "2026-04-10 16:00:00",
    status: "completed",
    tasks: ["task-backend","task-frontend"],
    completed_count: 2,
    total_count: 2
}' > "$RUNTIME_DIR/tasks/groups/${group_id}.json"

jq -n '{
    id: "group-auth",
    title: "认证功能",
    from: "human",
    created_at: "2026-04-10 16:00:00",
    status: "completed",
    prd: null,
    tasks: [
      {"id":"task-backend","title":"实现注册 API","type":"develop","assigned_to":"backend","phase":"done","status":"completed","result":"后端完成"},
      {"id":"task-frontend","title":"实现注册页面","type":"develop","assigned_to":"frontend","phase":"done","status":"completed","result":"前端完成"}
    ],
    verifications: [],
    timeline: ["2026-04-10 16:00:00 任务组创建 by human"]
}' > "$RUNTIME_DIR/stories/${group_id}.json"

jq -n '{
    id: "task-backend",
    title: "实现注册 API",
    assigned_to: "backend",
    phase: "done",
    status: "completed",
    completed_at: "2026-04-10 16:10:00",
    claimed_by: "backend",
    phase_payloads: {},
    phase_history: [{"phase":"implement","owner":"backend","completed_at":"2026-04-10 16:10:00","result":"后端完成"}],
    flow_log: [{"ts":"2026-04-10 16:00:00","action":"published","from_status":"-","to_status":"pending","actor":"human","detail":"实现注册 API [implement]"}]
}' > "$RUNTIME_DIR/tasks/completed/task-backend.json"

jq -n '{
    id: "task-frontend",
    title: "实现注册页面",
    assigned_to: "frontend",
    phase: "done",
    status: "completed",
    completed_at: "2026-04-10 16:12:00",
    claimed_by: "frontend",
    phase_payloads: {},
    phase_history: [{"phase":"implement","owner":"frontend","completed_at":"2026-04-10 16:12:00","result":"前端完成"}],
    flow_log: [{"ts":"2026-04-10 16:01:00","action":"published","from_status":"-","to_status":"pending","actor":"human","detail":"实现注册页面 [implement]"}]
}' > "$RUNTIME_DIR/tasks/completed/task-frontend.json"

candidate_path=$(run_insights suggest-playbook "$group_id")
assert_file_exists "candidate 文件生成" "$candidate_path"
assert_eq "candidate.status" "candidate" "$(jq -r '.status' "$candidate_path")"
assert_eq "candidate 首个 capability" "backend_dev" "$(jq -r '.candidate_playbook.plan_template[0].required_capability' "$candidate_path")"

section "Test 6: approve-playbook 只写 playbook 本体"
approved_file="$ROOT_DIR/config/orchestration/playbooks/test-approved-playbook.json"
rm -f "$approved_file"
run_insights approve-playbook "$candidate_path" --as "test-approved-playbook" >/dev/null
assert_file_exists "approved playbook 写入正式库" "$approved_file"
assert_eq "approved id 已覆盖" "test-approved-playbook" "$(jq -r '.id' "$approved_file")"
assert_eq "approved 不含 evidence" "false" "$(jq 'has("evidence")' "$approved_file")"
rm -f "$approved_file"

section "Test 7: approve-playbook 拒绝未知 capability"
bad_candidate="$TEST_ROOT/bad-candidate.json"
cat > "$bad_candidate" <<'EOF'
{
  "schema_version": 1,
  "source_group_id": "group-bad",
  "derived_from": {"workflow": "quick-task", "task_ids": ["task-bad"]},
  "candidate_playbook": {
    "id": "candidate-bad",
    "name": "坏候选",
    "strategy_hint": "serial-by-dependency",
    "plan_template": [
      {
        "id": "bad-step",
        "title": "坏步骤",
        "required_capability": "unknown_capability"
      }
    ]
  },
  "evidence": {},
  "status": "candidate"
}
EOF
set +e
bad_output=$(run_insights approve-playbook "$bad_candidate" --as "bad-approved" 2>&1)
bad_rc=$?
set -e
assert_nonzero "未知 capability approve 失败" "$bad_rc"
assert_contains "未知 capability 错误信息" "$bad_output" "unknown_capability"

printf '\n'
if [[ $FAIL_COUNT -eq 0 ]]; then
    printf '\033[32m全部通过\033[0m: %d 个断言\n' "$PASS_COUNT"
    exit 0
fi

printf '\033[31m失败\033[0m: %d 个断言失败，%d 个通过\n' "$FAIL_COUNT" "$PASS_COUNT"
printf '失败用例:\n'
for msg in "${FAIL_MESSAGES[@]}"; do
    printf '  - %s\n' "$msg"
done
exit 1
