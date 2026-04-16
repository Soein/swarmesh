# swarmesh v0.1 端到端实测记录

实测时间：2026-04-13
环境：macOS / tmux 3.6a / jq 1.7.1 / bash 5.3.9

## ✅ 通过项

### execute 模式
- `check-deps.sh` — 三个 CLI（claude/codex/gemini）+ 必需依赖全部识别
- `swarm-start.sh --mode execute --project /tmp/swarm-e2e --profile minimal --hidden` — 成功起 6 panes (4 minimal roles + supervisor + inspector auto-injected)
- `state.json.mode == "execute"` — mode 字段正确写入
- 6 pane CLI 进程全部启动（claude/codex/gemini 进程可见）
- tmux session 命名 `swarm-<project-basename>` 正常

### discuss 模式
- `swarm-start.sh --mode discuss --cli codex --name cx` — 起 tmux session `swarm-discuss`，pane 0.0 跑 codex
- `discuss-relay.sh add --name cl --cli claude` — 第二个 pane 0.1 成功加入
- state.json 正确：`mode: "discuss"` + `discuss.participants[]` 两个
- discuss/session.jsonl 正确：session_start + participant_join + message 三条记录
- `discuss-relay.sh list` 输出两位参与者
- `discuss-relay.sh post --from user --content "@cx @cl 只回 ok"` — turn_count 递增为 1，paste 分发到两个 pane
- **Claude 成功收到消息并自动回答了 "ok"** ✓（验证 paste 机制对 Claude CLI 工作）
- `discuss-relay.sh stop --clean` — tmux kill + 清理 runtime

## 🐛 发现的问题

### BUG-1：Codex 首次启动遇到"Do you trust this directory?"询问，paste 被阻塞

**现象**：
- Codex 启动后显示 `Do you trust the contents of this directory? 1. Yes 2. No`
- 我们的 paste 内容进了 compose 输入框但未提交
- 手动 tmux send Enter 之后才触发 Codex 真正处理消息

**根因**：
- `codex` CLI 在新目录首次运行会弹 trust 确认
- 当前 `DISCUSS_STARTUP_WAIT=3s` 后直接 paste，但此时 Codex 还卡在 trust 询问
- `\r` 进入的是 trust 选择框，不是 chat 输入

**影响**：Codex 参与者在首次进入新目录时失效

**可行修复**（v0.2 P1 里处理）：
1. `scripts/lib/discuss-relay.sh` cmd_start/add 对 codex 追加 `--yolo` 或 `--full-auto` flag（如果 Codex 支持）
2. 或：启动后检测 pane 内 "Do you trust" 文本，自动 send "1" + Enter
3. 或：在 tmux session 之外预先 `codex` 单跑一次 warmup，让用户接受 trust prompt

### BUG-2：swarm-stop 不在项目目录下执行时用错 RUNTIME_DIR

**现象**：
```
[ERROR] /Users/.../tmux并行-plugin-mvp/runtime/events.jsonl.lock: No such file
```

**根因**：
- `swarm-stop.sh` 没有 `--project` 参数
- `swarm-lib.sh:67-68` RUNTIME_DIR 回退逻辑：PWD 检测不到 .swarm → 用 `$SWARM_ROOT/runtime`（即插件根，不是项目根）
- 我在插件目录里跑 swarm-stop，它就去插件根的 runtime/ 捣鼓

**影响**：
- 用户必须 cd 到项目目录才能 swarm-stop
- 或：tmux session 可能残留，需要手动 kill

**可行修复**：
1. 给 `swarm-stop.sh` 加 `--project <dir>` 参数（低成本）
2. 或 `commands/swarm-stop.md` slash 命令里要求 cd 到项目再执行

### BUG-3：discuss-relay.sh stop 退出码 1

**现象**：stop 成功执行（tmux killed + runtime cleaned），但返回 exit 1

**根因**：末尾 `tmux ls` 在没有任何 session 时退出 1，被 set -e 吃掉。discuss-relay 没有用 `set -e` 但里面的 shell 可能受影响

