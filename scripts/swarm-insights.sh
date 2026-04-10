#!/usr/bin/env bash
################################################################################
# swarm-insights.sh - capability / playbook / candidate 工具
#
# 用法:
#   swarm-insights.sh validate-capabilities [file]
#   swarm-insights.sh validate-playbook <file>
#   swarm-insights.sh resolve-capability <capability>
#   swarm-insights.sh suggest-playbook <group-id>
#   swarm-insights.sh approve-playbook <candidate-file> --as <playbook-id>
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/swarm-lib.sh"

ORCHESTRATION_DIR="${CONFIG_DIR}/orchestration"
CAPABILITIES_FILE="${ORCHESTRATION_DIR}/capabilities.json"
PLAYBOOKS_DIR="${ORCHESTRATION_DIR}/playbooks"
CANDIDATES_DIR="${RUNTIME_DIR}/playbook-candidates"

usage() {
    cat <<'EOF'
swarm-insights.sh - capability / playbook / candidate 工具

用法:
  swarm-insights.sh validate-capabilities [file]
  swarm-insights.sh validate-playbook <file>
  swarm-insights.sh resolve-capability <capability>
  swarm-insights.sh suggest-playbook <group-id>
  swarm-insights.sh approve-playbook <candidate-file> --as <playbook-id>
EOF
}

require_file() {
    local file="$1"
    [[ -f "$file" ]] || die "文件不存在: $file"
}

load_capabilities_json() {
    require_file "$CAPABILITIES_FILE"
    cat "$CAPABILITIES_FILE"
}

