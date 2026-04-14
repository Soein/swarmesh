---
name: swarm-vote
description: 对 discuss 参与者做隔离投票——每人独立回答同一个问题，最后结构化汇总（对标 pal consensus）
---

对当前 discuss session 的所有参与者（或指定子集）发起**隔离投票**：同一个问题同时 paste 给每人，彼此看不到对方答案，最后汇总成 markdown。

与 `/swarm-chat-msg` 的区别：**无广播、无 @点名、无相互看见**——防止羊群效应。

## 执行步骤

### 1. 前提：discuss session 已启动且至少有 2 个参与者

```bash
jq -r '.mode' .swarm/runtime/state.json    # 必须是 discuss
jq -r '.discuss.participants | length' .swarm/runtime/state.json  # >= 2
```

如果没有，先 `/swarm-chat` + `/swarm-chat-add`。

### 2. 发起投票（v0.3+ 自动收集 + 稳定性判定）

```bash
VOTE_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-vote.sh" ask \
    --question "<问题正文>" \
    [--participants cx,cl,gem] \
    [--timeout 180] \
    [--min-responses 2] | tail -1)
```

后台每 5 秒 collect 一次。v0.3-A 起收集采用"hash 不变 + 命中提示符"连续 N 次稳定判定，避免半途截断。所有人答完或超时自动出 `report.md`。

### 3. 等 30-60 秒后查看报告

```bash
cat .swarm/runtime/discuss/votes/$VOTE_ID/report.md
```

或主动出最新版：

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-vote.sh" report --id $VOTE_ID
```

### 高级：禁用自动收集

```bash
VOTE_AUTO_COLLECT=0 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-vote.sh" ask --question "..."
```
然后手动调 `collect` + `report`。

## v0.4 表决语义

- **Marker 抽取**：paste 时要求 CLI 把最终答案包在 `<<<VOTE_<id>_START>>>` / `<<<VOTE_<id>_END>>>` 之间。抽取优先读 marker 内文本；CLI 不听话时自动回退到 v0.3 启发式路径。
- **弃权 (ABSTAIN)**：参与者在 marker 内只写 `ABSTAIN: <理由>` 即表示弃权。产物落在 `abstain-<name>.md`（不记入共识计算），report 单列"## 弃权"段。
- **Quorum**：`--min-responses N` 要求至少 N 个实质回答；未达时 report 顶部加"⚠️ 投票未达法定数"警告，LLM 综合 prompt 同步注明。
- **回写 discuss jsonl**：若当前在 discuss session 中，report 生成后会追加一行 `type=vote_report` 到 `runtime/discuss/session.jsonl`。只落盘不 paste，promote 默认忽略（仅 type=message）。

## 环境变量

| Env | 默认 | 说明 |
|---|---|---|
| `VOTE_AUTO_COLLECT` | 1 | 0 关闭后台自动 collect，完全手动 |
| `VOTE_STABLE_HITS` | 2 | 稳定性判定所需连续 quiet+prompt 次数 |
| `VOTE_DEFAULT_TIMEOUT` | 120 | 后台 collect 最长等待秒数 |
| `VOTE_LLM_DISABLE` | 0 | 1 跳过 LLM 综合，直接用关键词段 |
| `VOTE_LLM_CMD` | 自动探测 | 指定 headless CLI，如 `claude -p` / `codex exec` / `gemini -p` |
| `VOTE_LLM_TIMEOUT` | 90 | LLM 综合调用超时秒数 |

## 典型用例

```bash
/swarm-chat ~/app codex cx          # 起 Codex
/swarm-chat-add cl "claude"         # 加 Claude
/swarm-chat-add gm "gemini"         # 加 Gemini
/swarm-vote "Redis vs DynamoDB 做会话缓存，哪个更合适？请独立判断"
# ...等 1 分钟...
cat .swarm/runtime/discuss/votes/$VOTE_ID/report.md
```

$ARGUMENTS
