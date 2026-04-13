#!/usr/bin/env bash
################################################################################
# test-kernel-v2.sh - 任务内核 V2 回归测试
#
# 覆盖:
#   1. publish 写入新任务契约字段
#   2. research 完成后只能进入 synthesize
#   3. synthesize 缺少 orchestration_plan 时拒绝进入 implement
#   4. synthesize step 缺少 required_capability 时拒绝进入 implement
#   5. synthesize 输出 capability-based orchestration_plan 后进入 implement
#   6. implement 如承接 synthesize 计划，缺少 dispatch_receipts 时拒绝进入 integrate
#   7. implement 的 manual_override 缺少原因/风险时拒绝进入 integrate
#   8. implement 消费 synthesize 计划后必须进入 integrate
#   9. integrate 完成后必须进入 verify
#   10. 只有任务组整体完成后才允许通知 human
#   11. write 任务允许空 resource_keys，且相同 resource_keys 也允许并发认领
#   12. resume 缺少快照或 schema_version 不匹配时拒绝恢复
#
# 用法:
#   bash scripts/test-kernel-v2.sh
################################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export SWARM_ROOT="$ROOT_DIR"

TEST_ROOT=$(mktemp -d -t swarm-kernel-v2-XXXXXX)
export RUNTIME_DIR="$TEST_ROOT/runtime"
export PROJECT_DIR="$TEST_ROOT/project"
NOTIFY_LOG="$TEST_ROOT/notify.log"
EVENT_LOG="$TEST_ROOT/events.log"

mkdir -p "$PROJECT_DIR" "$RUNTIME_DIR"
git -C "$PROJECT_DIR" init >/dev/null 2>&1

source "$SCRIPT_DIR/swarm-lib.sh"
source "$SCRIPT_DIR/lib/msg-story.sh"
source "$SCRIPT_DIR/lib/msg-quality-gate.sh"
source "$SCRIPT_DIR/lib/msg-task-queue.sh"

PASS_COUNT=0
FAIL_COUNT=0
FAIL_MESSAGES=()
TEST_INSTANCE="human"

cleanup_test_root() {
    [[ "${BASH_SUBSHELL:-0}" -eq 0 ]] || return 0
    rm -rf "$TEST_ROOT"
}

trap cleanup_test_root EXIT

detect_my_instance() {
    echo "$TEST_INSTANCE"
}

_unified_notify() {
    local to="$1" content="$2" category="${3:-default}" priority="${4:-normal}"
    mkdir -p "$(dirname "$NOTIFY_LOG")"
    printf '%s\t%s\t%s\t%s\n' "$to" "$category" "$priority" "$content" >> "$NOTIFY_LOG"
}

emit_event() {
    mkdir -p "$(dirname "$EVENT_LOG")"
    printf '%s\n' "$*" >> "$EVENT_LOG"
}

_run_quality_gate() {
    return 0
}

_check_subtask_completion() {
    return 0
}

info() {
    return 0
}

warn() {
    return 0
}

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

