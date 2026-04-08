#!/usr/bin/env bash
################################################################################
# cli-launcher.sh - CLI 启动器与权限合并
#
# 提供两个共享函数:
#
#   1. resolve_role_permissions(role, category, [profile_json])
#      —— 把 config/permission-defaults.json 中 category 的默认模板
#         与 profile 中的 permission_defaults 和 role.permissions 三层合并，
#         输出最终生效的权限 JSON。
#
#   2. launch_cli_in_pane(pane_target, role, instance, worktree, cli_str, category, [profile_json])
#      —— 封装原本散落在 swarm-start.sh 和 swarm-join.sh 里的 CLI 启动序列，
#         调用 cli-permissions.sh::build_cli_command 拼接权限 flag，
#         再通过 _send_keys_enter 发送到目标 pane。
#
# 依赖:
#   - swarm-lib.sh (_send_keys_enter, log_*)
#   - cli-permissions.sh (build_cli_command, _is_codex)
#   - jq
#
# 由 swarm-lib.sh 加载。
################################################################################

[[ -n "${_CLI_LAUNCHER_LOADED:-}" ]] && return 0
_CLI_LAUNCHER_LOADED=1

# ===========================================================================
# resolve_role_permissions
# ===========================================================================
#
# 三层合并（低优先级 → 高优先级）:
#   1. config/permission-defaults.json[$category]
#   2. $profile_json.permission_defaults[$category]
#   3. $profile_json.roles[] | select(.name==$role) | .permissions
#
# 参数:
#   $1 - role:     角色实例名（如 backend-2）
#   $2 - category: 角色分类（management / quality / core）
#   $3 - profile_json (可选): profile 原始 JSON 字符串
#        未提供时从全局变量 $PROFILE_JSON 读取（swarm-start.sh 已导出）
#
# 输出:
#   合并后的权限 JSON 到 stdout
#
# 失败:
#   - defaults 文件不存在 → 打印一个最小 fallback (core 兜底) 并 log_warn
#
resolve_role_permissions() {
    local role="$1"
    local category="$2"
    local profile_json="${3:-${PROFILE_JSON:-}}"

    local defaults_file="${CONFIG_DIR}/permission-defaults.json"

    # 未传 category 时回退到 core
    [[ -z "$category" ]] && category="core"

    # 1. 读取 defaults
    local base="{}"
    if [[ -f "$defaults_file" ]]; then
        base=$(jq --arg c "$category" '.[$c] // .core // {}' "$defaults_file" 2>/dev/null)
        if [[ -z "$base" || "$base" == "null" ]]; then
            log_warn "resolve_role_permissions: $defaults_file 中未找到 category=$category，用空对象"
            base="{}"
        fi
    else
        log_warn "resolve_role_permissions: $defaults_file 不存在，使用空基线"
    fi

    # 2. 读取 profile 级覆盖
    local profile_override="{}"
    if [[ -n "$profile_json" ]]; then
        profile_override=$(jq --arg c "$category" \
            '.permission_defaults[$c] // {}' <<<"$profile_json" 2>/dev/null)
        [[ -z "$profile_override" || "$profile_override" == "null" ]] && profile_override="{}"
    fi

    # 3. 读取 role 级覆盖
    local role_override="{}"
    if [[ -n "$profile_json" ]]; then
        role_override=$(jq --arg r "$role" \
            '.roles[]? | select(.name==$r) | .permissions // {}' <<<"$profile_json" 2>/dev/null)
        [[ -z "$role_override" || "$role_override" == "null" ]] && role_override="{}"
    fi

    # 4. 合并（jq 的 * 运算符做递归合并：后者覆盖前者同名字段）
    jq -s '.[0] * .[1] * .[2]' \
        <(printf '%s' "$base") \
        <(printf '%s' "$profile_override") \
        <(printf '%s' "$role_override")
}

