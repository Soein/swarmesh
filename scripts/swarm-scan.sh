#!/usr/bin/env bash
################################################################################
# swarm-scan.sh - 项目结构事实收集
#
# 收集目标项目目录的原始事实（文件树、关键配置文件内容片段），
# 输出 project-info.json 供蜂群中的 LLM 角色自行解读技术栈。
#
# 设计理念：
#   脚本只负责收集原始信息，不做任何"判断"或"推荐"。
#   技术栈识别、验证命令推导、profile 建议等全部由 LLM 动态决定。
#
# 用法:
#   swarm-scan.sh <项目目录> [输出文件路径]
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_ROOT="${SWARM_ROOT:-$(dirname "$SCRIPT_DIR")}"
RUNTIME_DIR="${RUNTIME_DIR:-$SWARM_ROOT/runtime}"

# =============================================================================
# 配置
# =============================================================================

# 扫描深度（支持 monorepo）
SCAN_DEPTH="${SCAN_DEPTH:-2}"

# 关键配置文件名（只是用来定位，不做语言推断）
KEY_FILES=(
    package.json tsconfig.json
    pyproject.toml setup.py setup.cfg requirements.txt Pipfile
    go.mod
    Cargo.toml
    pom.xml build.gradle build.gradle.kts
    composer.json
    Gemfile
    mix.exs
    CMakeLists.txt Makefile
    Dockerfile docker-compose.yml docker-compose.yaml
    .github/workflows
)

# 配置文件最大读取行数（避免输出过大）
MAX_SNIPPET_LINES="${MAX_SNIPPET_LINES:-50}"

# =============================================================================
# 工具函数
# =============================================================================

log_info()  { echo "[SCAN] $*" >&2; }
die()       { echo "[SCAN-ERROR] $*" >&2; exit 1; }

# =============================================================================
# 收集函数
# =============================================================================

# 收集项目文件树（排除常见噪声目录）
collect_file_tree() {
    local project_dir="$1"
    find "$project_dir" -maxdepth "$SCAN_DEPTH" \
        -not -path "*/.git/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/.swarm-worktrees/*" \
        -not -path "*/vendor/*" \
        -not -path "*/__pycache__/*" \
        -not -path "*/.venv/*" \
        -not -path "*/target/*" \
        -not -path "*/dist/*" \
        -not -path "*/build/*" \
        -not -name ".DS_Store" \
        2>/dev/null \
        | sed "s|^$project_dir/||" \
        | sort
}

# 收集关键配置文件的内容片段
collect_key_file_snippets() {
    local project_dir="$1"
    local results="[]"

    for name in "${KEY_FILES[@]}"; do
        while IFS= read -r found; do
            [[ -z "$found" ]] && continue
            [[ -f "$found" ]] || continue

            local rel_path="${found#$project_dir/}"
            local content
            content=$(head -n "$MAX_SNIPPET_LINES" "$found" 2>/dev/null || true)

            # 如果文件超过限制行数，标注截断
            local total_lines
            total_lines=$(wc -l < "$found" 2>/dev/null | tr -d ' ')
            if [[ "$total_lines" -gt "$MAX_SNIPPET_LINES" ]]; then
                content+=$'\n'"... (截断，共 $total_lines 行)"
            fi

            results=$(echo "$results" | jq \
                --arg path "$rel_path" \
                --arg content "$content" \
                '. += [{"path": $path, "content": $content}]')
        done < <(find "$project_dir" -maxdepth "$SCAN_DEPTH" -name "$name" \
            -not -path "*/node_modules/*" \
            -not -path "*/.git/*" \
            -not -path "*/.swarm-worktrees/*" \
            2>/dev/null)
    done

    echo "$results"
}

# 收集用户自定义的验证配置（如果存在）
collect_user_verify_config() {
    local project_dir="$1"
    local verify_file="$project_dir/.swarm/verify.json"

    if [[ -f "$verify_file" ]]; then
        jq '.' "$verify_file" 2>/dev/null || echo "{}"
    else
        echo "{}"
    fi
}

# =============================================================================
# 主入口
# =============================================================================

main() {
    local project_dir="${1:-}"
    local output_file="${2:-$RUNTIME_DIR/project-info.json}"

    [[ -n "$project_dir" ]] || die "用法: swarm-scan.sh <项目目录> [输出文件路径]"
    [[ -d "$project_dir" ]] || die "项目目录不存在: $project_dir"

    project_dir="$(cd "$project_dir" && pwd)"
    log_info "开始收集项目信息: $project_dir"

    # 1. 文件树
    log_info "收集文件树..."
    local file_tree
    file_tree=$(collect_file_tree "$project_dir")
    local file_count
    file_count=$(echo "$file_tree" | wc -l | tr -d ' ')
    log_info "  共 $file_count 个文件/目录"

    # 转为 JSON 数组
    local file_tree_json
    file_tree_json=$(echo "$file_tree" | jq -R '.' | jq -s '.')

    # 2. 关键配置文件内容
    log_info "收集关键配置文件..."
    local snippets_json
    snippets_json=$(collect_key_file_snippets "$project_dir")
    local snippet_count
    snippet_count=$(echo "$snippets_json" | jq 'length')
    log_info "  发现 $snippet_count 个关键文件"

    # 3. 用户自定义验证配置
    local user_verify_json
    user_verify_json=$(collect_user_verify_config "$project_dir")

    # 4. 输出
    mkdir -p "$(dirname "$output_file")"
    jq -n \
        --arg scanned_at "$(get_timestamp)" \
        --arg project_dir "$project_dir" \
        --argjson file_tree "$file_tree_json" \
        --argjson key_files "$snippets_json" \
        --argjson user_verify "$user_verify_json" \
        '{
            scanned_at: $scanned_at,
            project_dir: $project_dir,
            file_tree: $file_tree,
            key_files: $key_files,
            user_verify: $user_verify,
            verify_commands: {},
            context_summary: ""
        }' > "$output_file"

    log_info "项目信息已写入: $output_file"
    echo "$output_file"
}

main "$@"