assert_file_not_exists() {
    local label="$1" file="$2"
    if [[ ! -f "$file" ]]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  \033[31m✗\033[0m %s\n' "$label"
        printf '      unexpected file: %s\n' "$file"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_MESSAGES+=("$label")
    fi
}

assert_notify_count() {
    local label="$1" target="$2" expected="$3"
    local actual=0
    if [[ -f "$NOTIFY_LOG" ]]; then
        actual=$(awk -F'\t' -v t="$target" '$1 == t { count++ } END { print count + 0 }' "$NOTIFY_LOG")
    fi
    assert_eq "$label" "$expected" "$actual"
}

setup_runtime() {
    rm -rf "$RUNTIME_DIR"
    mkdir -p \
        "$TASKS_DIR/pending" \
        "$TASKS_DIR/processing" \
        "$TASKS_DIR/completed" \
        "$TASKS_DIR/failed" \
        "$TASKS_DIR/blocked" \
        "$TASKS_DIR/paused" \
        "$TASKS_DIR/pending_review" \
        "$TASKS_DIR/groups" \
        "$RUNTIME_DIR/stories" \
        "$MESSAGES_DIR/inbox/human" \
        "$MESSAGES_DIR/outbox/human"
    : > "$NOTIFY_LOG"
    : > "$EVENT_LOG"

    jq -n \
        --arg project "$PROJECT_DIR" \
        '{
            session: "test-session",
            profile: "minimal",
            project: $project,
            panes: [
              {instance:"human", role:"human", pane:"0.0", cli:"shell", log:""},
              {instance:"researcher", role:"researcher", pane:"0.1", cli:"shell", log:""},
              {instance:"synthesizer", role:"synthesizer", pane:"0.2", cli:"shell", log:""},
              {instance:"implementer", role:"implementer", pane:"0.3", cli:"shell", log:""},
              {instance:"integrator", role:"integrator", pane:"0.4", cli:"shell", log:""},
              {instance:"reviewer", role:"reviewer", pane:"0.5", cli:"shell", log:""},
              {instance:"implementer-2", role:"implementer", pane:"0.6", cli:"shell", log:""},
              {instance:"supervisor", role:"supervisor", pane:"0.7", cli:"shell", log:""}
            ]
        }' > "$STATE_FILE"
}

build_contract() {
    local phase="$1"
    local impact_scope="${2:-read_only}"
    local execution_mode="${3:-parallel}"
    local resource_keys="${4:-[]}"

    jq -nc \
        --arg phase "$phase" \
        --arg impact_scope "$impact_scope" \
        --arg execution_mode "$execution_mode" \
        --argjson resource_keys "$resource_keys" \
        '{
            phase: $phase,
            phase_assignments: {
                research: "researcher",
                synthesize: "synthesizer",
                implement: "implementer",
                integrate: "integrator",
                verify: "reviewer"
            },
            inputs: ["需求文档", "现有代码"],
            expected_outputs: ["facts.md", "spec.md"],
            acceptance_criteria: ["遵循任务契约", "只输出当前阶段允许的产物"],
            impact_scope: $impact_scope,
            execution_mode: $execution_mode,
            resource_keys: $resource_keys,
            handoff_format: "markdown"
        }'
}

build_synthesize_payload() {
    local steps_json="${1:-}"

    if [[ -n "$steps_json" ]]; then
        jq -nc \
            --argjson steps "$steps_json" \
            '{
                spec: {
                    summary: "将调研事实转成可执行 spec",
                    deliverables: ["子任务清单", "依赖关系", "验收重点"]
                },
                orchestration_plan: {
                    strategy_hint: "parallel-by-module",
                    steps: $steps
                }
            }'
        return 0
    fi

    jq -nc '{
        spec: {
            summary: "将调研事实转成可执行 spec",
            deliverables: ["子任务清单", "依赖关系", "验收重点"]
        },
        orchestration_plan: {
            playbook_id: "parallel-feature",
            strategy_hint: "parallel-by-module",
            risk_checks: ["接口契约是否前置明确"],
            integration_focus: ["前后端接口一致性"],
            steps: [
                {
                    id: "plan-backend",
                    title: "派发后端任务",
                    required_capability: "backend_dev",
                    depends_on: [],
                    resolution: {
                        suggested_role: "implementer",
                        suggested_dispatch_mode: "existing_role",
                        suggested_join_command: ""
                    }
                },
                {
                    id: "plan-frontend",
                    title: "派发前端任务",
                    required_capability: "frontend_dev",
                    depends_on: ["plan-backend"],
                    resolution: {
                        suggested_role: "implementer-2",
                        suggested_dispatch_mode: "existing_role",
                        suggested_join_command: ""
                    }
                }
            ]
        }
    }'
}

