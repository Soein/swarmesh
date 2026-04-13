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

### 2. 发起投票

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-vote.sh" ask \
    --question "<问题正文>" \
    [--participants cx,cl,gem] \
    [--timeout 180]
```

记下返回的 `vote_id`（形如 `vote-1728000000-12345`）。

### 3. 等参与者回答（至少 30-60 秒，根据 CLI 响应速度）

### 4. 收集回答

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-vote.sh" collect --id <vote_id>
```

未收齐可以多次执行。

### 5. 生成汇总报告

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/lib/discuss-vote.sh" report --id <vote_id>
```

输出 markdown，每人独立一节 + 合并关键词统计。可直接把结果展示给用户。

## 典型用例

```bash
/swarm-chat ~/app codex cx          # 起 Codex
/swarm-chat-add cl "claude"         # 加 Claude
/swarm-chat-add gm "gemini"         # 加 Gemini
/swarm-vote "Redis vs DynamoDB 做会话缓存，哪个更合适？请独立判断"
# ...等 1 分钟...
# （由 Claude Code 主会话）按 vote_id 执行 collect + report
```

## 注意

- v0.2 的 `collect` 是**半自动**：从 pane capture 提取"问题之后的新文本"作为回答。遇到 CLI 格式特殊（如大量装饰行）可能提取不完整，可以重试。
- 未来 v0.3 会交给 watcher 自动在"问题之后、提示符再现"时捕获。

$ARGUMENTS
