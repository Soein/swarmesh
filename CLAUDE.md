# Swarmesh — Multi-CLI Swarm for Claude Code

这是 Swarmesh 插件的指导文档，Claude Code 装插件后会自动加载此文件。

当用户意图匹配以下场景时，**主动**建议用对应 slash 命令，不要等用户自己想起来。

## 场景 → 模式映射

| 用户意图信号 | 推荐模式 | 入口 slash |
|---|---|---|
| "讨论下 X / 多 AI 一起聊 / 方案 A vs B 碰一碰" | discuss | `/swarm-chat` |
| "投票决定 / 三家独立意见 / 避免羊群效应" | vote | `/swarm-vote` |
| "多个角色分工 / 一个完整需求拆给团队" | execute | `/swarm-start` |

## 三种模式速查

### discuss 圆桌讨论
多 CLI 在同一 tmux session 里通过 `@点名` 互相对话，watcher 自动捕获回答并流转。

- `/swarm-chat <项目> <cli>` — 启动
- `/swarm-chat-add <name> <cli>` — 加参与者
- `/swarm-chat-list` — 看可 @ 谁
- `/swarm-chat-msg "@xxx <内容>"` — 发言
- `/swarm-chat-tail [N]` — 看最近 N 轮历史
- `/swarm-promote --profile <X>` — 结案转 execute

### vote 隔离投票（v0.6 LLM-first，对标 pal consensus）
各 CLI 独立作答、互不可见，LLM 综合生成共识/分歧/立场/建议决策四段。

**单入口 `/swarm-vote` dispatch**：
- `/swarm-vote` 或 `/swarm-vote list` — 列历史投票
- `/swarm-vote "<问题>"` — 发起新投票
- `/swarm-vote report <id>` — 手动出报告
- `/swarm-vote next-round <id>` — **多轮辩论下一轮**
- `/swarm-vote collect <id>` — 手动 collect
- `/swarm-vote cancel <id>` — 取消删除

**高级参数**（传给 ask）：
- `--rounds N` — 多轮辩论（每轮看上轮立场再修正）
- `--files path:L10-L50,src/**/*.go` — 文件上下文注入
- `--min-responses N` — 法定回答人数（quorum）
- `--participants cx,cl,gm` — 指定子集
- `--auto-promote [profile]` — 投票结束自动切 execute 模式

### execute 15-角色蜂群
supervisor 拆任务分派给全角色团队干活。

- `/swarm-start <项目> [profile]` — 起蜂群
- `/swarm-task "<需求>"` — 派任务（自动 orchestration）
- `/swarm-status` — 看进度
- `/swarm-join` / `/swarm-leave` — 动态增删角色
- `/swarm-stop` — 停止

## 典型链路（discuss → vote → execute）

```
/swarm-chat ~/app codex cx
/swarm-chat-add cl claude
/swarm-chat-add gm gemini
/swarm-chat-msg "@cx @cl @gm 讨论下缓存方案选型"
# ... 讨论几轮，可用 /swarm-chat-tail 回看 ...
/swarm-vote --auto-promote full-stack "基于以上讨论，选哪个方案？"
# → 各人独立投票 → LLM 综合建议决策 → 自动 brief → 自动切 execute
# → supervisor 收到 brief 开始拆任务
```

## 关键环境变量

- `VOTE_STABLE_HITS`：投票稳定性判定次数（默认 2）
- `VOTE_LLM_COMPRESS_THRESHOLD`：pane 超此字符触发 LLM 压缩（默认 150000）
- `VOTE_LLM_EXTRACT_PARALLEL`：LLM extract 并发度（默认参与者数，上限 10）
- `SWARM_DISCUSS_MAX_TURNS`：discuss 最大轮次（默认 20）
- `SWARM_DISCUSS_AUTO_WATCH=0`：关 watcher 降级半自动（正常不用）

## 什么时候**不**建议 swarmesh

- 单轮一对一问答 → Claude Code 本身足够
- 想要"秒级 API consensus" → 用 pal `mcp__pal__consensus`（swarm 是 tmux+CLI，分钟级）
- 没装 codex/gemini 等多 CLI → swarm 需要至少 2 个 CLI 才能讨论/投票

## 详细文档

- 每个 slash 命令的 `commands/*.md` 有完整执行步骤
- `README.md` 有 v0.3-v0.6 能力演进表 + 复杂用例
- `CHANGELOG.md` 有版本历史