build_implement_payload() {
    local executed_json="${1:-}"
    local published_json="${2:-}"
    local receipts_json="${3:-}"

    if [[ -n "$executed_json" && -n "$published_json" && -n "$receipts_json" ]]; then
        jq -nc \
            --argjson executed "$executed_json" \
            --argjson published "$published_json" \
            --argjson receipts "$receipts_json" \
            '{
                summary: "已按计划派发实现任务",
                executed_plan_step_ids: $executed,
                published_tasks: $published,
                dispatch_receipts: $receipts
            }'
        return 0
    fi

    jq -nc '{
        summary: "已按计划派发实现任务",
        executed_plan_step_ids: ["plan-backend", "plan-frontend"],
        published_tasks: ["task-sub-1", "task-sub-2"],
        dispatch_receipts: [
            {
                step_id: "plan-backend",
                required_capability: "backend_dev",
                suggested_role: "implementer",
                suggested_dispatch_mode: "existing_role",
                final_role: "implementer",
                final_dispatch_mode: "existing_role",
                resolution_source: "auto",
                resolution_reason: "",
                resolution_risk: "",
                published_task_id: "task-sub-1"
            },
            {
                step_id: "plan-frontend",
                required_capability: "frontend_dev",
                suggested_role: "implementer-2",
                suggested_dispatch_mode: "existing_role",
                final_role: "implementer",
                final_dispatch_mode: "existing_role",
                resolution_source: "manual_override",
                resolution_reason: "实现上下文集中在同一个工蜂更快",
                resolution_risk: "需要 verify 重点检查前端联调结果",
                published_task_id: "task-sub-2"
            }
        ]
    }'
}

publish_task() {
    local type="$1" title="$2" contract_json="$3"
    TEST_INSTANCE="human"
    cmd_publish "$type" "$title" \
        --description "测试任务: $title" \
        --priority high \
        --contract "$contract_json" | tail -n 1 | tr -d '\r'
}

section "Test 1: publish 写入 V2 契约"
setup_runtime
contract=$(build_contract "research" "write" "exclusive" '["repo:kernel"]')
task_id=$(publish_task "orchestrate" "实现新任务模型" "$contract")
task_file="$TASKS_DIR/pending/${task_id}.json"
assert_file_exists "publish 生成 pending 任务文件" "$task_file"
assert_eq "schema_version == 2" "2" "$(jq -r '.schema_version' "$task_file")"
assert_eq "phase == research" "research" "$(jq -r '.phase' "$task_file")"
assert_eq "phase_owner == researcher" "researcher" "$(jq -r '.phase_owner' "$task_file")"
assert_eq "impact_scope == write" "write" "$(jq -r '.impact_scope' "$task_file")"
assert_eq "execution_mode == exclusive" "exclusive" "$(jq -r '.execution_mode' "$task_file")"
assert_eq "resource_keys[0]" "repo:kernel" "$(jq -r '.resource_keys[0]' "$task_file")"
assert_eq "inputs 数量 == 2" "2" "$(jq '.inputs | length' "$task_file")"
assert_eq "expected_outputs 数量 == 2" "2" "$(jq '.expected_outputs | length' "$task_file")"
assert_eq "acceptance_criteria 数量 == 2" "2" "$(jq '.acceptance_criteria | length' "$task_file")"
assert_eq "handoff_format == markdown" "markdown" "$(jq -r '.handoff_format' "$task_file")"

section "Test 2: research 完成后进入 synthesize"
setup_runtime
task_id=$(publish_task "analysis" "研究现状" "$(build_contract "research")")
TEST_INSTANCE="researcher"
cmd_claim "$task_id" >/dev/null
cmd_complete_task "$task_id" "这里只记录事实，不给方案" >/dev/null
pending_after_research="$TASKS_DIR/pending/${task_id}.json"
assert_file_exists "research 完成后任务回到 pending" "$pending_after_research"
assert_file_not_exists "research 完成后不会直接 completed" "$TASKS_DIR/completed/${task_id}.json"
assert_eq "phase 推进到 synthesize" "synthesize" "$(jq -r '.phase' "$pending_after_research")"
assert_eq "phase_owner 推进到 synthesizer" "synthesizer" "$(jq -r '.phase_owner' "$pending_after_research")"
assert_eq "assigned_to 同步为 synthesizer" "synthesizer" "$(jq -r '.assigned_to' "$pending_after_research")"
assert_eq "research 结果写入 phase_results" "这里只记录事实，不给方案" "$(jq -r '.phase_results.research' "$pending_after_research")"
assert_notify_count "research 完成后不通知 human" "human" "0"
assert_notify_count "research 完成后通知下游 synthesizer" "synthesizer" "1"

