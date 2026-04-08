#!/usr/bin/env bash
################################################################################
# test-permissions.sh - P0 权限层静态验证脚本
#
# 运行一系列静态测试，验证:
#   1. cli-permissions.sh 和 cli-launcher.sh 的函数都能被加载
#   2. CLI 品种检测（claude/codex/gemini/unknown）正确
#   3. category 推断正确（管理/质量/核心）
#   4. 三类默认权限合并后字段齐全
#   5. 三家 CLI 的 build_cli_command 输出可被 shell eval 正确还原
#   6. Codex+management 硬阻断生效（SWARM_ALLOW_CODEX_MGMT 未设置时）
#   7. 用户已写死 flag 时不静默覆盖
#   8. 未知 CLI pass-through
#   9. SWARM_PERMISSIONS=off 紧急回滚
#
# 不依赖 tmux session / 实际 CLI 进程，可在任意机器上快速跑。
#
# 用法:
#   bash scripts/test-permissions.sh
#
# 退出码:
#   0 - 全部通过
#   1 - 至少一个 case 失败
################################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export SWARM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 用临时目录，避免污染真实 runtime
TEST_RUNTIME=$(mktemp -d -t swarm-perm-test-XXXXXX)
export RUNTIME_DIR="$TEST_RUNTIME"
mkdir -p "$RUNTIME_DIR/perms" "$RUNTIME_DIR/logs"

# 加载主库（会自动 source cli-permissions.sh + cli-launcher.sh）
source "$SCRIPT_DIR/swarm-lib.sh"

# ============================================================================
# 测试框架
# ============================================================================