validate_capabilities_json() {
    local file="${1:-$CAPABILITIES_FILE}"
    require_file "$file"

    jq -ce --arg roles_dir "${CONFIG_DIR}/roles" '
        if type != "object" then
            error("capabilities 必须是 JSON 对象")
        else
            .
        end
        | if (.schema_version // 0) == 1 then . else error("schema_version 必须为 1") end
        | .capabilities = (.capabilities // {})
        | if (.capabilities | type) == "object" and (.capabilities | length) > 0 then
              .
          else
              error("capabilities 必须是非空对象")
          end
        | .capabilities |= with_entries(
            .value = (
                if (.value | type) != "object" then
                    error("capability 定义必须是对象")
                else
                    .
                end
                | .preferred_roles = (.preferred_roles // [])
                | .fallback_roles = (.fallback_roles // [])
                | .auto_join = (.auto_join // {enabled:false})
                | if (.preferred_roles | type) == "array" then . else error("preferred_roles 必须是数组") end
                | if (.fallback_roles | type) == "array" then . else error("fallback_roles 必须是数组") end
                | if (.auto_join | type) == "object" then . else error("auto_join 必须是对象") end
                | if ((.auto_join.enabled // false) | type) == "boolean" then . else error("auto_join.enabled 必须是布尔值") end
                | if (.auto_join.enabled // false) then
                    if ((.auto_join.role // "") | type) == "string" and (.auto_join.role // "") != "" then . else error("auto_join.role 不能为空") end
                    | if ((.auto_join.config // "") | type) == "string" and (.auto_join.config // "") != "" then . else error("auto_join.config 不能为空") end
                    | if ((.auto_join.default_cli // "") | type) == "string" and (.auto_join.default_cli // "") != "" then . else error("auto_join.default_cli 不能为空") end
                  else
                    .
                  end
            )
        )
    ' "$file" >/dev/null
}

capability_exists() {
    local capability="$1"
    jq -e --arg capability "$capability" '.capabilities[$capability] != null' "$CAPABILITIES_FILE" >/dev/null 2>&1
}

validate_playbook_json() {
    local file="$1"
    require_file "$file"
    validate_capabilities_json "$CAPABILITIES_FILE"

    jq -ce --slurpfile caps "$CAPABILITIES_FILE" '
        ($caps[0].capabilities // {}) as $capabilities
        | if type != "object" then
            error("playbook 必须是 JSON 对象")
          else
            .
          end
        | if ((.id // "") | type) == "string" and (.id // "") != "" then . else error("playbook.id 不能为空") end
        | if ((.name // "") | type) == "string" and (.name // "") != "" then . else error("playbook.name 不能为空") end
        | if ((.strategy_hint // "") | type) == "string" and (.strategy_hint // "") != "" then . else error("playbook.strategy_hint 不能为空") end
        | .when_to_use = (.when_to_use // [])
        | .risk_checks = (.risk_checks // [])
        | .integration_focus = (.integration_focus // [])
        | .plan_template = (.plan_template // [])
        | if (.when_to_use | type) == "array" then . else error("when_to_use 必须是数组") end
        | if (.risk_checks | type) == "array" then . else error("risk_checks 必须是数组") end
        | if (.integration_focus | type) == "array" then . else error("integration_focus 必须是数组") end
        | if (.plan_template | type) == "array" and (.plan_template | length) > 0 then
              .
          else
              error("plan_template 必须是非空数组")
          end
        | .plan_template |= map(
            if type != "object" then
                error("plan_template 项必须是对象")
            else
                .
            end
            | if has("resolved_role") then error("正式 playbook 禁止出现 resolved_role") else . end
            | if has("dispatch_mode") then error("正式 playbook 禁止出现 dispatch_mode") else . end
            | if ((.id // "") | type) == "string" and (.id // "") != "" then . else error("plan_template[].id 不能为空") end
            | if ((.title // "") | type) == "string" and (.title // "") != "" then . else error("plan_template[].title 不能为空") end
            | if ((.required_capability // "") | type) == "string" and (.required_capability // "") != "" then
                  .
              else
                  error("plan_template[].required_capability 不能为空")
              end
            | .depends_on = (.depends_on // [])
            | if (.depends_on | type) == "array" then . else error("plan_template[].depends_on 必须是数组") end
            | if $capabilities[.required_capability] != null then
                  .
              else
                  error("未知 capability: " + .required_capability)
              end
        )
    ' "$file" >/dev/null
}

candidate_schema_ok() {
    local file="$1"
    require_file "$file"
    jq -ce '
        if type != "object" then
            error("candidate 必须是对象")
        else
            .
        end
        | if (.schema_version // 0) == 1 then . else error("candidate.schema_version 必须为 1") end
        | if ((.source_group_id // "") | type) == "string" and (.source_group_id // "") != "" then . else error("source_group_id 不能为空") end
        | if (.candidate_playbook | type) == "object" then . else error("candidate_playbook 必须是对象") end
        | if ((.status // "") | type) == "string" and (.status // "") == "candidate" then . else error("status 必须为 candidate") end
    ' "$file" >/dev/null
}

capability_definition() {
    local capability="$1"
    jq -c --arg capability "$capability" '.capabilities[$capability]' "$CAPABILITIES_FILE"
}

role_online() {
    local role="$1"
    [[ -f "$STATE_FILE" ]] || return 1
    jq -e --arg role "$role" '.panes[] | select(.role == $role)' "$STATE_FILE" >/dev/null 2>&1
}

resolve_capability() {
    local capability="$1"
    capability_exists "$capability" || die "未知 capability: $capability"

    local definition preferred fallback auto_join_role auto_join_config auto_join_cli
    definition=$(capability_definition "$capability")
    preferred=$(jq -r '.preferred_roles[]?' <<<"$definition")
    fallback=$(jq -r '.fallback_roles[]?' <<<"$definition")
    auto_join_role=$(jq -r '.auto_join.role // ""' <<<"$definition")
    auto_join_config=$(jq -r '.auto_join.config // ""' <<<"$definition")
    auto_join_cli=$(jq -r '.auto_join.default_cli // ""' <<<"$definition")

    local role
    while IFS= read -r role; do
        [[ -z "$role" ]] && continue
        if role_online "$role"; then
            jq -n \
                --arg capability "$capability" \
                --arg mode "existing_role" \
                --arg resolved "$role" \
                --argjson definition "$definition" \
                '{
                    capability: $capability,
                    dispatch_mode: $mode,
                    resolved_role: $resolved,
                    join_command: "",
                    capability_definition: $definition
                }'
            return 0
        fi
    done <<< "$preferred"

    while IFS= read -r role; do
        [[ -z "$role" ]] && continue
        if role_online "$role"; then
            jq -n \
                --arg capability "$capability" \
                --arg mode "fallback_role" \
                --arg resolved "$role" \
                --argjson definition "$definition" \
                '{
                    capability: $capability,
                    dispatch_mode: $mode,
                    resolved_role: $resolved,
                    join_command: "",
                    capability_definition: $definition
                }'
            return 0
        fi
    done <<< "$fallback"

    if jq -e '.auto_join.enabled == true' <<<"$definition" >/dev/null 2>&1; then
        jq -n \
            --arg capability "$capability" \
            --arg mode "new_role" \
            --arg resolved "$auto_join_role" \
            --arg cli "$auto_join_cli" \
            --arg config "$auto_join_config" \
            --argjson definition "$definition" \
            '{
                capability: $capability,
                dispatch_mode: $mode,
                resolved_role: $resolved,
                join_command: ("swarm-join.sh " + $resolved + " --cli " + ($cli | @sh) + " --config " + ($config | @sh)),
                capability_definition: $definition
            }'
        return 0
    fi

    jq -n \
        --arg capability "$capability" \
        --argjson definition "$definition" \
        '{
            capability: $capability,
            dispatch_mode: "unresolved",
            resolved_role: "",
            join_command: "",
            capability_definition: $definition
        }'
}

role_to_capability() {
    local role="$1" title="${2:-}" type="${3:-}" phase="${4:-}"
    local title_lc type_lc phase_lc
    title_lc=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
    type_lc=$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]')
    phase_lc=$(printf '%s' "$phase" | tr '[:upper:]' '[:lower:]')

    case "$role" in
        prd) echo "requirement_analysis"; return 0 ;;
        architect) echo "architecture_design"; return 0 ;;
        backend) echo "backend_dev"; return 0 ;;
        frontend|ui-designer) echo "frontend_dev"; return 0 ;;
        database) echo "database_design"; return 0 ;;
        devops) echo "devops_ops"; return 0 ;;
        tester) echo "testing"; return 0 ;;
        reviewer|auditor)
            if [[ "$title_lc" == *security* || "$title" == *安全* || "$title" == *审计* ]]; then
                echo "security_audit"
            else
                echo "code_review"
            fi
            return 0
            ;;
        integrator) echo "integration"; return 0 ;;
        inspector) echo "verification"; return 0 ;;
        security) echo "security_audit"; return 0 ;;
    esac

    if [[ "$type_lc" == review || "$phase_lc" == verify ]]; then
        echo "verification"
        return 0
    fi

    local mapped
    mapped=$(jq -r --arg role "$role" '
        .capabilities as $caps
        | ($caps | to_entries | map(select((.value.preferred_roles // []) | index($role) != null))) as $preferred
        | if ($preferred | length) > 0 then
              $preferred[0].key
          else
              (($caps | to_entries | map(select((.value.fallback_roles // []) | index($role) != null))) as $fallback
               | if ($fallback | length) > 0 then $fallback[0].key else "" end)
          end
    ' "$CAPABILITIES_FILE" 2>/dev/null) || mapped=""
    if [[ -n "$mapped" && "$mapped" != "null" ]]; then
        echo "$mapped"
        return 0
    fi

    echo "requirement_analysis"
}

task_file_for_group_task() {
    local task_id="$1"
    local dir
    for dir in completed processing pending failed blocked paused pending_review; do
        local file="$TASKS_DIR/$dir/${task_id}.json"
        [[ -f "$file" ]] && { echo "$file"; return 0; }
    done
    return 1
}

canonical_role_name() {
    local raw="$1"
    local resolved=""
    if [[ -f "$STATE_FILE" ]]; then
        resolved=$(jq -r --arg raw "$raw" '
            (.panes[] | select(.instance == $raw) | .role) //
            (.panes[] | select(.role == $raw) | .role) //
            empty
        ' "$STATE_FILE" 2>/dev/null | head -1)
    fi
    if [[ -n "$resolved" ]]; then
        echo "$resolved"
        return 0
    fi
    if [[ "$raw" =~ ^(.+)-[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "$raw"
}

strategy_hint_for_group() {
    local group_file="$1"
    local has_deps
    has_deps=$(jq '[.tasks[]] | length' "$group_file" 2>/dev/null)
    if [[ "${has_deps:-0}" -le 1 ]]; then
        echo "single-track"
        return 0
    fi

    local task_id task_file
    while IFS= read -r task_id; do
        [[ -z "$task_id" ]] && continue
        task_file=$(task_file_for_group_task "$task_id" || true)
        if [[ -n "$task_file" ]] && jq -e '(.depends_on // []) | length > 0' "$task_file" >/dev/null 2>&1; then
            echo "serial-by-dependency"
            return 0
        fi
    done < <(jq -r '.tasks[]' "$group_file" 2>/dev/null)

    echo "parallel-by-module"
}

suggest_playbook() {
    local group_id="$1"
    local group_file="$TASKS_DIR/groups/${group_id}.json"
    local story_file="$RUNTIME_DIR/stories/${group_id}.json"
    require_file "$group_file"
    require_file "$story_file"
    validate_capabilities_json "$CAPABILITIES_FILE"

    mkdir -p "$CANDIDATES_DIR"

    local plan_tmp
    plan_tmp=$(mktemp "${RUNTIME_DIR}/plan-template-XXXXXX")
    local successful_tmp
    successful_tmp=$(mktemp "${RUNTIME_DIR}/successful-seq-XXXXXX")
    local fallback_tmp
    fallback_tmp=$(mktemp "${RUNTIME_DIR}/fallback-usage-XXXXXX")
    local auto_join_tmp
    auto_join_tmp=$(mktemp "${RUNTIME_DIR}/auto-join-XXXXXX")
    local conflict_tmp
    conflict_tmp=$(mktemp "${RUNTIME_DIR}/conflicts-XXXXXX")
    local rework_tmp
    rework_tmp=$(mktemp "${RUNTIME_DIR}/rework-XXXXXX")
    trap "rm -f '$plan_tmp' '$successful_tmp' '$fallback_tmp' '$auto_join_tmp' '$conflict_tmp' '$rework_tmp'" RETURN

    printf '[]' > "$plan_tmp"
    printf '[]' > "$successful_tmp"
    printf '[]' > "$fallback_tmp"
    printf '[]' > "$auto_join_tmp"
    printf '[]' > "$conflict_tmp"
    printf '[]' > "$rework_tmp"

    local task_id task_file title type phase assigned_to role capability depends_json
    while IFS= read -r task_id; do
        [[ -z "$task_id" ]] && continue
        task_file=$(task_file_for_group_task "$task_id" || true)

        if [[ -n "$task_file" ]]; then
            title=$(jq -r '.title // ""' "$task_file")
            type=$(jq -r '.type // ""' "$task_file")
            phase=$(jq -r '.phase // ""' "$task_file")
            assigned_to=$(jq -r '.assigned_to // .claimed_by // ""' "$task_file")
            depends_json=$(jq -c '.depends_on // []' "$task_file")
        else
            title=$(jq -r --arg tid "$task_id" '.tasks[] | select(.id == $tid) | .title // ""' "$story_file")
            type=$(jq -r --arg tid "$task_id" '.tasks[] | select(.id == $tid) | .type // ""' "$story_file")
            phase=$(jq -r --arg tid "$task_id" '.tasks[] | select(.id == $tid) | .phase // ""' "$story_file")
            assigned_to=$(jq -r --arg tid "$task_id" '.tasks[] | select(.id == $tid) | .assigned_to // ""' "$story_file")
            depends_json='[]'
        fi

        role=$(canonical_role_name "$assigned_to")
        capability=$(role_to_capability "$role" "$title" "$type" "$phase")

        jq --arg id "$task_id" --arg title "$title" --arg capability "$capability" --argjson depends "$depends_json" \
            '. += [{
                id: $id,
                title: (if $title == "" then $id else $title end),
                required_capability: $capability,
                depends_on: $depends
            }]' "$plan_tmp" > "${plan_tmp}.tmp" && mv "${plan_tmp}.tmp" "$plan_tmp"

        if [[ -n "$task_file" ]] && jq -e '.status == "completed"' "$task_file" >/dev/null 2>&1; then
            jq --arg task "$task_id" '. += [$task]' "$successful_tmp" > "${successful_tmp}.tmp" && mv "${successful_tmp}.tmp" "$successful_tmp"
        fi

        if [[ -n "$task_file" ]] && jq -e '.status == "failed"' "$task_file" >/dev/null 2>&1; then
            jq --arg task "$task_id" '. += [$task]' "$rework_tmp" > "${rework_tmp}.tmp" && mv "${rework_tmp}.tmp" "$rework_tmp"
        fi

        if [[ "$title" == *冲突* || "$title" == *conflict* ]]; then
            jq --arg task "$task_id" '. += [$task]' "$conflict_tmp" > "${conflict_tmp}.tmp" && mv "${conflict_tmp}.tmp" "$conflict_tmp"
        fi
    done < <(jq -r '.tasks[]' "$group_file" 2>/dev/null)

    local strategy_hint group_title candidate_file ts
    strategy_hint=$(strategy_hint_for_group "$group_file")
    group_title=$(jq -r '.title // "未命名任务组"' "$group_file")
    ts=$(date +%Y%m%d%H%M%S)
    candidate_file="$CANDIDATES_DIR/${ts}-${group_id}.json"

    jq -n \
        --arg group_id "$group_id" \
        --arg title "$group_title" \
        --arg strategy "$strategy_hint" \
        --arg workflow "unknown" \
        --slurpfile plan "$plan_tmp" \
        --slurpfile successful "$successful_tmp" \
        --slurpfile fallback "$fallback_tmp" \
        --slurpfile auto_join "$auto_join_tmp" \
        --slurpfile conflicts "$conflict_tmp" \
        --slurpfile rework "$rework_tmp" \
        '{
            schema_version: 1,
            source_group_id: $group_id,
            derived_from: {
                workflow: $workflow,
                task_ids: ($successful[0] + ($rework[0] // []))
            },
            candidate_playbook: {
                id: ("candidate-" + $group_id),
                name: ("候选：" + $title),
                when_to_use: [
                    "基于历史任务组自动归纳生成",
                    "需要人工审核后才能入库"
                ],
                strategy_hint: $strategy,
                plan_template: $plan[0],
                risk_checks: (
                    [
                        (if (($rework[0] // []) | length) > 0 then "存在返工痕迹，需要人工复核计划边界" else empty end),
                        (if (($conflicts[0] // []) | length) > 0 then "历史任务出现冲突线索，需要补充集成关注点" else empty end),
                        (if (($plan[0] | map(.required_capability) | unique | length) > 1) then "跨能力协作需检查接口和职责边界" else empty end)
                    ] | map(select(. != null))
                ),
                integration_focus: (
                    [
                        (if (($plan[0] | map(.required_capability) | index("backend_dev")) != null and ($plan[0] | map(.required_capability) | index("frontend_dev")) != null) then "前后端接口一致性" else empty end),
                        (if (($plan[0] | map(.required_capability) | index("database_design")) != null and ($plan[0] | map(.required_capability) | index("backend_dev")) != null) then "数据库 Schema 与后端读写一致性" else empty end),
                        "多产出汇总说明"
                    ] | map(select(. != null))
                )
            },
            evidence: {
                successful_sequence: $successful[0],
                fallback_usage: $fallback[0],
                auto_join_usage: $auto_join[0],
                integration_conflicts: $conflicts[0],
                rework_signals: $rework[0]
            },
            status: "candidate"
        }' > "$candidate_file"

    echo "$candidate_file"
}

approve_playbook() {
    local candidate_file="$1"
    shift

    local playbook_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --as)
                playbook_id="$2"
                shift 2
                ;;
            *)
                die "approve-playbook: 未知参数 $1"
                ;;
        esac
    done

    [[ -n "$playbook_id" ]] || die "approve-playbook: 缺少 --as <playbook-id>"
    candidate_schema_ok "$candidate_file"
    validate_capabilities_json "$CAPABILITIES_FILE"

    local tmp_playbook
    tmp_playbook=$(mktemp "${RUNTIME_DIR}/approved-playbook-XXXXXX")
    trap "rm -f '$tmp_playbook'" RETURN

    jq --arg playbook_id "$playbook_id" '.candidate_playbook | .id = $playbook_id' "$candidate_file" > "$tmp_playbook"
    validate_playbook_json "$tmp_playbook"

    mkdir -p "$PLAYBOOKS_DIR"
    local target_file="$PLAYBOOKS_DIR/${playbook_id}.json"
    [[ ! -f "$target_file" ]] || die "目标 playbook 已存在: $target_file"
    jq '.' "$tmp_playbook" > "$target_file"
    echo "$target_file"
}

cmd="${1:-}"
case "$cmd" in
    validate-capabilities)
        shift
        validate_capabilities_json "${1:-$CAPABILITIES_FILE}"
        ;;
    validate-playbook)
        shift
        [[ $# -ge 1 ]] || die "用法: swarm-insights.sh validate-playbook <file>"
        validate_playbook_json "$1"
        ;;
    resolve-capability)
        shift
        [[ $# -ge 1 ]] || die "用法: swarm-insights.sh resolve-capability <capability>"
        validate_capabilities_json "$CAPABILITIES_FILE"
        resolve_capability "$1"
        ;;
    suggest-playbook)
        shift
        [[ $# -ge 1 ]] || die "用法: swarm-insights.sh suggest-playbook <group-id>"
        suggest_playbook "$1"
        ;;
    approve-playbook)
        shift
        [[ $# -ge 1 ]] || die "用法: swarm-insights.sh approve-playbook <candidate-file> --as <playbook-id>"
        approve_playbook "$@"
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        die "未知命令: $cmd"
        ;;
esac
