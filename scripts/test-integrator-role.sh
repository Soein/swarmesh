#!/usr/bin/env bash
################################################################################
# test-integrator-role.sh - integrator 独立角色回归测试
#
# 覆盖:
#   1. 独立 integrator 角色文件存在且 frontmatter 正确
#   2. 所有内置 profile 显式包含 integrator
#   3. swarm-start.sh 会自动注入 integrator
#   4. 默认 workflow / CLI / 帮助示例都把 integrate 指向 integrator
#
# 用法:
#   bash scripts/test-integrator-role.sh
################################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
FAIL_MESSAGES=()

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

section "Test 1: integrator 角色文件"
role_file="$ROOT_DIR/config/roles/quality/integrator.md"
assert_file_exists "integrator 角色文件存在" "$role_file"
if [[ -f "$role_file" ]]; then
    assert_eq "integrator.name" "name: integrator" "$(grep '^name:' "$role_file" | head -1 | tr -d '\r')"
    assert_eq "integrator.category" "category: quality" "$(grep '^category:' "$role_file" | head -1 | tr -d '\r')"
fi

section "Test 2: profiles 显式包含 integrator"
for profile in minimal web-dev full-stack; do
    profile_file="$ROOT_DIR/config/profiles/${profile}.json"
    actual=$(jq -r '[.roles[] | select(.name == "integrator")] | length' "$profile_file")
    assert_eq "$profile profile 含 integrator" "1" "$actual"
done

section "Test 3: swarm-start 自动注入 integrator"
start_snippet=$(sed -n '650,690p' "$ROOT_DIR/scripts/swarm-start.sh")
assert_contains "swarm-start 含 integrator 注入逻辑" "$start_snippet" 'integrator'
assert_contains "swarm-start 注入 quality/integrator.md" "$start_snippet" 'quality/integrator.md'

section "Test 4: 默认 integrate 负责人是 integrator"
for workflow in quick-task feature-complete product-feature relay-chain; do
    workflow_file="$ROOT_DIR/workflows/${workflow}.json"
    actual=$(jq -r '[.stages[].tasks[].phase_assignments.integrate] | all(. == "integrator")' "$workflow_file")
    assert_eq "$workflow workflow integrate 默认值" "true" "$actual"
done

cli_snippet=$(sed -n '360,390p' "$ROOT_DIR/scripts/swarm-cli.sh")
assert_contains "swarm-cli 默认 contract 使用 integrator" "$cli_snippet" 'integrate: "integrator"'

msg_examples=$(sed -n '790,845p' "$ROOT_DIR/scripts/swarm-msg.sh")
assert_contains "swarm-msg 示例使用 integrator" "$msg_examples" '"integrate":"integrator"'

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