PASS_COUNT=0
FAIL_COUNT=0
FAIL_MESSAGES=()

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
        printf '      needle not found in haystack\n'
        printf '      needle:   %s\n' "$needle"
        printf '      haystack: %s\n' "$haystack"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_MESSAGES+=("$label")
    fi
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  \033[31m✗\033[0m %s\n' "$label"
        printf '      unexpected needle found\n'
        printf '      needle:   %s\n' "$needle"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_MESSAGES+=("$label")
    fi
}

section() {
    printf '\n\033[1;34m═══ %s ═══\033[0m\n' "$1"
}

# ============================================================================
# Test 1: 函数加载检查
# ============================================================================

section "Test 1: 函数加载"

for fn in \
    _detect_cli_kind _is_claude _is_codex _is_gemini \
    _build_claude_cmd _build_gemini_cmd _build_codex_cmd \
    build_cli_command \
    resolve_role_permissions launch_cli_in_pane infer_category_from_config; do
    if declare -F "$fn" > /dev/null; then
        assert_eq "函数 $fn 已加载" "OK" "OK"
    else
        assert_eq "函数 $fn 已加载" "OK" "MISSING"
    fi
done

# ============================================================================
# Test 2: CLI 品种检测
# ============================================================================

section "Test 2: CLI 品种检测"

assert_eq "claude chat → claude"            "claude"  "$(_detect_cli_kind 'claude chat')"
assert_eq "claude → claude"                 "claude"  "$(_detect_cli_kind 'claude')"
assert_eq "codex chat → codex"              "codex"   "$(_detect_cli_kind 'codex chat')"
assert_eq "codex → codex"                   "codex"   "$(_detect_cli_kind 'codex')"
assert_eq "gemini --approval-mode yolo → gemini" "gemini" "$(_detect_cli_kind 'gemini --approval-mode yolo')"
assert_eq "gemini → gemini"                 "gemini"  "$(_detect_cli_kind 'gemini')"
assert_eq "aider → unknown"                 "unknown" "$(_detect_cli_kind 'aider')"
assert_eq "绝对路径 /usr/local/bin/claude chat → claude" "claude" "$(_detect_cli_kind '/usr/local/bin/claude chat')"

# ============================================================================
# Test 3: category 推断
# ============================================================================

section "Test 3: category 推断"

assert_eq "core/backend.md → core"             "core"       "$(infer_category_from_config 'core/backend.md')"
assert_eq "quality/reviewer.md → quality"      "quality"    "$(infer_category_from_config 'quality/reviewer.md')"
assert_eq "management/supervisor.md → mgmt"    "management" "$(infer_category_from_config 'management/supervisor.md')"
assert_eq "unknown/foo.md → core (fallback)"   "core"       "$(infer_category_from_config 'unknown/foo.md')"

# ============================================================================
# Test 4: 权限合并
# ============================================================================

section "Test 4: 三类默认权限合并字段齐全"

mgmt_perms=$(resolve_role_permissions "supervisor" "management")
quality_perms=$(resolve_role_permissions "reviewer" "quality")
core_perms=$(resolve_role_permissions "backend" "core")

assert_eq "management.tier == coordinator"      "coordinator"         "$(jq -r .tier <<<"$mgmt_perms")"
assert_eq "quality.tier == in_process_teammate" "in_process_teammate" "$(jq -r .tier <<<"$quality_perms")"
assert_eq "core.tier == async_agent"            "async_agent"         "$(jq -r .tier <<<"$core_perms")"

assert_eq "management.fs == read-only"         "read-only"       "$(jq -r .fs <<<"$mgmt_perms")"
assert_eq "quality.fs == read-only"            "read-only"       "$(jq -r .fs <<<"$quality_perms")"
assert_eq "core.fs == workspace-write"         "workspace-write" "$(jq -r .fs <<<"$core_perms")"

# 关键边界：core 应禁止 swarm-join.sh（防递归派发）
core_deny_bash=$(jq -r '.deny_bash | join(",")' <<<"$core_perms")
assert_contains "core 禁止 swarm-join.sh"         "$core_deny_bash" "swarm-join.sh:*"
assert_contains "core 禁止 swarm-leave.sh"        "$core_deny_bash" "swarm-leave.sh:*"
assert_contains "core 禁止 request-supervisor"    "$core_deny_bash" "request-supervisor:*"

# management 应禁止 edit/write/delete
mgmt_deny_tools=$(jq -r '.deny_tools | join(",")' <<<"$mgmt_perms")
assert_contains "management 禁止 edit" "$mgmt_deny_tools" "edit"
assert_contains "management 禁止 write" "$mgmt_deny_tools" "write"

# ============================================================================
# Test 5: 三家 CLI 的 build_cli_command 输出可被 eval 还原
# ============================================================================

section "Test 5: build_cli_command 输出可被 shell eval 还原"

# Claude Code - management
claude_mgmt_cmd=$(build_cli_command "claude chat" "$mgmt_perms")
eval "set -- $claude_mgmt_cmd"
assert_eq "claude mgmt argv[0]" "claude" "$1"
assert_eq "claude mgmt argv[1]" "chat"   "$2"
# 找 --permission-mode 和 --disallowedTools
claude_mgmt_str="$*"
assert_contains "claude mgmt 含 --permission-mode"      "$claude_mgmt_str" "--permission-mode"
assert_contains "claude mgmt 含 --allowedTools"         "$claude_mgmt_str" "--allowedTools"
assert_contains "claude mgmt 含 Bash(swarm-msg.sh:*)"   "$claude_mgmt_str" "Bash(swarm-msg.sh:*)"
assert_contains "claude mgmt 含 Bash(git status)"       "$claude_mgmt_str" "Bash(git status)"
assert_contains "claude mgmt 含 --disallowedTools Edit" "$claude_mgmt_str" "Edit"
assert_contains "claude mgmt 含 Bash(git push:*) 禁用"  "$claude_mgmt_str" "Bash(git push:*)"

# Claude Code - core (应允许 Edit/Write)
claude_core_cmd=$(build_cli_command "claude chat" "$core_perms")
eval "set -- $claude_core_cmd"
claude_core_str="$*"
assert_contains "claude core 含 Edit 允许"              "$claude_core_str" "Edit"
assert_contains "claude core 含 Write 允许"             "$claude_core_str" "Write"
# 关键：core 应禁止 swarm-join.sh
assert_contains "claude core 禁止 swarm-join.sh"        "$claude_core_str" "Bash(swarm-join.sh:*)"

# Gemini - core
gemini_core_cmd=$(build_cli_command "gemini" "$core_perms")
eval "set -- $gemini_core_cmd"
gemini_core_str="$*"
assert_contains "gemini core 含 --approval-mode yolo"   "$gemini_core_str" "--approval-mode yolo"
assert_contains "gemini core 含 ReadFileTool"            "$gemini_core_str" "ReadFileTool"
assert_contains "gemini core 含 WriteFileTool"           "$gemini_core_str" "WriteFileTool"
assert_contains "gemini core 含 ShellTool"               "$gemini_core_str" "ShellTool"

# Codex - core (仅粗粒度)
codex_core_cmd=$(build_cli_command "codex chat" "$core_perms")
eval "set -- $codex_core_cmd"
codex_core_str="$*"
assert_contains "codex core 含 --sandbox workspace-write"     "$codex_core_str" "--sandbox workspace-write"
assert_contains "codex core 含 --ask-for-approval never"      "$codex_core_str" "--ask-for-approval never"

# Codex - quality
codex_quality_cmd=$(build_cli_command "codex chat" "$quality_perms")
eval "set -- $codex_quality_cmd"
codex_quality_str="$*"
assert_contains "codex quality 含 --sandbox read-only"        "$codex_quality_str" "--sandbox read-only"

# ============================================================================
# Test 6: Codex+management 硬阻断
# ============================================================================

section "Test 6: Codex + management 组合硬阻断"

unset SWARM_ALLOW_CODEX_MGMT
block_output=$(launch_cli_in_pane "0.0" "supervisor" "supervisor-test" \
    "/tmp/fake-worktree" "codex chat" "management" "" 2>&1 || true)
assert_contains "Codex+management 被阻断（无 override）" \
    "$block_output" "codex CLI + management 分类被默认阻断"

# 验证启用 override 后可以通过
export SWARM_ALLOW_CODEX_MGMT=1
override_output=$(launch_cli_in_pane "0.0" "supervisor" "supervisor-test-override" \
    "/tmp/fake-worktree" "codex chat" "management" "" 2>&1 || true)
# 注：override 后函数会继续执行，但 _send_keys_enter 会因 pane 不存在而报错，
# 这不影响我们的 assert（只检查 warn 日志存在）
assert_contains "Codex+management override 后有 warn 日志" \
    "$override_output" "允许 codex+management 组合"
unset SWARM_ALLOW_CODEX_MGMT

# ============================================================================
# Test 7: 用户已写死 flag 不被覆盖
# ============================================================================

section "Test 7: 用户已写死的 CLI flag 优先"

# gemini --approval-mode yolo (用户写死)，权限层要求 default
user_yolo_cmd=$(build_cli_command "gemini --approval-mode yolo" "$mgmt_perms" 2>&1)
assert_contains "warn 提示 --approval-mode 已含" \
    "$user_yolo_cmd" "已含 --approval-mode，跳过权限层覆盖"
# 原始 yolo 应保留
assert_contains "gemini 原始 yolo 保留" "$user_yolo_cmd" "gemini --approval-mode yolo"

# claude --permission-mode acceptEdits (用户写死)
user_claude_cmd=$(build_cli_command "claude chat --permission-mode acceptEdits" "$mgmt_perms" 2>&1)
assert_contains "claude 已含 --permission-mode 时有 warn" \
    "$user_claude_cmd" "已含 --permission-mode"

# ============================================================================
# Test 8: 未识别 CLI 必须 die（严格模式）
# ============================================================================

section "Test 8: 未识别 CLI 必须 die"

# 用子 shell 包裹：die 会 exit 1，子 shell 退出不会影响主测试进程
unknown_output=$(bash -c '
    set +e
    source "'"$SCRIPT_DIR"'/swarm-lib.sh" 2>/dev/null
    build_cli_command "aider --model gpt-4" "{}" 2>&1
    echo "EXITCODE=$?"
' || true)
assert_contains "未识别 CLI die 错误信息" "$unknown_output" "未识别 CLI 类型"
assert_not_contains "未识别 CLI 不会原样输出" "$unknown_output" "aider --model gpt-4
EXITCODE=0"

# ============================================================================
# Test 9: Profile schema 严格模式（所有 role 必须带 category）
# ============================================================================

section "Test 9: Profile JSON schema 严格模式"

for profile in minimal web-dev full-stack; do
    profile_file="$SWARM_ROOT/config/profiles/${profile}.json"
    if [[ ! -f "$profile_file" ]]; then
        continue
    fi
    # 所有 role 必须显式带 category，且值必须是 management/quality/core
    missing_cat=$(jq -r '[.roles[] | select(.category == null)] | length' "$profile_file")
    assert_eq "profile ${profile}.json 所有 role 含 category" "0" "$missing_cat"

    invalid_cat=$(jq -r '[.roles[] | select(.category != null and (.category | IN("management","quality","core") | not))] | length' "$profile_file")
    assert_eq "profile ${profile}.json category 值合法" "0" "$invalid_cat"
done

# ============================================================================
# 总结
# ============================================================================

section "测试总结"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
printf '  通过: %d / %d\n' "$PASS_COUNT" "$TOTAL"
if [[ $FAIL_COUNT -gt 0 ]]; then
    printf '  \033[31m失败: %d\033[0m\n' "$FAIL_COUNT"
    printf '\n失败项:\n'
    for m in "${FAIL_MESSAGES[@]}"; do
        printf '  - %s\n' "$m"
    done
fi

# 清理临时目录
rm -rf "$TEST_RUNTIME"

if [[ $FAIL_COUNT -eq 0 ]]; then
    printf '\n\033[1;32m✓ 所有权限层静态测试通过\033[0m\n'
    exit 0
else
    printf '\n\033[1;31m✗ 部分测试失败\033[0m\n'
    exit 1
fi