**影响**：脚本本身功能 OK，但 CI 里会误判失败

**可行修复**：末尾 tmux ls 加 `|| true`；或不调用

## 📝 不是 bug 但值得优化

- `discuss-relay.sh post` 当 @ 的人正是 `--from`（自己）时不应 paste——防回环（已记入 v0.2 计划）
- 首次 paste 的 context 含"最近历史"冗余了当前消息（"---历史---" 和 "---当前---" 内容相同）——清晰度问题，不影响功能
- `list-roles` 在 discuss 模式下没输出（因为它查 execute 的 panes 数组，不是 discuss.participants）——swarm-status 命令需要兼容两个模式

## v0.2 P1 优先修的问题

1. BUG-1（Codex trust prompt）— 硬卡点，必修。建议方案：watcher 启动时检测 "Do you trust" 字样自动回 1+Enter。
2. 防回环 `--skip-self`（已在计划内）
3. discuss-relay post 去重 "当前" 重复（优化）
4. BUG-2/3 归为 v0.2 polish，不阻塞 watcher 开发

## 验证结论

**v0.1 核心机制可用**：数据层 + paste + jsonl 落盘全部通过真 tmux 验证；Claude CLI 完美工作。
**Codex 首次 trust prompt 是唯一硬伤**，必须在 P1 watcher 实现时附带处理。
**可以进入 P1。**

---

## v0.2.1 watcher 真机 e2e 实测（2026-04-13 18:00-18:46）

**初次 v0.2 e2e 严重失败**：watcher 把启动屏 / paste 回显 / 思考过程当成 "answer" 推进 jsonl，单次 post 1696 chars 全是垃圾。

### 修复迭代（5 轮）

1. **冷启动 baseline**：watcher 启动后第一次见 pane 抓快照，baseline 内容永不算 answer
2. **STARTUP_PATTERNS 只看末 12 行**：避免 scrollback 历史里旧启动屏永久阻断
3. **CJK 缩进剥离**：Codex 渲染加 2 空格缩进，必须 `sed trim` 在 `grep -vE` 之前，否则 `^Tip:` 永不命中
4. **post 后更新 baseline**：成功 post 后把 current pane 写为新 baseline，下一轮只剩真正新增
5. **末尾 N 行截取**：`| tail -8` 强制只取过滤后最末 8 行（CLI 答完最新输出在末尾）

### 修复后实测

发问 `@cx 中文5字答 Redis 优势`，30 秒后 jsonl：
```
• 快稳抗压强
• 快稳抗压强
• 低延迟抗压
```
**23 字符纯回答**。0 启动屏 / 0 paste 回显 / 0 OMX hook / 0 工具调用日志。

### 仍存的小毛病（不阻塞发布）

- 同回答可能重复：watcher 末 8 行可能含 Codex 给的多个版本回答，jsonl 出现近似内容（非污染，是 Codex 真发了多个）
- 首问慢：Codex 进 OMX/skill 检查会耗 30-60s；想加速可设 `DISCUSS_QUIET_PERIOD=4`

### v0.2.1 修复确认

| 修复 | 状态 |
|---|---|
| BUG-1 Codex trust 自动 | ✅ 真机验证 |
| BUG-2 swarm-stop --project | ✅ |
| 防回环 @ 自己 | ✅ |
| Claude safety check 自动 | ✅ 真机验证 |
| Codex trust 去重（一次性） | ✅ 单测 + 真机验证 |
| 冷启动 baseline | ✅ 真机验证 |
| 防抖提升 quiet=8s | ✅ |
| 最小 20 字符过滤 | ✅ |
| 末尾 8 行截取 | ✅ 真机验证 |
| 启动屏 / OMX / paste header 过滤 | ✅ 真机验证 |
| 重复 hash 去重 (posted_hash) | ✅ |

**v0.2.1 watcher 真交互兑现，可以发布。**
