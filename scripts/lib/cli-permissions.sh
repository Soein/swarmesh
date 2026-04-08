#!/usr/bin/env bash
################################################################################
# cli-permissions.sh - CLI 权限适配器
#
# 把 CLI 无关的权限语义（见 config/permission-defaults.json）翻译为
# 各家 AI CLI 的原生命令行 flag。
#
# 支持的 CLI:
#   - Claude Code   (claude chat / claude) —— 细粒度: --permission-mode / --allowedTools / --disallowedTools
#   - Gemini CLI    (gemini)                —— 细粒度: --approval-mode / --allowed-tools
#   - OpenAI Codex  (codex chat / codex)    —— 粗粒度: --sandbox / --ask-for-approval（execpolicy 细粒度为 TODO）
#
# 对接 Claude Code 官方 2.1.88 coordinatorMode.ts + constants/tools.ts 的权限模型:
#   - COORDINATOR_MODE_ALLOWED_TOOLS -> management 层
#   - IN_PROCESS_TEAMMATE_ALLOWED_TOOLS -> quality 层
#   - ASYNC_AGENT_ALLOWED_TOOLS - ALL_AGENT_DISALLOWED_TOOLS -> core 层
#
# 由 swarm-lib.sh 加载。
################################################################################

[[ -n "${_CLI_PERMISSIONS_LOADED:-}" ]] && return 0
_CLI_PERMISSIONS_LOADED=1

# ===========================================================================
# CLI 品种检测
# ===========================================================================
#
# 接收原始 CLI 字符串（如 "claude chat", "gemini --approval-mode yolo"），
# 返回一个标识: claude / codex / gemini / unknown
#
_detect_cli_kind() {
    local s="$1"
    case "$s" in
        claude|claude\ *) echo "claude" ;;
        codex|codex\ *)   echo "codex" ;;
        gemini|gemini\ *) echo "gemini" ;;
        *)
            # 兼容绝对路径: /usr/local/bin/claude
            case "$s" in
                */claude|*/claude\ *) echo "claude" ;;
                */codex|*/codex\ *)   echo "codex" ;;
                */gemini|*/gemini\ *) echo "gemini" ;;
                *) echo "unknown" ;;
            esac
            ;;
    esac
}

_is_claude() { [[ "$(_detect_cli_kind "$1")" == "claude" ]]; }
_is_codex()  { [[ "$(_detect_cli_kind "$1")" == "codex"  ]]; }
_is_gemini() { [[ "$(_detect_cli_kind "$1")" == "gemini" ]]; }

# ===========================================================================
# 用户已写死 flag 检测
# ===========================================================================
#
# 防止 build_cli_command 静默覆盖用户在 profile 里手写的 flag。
# 例如 "gemini --approval-mode yolo" 已写死 yolo，权限层要求 default 时
# 应该 log_warn 告警并保留用户意图。
#
_cli_has_flag() {
    local cli_str="$1" flag="$2"
    [[ " $cli_str " == *" $flag "* ]] || [[ " $cli_str " == *" $flag="* ]]
}

# ===========================================================================
# 辅助: 转义单个 shell 参数
# ===========================================================================
_shell_quote() {
    printf '%q' "$1"
}

