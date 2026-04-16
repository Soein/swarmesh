---
name: swarm-vote
description: Run isolated multi-AI voting with LLM consensus analysis—independent judgment, no groupthink. Dispatcher for ask/list/report/next-round/cancel subcommands. Use when user asks to "vote on X", "get independent opinions", "consensus from 3 AIs", "投票决定 / 独立判断 / 三家意见 / 避免羊群效应", supports multi-round debate and file context injection.
---

# Swarmesh vote — LLM-first isolated consensus

各 CLI 独立作答、互不可见，LLM 综合生成共识/分歧/立场/建议决策四段。

## 1. 定位 plugin root

```bash
# Locate swarmesh plugin root (优先 $SWARM_ROOT env)
if [[ -z "${SWARM_ROOT:-}" || ! -d "$SWARM_ROOT/scripts" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -type d -name scripts 2>/dev/null \
        | grep -E '/swarmesh/[^/]+/scripts$' | head -1 | sed 's|/scripts$||')
fi
[[ -n "${SWARM_ROOT:-}" && -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 swarmesh plugin root，请 export SWARM_ROOT=/path/to/swarmesh"; exit 1; }
```

## 2. 解析意图（dispatcher，bash 先行确定）

**不要让 LLM 自由判断**。先用 bash 按第一个 token 硬路由：

```bash
# 参数解析：$1 = 第一个 token，$2+ = 剩余参数
_FIRST="${1:-}"
case "$_FIRST" in
    "" | list)
        "$SWARM_ROOT/scripts/lib/discuss-vote.sh" list
        exit $?
        ;;
    report | collect | next-round | cancel)
        _ID="${2:-}"
        [[ -n "$_ID" ]] || { echo "⚠ $_FIRST 需要 vote-id 作为第 2 个参数"; exit 1; }
        "$SWARM_ROOT/scripts/lib/discuss-vote.sh" "$_FIRST" --id "$_ID"
        exit $?
        ;;
    *)
        # 其他文本视作问题正文，走 ask 流程（见 §3）
        _QUESTION="$*"
        ;;
esac
```

**dispatch 表**：

| 第一个 token | 行为 |
|---|---|
| 空 / `list` | `list` 列历史 |
| `report <id>` | `report --id <id>` |
| `collect <id>` | `collect --id <id>` |
| `next-round <id>` | `next-round --id <id>`（多轮辩论） |
| `cancel <id>` | `cancel --id <id>` |
| 其他任何文本 | 作为"问题"走 §3 ask |

示例：
```
$swarm-vote                           # 列历史
$swarm-vote list                      # 列历史（显式）
$swarm-vote report vote-xxx-abc       # 看报告
$swarm-vote next-round vote-xxx-abc   # 下一轮
$swarm-vote cancel vote-xxx-abc       # 取消
$swarm-vote "Redis vs Dynamo？"        # 发起新投票
```

## 4. ask 流程（发起新投票）

### 前提：discuss session 已启动 + ≥2 参与者

```bash
MODE=$(jq -r '.mode' .swarm/runtime/state.json)
[[ "$MODE" == "discuss" ]] || { echo "⚠️ 必须先 \$swarm-chat 启动"; exit 1; }
jq -r '.discuss.participants | length' .swarm/runtime/state.json  # >= 2
```

### 发起

```bash
VOTE_ID=$("$SWARM_ROOT/scripts/lib/discuss-vote.sh" ask \
    --question "<问题正文>" \
    [--participants cx,cl,gm] \
    [--timeout 180] \
    [--min-responses 2] \
    [--rounds 3] \
    [--files 'src/**/*.go:L10-L50,README.md'] \
    [--auto-promote full-stack] | tail -1)
```

后台每 5 秒 collect。v0.3-A 起用"hash 不变 + 命中提示符"连续 N 次稳定判定。所有人答完或超时自动出 `report.md`。

### 查看报告

```bash
cat .swarm/runtime/discuss/votes/$VOTE_ID/report.md
```

或主动出最新版：

```bash
"$SWARM_ROOT/scripts/lib/discuss-vote.sh" report --id $VOTE_ID
```

## 5. v0.6 关键特性

- **LLM-assisted extract**：pane 原文喂 headless CLI 返回结构化 JSON（v0.5）
- **Stance 分组**：LLM 打 pro/con/neutral/other 标签，report 按立场聚段（v0.5.1）
- **多轮辩论**：`--rounds N` + `next-round` 子命令，每轮看上轮立场修正（v0.5.2）
- **pane 无限 + LLM 压缩**：超 150K 字符自动压缩（v0.6.0）
- **--files 文件注入**：支持 glob + 行号范围（v0.6.1）
- **--auto-promote**：最终轮 LLM 综合建议决策 → 自动生成 brief → 切 execute（v0.6.2）

## 关键 env

| Env | 默认 | 说明 |
|---|---|---|
| `VOTE_STABLE_HITS` | 2 | 稳定性判定次数 |
| `VOTE_LLM_COMPRESS_THRESHOLD` | 150000 | pane 字符超此值触发压缩 |
| `VOTE_LLM_EXTRACT_PARALLEL` | pending 人数 | LLM extract 并发度 |
| `VOTE_LLM_EXTRACT_MAX` | 10 | 并发硬上限 |

## 典型用例

```bash
# 代码评审型投票
$swarm-vote --files 'scripts/lib/*.sh:L1-L100,docs/ARCHITECTURE.md' \
    "这些代码该不该重构？"

# 多轮辩论
ID=$($swarm-vote --rounds 3 --question "方案 A vs B？")
$swarm-vote collect $ID
$swarm-vote report $ID
$swarm-vote next-round $ID
# ... 重复直到最终轮

# 全自动闭环
$swarm-vote --auto-promote full-stack "下一步做什么？"
# → 投票 → LLM 综合 → 建议决策 → 自动 brief → 切 execute → supervisor 开工
```
