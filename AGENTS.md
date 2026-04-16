# Swarmesh — Multi-CLI Swarm for Codex

Codex 装了这个插件后，`skills/` 下的 13 个 skill 会按 description 自动匹配用户意图激活，也可用 `$skill-name` 显式调用或从 `/skills` 菜单选。

## 场景 → Skill 映射

LLM 按 description 自动激活，以下表格帮助匹配判断：

| 用户意图信号 | 推荐 skill | 显式调用 |
|---|---|---|
| "讨论下 X / 多 AI 一起聊 / 方案对比碰一碰" | swarm-chat | `$swarm-chat` |
| "投票决定 / 独立判断 / 避免羊群效应 / 三家意见" | swarm-vote | `$swarm-vote` |
| "多角色分工 / 完整需求拆给团队" | swarm-start | `$swarm-start` |
| "看下当前讨论 / 回看对话 / discuss 历史" | swarm-chat-tail | `$swarm-chat-tail` |
| "当前状态 / 谁在跑 / 进度" | swarm-status | `$swarm-status` |
| "停止 / 结束 / 杀掉" | swarm-stop | `$swarm-stop` |

## 三种模式

### discuss 圆桌讨论
多 CLI 在同一 tmux session 里通过 @点名 互相对话。

| Skill | 作用 |
|---|---|
| `$swarm-chat` | 启动 discuss session，拉起第一个参与者 |
| `$swarm-chat-add` | 加一个新 CLI 参与者 |
| `$swarm-chat-list` | 列出当前参与者（可 @ 谁） |
| `$swarm-chat-msg` | 发消息（@ 点名触发对方接话） |
| `$swarm-chat-tail` | 查看最近 N 轮对话 |
| `$swarm-promote` | 讨论结案 → 自动切 execute |

### vote 隔离投票（v0.6 LLM-first，对标 pal consensus）
各 CLI 独立作答、互不可见，LLM 综合生成共识/分歧/立场/建议决策。

`$swarm-vote` 是 **单入口 dispatcher**，按第一个 token 路由：
- `$swarm-vote`（无参数）— 列历史投票
- `$swarm-vote "<问题>"` — 发起新投票
- `$swarm-vote list` — 列历史
- `$swarm-vote report <id>` — 手动出报告
- `$swarm-vote next-round <id>` — 多轮辩论下一轮
- `$swarm-vote collect <id>` — 手动 collect
- `$swarm-vote cancel <id>` — 取消

**高级参数**：
- `--rounds N` 多轮辩论
- `--files path:L10-L50,src/**/*.go` 文件上下文注入
- `--min-responses N` quorum 法定人数
- `--auto-promote [profile]` 投票完自动切 execute

### execute 15-角色蜂群
supervisor 拆任务分派给全角色团队。

| Skill | 作用 |
|---|---|
| `$swarm-start` | 起蜂群 |
| `$swarm-task` | 派任务给 supervisor |
| `$swarm-join` / `$swarm-leave` | 动态增删角色 |

## 典型链路（discuss → vote → execute）

```
$swarm-chat ~/app codex cx
$swarm-chat-add cl claude
$swarm-chat-add gm gemini
$swarm-chat-msg "@cx @cl @gm 讨论下缓存方案"
# ... 讨论几轮 ...
$swarm-chat-tail 20
$swarm-vote --auto-promote full-stack "选哪个方案？"
# → 投票 → LLM 综合 → 自动切 execute → supervisor 开工
```

## 关键环境变量

- `VOTE_STABLE_HITS`：投票稳定性判定次数（默认 2）
- `VOTE_LLM_COMPRESS_THRESHOLD`：pane 超此字符触发 LLM 压缩（默认 150000）
- `SWARM_DISCUSS_MAX_TURNS`：discuss 最大轮次（默认 20）
- `SWARM_ROOT`：手动指定 plugin 根目录（正常 skills 会自动探测）

## 什么时候**不**推荐 Swarmesh

- 单轮一对一问答 → Codex 本身足够
- "秒级 API consensus" → 用 pal `mcp__pal__consensus`（swarm 是 tmux+CLI，分钟级）
- 没装 claude/gemini 等其它 CLI → swarm 至少需要 2 个 CLI 才能讨论/投票

## Plugin Root 定位

每个 skill body 首部用探测 snippet 定位 plugin 安装路径：
```bash
SWARM_ROOT="${SWARM_ROOT:-}"
if [[ -z "$SWARM_ROOT" ]]; then
    SWARM_ROOT=$(find "$HOME/.codex/plugins/cache" -maxdepth 3 -type d -name 'swarmesh' 2>/dev/null | head -1)
    [[ -n "$SWARM_ROOT" ]] && SWARM_ROOT=$(find "$SWARM_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
fi
[[ -d "$SWARM_ROOT/scripts" ]] || { echo "⚠ 未找到 SWARM_ROOT"; exit 1; }
```

装插件后若探测失败，手动 `export SWARM_ROOT=~/.codex/plugins/cache/.../swarmesh/<version>`。

## 详细文档

- 每个 skill 的 `skills/<name>/SKILL.md` 有完整指令
- `README.md` 有 v0.3-v0.6 能力演进表
- `CHANGELOG.md` 有版本历史
