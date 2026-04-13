#!/usr/bin/env bash
# check-deps.sh — tmux-swarm 插件依赖自检
#
# 用法:
#   check-deps.sh              # 人类可读报告，缺失时退出码 1
#   check-deps.sh --quiet      # 只在缺失时输出警告（SessionStart hook 使用）
#   check-deps.sh --json       # 机器可读 JSON 输出
#
# 必需依赖: tmux, jq, bash >= 4
# 可选依赖（按 profile 启用）: claude, codex, gemini

set -uo pipefail

MODE="human"
case "${1:-}" in
    --quiet) MODE="quiet" ;;
    --json)  MODE="json" ;;
    "")      ;;
    *)       echo "未知参数: $1"; exit 2 ;;
esac

REQUIRED=(tmux jq bash)
OPTIONAL=(claude codex gemini)

missing_required=()
missing_optional=()
versions=()

for cmd in "${REQUIRED[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        case "$cmd" in
            tmux) v=$(tmux -V 2>/dev/null | head -1) ;;
            jq)   v=$(jq --version 2>/dev/null) ;;
            bash) v=$(bash --version 2>/dev/null | head -1) ;;
            *)    v=installed ;;
        esac
        versions+=("$cmd=$v")
    else
        missing_required+=("$cmd")
    fi
done

for cmd in "${OPTIONAL[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        versions+=("$cmd=installed")
    else
        missing_optional+=("$cmd")
    fi
done

if [[ "$MODE" == "json" ]]; then
    jq -n \
        --argjson missing_required "$(printf '%s\n' "${missing_required[@]+"${missing_required[@]}"}" | jq -R . | jq -s .)" \
        --argjson missing_optional "$(printf '%s\n' "${missing_optional[@]+"${missing_optional[@]}"}" | jq -R . | jq -s .)" \
        --argjson versions "$(printf '%s\n' "${versions[@]+"${versions[@]}"}" | jq -R . | jq -s .)" \
        '{ok: ($missing_required | length == 0), missing_required: $missing_required, missing_optional: $missing_optional, versions: $versions}'
    [[ ${#missing_required[@]} -eq 0 ]] && exit 0 || exit 1
fi

if [[ ${#missing_required[@]} -gt 0 ]]; then
    echo "⚠️  tmux-swarm 插件缺少必需依赖: ${missing_required[*]}"
    echo "   安装建议 (macOS): brew install ${missing_required[*]}"
    echo "   安装建议 (Linux): apt install ${missing_required[*]}  # 或 pacman/yum"
    exit 1
fi

if [[ "$MODE" == "quiet" ]]; then
    # hook 模式：仅在可选 CLI 全缺失时提示
    if [[ ${#missing_optional[@]} -eq ${#OPTIONAL[@]} ]]; then
        echo "ℹ️  tmux-swarm: 未检测到任何 AI CLI (${OPTIONAL[*]})，安装后才能启动蜂群。"
    fi
    exit 0
fi

echo "✅ tmux-swarm 依赖检查通过"
echo
echo "必需依赖:"
for v in "${versions[@]}"; do
    case "$v" in
        tmux=*|jq=*|bash=*) echo "   $v" ;;
    esac
done
echo
echo "AI CLI:"
for cmd in "${OPTIONAL[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "   $cmd ✓"
    else
        echo "   $cmd ✗ (未安装，对应角色将无法启动)"
    fi
done
exit 0