# ===========================================================================
# launch_cli_in_pane
# ===========================================================================
#
# 统一的 CLI 启动序列，替代 swarm-start.sh:687-689 和 swarm-join.sh:241 的
# 双份重复代码。
#
# 参数:
#   $1 - pane_target (如 "0.1")
#   $2 - role        (如 "backend")
#   $3 - instance    (如 "backend" 或 "backend-2")
#   $4 - worktree    (角色的 git worktree 路径)
#   $5 - cli_str     (原始 CLI 命令字符串，如 "claude chat")
#   $6 - category    (management / quality / core；空则根据 role 名猜测失败回退 core)
#   $7 - profile_json (可选) 用于 resolve_role_permissions 的权限合并
#
# 副作用:
#   - 写入 ${RUNTIME_DIR}/perms/${instance}.json （合并后的权限快照，供 status/调试）
#   - 通过 _send_keys_enter 向目标 pane 发送启动命令
#
# 返回:
#   0 = 成功
#   1 = Codex+management 组合被阻断 (除非 SWARM_ALLOW_CODEX_MGMT=1)
#
launch_cli_in_pane() {
    local pane_target="$1"
    local role="$2"
    local instance="$3"
    local worktree="$4"
    local cli_str="$5"
    local category="${6:-core}"
    local profile_json="${7:-${PROFILE_JSON:-}}"

    # ----- 1. 合并权限 -----
    local perms
    perms=$(resolve_role_permissions "$role" "$category" "$profile_json")

    # ----- 2. Codex + management 硬阻断检查 -----
    if _is_codex "$cli_str" && [[ "$category" == "management" ]]; then
        if [[ "${SWARM_ALLOW_CODEX_MGMT:-0}" != "1" ]]; then
            log_error "cli-launcher: role=$role cli=$cli_str: codex CLI + management 分类被默认阻断"
            log_error "  原因: Codex 仅有 OS 级 sandbox，无细粒度工具白名单，management 角色易被 prompt injection 骗去读敏感文件"
            log_error "  若确需使用，export SWARM_ALLOW_CODEX_MGMT=1 后重试"
            return 1
        fi
        log_warn "cli-launcher: role=$role 允许 codex+management 组合（SWARM_ALLOW_CODEX_MGMT=1），仅享受文件系统隔离"
    fi

    # ----- 3. 构建带权限的 CLI 命令 -----
    local wrapped_cli
    wrapped_cli=$(build_cli_command "$cli_str" "$perms")

    # ----- 4. 写入权限快照 -----
    mkdir -p "${RUNTIME_DIR}/perms"
    printf '%s' "$perms" > "${RUNTIME_DIR}/perms/${instance}.json"

    # ----- 5. Debug: 可选打印最终命令 -----
    if [[ "${SWARM_DEBUG_CLI_CMD:-0}" == "1" ]]; then
        log_info "cli-launcher: role=$role instance=$instance category=$category"
        log_info "  原始 CLI: $cli_str"
        log_info "  权限封装: $wrapped_cli"
    fi

    # ----- 6. 启动 CLI -----
    _send_keys_enter "$pane_target" \
        "cd \"$worktree\" && export SWARM_ROLE=\"$role\" && export SWARM_INSTANCE=\"$instance\" && export RUNTIME_DIR=\"$RUNTIME_DIR\" && export SWARM_SESSION=\"$SESSION_NAME\" && $wrapped_cli" \
        "$cli_str"

    return 0
}

# ===========================================================================
# infer_category_from_config: 从 config 路径推断 category
# ===========================================================================
#
# 用于 profile 或 swarm-join.sh 未显式传 category 时的兜底。
#
# 参数:
#   $1 - config 路径（相对 config/roles/，如 "core/backend.md"）
#
# 输出:
#   category 字符串到 stdout (management / quality / core)
#
infer_category_from_config() {
    local cfg="$1"
    case "$cfg" in
        management/*) echo "management" ;;
        quality/*)    echo "quality" ;;
        core/*)       echo "core" ;;
        *)            echo "core" ;;  # 向后兼容: 未知路径视为 core
    esac
}