section "Test 3: synthesize 缺少 orchestration_plan 时拒绝进入 implement"
setup_runtime
task_id=$(publish_task "orchestrate" "生成执行计划" "$(build_contract "synthesize")")
TEST_INSTANCE="synthesizer"
cmd_claim "$task_id" >/dev/null
set +e
missing_plan_output=$(cmd_complete_task "$task_id" '{"spec":{"summary":"只有 spec，没有计划"}}' 2>&1)
missing_plan_rc=$?
set -e
assert_nonzero "synthesize 缺少 orchestration_plan 时 complete-task 失败" "$missing_plan_rc"
assert_contains "缺少 orchestration_plan 错误信息" "$missing_plan_output" "orchestration_plan"
assert_file_exists "失败后任务仍留在 processing" "$TASKS_DIR/processing/${task_id}.json"
assert_file_not_exists "失败后不会推进到 pending implement" "$TASKS_DIR/pending/${task_id}.json"

section "Test 4: synthesize step 缺少 required_capability 时拒绝进入 implement"
setup_runtime
task_id=$(publish_task "orchestrate" "生成执行计划" "$(build_contract "synthesize")")
TEST_INSTANCE="synthesizer"
cmd_claim "$task_id" >/dev/null
set +e
missing_cap_output=$(cmd_complete_task "$task_id" '{"spec":{"summary":"将调研事实转成可执行 spec"},"orchestration_plan":{"steps":[{"id":"plan-backend","title":"派发后端任务"}]}}' 2>&1)
missing_cap_rc=$?
set -e
assert_nonzero "synthesize step 缺少 required_capability 时 complete-task 失败" "$missing_cap_rc"
assert_contains "缺少 required_capability 错误信息" "$missing_cap_output" "required_capability"
assert_file_exists "缺 capability 后任务仍留在 processing" "$TASKS_DIR/processing/${task_id}.json"
assert_file_not_exists "缺 capability 后不会推进到 pending implement" "$TASKS_DIR/pending/${task_id}.json"

section "Test 5: synthesize 输出 capability-based orchestration_plan 后进入 implement"
setup_runtime
task_id=$(publish_task "orchestrate" "生成执行计划" "$(build_contract "synthesize")")
TEST_INSTANCE="synthesizer"
cmd_claim "$task_id" >/dev/null
cmd_complete_task "$task_id" "$(build_synthesize_payload)" >/dev/null
pending_after_synthesize="$TASKS_DIR/pending/${task_id}.json"
assert_file_exists "synthesize 完成后任务回到 pending" "$pending_after_synthesize"
assert_eq "phase 推进到 implement" "implement" "$(jq -r '.phase' "$pending_after_synthesize")"
assert_eq "phase_owner 推进到 implementer" "implementer" "$(jq -r '.phase_owner' "$pending_after_synthesize")"
assert_eq "synthesize spec 已结构化保存" "将调研事实转成可执行 spec" "$(jq -r '.phase_payloads.synthesize.spec.summary' "$pending_after_synthesize")"
assert_eq "orchestration_plan step 数量 == 2" "2" "$(jq '.phase_payloads.synthesize.orchestration_plan.steps | length' "$pending_after_synthesize")"
assert_eq "第一个 step capability 已保存" "backend_dev" "$(jq -r '.phase_payloads.synthesize.orchestration_plan.steps[0].required_capability' "$pending_after_synthesize")"
assert_eq "第二个 step resolution.suggested_role 已保存" "implementer-2" "$(jq -r '.phase_payloads.synthesize.orchestration_plan.steps[1].resolution.suggested_role' "$pending_after_synthesize")"
assert_notify_count "synthesize 完成后不通知 human" "human" "0"
assert_notify_count "synthesize 完成后通知 implementer" "implementer" "1"

