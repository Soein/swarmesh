# Contributing to Swarmesh

## 开发环境

```bash
git clone https://github.com/Soein/swarmesh
cd swarmesh

# 依赖
brew install tmux jq                    # macOS
# 可选：至少一个 AI CLI 做真 E2E
#   claude (Anthropic) / codex (OpenAI) / gemini (Google)
```

## 跑测试

```bash
bash tests/test-discuss-vote.sh      # 85/85
bash tests/test-discuss-relay.sh     # 17/17
bash tests/test-discuss-watcher.sh   # 22/22
# + 其他 6 个套件（kernel / permissions / playbook / 等）
```

所有测试都走 mock（tmux / LLM / CLI 全部 shell 函数替身），不真起 tmux session，不真调 LLM CLI。

## 提 PR

1. 建议先开 issue 讨论方向
2. commit 消息遵循 [Conventional Commits](https://www.conventionalcommits.org/)：
   - `feat:` 新功能
   - `fix:` 修 bug
   - `docs:` 文档
   - `chore:` 杂项
3. **新功能必须带测试**。参考 `tests/test-discuss-vote.sh` 的 mock 模式
4. 跑全量测试套件绿再提
5. 大改动先在 `docs/superpowers/plans/` 或 issue 里写 plan

## 架构

- `scripts/lib/*.sh` — 核心库（discuss-relay / discuss-vote / discuss-watcher）
- `scripts/swarm-*.sh` — 用户入口脚本（供 slash commands 调用）
- `commands/*.md` — Claude Code slash command 声明
- `config/profiles/*.json` — 角色团队配置
- `config/roles/*.md` — 角色 prompt

## 代码风格

- Bash 3.2 兼容（macOS 默认版本）
- `set -uo pipefail` 严格模式
- 注意：中文全角标点（`，。（）`）会被 bash `set -u` 吞进变量名，变量引用务必用 `${var}` 形式而非 `$var`

## 许可证

BSL-1.1（见 `LICENSE`）。贡献者保留版权，同时授予项目 BSL-1.1 分发权。
