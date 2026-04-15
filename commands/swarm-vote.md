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

## v0.5 表决语义（LLM-first 架构）

- **LLM-assisted 抽取**：v0.4 的 marker/启发式**彻底删除**。collect 稳定性达标后，每人 pane 原文并发喂给 headless CLI，返回 `{status, content, abstain_reason, confidence, stance}` 结构化 JSON。CLI 不可用即报错，不再有降级路径。
- **弃权（ABSTAIN）**：由 LLM 智能识别（任何语言、任何变体），不再依赖 `ABSTAIN:` 硬前缀。
- **Stance 分组**：LLM 给每个答案打 `pro/con/neutral/other` 标签，report 按立场分组展示。
- **Quorum**：`--min-responses N` 要求至少 N 个实质回答（弃权不算）；未达时 report 顶部加"⚠️ 投票未达法定数"。
- **多轮辩论**：`--rounds N` + `next-round` 子命令，第 2 轮起 paste 附上一轮各人立场，要求"维持原判或根据对方论点修正"。
- **vote → discuss jsonl 回写**：`type=vote_report` 事件，promote 默认忽略。
- **UUID vote_id + list/cancel**：同秒并发不碰撞，历史可查可撤。

## v0.6 新增

- **pane 无限化 + LLM 压缩兜底**：`tmux capture-pane -S -` 抽 tmux 底层所有 scrollback，超 `VOTE_LLM_COMPRESS_THRESHOLD`（默认 150000 字符）自动 LLM 压缩后再 extract。长讨论不再丢信息。
- **`--files <spec>` 文件上下文注入**：paste 时把文件内容自动塞进 header。支持单文件 / 行号范围 / glob：
  - `path`、`path:42-120`、`path:L42-L120`
  - `src/**/*.go`、`src/**/*.go:1-50`
- **`--auto-promote [profile]` 自动化闭环**：vote 产出 LLM 综合的"## 建议决策"段 → 自动构造 brief → 调 `discuss-relay.sh promote --brief-file` → 从 discuss 切 execute 模式，无需人肉跑 `/swarm-promote`。

## 环境变量

| Env | 默认 | 说明 |
|---|---|---|
| `VOTE_AUTO_COLLECT` | 1 | 0 关闭后台自动 collect，完全手动 |
| `VOTE_STABLE_HITS` | 2 | 稳定性判定所需连续 quiet+prompt 次数 |
| `VOTE_DEFAULT_TIMEOUT` | 120 | 后台 collect 最长等待秒数 |
| `VOTE_LLM_DISABLE` | 0 | 1 跳过 LLM 综合，直接用关键词段 |
| `VOTE_LLM_CMD` | 自动探测 | 指定 headless CLI，如 `claude -p` / `codex exec` / `gemini -p` |
| `VOTE_LLM_TIMEOUT` | 90 | LLM 综合调用超时秒数 |
| `VOTE_MARKER_START_TMPL` | `<<<VOTE_%s_START>>>` | marker 起始模板（v0.5 仅作 CLI 软提示） |
| `VOTE_MARKER_END_TMPL` | `<<<VOTE_%s_END>>>` | marker 结束模板 |
| `VOTE_LLM_EXTRACT_CMD` | 自动探测 | LLM extract 阶段的 headless CLI（默认复用 `VOTE_LLM_CMD`） |
| `VOTE_LLM_EXTRACT_TIMEOUT` | 30 | LLM extract 单次调用超时秒数 |
| `VOTE_LLM_EXTRACT_PARALLEL` | pending 人数 | LLM extract 并发度 |
| `VOTE_LLM_EXTRACT_MAX` | 10 | LLM extract 并发硬上限（防资源挤爆） |
| `VOTE_LLM_COMPRESS_THRESHOLD` | 150000 | pane 字符数超此值触发 LLM 压缩（≈ 40K token） |
| `VOTE_LLM_COMPRESS_TIMEOUT` | 60 | LLM 压缩调用超时秒数 |
| `VOTE_FILES_MAX_BYTES` | 10485760 | `--files` 注入总字节硬顶（10MB） |

## 典型用例

### 1. 基础三方投票

