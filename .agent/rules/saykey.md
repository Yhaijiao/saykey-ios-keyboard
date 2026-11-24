---
trigger: always_on
---

# SayKey 项目规则

开始工作前先读仓库根目录的 `AGENTS.md`（完整规则）和 `docs/交接.md`（当前状态、待办、运行环境）。

核心规则（与 AGENTS.md 一致，冲突时以 AGENTS.md 为准）：

- 用中文和 Jeremy 交流，解释直白，他刚接触 Git / CI。
- PR 标题和描述用中文；代码、注释、commit message 用英文。
- 开发分支 `feature/phone-asr`；每项工作新开分支，PR 合回它。不要动 `main`。
- 不改 Bundle ID（`org.capswriterlab.*`）、不改安装包文件名 `CapsWriterLab-sideload.ipa`、不改带 CapsWriter 旧前缀的 target / 文件名。
- 绝不写入或打印令牌、配对码、个人热词、录音。发布令牌是 GitHub Secret `RELEASES_TOKEN`，只提名字。不碰 `private/`。
- 要发布的改动在 `project.yml` 同时加 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。
- iOS 只在 GitHub Actions 的 Mac 上编译（`build-ios.yml` 手动触发），模拟器测试默认不跑。
- 合并前让 Jeremy 看 PR；一批合并且编译通过后直接发布，不用再问。
- 隐私第一；能发出去比打磨重要；不做没要求的大重构。
- 现在先做：docs/交接.md 第 7 节「最新反馈（2026-11-24）」的三项。