section "Test 6: implement 如承接 synthesize 计划，缺少 dispatch_receipts 时拒绝进入 integrate"
setup_runtime
task_id=$(publish_task "orchestrate" "执行计划派发" "$(build_contract "synthesize")")
TEST_INSTANCE="synthesizer"
cmd_claim "$task_id" >/dev/null
cmd_complete_task "$task_id" "$(build_synthesize_payload)" >/dev/null
TEST_INSTANCE="implementer"
cmd_claim "$task_id" >/dev/null
set +e
missing_receipt_output=$(cmd_complete_task "$task_id" '{"summary":"已经派发，但没写 dispatch_receipts","executed_plan_step_ids":["plan-backend","plan-frontend"],"published_tasks":["task-sub-1","task-sub-2"]}' 2>&1)
missing_receipt_rc=$?
set -e
assert_nonzero "implement 缺少 dispatch_receipts 时 complete-task 失败" "$missing_receipt_rc"
assert_contains "缺少 dispatch_receipts 错误信息" "$missing_receipt_output" "dispatch_receipts"
assert_file_exists "implement 失败后任务仍留在 processing" "$TASKS_DIR/processing/${task_id}.json"
assert_eq "implement 失败后 phase 仍为 implement" "implement" "$(jq -r '.phase' "$TASKS_DIR/processing/${task_id}.json")"

section "Test 7: implement 的 manual_override 缺少原因/风险时拒绝进入 integrate"
setup_runtime
task_id=$(publish_task "orchestrate" "执行计划派发" "$(build_contract "synthesize")")
TEST_INSTANCE="synthesizer"
cmd_claim "$task_id" >/dev/null
cmd_complete_task "$task_id" "$(build_synthesize_payload)" >/dev/null
TEST_INSTANCE="implementer"
cmd_claim "$task_id" >/dev/null
bad_override_receipts=$(jq -nc '[
    {
        step_id: "plan-backend",
        required_capability: "backend_dev",
        suggested_role: "implementer",
        suggested_dispatch_mode: "existing_role",
        final_role: "implementer",
        final_dispatch_mode: "existing_role",
        resolution_source: "auto",
        resolution_reason: "",
        resolution_risk: "",
        published_task_id: "task-sub-1"
    },
    {
        step_id: "plan-frontend",
        required_capability: "frontend_dev",
        suggested_role: "implementer-2",
        suggested_dispatch_mode: "existing_role",
        final_role: "implementer",
        final_dispatch_mode: "existing_role",
        resolution_source: "manual_override",
        resolution_reason: "",
        resolution_risk: "",
        published_task_id: "task-sub-2"
    }
]')
set +e
bad_override_output=$(cmd_complete_task "$task_id" "$(build_implement_payload '["plan-backend","plan-frontend"]' '["task-sub-1","task-sub-2"]' "$bad_override_receipts")" 2>&1)
bad_override_rc=$?
set -e
assert_nonzero "manual_override 缺少原因/风险时 complete-task 失败" "$bad_override_rc"
assert_contains "manual_override 缺少原因/风险错误信息" "$bad_override_output" "manual_override"
assert_file_exists "manual_override 缺原因时任务仍留在 processing" "$TASKS_DIR/processing/${task_id}.json"

section "Test 8: implement 消费 synthesize 计划后必须进入 integrate"
setup_runtime
task_id=$(publish_task "orchestrate" "执行计划派发" "$(build_contract "synthesize")")
TEST_INSTANCE="synthesizer"
cmd_claim "$task_id" >/dev/null
cmd_complete_task "$task_id" "$(build_synthesize_payload)" >/dev/null
TEST_INSTANCE="implementer"
cmd_claim "$task_id" >/dev/null
cmd_complete_task "$task_id" "$(build_implement_payload)" >/dev/null
pending_after_impl="$TASKS_DIR/pending/${task_id}.json"
assert_file_exists "implement 完成后任务回到 pending" "$pending_after_impl"
assert_file_not_exists "implement 完成后不会直接 completed" "$TASKS_DIR/completed/${task_id}.json"
assert_eq "phase 推进到 integrate" "integrate" "$(jq -r '.phase' "$pending_after_impl")"
assert_eq "phase_owner 推进到 integrator" "integrator" "$(jq -r '.phase_owner' "$pending_after_impl")"
assert_eq "implement 执行回执已保存" "2" "$(jq '.phase_payloads.implement.executed_plan_step_ids | length' "$pending_after_impl")"
assert_eq "dispatch_receipts 已保存" "2" "$(jq '.phase_payloads.implement.dispatch_receipts | length' "$pending_after_impl")"
assert_eq "manual override 已留痕" "manual_override" "$(jq -r '.phase_payloads.implement.dispatch_receipts[1].resolution_source' "$pending_after_impl")"
assert_notify_count "implement 完成后不通知 human" "human" "0"
assert_notify_count "implement 完成后通知 integrator" "integrator" "1"