```bash
/swarm-chat ~/app codex cx          # 起 Codex
/swarm-chat-add cl "claude"         # 加 Claude
/swarm-chat-add gm "gemini"         # 加 Gemini
/swarm-vote "Redis vs DynamoDB 做会话缓存，哪个更合适？请独立判断"
# ...等 1 分钟...
cat .swarm/runtime/discuss/votes/$VOTE_ID/report.md
```

### 2. 带 quorum 的强表决（3 人至少 2 人给实质答案才算数）

```bash
VOTE_ID=$(discuss-vote.sh ask \
    --question "这个 PR 是否可以合并？" \
    --participants cx,cl,gm \
    --min-responses 2 | tail -1)
# 若只有 1 人答：report 顶部会出 "⚠️ 投票未达法定数（1/2）"
```

### 3. 弃权演示（CLI 信息不足时主动声明）

```bash
/swarm-vote "根据已有信息，A 和 B 哪个更安全？"
# 若某 CLI 在 marker 内回：ABSTAIN: 没看到 A/B 的实现代码，无法判断
#  → abstain-<n>.md 落盘，report "## 弃权" 段列出理由
#  → LLM 综合 prompt 自动忽略弃权者
```

### 4. 嵌在 discuss 管道里（vote_report 回写 jsonl）

```bash
# 讨论中...
/swarm-vote "上面几个方案里选哪个？"
# 投票完成后，tail -1 .swarm/runtime/discuss/session.jsonl
# 可见 {"type":"vote_report","vote_id":"...","answered":[...],...}
# 后续 /swarm-promote 不受干扰（默认仅收录 type=message）
```

### 5. 多轮辩论（v0.5）

```bash
VOTE_ID=$(discuss-vote.sh ask --question "方案 A 还是 B？" \
    --participants cx,cl,gm --rounds 3 | tail -1)

# Round 1
discuss-vote.sh collect --id $VOTE_ID      # 等各人独立答
discuss-vote.sh report  --id $VOTE_ID      # 看 R1 综合
discuss-vote.sh next-round --id $VOTE_ID   # 归档 R1 → paste R2 指令

# Round 2
discuss-vote.sh collect --id $VOTE_ID      # 各人看了别人答案后修正
discuss-vote.sh report  --id $VOTE_ID      # R2 综合（有无立场变化）

# Round 3 同理
```

产物组织：
```
runtime/discuss/votes/$VOTE_ID/
    meta.json              # 含 current_round + max rounds
    answer-cx.md           # 当前轮答案（最新）
    meta-cx.json           # 当前轮 stance/confidence
    round1/                # R1 归档
        answer-cx.md
        meta-cx.json
        report.md
    round2/                # R2 归档（R3 开始时归档）
        ...
```

### 6. 查看 / 取消

```bash
discuss-vote.sh list                      # 列历史投票
# vote-1712... [R2/3 | 2/3 答]  方案 A 还是 B？

discuss-vote.sh cancel --id <vote-id>     # 取消并删 vote 目录
```

### 7. 代码评审（v0.6.1 `--files`）

```bash
# 对照一批代码文件 + README 做决策，不用人肉 paste
discuss-vote.sh ask \
    --question "这批 lib 该不该抽象成单独的库？" \
    --participants cx,cl,gm \
    --files 'scripts/lib/*.sh,docs/ARCHITECTURE.md:L1-L50'
# 参与者 pane 里自动看到文件内容块，LLM 基于实码评审
```

### 8. 自动闭环（v0.6.2 `--auto-promote`）

```bash
# 投票 + 自动 promote：讨论 → 投票 → execute 一条龙
discuss-vote.sh ask \
    --question "下一步做哪个？A/B/C" \
    --participants cx,cl \
    --auto-promote full-stack

# 投票完成后自动：
# 1. LLM 综合给出"## 建议决策"段
# 2. 生成 brief-for-promote.md
# 3. 调 discuss-relay.sh promote --brief-file ... --profile full-stack
# 4. tmux session 从 discuss 切到 execute
# 5. supervisor 收到首条消息（建议决策作为 brief）
```

$ARGUMENTS