# ===========================================================================
# Claude Code 适配器
# ===========================================================================
#
# 支持细粒度：--permission-mode + --allowedTools + --disallowedTools
# 抽象工具 -> Claude 工具名映射:
#   read   -> Read
#   write  -> Write
#   edit   -> Edit
#   search -> Grep, Glob
#   list   -> LS
#   messaging -> (通过 Bash(swarm-msg.sh:*) 白名单实现，不在工具层)
#   test_runner -> (通过 Bash(npm test:*) 等白名单实现)
#   bash   -> (由 allow_bash 处理)
#
# allow_bash / deny_bash 的模式直接透传为 Bash(pattern)。
#
# 安全依赖: core 类型 allow_bash=["*"] (生成裸 Bash) + deny_bash=[...] 同时使用，
# 依赖 Claude Code 的 deny > allow 优先级。已通过官方源码确认:
#   restored-src/src/tools/BashTool/bashPermissions.ts:1312
#   "Deny takes priority — return immediately"
# 即即使 --allowedTools 含裸 Bash，--disallowedTools Bash(rm:*) 仍会优先生效。
#
_build_claude_cmd() {
    local cli="$1" perms="$2"

    # ----- exec 模式 → --permission-mode -----
    local perm_mode="default"
    case "$(jq -r '.exec // "default"' <<<"$perms")" in
        never-ask)  perm_mode="acceptEdits" ;;
        on-request) perm_mode="default" ;;
        ask)        perm_mode="default" ;;
        default)    perm_mode="default" ;;
    esac

    # 用户已写死 --permission-mode 时不覆盖
    if _cli_has_flag "$cli" "--permission-mode"; then
        log_warn "cli-permissions: $cli 已含 --permission-mode，跳过权限层覆盖"
        perm_mode=""
    fi

    # ----- 构建 --allowedTools -----
    local -a allowed=()

    # 抽象工具 -> Claude 工具名
    while IFS= read -r t; do
        case "$t" in
            read)   allowed+=("Read") ;;
            write)  allowed+=("Write") ;;
            edit)   allowed+=("Edit") ;;
            search) allowed+=("Grep" "Glob") ;;
            list)   allowed+=("LS") ;;
            messaging|test_runner|bash) ;;  # 由 allow_bash 处理
        esac
    done < <(jq -r '.allow_tools[]?' <<<"$perms" 2>/dev/null)

    # allow_bash 模式 -> Bash(pattern)
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        if [[ "$b" == "*" ]]; then
            allowed+=("Bash")
        else
            allowed+=("Bash($b)")
        fi
    done < <(jq -r '.allow_bash[]?' <<<"$perms" 2>/dev/null)

    # ----- 构建 --disallowedTools -----
    local -a disallowed=()

    while IFS= read -r t; do
        case "$t" in
            edit)   disallowed+=("Edit") ;;
            write)  disallowed+=("Write" "NotebookEdit") ;;
            delete) ;;  # 通过 deny_bash rm:* 实现
        esac
    done < <(jq -r '.deny_tools[]?' <<<"$perms" 2>/dev/null)

    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        disallowed+=("Bash($b)")
    done < <(jq -r '.deny_bash[]?' <<<"$perms" 2>/dev/null)

    # ----- 拼装输出 -----
    local out="$cli"
    [[ -n "$perm_mode" ]] && out+=" --permission-mode $perm_mode"

    if [[ ${#allowed[@]} -gt 0 ]]; then
        out+=" --allowedTools"
        local a
        for a in "${allowed[@]}"; do
            out+=" $(_shell_quote "$a")"
        done
    fi

    if [[ ${#disallowed[@]} -gt 0 ]]; then
        out+=" --disallowedTools"
        local d
        for d in "${disallowed[@]}"; do
            out+=" $(_shell_quote "$d")"
        done
    fi

    printf '%s' "$out"
}

# ===========================================================================
# Gemini CLI 适配器
# ===========================================================================
#
# 细粒度: --approval-mode + --allowed-tools "ShellTool(cmd),ReadFileTool,..."
# 抽象工具 -> Gemini 工具名映射:
#   read   -> ReadFileTool, ReadManyFilesTool
#   write  -> WriteFileTool
#   edit   -> EditTool
#   search -> SearchTextTool, GlobTool
#   list   -> LSTool
#
_build_gemini_cmd() {
    local cli="$1" perms="$2"

    # ----- exec 模式 → --approval-mode -----
    local approval_mode="default"
    case "$(jq -r '.exec // "default"' <<<"$perms")" in
        never-ask)  approval_mode="yolo" ;;
        on-request) approval_mode="default" ;;
        ask)        approval_mode="default" ;;
        default)    approval_mode="default" ;;
    esac

    if _cli_has_flag "$cli" "--approval-mode"; then
        log_warn "cli-permissions: $cli 已含 --approval-mode，跳过权限层覆盖"
        approval_mode=""
    fi

    # ----- --allowed-tools 列表 -----
    local -a tools=()

    while IFS= read -r t; do
        case "$t" in
            read)   tools+=("ReadFileTool" "ReadManyFilesTool") ;;
            write)  tools+=("WriteFileTool") ;;
            edit)   tools+=("EditTool") ;;
            search) tools+=("SearchTextTool" "GlobTool") ;;
            list)   tools+=("LSTool") ;;
            messaging|test_runner|bash) ;;  # 由 ShellTool 处理
        esac
    done < <(jq -r '.allow_tools[]?' <<<"$perms" 2>/dev/null)

    # allow_bash 模式 -> ShellTool(cmd)
    # Gemini 的 ShellTool 参数是命令前缀而非完整模式，故取模式中的第一个 token
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        if [[ "$b" == "*" ]]; then
            tools+=("ShellTool")
            continue
        fi
        # 提取命令前缀: "npm test:*" -> "npm test"; "swarm-msg.sh:*" -> "swarm-msg.sh"
        local prefix="${b%:\*}"
        prefix="${prefix%\*}"
        tools+=("ShellTool(${prefix})")
    done < <(jq -r '.allow_bash[]?' <<<"$perms" 2>/dev/null)

    # ----- 拼装输出 -----
    local out="$cli"
    [[ -n "$approval_mode" ]] && out+=" --approval-mode $approval_mode"

    if [[ ${#tools[@]} -gt 0 ]]; then
        # Gemini 用逗号分隔的单个字符串
        local joined
        joined=$(IFS=,; echo "${tools[*]}")
        out+=" --allowed-tools $(_shell_quote "$joined")"
    fi

    printf '%s' "$out"
}

# ===========================================================================
# OpenAI Codex 适配器
# ===========================================================================
#
# 粗粒度: --sandbox + --ask-for-approval（依靠 OS 级 sandbox 做文件系统隔离）
# 细粒度白名单需要 execpolicy .rules 文件 + Starlark 语法，第一阶段不做。
#
# 映射:
#   fs: read-only        -> --sandbox read-only
#   fs: workspace-write  -> --sandbox workspace-write
#   fs: full-write       -> --sandbox danger-full-access
#
#   exec: never-ask   -> --ask-for-approval never
#   exec: on-request  -> --ask-for-approval on-request
#   exec: ask         -> --ask-for-approval on-failure
#
_build_codex_cmd() {
    local cli="$1" perms="$2"

    local sandbox="workspace-write"
    case "$(jq -r '.fs // "workspace-write"' <<<"$perms")" in
        read-only)       sandbox="read-only" ;;
        workspace-write) sandbox="workspace-write" ;;
        full-write)      sandbox="danger-full-access" ;;
    esac

    local approval="on-request"
    case "$(jq -r '.exec // "on-request"' <<<"$perms")" in
        never-ask)  approval="never" ;;
        on-request) approval="on-request" ;;
        ask)        approval="on-failure" ;;
    esac

    # 用户已写死 flag 时不覆盖
    if _cli_has_flag "$cli" "--sandbox" || _cli_has_flag "$cli" "-s"; then
        log_warn "cli-permissions: $cli 已含 --sandbox，跳过权限层覆盖"
        sandbox=""
    fi
    if _cli_has_flag "$cli" "--ask-for-approval" || _cli_has_flag "$cli" "-a"; then
        log_warn "cli-permissions: $cli 已含 --ask-for-approval，跳过权限层覆盖"
        approval=""
    fi

    local out="$cli"
    [[ -n "$sandbox" ]]  && out+=" --sandbox $sandbox"
    [[ -n "$approval" ]] && out+=" --ask-for-approval $approval"

    # TODO(P0-followup): 第二阶段引入 execpolicy .rules 文件支持细粒度白名单
    # 生成位置: $RUNTIME_DIR/codex-policies/${INSTANCE}.rules
    # 通过 codex --config execpolicy.user_rules=<path> 加载，pane 退出时清理

    printf '%s' "$out"
}

# ===========================================================================
# 主入口: build_cli_command
# ===========================================================================
#
# 参数:
#   $1 - cli_str: profile 里的原始 CLI 字符串（如 "claude chat"）
#   $2 - perms_json: 单角色权限 JSON（已合并默认值，见 resolve_role_permissions）
#
# 输出:
#   完整的 CLI 命令字符串（到 stdout），含权限 flag
#
# 失败:
#   - 未识别 CLI 类型 → die (仅支持 claude / codex / gemini)
#
build_cli_command() {
    local cli_str="$1" perms="$2"

    local kind
    kind=$(_detect_cli_kind "$cli_str")

    case "$kind" in
        claude)  _build_claude_cmd "$cli_str" "$perms" ;;
        codex)   _build_codex_cmd  "$cli_str" "$perms" ;;
        gemini)  _build_gemini_cmd "$cli_str" "$perms" ;;
        unknown)
            die "cli-permissions: 未识别 CLI 类型 '$cli_str' (仅支持 claude / codex / gemini)"
            ;;
    esac
}