section "Test 9: integrate 完成后必须进入 verify"
setup_runtime
task_id=$(publish_task "develop" "集成实现结果" "$(build_contract "integrate" "write" "exclusive" '["repo:kernel"]')")
TEST_INSTANCE="integrator"
cmd_claim "$task_id" >/dev/null
cmd_complete_task "$task_id" "分支已合并，接口已对齐" >/dev/null
pending_after_integrate="$TASKS_DIR/pending/${task_id}.json"
assert_file_exists "integrate 完成后任务回到 pending" "$pending_after_integrate"
assert_file_not_exists "integrate 完成后不会直接 completed" "$TASKS_DIR/completed/${task_id}.json"
assert_eq "phase 推进到 verify" "verify" "$(jq -r '.phase' "$pending_after_integrate")"
assert_eq "phase_owner 推进到 reviewer" "reviewer" "$(jq -r '.phase_owner' "$pending_after_integrate")"
assert_notify_count "integrate 完成后不通知 human" "human" "0"
assert_notify_count "integrate 完成后通知 reviewer" "reviewer" "1"

section "Test 10: 只有任务组整体完成后才通知 human"
setup_runtime
group_id="group-static-1"

jq -n \
    --arg id "$group_id" \
    --arg title "整体汇报测试" \
    --arg from "human" \
    --arg created_at "$(get_timestamp)" \
    '{
        id: $id,
        title: $title,
        from: $from,
        created_at: $created_at,
        status: "active",
        tasks: ["task-group-a", "task-group-b"],
        completed_count: 1,
        total_count: 2
    }' > "$TASKS_DIR/groups/${group_id}.json"

jq -n \
    --arg id "task-group-a" \
    --arg group_id "$group_id" \
    --arg from "human" \
    --arg title "任务 A" \
    --arg created_at "$(get_timestamp)" \
    '{
        schema_version: 2,
        id: $id,
        group_id: $group_id,
        from: $from,
        title: $title,
        status: "completed",
        phase: "done",
        created_at: $created_at
    }' > "$TASKS_DIR/completed/task-group-a.json"

_check_group_completion "task-group-a"
assert_notify_count "组内首个子任务完成后不通知 human" "human" "0"

jq -n \
    --arg id "task-group-b" \
    --arg group_id "$group_id" \
    --arg from "human" \
    --arg title "任务 B" \
    --arg created_at "$(get_timestamp)" \
    '{
        schema_version: 2,
        id: $id,
        group_id: $group_id,
        from: $from,
        title: $title,
        status: "completed",
        phase: "done",
        created_at: $created_at
    }' > "$TASKS_DIR/completed/task-group-b.json"

_check_group_completion "task-group-b"
assert_notify_count "任务组整体完成后通知 human 一次" "human" "1"
assert_eq "任务组状态 == completed" "completed" "$(jq -r '.status' "$TASKS_DIR/groups/${group_id}.json")"

section "Test 11: exclusive 任务的 resource_keys 必须真正互斥（Codex/Claude 交叉审查发现的空壳约束修复）"
setup_runtime
task_without_keys=$(publish_task "develop" "写 kernel C" "$(build_contract "implement" "write" "exclusive" '[]')")
assert_file_exists "空 resource_keys 的 exclusive 任务仍可发布" "$TASKS_DIR/pending/${task_without_keys}.json"
assert_eq "空 resource_keys 会原样保留" "0" "$(jq '.resource_keys | length' "$TASKS_DIR/pending/${task_without_keys}.json")"

setup_runtime
task_a=$(publish_task "develop" "写 kernel A" "$(build_contract "implement" "write" "exclusive" '["repo:kernel"]')")
task_b=$(publish_task "develop" "写 kernel B" "$(build_contract "implement" "write" "exclusive" '["repo:kernel"]')")
TEST_INSTANCE="implementer"
cmd_claim "$task_a" >/dev/null
TEST_INSTANCE="implementer-2"
# 第二个 exclusive claim 必须失败：资源被 task_a 独占
if ( cmd_claim "$task_b" >/dev/null 2>&1 ); then
    assert_eq "第二个 exclusive claim 应被资源冲突拒绝" "expected_fail" "claim_succeeded"
