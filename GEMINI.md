# GEMINI.md — SayKey 项目规则（Antigravity / Gemini 必读）

**完整规则在 [AGENTS.md](AGENTS.md)，当前状态和待办在 [docs/交接.md](docs/交接.md)。开始任何工作前先读这两个文件。**

下面是最重要的几条，和 AGENTS.md 一致，冲突时以 AGENTS.md 为准：

1. 用中文和 Jeremy 交流，解释要直白（他刚接触 Git / CI）。
2. **PR 标题和描述用中文；代码、注释、commit message 用英文。**
3. 开发分支是 `feature/phone-asr`。每项工作新开分支，PR 合回 `feature/phone-asr`。不要动 `main`。
4. **不要改 Bundle ID**（`org.capswriterlab.*`），**不要改安装包文件名** `CapsWriterLab-sideload.ipa`，不要给带 CapsWriter 旧前缀的 target / 文件改名。
5. **永远不要**把令牌、配对码、个人热词、录音写进代码、文档或 commit。发布令牌在 GitHub Secrets 里叫 `RELEASES_TOKEN`，只提名字。不要碰本地 `private/` 目录。
6. 要发布的改动要在 `project.yml` 里同时加版本号和 build 号（当前 0.4.34 / 47，下一个 0.4.35 / 48），并同步改 `.github/workflows/build-ios.yml` 里的打包校验版本号。
7. iOS 只能在 GitHub Actions 的 Mac 上编译（`build-ios.yml`，手动触发）。模拟器测试默认不跑。
8. 合并 PR 前让 Jeremy 看一眼；一批功能都合并且编译通过后，直接用「只发布」把安装包发到 SideStore 更新地址，不用再问。
9. 隐私第一，能发出去比打磨重要，不要做没要求的大重构。

**现在先做**：docs/交接.md 第 7 节「最新反馈（2026-11-24）」的三项（跳主 App 再跳回的回归、去语气词 / 口吃重复、误触滑动）。
