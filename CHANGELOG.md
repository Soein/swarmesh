# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.7.0] - 2026-04-16
### Added
- **Codex CLI 插件适配**：同 repo 双平台支持
  - `.codex-plugin/plugin.json` Codex manifest
  - `.agents/plugins/marketplace.json` repo-level marketplace
  - `AGENTS.md` Codex 引导文档（CLAUDE.md 的 Codex 版本）
  - `skills/` 下 13 个 SKILL.md（按 agentskills.io 标准，description 含 "what + when" + quoted phrases）
  - 每个 skill body 内置 `SWARM_ROOT` 探测 snippet（`~/.codex/plugins/cache` 兜底）
  - README 加 Codex 安装段

### Changed
- Claude Code 和 Codex 共享 `scripts/` 同一套 bash 代码（CLI-agnostic，`BASH_SOURCE` 自推导）
- Claude Code 版 `commands/*.md` 保持不变，确保 v0.6.4 行为零回归

## [0.6.4] - 2026-04-15
### Fixed
- `_vote_hit_prompt` tail -6 → -20，覆盖 Claude TUI 8 行状态栏（E2E 发现的 production-killer bug）

## [0.6.3] - 2026-04-15
### Fixed
- auto-promote 仅在最终轮触发，避免多轮辩论中途 kill discuss session

## [0.6] - 2026-04-15
### Added
- **pane 无限 capture + LLM 压缩兜底** (v0.6.0): `tmux capture-pane -S -` 抽全部 scrollback，超 150K 字符自动 LLM 压缩
- **`--files` 文件上下文注入** (v0.6.1): 单文件 / 行号范围 / glob (`src/**/*.go:L10-L50`)，对标 pal relevant-files
- **`--auto-promote` 自动化闭环** (v0.6.2): 最终轮 LLM 综合 "## 建议决策" 段 → 自动 brief → promote 到 execute
- `discuss-relay.sh promote --brief-file <path>`: 支持外部 brief 替代自动生成

## [0.5] - 2026-04-14
### Added
- **LLM-assisted collect** (v0.5.0): 彻底删除 marker/启发式黑名单，pane 原文喂 headless CLI 返回 `{status, content, abstain_reason, confidence, stance}` JSON
- **Stance 自动分组** (v0.5.1): report 按 pro/con/neutral/other 聚段
- **多轮辩论** (v0.5.2): `--rounds N` + `next-round` 子命令，每轮看上轮立场后修正
- **UX 收尾** (v0.5.3): UUID vote_id + `list` / `cancel` 子命令

### Removed
- v0.4 的 awk marker 硬抽取 + v0.3 启发式 grep -vE 15-模式黑名单

## [0.4] - 2026-04-14
### Added
- Marker 锚点抽取 + 启发式回退
- Abstain 语义 (ABSTAIN: 前缀) + report 弃权段
- Quorum / `--min-responses` 法定人数判定
- Vote report 单向回写 discuss session.jsonl (`type=vote_report`)

## [0.3] - 2026-04-14
### Added
- vote collect 接入 watcher 式稳定性判定 (hash + prompt + quiet_hits)
- LLM 驱动的共识/分歧/各方立场/建议决策四段综合分析
- `DISCUSS_SESSION_NAME` 按项目派生（消除同机多项目 discuss 冲突）

## [0.2.2] - 2026-04-14
### Fixed
- discuss-vote 后台 self-spawn 用 `$0` 导致 fork 炸弹（改 `${BASH_SOURCE[0]}`）
- discuss/watcher/vote 清单清扫 + test 去硬编码行号

## [0.2.1] - 2026-04-13
### Fixed
- watcher 真交互兑现 + swarm-stop 路径修复

## [0.2] - 2026-04-13
### Added
- 真交互（pane watcher 自动流转 CLI 回答）
- 隔离投票（对标 pal consensus）
- e2e 记录

## [0.1] - 2026-04
### Added
- 初始版本：execute 模式 / 15 角色 / supervisor 编排 / profile 系统