else
    assert_eq "第二个 exclusive claim 被资源冲突拒绝" "expected_fail" "expected_fail"
fi
assert_file_not_exists "第二个任务不应进入 processing" "$TASKS_DIR/processing/${task_b}.json"
assert_file_exists "第二个任务应回退 pending" "$TASKS_DIR/pending/${task_b}.json"
assert_eq "blocked_reason 被标记为 resource_conflict" "resource_conflict" "$(jq -r '.blocked_reason // "null"' "$TASKS_DIR/pending/${task_b}.json")"
assert_eq "resource_blocked_by 指向 task_a" "$task_a" "$(jq -r '.resource_blocked_by // "null"' "$TASKS_DIR/pending/${task_b}.json")"

# parallel 任务仍允许共享 resource_keys（回归保护）
setup_runtime
task_p1=$(publish_task "develop" "并行任务 P1" "$(build_contract "implement" "write" "parallel" '["repo:kernel"]')")
task_p2=$(publish_task "develop" "并行任务 P2" "$(build_contract "implement" "write" "parallel" '["repo:kernel"]')")
TEST_INSTANCE="implementer"
cmd_claim "$task_p1" >/dev/null
TEST_INSTANCE="implementer-2"
cmd_claim "$task_p2" >/dev/null
assert_file_exists "parallel 任务允许共享 resource_keys (P1)" "$TASKS_DIR/processing/${task_p1}.json"
assert_file_exists "parallel 任务允许共享 resource_keys (P2)" "$TASKS_DIR/processing/${task_p2}.json"

section "Test 12: resume 快照缺失或 schema_version 不匹配时拒绝恢复"
resume_project_missing="$TEST_ROOT/resume-missing"
mkdir -p "$resume_project_missing/.swarm/runtime"
git -C "$resume_project_missing" init >/dev/null 2>&1
cat > "$resume_project_missing/.swarm/runtime/state.json" <<'EOF'
{
  "status": "stopped",
  "profile": "minimal",
  "project": "__PROJECT__",
  "resume": {
    "resumable": true
  }
}
EOF
sed -i.bak "s|__PROJECT__|$resume_project_missing|g" "$resume_project_missing/.swarm/runtime/state.json" 2>/dev/null || \
    perl -0pi -e "s|__PROJECT__|$resume_project_missing|g" "$resume_project_missing/.swarm/runtime/state.json"
rm -f "$resume_project_missing/.swarm/runtime/state.json.bak"
set +e
missing_output=$(bash "$SCRIPT_DIR/swarm-start.sh" --project "$resume_project_missing" --resume --hidden 2>&1)
missing_rc=$?
set -e
assert_nonzero "缺少快照时 resume 失败" "$missing_rc"
assert_contains "缺少快照错误信息" "$missing_output" "resume snapshot"

resume_project_mismatch="$TEST_ROOT/resume-mismatch"
mkdir -p "$resume_project_mismatch/.swarm/runtime"
git -C "$resume_project_mismatch" init >/dev/null 2>&1
cat > "$resume_project_mismatch/.swarm/runtime/state.json" <<'EOF'
{
  "status": "stopped",
  "profile": "minimal",
  "project": "__PROJECT__",
  "resume": {
    "resumable": true,
    "snapshot": {
      "schema_version": 1
    }
  }
}
EOF
sed -i.bak "s|__PROJECT__|$resume_project_mismatch|g" "$resume_project_mismatch/.swarm/runtime/state.json" 2>/dev/null || \
    perl -0pi -e "s|__PROJECT__|$resume_project_mismatch|g" "$resume_project_mismatch/.swarm/runtime/state.json"
rm -f "$resume_project_mismatch/.swarm/runtime/state.json.bak"
set +e
mismatch_output=$(bash "$SCRIPT_DIR/swarm-start.sh" --project "$resume_project_mismatch" --resume --hidden 2>&1)
mismatch_rc=$?
set -e
assert_nonzero "schema_version 不匹配时 resume 失败" "$mismatch_rc"
assert_contains "schema_version 不匹配错误信息" "$mismatch_output" "schema_version"

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
